module auroraopencode_pro_tools_test;

import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.tools : builtinToolDefinitions, executeTool,
    nativeOnlyToolDefinitions, resolveToolPath, toolSteeringPrompt;
import std.file : exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
    write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf;

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

    // read a file from the workspace (relative path)
    auto readResult = executeTool(makeCall("read",
        `{"filePath":"src/main.d"}`), dir);
    assert(!readResult.failed, "read failed: " ~ readResult.output);
    assert(readResult.output.indexOf("void main") >= 0,
        "read did not return file contents");

    // write a new file then read it back
    auto writeResult = executeTool(makeCall("write",
        `{"filePath":"src/generated.txt","content":"hello from tool"}`), dir);
    assert(!writeResult.failed, "write failed: " ~ writeResult.output);
    assert(readText(buildPath(dir, "src", "generated.txt")) ==
        "hello from tool", "write did not persist the content");

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

    // The D-native `dshell` tool covers pwd/ls/stat without any shell.
    auto pwdResult = executeTool(makeCall("dshell",
        `{"command":"pwd"}`), dir);
    assert(!pwdResult.failed, "dshell pwd failed: " ~ pwdResult.output);
    assert(pwdResult.output.indexOf(dir) >= 0,
        "dshell pwd did not return the workspace path: " ~ pwdResult.output);

    auto lsResult = executeTool(makeCall("dshell",
        `{"command":"ls"}`), dir);
    assert(!lsResult.failed, "dshell ls failed: " ~ lsResult.output);
    assert(lsResult.output.indexOf("README.md") >= 0,
        "dshell ls did not list the directory: " ~ lsResult.output);
    assert(lsResult.output.indexOf("[f]") >= 0,
        "dshell ls did not tag file entries: " ~ lsResult.output);
    assert(lsResult.output.indexOf("[d]") >= 0,
        "dshell ls did not tag directory entries: " ~ lsResult.output);

    auto statResult = executeTool(makeCall("dshell",
        `{"command":"stat","path":"src/main.d"}`), dir);
    assert(!statResult.failed, "dshell stat failed: " ~ statResult.output);
    assert(statResult.output.indexOf("<type>file</type>") >= 0,
        "dshell stat did not report a file: " ~ statResult.output);
    writeln("D-native dshell pwd / ls / stat OK");

    // Toolset shapes: default has the shell tool, native-only does not.
    auto defaults = builtinToolDefinitions();
    bool hasShell;
    bool defaultHasDshell;
    foreach (tool; defaults)
    {
        if (tool.name == "bash") hasShell = true;
        if (tool.name == "dshell") defaultHasDshell = true;
    }
    assert(hasShell, "Default toolset must include the shell tool");
    assert(defaultHasDshell, "Default toolset must include dshell");

    auto natives = nativeOnlyToolDefinitions();
    bool nativeHasShell;
    bool hasRun;
    bool nativeHasDshell;
    foreach (tool; natives)
    {
        if (tool.name == "bash") nativeHasShell = true;
        if (tool.name == "run") hasRun = true;
        if (tool.name == "dshell") nativeHasDshell = true;
    }
    assert(!nativeHasShell, "Native toolset must not include the shell tool");
    assert(hasRun, "Native toolset must include the run tool");
    assert(nativeHasDshell, "Native toolset must include dshell");
    assert(toolSteeringPrompt(true).indexOf("no shell") >= 0,
        "Native steering prompt must say there is no shell");
    assert(toolSteeringPrompt(false).indexOf("dshell") >= 0,
        "Default steering prompt must steer toward dshell");
    writeln("Default vs native-only toolset shapes OK");

    // unknown tools report a clear error rather than crashing
    auto unknownResult = executeTool(makeCall("nope", "{}"), dir);
    assert(unknownResult.failed, "unknown tool should fail");

    writeln("Aurora OpenCode Pro tools module test passed.");
    try rmdirRecurse(dir);
    catch (Exception) {}
    return 0;
}
