module auroraopencode_pro_tools_test;

import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.tools : builtinToolDefinitions, executeTool,
    nativeOnlyToolDefinitions, resolveToolPath, toolSteeringPrompt;
import std.array : replicate;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
    write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;
import std.utf : validate;

private OpenCodeToolCall makeCall(string name, string args)
{
    OpenCodeToolCall call;
    call.id = "call_test";
    call.name = name;
    call.arguments = args;
    return call;
}

int main()
{
    const dir = buildPath(tempDir(), "aurora-opencode-tools-test");
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    mkdirRecurse(buildPath(dir, "src"));
    write(buildPath(dir, "src", "main.d"), "import std.stdio;\nvoid main() {}\n");
    write(buildPath(dir, "README.md"), "aurora tools test\n");

    // read a file from the workspace (relative path), prefixed with 1-indexed
    // line numbers so the model has stable edit anchors.
    auto readResult = executeTool(makeCall("read",
        `{"filePath":"src/main.d"}`), dir);
    assert(!readResult.failed, "read failed: " ~ readResult.output);
    assert(readResult.output.indexOf("void main") >= 0,
        "read did not return file contents");
    assert(readResult.output.indexOf("1: import std.stdio;") >= 0,
        "read did not prefix line numbers: " ~ readResult.output);

    // offset/limit page through a file without dumping all of it.
    auto pageRead = executeTool(makeCall("read",
        `{"filePath":"src/main.d","offset":2,"limit":1}`), dir);
    assert(!pageRead.failed, "paged read failed: " ~ pageRead.output);
    assert(pageRead.output.indexOf("2: void main() {}") >= 0,
        "paged read returned the wrong line: " ~ pageRead.output);
    assert(pageRead.output.indexOf("1: import") < 0,
        "paged read leaked earlier lines: " ~ pageRead.output);
    auto pastEnd = executeTool(makeCall("read",
        `{"filePath":"src/main.d","offset":99}`), dir);
    assert(pastEnd.failed, "offset past EOF should fail");

    // Reading a file past the output cap pages with a continuation hint
    // instead of splitting a multibyte character (a raw byte cut used to
    // corrupt UTF-8).
    auto wide = replicate("é\n", 40_000); // 80 000 bytes across 40 000 lines
    write(buildPath(dir, "wide.txt"), wide);
    auto wideRead = executeTool(makeCall("read",
        `{"filePath":"wide.txt"}`), dir);
    assert(!wideRead.failed, "wide read failed: " ~ wideRead.output);
    assert(wideRead.output.indexOf("Use offset=") >= 0,
        "wide read did not offer continuation");
    assert(wideRead.output.length < 60_000,
        "wide read was not bounded to the output cap");
    try validate(wideRead.output);
    catch (Exception error)
        assert(false, "paged read is not valid UTF-8: " ~ error.msg);

    // A single over-long line is truncated with a marker rather than eating
    // the whole output budget.
    write(buildPath(dir, "oneline.txt"), replicate("x", 5_000));
    auto oneLineRead = executeTool(makeCall("read",
        `{"filePath":"oneline.txt"}`), dir);
    assert(!oneLineRead.failed, "one-line read failed: " ~ oneLineRead.output);
    assert(oneLineRead.output.indexOf("(line truncated)") >= 0,
        "over-long line was not truncated: " ~ oneLineRead.output);

    // A non-UTF-8 file is decoded leniently instead of failing the read, and
    // the result is still valid UTF-8 (safe to persist into the session).
    auto latinBytes = cast(ubyte[])"caf\xE9-latin1".dup;
    write(buildPath(dir, "latin1.txt"), latinBytes);
    auto latinRead = executeTool(makeCall("read",
        `{"filePath":"latin1.txt"}`), dir);
    assert(!latinRead.failed, "latin1 read failed: " ~ latinRead.output);
    try validate(latinRead.output);
    catch (Exception error)
        assert(false, "lenient read is not valid UTF-8: " ~ error.msg);
    assert(latinRead.output.indexOf("latin1") >= 0,
        "lenient read lost the file contents: " ~ latinRead.output);
    writeln("read pages, numbers lines, caps long lines, survives non-UTF-8 bytes");

    // edit rejects an identical oldString/newString instead of rewriting the
    // same bytes and claiming success.
    auto sameEdit = executeTool(makeCall("edit",
        `{"filePath":"README.md","oldString":"aurora tools test","newString":"aurora tools test"}`),
        dir);
    assert(sameEdit.failed, "identical edit should fail");
    writeln("edit rejects identical old/new strings");

    // edit falls back to a whitespace-tolerant match when the anchor differs
    // only in indentation (the exact text is absent), instead of failing.
    write(buildPath(dir, "fuzzy.txt"), "void f()\n{\n    return one;\n}\n");
    auto fuzzyEdit = executeTool(makeCall("edit",
        `{"filePath":"fuzzy.txt","oldString":"\treturn one;","newString":"    return two;"}`),
        dir);
    assert(!fuzzyEdit.failed, "fuzzy edit failed: " ~ fuzzyEdit.output);
    assert(readText(buildPath(dir, "fuzzy.txt")).indexOf("return two;") >= 0,
        "fuzzy edit did not apply: " ~ readText(buildPath(dir, "fuzzy.txt")));

    // An ambiguous fuzzy anchor still fails instead of editing an arbitrary
    // one of the matches.
    write(buildPath(dir, "dup.txt"), "  alpha\n    alpha\n");
    auto ambiguousEdit = executeTool(makeCall("edit",
        `{"filePath":"dup.txt","oldString":"\talpha","newString":"beta"}`), dir);
    assert(ambiguousEdit.failed, "ambiguous fuzzy edit should fail");
    writeln("edit tolerates indentation drift but rejects ambiguity");

    // write a new file then read it back
    auto writeResult = executeTool(makeCall("write",
        `{"filePath":"src/generated.txt","content":"hello from tool"}`), dir);
    assert(!writeResult.failed, "write failed: " ~ writeResult.output);
    assert(readText(buildPath(dir, "src", "generated.txt")) ==
        "hello from tool", "write did not persist the content");

    // remove deletes a file, and a directory recursively. This is the native
    // alternative to shelling out to del/rm/Remove-Item.
    auto removeResult = executeTool(makeCall("remove",
        `{"path":"src/generated.txt"}`), dir);
    assert(!removeResult.failed, "remove failed: " ~ removeResult.output);
    assert(!exists(buildPath(dir, "src", "generated.txt")),
        "remove did not delete the file");

    mkdirRecurse(buildPath(dir, "trash", "nested"));
    write(buildPath(dir, "trash", "nested", "deleteme.txt"), "x");
    auto removeDirResult = executeTool(makeCall("remove",
        `{"path":"trash"}`), dir);
    assert(!removeDirResult.failed,
        "remove directory failed: " ~ removeDirResult.output);
    assert(!exists(buildPath(dir, "trash")),
        "remove did not delete the directory tree");

    auto removeMissing = executeTool(makeCall("remove",
        `{"path":"does-not-exist.txt"}`), dir);
    assert(removeMissing.failed, "remove of a missing path should fail");
    writeln("D-native remove tool deletes files and directories");

    // glob with ** recursion
    auto globResult = executeTool(makeCall("glob", `{"pattern":"**/*.d"}`),
        dir);
    assert(!globResult.failed, "glob failed: " ~ globResult.output);
    assert(globResult.output.indexOf("main.d") >= 0,
        "glob did not recurse into src/");

    // grep finds the marker text
    auto grepResult = executeTool(makeCall("grep", `{"pattern":"aurora"}`),
        dir);
    assert(!grepResult.failed, "grep failed: " ~ grepResult.output);
    assert(grepResult.output.indexOf("README.md") >= 0,
        "grep did not find the matching file");
    assert(grepResult.output.indexOf("README.md:1: aurora tools test") >= 0,
        "grep did not return the matching line with a line number: " ~
        grepResult.output);

    // grep honors the documented glob `include` filter. The old filter was a
    // literal suffix test, so "*.d" could never match a real file name.
    write(buildPath(dir, "src", "extra.d"), "needle-marker\n");
    write(buildPath(dir, "src", "extra.txt"), "needle-marker\n");
    auto grepInclude = executeTool(makeCall("grep",
        `{"pattern":"needle-marker","include":"*.d"}`), dir);
    assert(!grepInclude.failed, "grep include failed: " ~ grepInclude.output);
    assert(grepInclude.output.indexOf("extra.d") >= 0,
        "grep include *.d did not match a .d file: " ~ grepInclude.output);
    assert(grepInclude.output.indexOf("extra.txt") < 0,
        "grep include *.d incorrectly matched a .txt file: " ~
        grepInclude.output);
    // A bare extension is accepted too.
    auto grepExt = executeTool(makeCall("grep",
        `{"pattern":"needle-marker","include":".txt"}`), dir);
    assert(!grepExt.failed, "grep include .txt failed: " ~ grepExt.output);
    assert(grepExt.output.indexOf("extra.txt") >= 0,
        "grep include .txt did not match: " ~ grepExt.output);
    writeln("grep include is a glob (and accepts a bare extension)");

    // bash echo round-trips through the shell
    auto bashResult = executeTool(makeCall("bash",
        `{"command":"echo aurora-tool-echo"}`), dir);
    assert(!bashResult.failed, "bash failed: " ~ bashResult.output);
    assert(bashResult.output.indexOf("aurora-tool-echo") >= 0,
        "bash echo output missing: " ~ bashResult.output);

    version (Windows)
    {
        // The shell tool is shell-aware: cmd, PowerShell, and pwsh all work.
        auto cmdResult = executeTool(makeCall("bash",
            `{"command":"echo cmd-ok","shell":"cmd"}`), dir);
        assert(!cmdResult.failed, "cmd failed: " ~ cmdResult.output);
        assert(cmdResult.output.indexOf("cmd-ok") >= 0,
            "cmd echo output missing: " ~ cmdResult.output);

        auto psResult = executeTool(makeCall("bash",
            `{"command":"Write-Output ps-ok","shell":"powershell"}`), dir);
        assert(!psResult.failed, "powershell failed: " ~ psResult.output);
        assert(psResult.output.indexOf("ps-ok") >= 0,
            "powershell output missing: " ~ psResult.output);

        // workdir runs the command in the requested directory.
        auto workdirResult = executeTool(makeCall("bash",
            `{"command":"cd","shell":"cmd","workdir":"src"}`), dir);
        assert(!workdirResult.failed,
            "workdir failed: " ~ workdirResult.output);
        assert(workdirResult.output.indexOf("src") >= 0 ||
            workdirResult.output.indexOf("main.d") >= 0,
            "workdir did not change directory: " ~ workdirResult.output);
        writeln("cmd / powershell / workdir shell selection OK");
    }

    // The D-native `run` tool executes a program directly with an argument
    // list — no shell involved. On Windows use cmd.exe as the program; on
    // Unix use /bin/echo.
    version (Windows)
    {
        auto runResult = executeTool(makeCall("run",
            `{"program":"cmd.exe","args":["/d","/c","echo","run-ok"]}`),
            dir);
        assert(!runResult.failed, "run failed: " ~ runResult.output);
        assert(runResult.output.indexOf("run-ok") >= 0,
            "run did not pass args through: " ~ runResult.output);
        writeln("D-native run tool executes a program directly");
    }
    else
    {
        auto runResult = executeTool(makeCall("run",
            `{"program":"/bin/echo","args":["run-ok"]}`), dir);
        assert(!runResult.failed, "run failed: " ~ runResult.output);
        assert(runResult.output.indexOf("run-ok") >= 0,
            "run did not pass args through: " ~ runResult.output);
        writeln("D-native run tool executes a program directly");
    }

    // The D-native `dshell` tool uses short natural words: where / list /
    // info (the legacy pwd/ls/dir/stat words still work as aliases).
    auto whereResult = executeTool(makeCall("dshell",
        `{"command":"where"}`), dir);
    assert(!whereResult.failed, "dshell where failed: " ~ whereResult.output);
    assert(whereResult.output.indexOf(dir) >= 0,
        "dshell where did not return the workspace path: " ~
        whereResult.output);

    auto listResult = executeTool(makeCall("dshell",
        `{"command":"list"}`), dir);
    assert(!listResult.failed, "dshell list failed: " ~ listResult.output);
    assert(listResult.output.indexOf("README.md") >= 0,
        "dshell list did not show the directory: " ~ listResult.output);
    assert(listResult.output.indexOf("[f]") >= 0,
        "dshell list did not tag file entries: " ~ listResult.output);
    assert(listResult.output.indexOf("[d]") >= 0,
        "dshell list did not tag directory entries: " ~ listResult.output);

    auto infoResult = executeTool(makeCall("dshell",
        `{"command":"info","path":"src/main.d"}`), dir);
    assert(!infoResult.failed, "dshell info failed: " ~ infoResult.output);
    assert(infoResult.output.indexOf("<type>file</type>") >= 0,
        "dshell info did not report a file: " ~ infoResult.output);

    // Legacy aliases (pwd/ls/stat) still resolve to the same operations.
    auto aliasPwd = executeTool(makeCall("dshell",
        `{"command":"pwd"}`), dir);
    assert(!aliasPwd.failed && aliasPwd.output.indexOf(dir) >= 0,
        "dshell pwd alias failed: " ~ aliasPwd.output);
    auto aliasLs = executeTool(makeCall("dshell",
        `{"command":"ls"}`), dir);
    assert(!aliasLs.failed && aliasLs.output.indexOf("README.md") >= 0,
        "dshell ls alias failed: " ~ aliasLs.output);
    auto aliasStat = executeTool(makeCall("dshell",
        `{"command":"stat","path":"src/main.d"}`), dir);
    assert(!aliasStat.failed &&
        aliasStat.output.indexOf("<type>file</type>") >= 0,
        "dshell stat alias failed: " ~ aliasStat.output);
    writeln("D-native dshell where / list / info (+ aliases) OK");

    // The advertised dshell schema must teach ONLY the natural words. Legacy
    // abbreviations stay accepted at runtime but must never be offered to the
    // model (otherwise it keeps reaching for pwd/ls/stat).
    foreach (toolset; [builtinToolDefinitions(), nativeOnlyToolDefinitions()])
    {
        foreach (tool; toolset)
        {
            if (tool.name != "dshell") continue;
            assert(tool.description.indexOf("pwd") < 0,
                "dshell description must not teach pwd");
            assert(tool.description.indexOf("ls") < 0,
                "dshell description must not teach ls");
            assert(tool.description.indexOf("stat") < 0,
                "dshell description must not teach stat");
            assert(tool.parametersJson.indexOf("pwd") < 0,
                "dshell schema must not advertise pwd");
            assert(tool.parametersJson.indexOf("\"ls\"") < 0,
                "dshell schema must not advertise ls");
            assert(tool.parametersJson.indexOf("\"stat\"") < 0,
                "dshell schema must not advertise stat");
        }
    }
    writeln("dshell advertises only the natural words");

    // Toolset shapes: default has the shell tool, native-only does not.
    auto defaults = builtinToolDefinitions();
    bool hasShell;
    bool defaultHasDshell;
    bool defaultHasRemove;
    foreach (tool; defaults)
    {
        if (tool.name == "bash") hasShell = true;
        if (tool.name == "dshell") defaultHasDshell = true;
        if (tool.name == "remove") defaultHasRemove = true;
    }
    assert(hasShell, "Default toolset must include the shell tool");
    assert(defaultHasDshell, "Default toolset must include dshell");
    assert(defaultHasRemove, "Default toolset must include remove");

    auto natives = nativeOnlyToolDefinitions();
    bool nativeHasShell;
    bool hasRun;
    bool nativeHasDshell;
    bool nativeHasRemove;
    foreach (tool; natives)
    {
        if (tool.name == "bash") nativeHasShell = true;
        if (tool.name == "run") hasRun = true;
        if (tool.name == "dshell") nativeHasDshell = true;
        if (tool.name == "remove") nativeHasRemove = true;
    }
    assert(!nativeHasShell, "Native toolset must not include the shell tool");
    assert(hasRun, "Native toolset must include the run tool");
    assert(nativeHasDshell, "Native toolset must include dshell");
    assert(nativeHasRemove, "Native toolset must include remove");
    assert(toolSteeringPrompt(true).indexOf("no shell") >= 0,
        "Native steering prompt must say there is no shell");
    assert(toolSteeringPrompt(false).indexOf("where") >= 0,
        "Default steering prompt must steer toward the natural dshell words");
    assert(toolSteeringPrompt(true).indexOf("list") >= 0,
        "Native steering prompt must mention the list operation");
    assert(toolSteeringPrompt(true).indexOf("remove") >= 0,
        "Native steering prompt must mention the remove tool");
    writeln("Default vs native-only toolset shapes OK");

    // unknown tools report a clear error rather than crashing
    auto unknownResult = executeTool(makeCall("nope", "{}"), dir);
    assert(unknownResult.failed, "unknown tool should fail");

    version (Windows)
    {
        // Regression: console tools (e.g. cmd `dir`) emit the OEM codepage.
        // The tool output must be valid UTF-8 so it can be persisted into the
        // JSON sessions file and restored on the next launch without an
        // "Invalid UTF-8 sequence" crash.
        auto oemResult = executeTool(makeCall("bash",
            `{"command":"dir","shell":"cmd"}`), dir);
        assert(!oemResult.failed, "dir failed: " ~ oemResult.output);
        import std.utf : validate;
        try
        {
            validate(oemResult.output);
        }
        catch (Exception error)
        {
            assert(false, "Tool output is not valid UTF-8: " ~ error.msg);
        }
        // The free-space line in `dir` contains the OEM thousands separator,
        // which must decode to a valid UTF-8 character (not a raw byte).
        assert(oemResult.output.indexOf("bytes free") >= 0,
            "dir did not produce its full listing: " ~ oemResult.output);
        writeln("Tool output is valid UTF-8 (safe to persist)");
    }

    writeln("Aurora OpenCode Pro tools module test passed.");
    try rmdirRecurse(dir);
    catch (Exception) {}
    return 0;
}
