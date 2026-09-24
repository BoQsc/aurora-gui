module auroraopencode_pro_tools_test;

import auroraopencode.core : OpenCodeToolCall,
    setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : ChangeContext, ToolCancellation, ToolExecution,
    buildSystemPrompt, builtinToolDefinitions, cancelRunningCommands, executeTool,
    listChangeRecords, nativeOnlyToolDefinitions, resetRunningCommands,
    rebuildRequestHandler, resolveToolPath, revertChangeRecord,
    toolSteeringPrompt;
import auroraopencode.systemprompt : PromptVerbosity, promptVerbosityDirective,
    promptVerbosityFromName, promptVerbosityLabel, promptVerbosityName,
    promptVerbosityNames, rebuildModule, setSystemPromptModules;
import std.array : replicate;
import std.file : copy, exists, mkdirRecurse, readText, rmdirRecurse, tempDir,
    write;
import std.path : buildPath;
import std.process : environment;
import std.json : parseJSON;
import std.stdio : writeln;
import std.string : indexOf, replace;
import std.utf : validate;
import core.thread : Thread;
import core.time : msecs;

private OpenCodeToolCall makeCall(string name, string args)
{
    OpenCodeToolCall call;
    call.id = "call_test";
    call.name = name;
    call.arguments = args;
    return call;
}

/// Strip the Environment section's "Local date and time" line, which embeds
/// the wall clock. Two prompts built at different instants otherwise differ by
/// that timestamp alone, so verbosity comparisons must ignore it.
private string withoutTimestamp(string prompt)
{
    const marker = "  Local date and time: ";
    const start = prompt.indexOf(marker);
    if (start < 0) return prompt;
    const end = prompt.indexOf("\n", start);
    if (end < 0) return prompt;
    return prompt[0 .. start] ~ prompt[end .. $];
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

    // Long searches return control with concrete progress rather than being
    // treated as hung. The agent can inspect that report and deliberately grant
    // the same focused search more time when the observed work is reasonable.
    auto pausedGrep = executeTool(makeCall("grep",
        `{"pattern":"definitely-absent","path":"wide.txt","timeout":1}`), dir);
    assert(pausedGrep.failed && pausedGrep.output.indexOf("soft deadline") >= 0 &&
        pausedGrep.output.indexOf("lines; found") >= 0 &&
        pausedGrep.output.indexOf("decide whether waiting longer") >= 0,
        "long grep did not return an inspectable progress report: " ~
        pausedGrep.output);
    auto extendedGrep = executeTool(makeCall("grep",
        `{"pattern":"definitely-absent","path":"wide.txt",` ~
        `"timeout":60000}`), dir);
    assert(!extendedGrep.failed &&
        extendedGrep.output.indexOf("No matches") >= 0,
        "agent-selected longer grep deadline did not complete: " ~
        extendedGrep.output);
    writeln("grep soft deadline reports progress and permits a longer wait");

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

    // A repository-wide search must not crawl generated/VCS trees or binary
    // artifacts. Those can dwarf the source tree and previously made several
    // parallel greps appear to hang for minutes.
    mkdirRecurse(buildPath(dir, "build", "deep"));
    write(buildPath(dir, "build", "deep", "ignored.d"),
        "ignored-search-marker\n");
    write(buildPath(dir, "src", "ignored.exe"),
        "ignored-search-marker\n");
    auto ignoredGrep = executeTool(makeCall("grep",
        `{"pattern":"ignored-search-marker"}`), dir);
    assert(!ignoredGrep.failed && ignoredGrep.output.indexOf("No matches") >= 0,
        "grep entered a generated directory or binary artifact: " ~
        ignoredGrep.output);

    // Stop is per conversation and must also interrupt native searches, not
    // only spawned shell commands.
    auto grepCancellation = new ToolCancellation();
    grepCancellation.cancel();
    auto cancelledGrep = executeTool(makeCall("grep",
        `{"pattern":"aurora"}`), dir, grepCancellation);
    assert(cancelledGrep.failed &&
        cancelledGrep.output.indexOf("cancelled") >= 0,
        "cancelled grep kept running: " ~ cancelledGrep.output);
    writeln("grep skips generated/binary trees and responds to Stop");

    // A tool must not widen a project-local search to its parent directory.
    // In real workspaces that parent commonly contains every cloned repository.
    const jsonParent = tempDir().replace("\\", "/");
    auto parentGrep = executeTool(makeCall("grep",
        `{"pattern":"aurora","path":"` ~ jsonParent ~ `"}`), dir);
    assert(parentGrep.failed && parentGrep.output.indexOf(
        "refusing to search a parent") >= 0,
        "grep searched above the active workspace: " ~ parentGrep.output);
    auto parentGlob = executeTool(makeCall("glob",
        `{"pattern":"**/*.d","path":"` ~ jsonParent ~ `"}`), dir);
    assert(parentGlob.failed && parentGlob.output.indexOf(
        "refusing to search a parent") >= 0,
        "glob searched above the active workspace: " ~ parentGlob.output);
    writeln("Search tools reject parents of the active workspace");

    // A chat can belong to the sandbox while the user explicitly names another
    // repository. Search tools must honor that root instead of silently looking
    // in the session workspace and sending the model into fallback tool loops.
    auto otherRoot = buildPath(dir, "other-repo");
    mkdirRecurse(buildPath(otherRoot, "source"));
    write(buildPath(otherRoot, "source", "target.d"), "outside-workspace-marker\n");
    const jsonRoot = otherRoot.replace("\\", "/");
    auto rootedGlob = executeTool(makeCall("glob",
        `{"pattern":"**/*.d","path":"` ~ jsonRoot ~ `"}`), dir);
    assert(!rootedGlob.failed && rootedGlob.output.indexOf("target.d") >= 0,
        "glob ignored its explicit search root: " ~ rootedGlob.output);
    auto rootedGrep = executeTool(makeCall("grep",
        `{"pattern":"outside-workspace-marker","path":"` ~ jsonRoot ~ `"}`), dir);
    assert(!rootedGrep.failed && rootedGrep.output.indexOf("target.d:1:") >= 0,
        "grep ignored its explicit search root: " ~ rootedGrep.output);
    auto fileGrep = executeTool(makeCall("grep",
        `{"pattern":"outside-workspace-marker","path":"` ~
        jsonRoot ~ `/source/target.d"}`), dir);
    assert(!fileGrep.failed && fileGrep.output.indexOf("target.d:1:") >= 0,
        "grep rejected an explicit file path: " ~ fileGrep.output);
    writeln("glob and grep honor explicit repository and file paths");

    // bash echo round-trips through the shell
    auto bashResult = executeTool(makeCall("bash",
        `{"command":"echo aurora-tool-echo"}`), dir);
    assert(!bashResult.failed, "bash failed: " ~ bashResult.output);

    version (Windows)
    {
        auto nonzero = executeTool(makeCall("bash",
            `{"command":"exit /b 7","shell":"cmd"}`), dir);
        assert(nonzero.failed,
            "non-zero command exit was incorrectly recorded as success");
        assert(nonzero.output.indexOf("code 7") >= 0,
            "non-zero command output omitted the exit code: " ~
            nonzero.output);
    }
    else
    {
        auto nonzero = executeTool(makeCall("bash",
            `{"command":"exit 7","shell":"sh"}`), dir);
        assert(nonzero.failed,
            "non-zero command exit was incorrectly recorded as success");
    }
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

    version (Windows)
    {
        // Every tool call is timed so the transcript can show how long a
        // command took. Use a command that actually waits (~1s) and assert a
        // measurable non-zero duration.
        auto slow = executeTool(makeCall("bash",
            `{"command":"ping -n 2 127.0.0.1 >nul","shell":"cmd"}`), dir);
        assert(!slow.failed, "timed command failed: " ~ slow.output);
        assert(slow.elapsedMs >= 100, "tool execution was not timed");
        writeln("tool calls report their elapsed time");

        // Stop must interrupt a command already running on a tool worker. This
        // also guards the UI/worker race where the worker used to clear a Stop
        // request just after the user clicked the button.
        resetRunningCommands();
        ToolExecution cancelled;
        auto worker = new Thread({
            cancelled = executeTool(makeCall("run",
                `{"program":"cmd.exe","args":["/d","/c","ping -n 30 127.0.0.1 >nul"]}`),
                dir);
        });
        worker.start();
        Thread.sleep(msecs(250));
        cancelRunningCommands();
        worker.join();
        assert(cancelled.failed &&
            cancelled.output.indexOf("stopped by user") >= 0,
            "Stop did not terminate the running command: " ~ cancelled.output);
        assert(cancelled.elapsedMs < 5_000,
            "Stopped command did not return promptly");
        resetRunningCommands();
        writeln("Stop promptly terminates a running command");
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

        // A binary built in workdir must launch without an extra PATH lookup
        // or a full absolute path, including an explicit relative path.
        const localExe = buildPath(dir, "local-tool.exe");
        copy(environment.get("COMSPEC"), localExe);
        foreach (name; ["local-tool.exe", "./local-tool.exe"])
        {
            auto localRun = executeTool(makeCall("run",
                `{"program":"` ~ name ~
                `","args":["/d","/c","echo local-run-ok"]}`), dir);
            assert(!localRun.failed &&
                localRun.output.indexOf("local-run-ok") >= 0,
                "run could not launch a workdir executable: " ~
                localRun.output);
        }

        // Long commands can detach from the model round and remain addressable
        // by a stable process id. Polling output/status must not relaunch them.
        auto background = executeTool(makeCall("run",
            `{"program":"cmd.exe","args":["/d","/c","echo bg-start & ping -n 2 127.0.0.1 >nul & echo bg-done"],"background":true}`),
            dir);
        assert(!background.failed, "background run failed: " ~
            background.output);
        const marker = background.output.indexOf("processId: ");
        assert(marker >= 0, "background run returned no process id: " ~
            background.output);
        auto idBody = background.output[cast(size_t) marker + 11 .. $];
        const idEnd = idBody.indexOf('\n');
        const processId = idEnd >= 0
            ? idBody[0 .. cast(size_t) idEnd] : idBody;
        assert(processId.length > 0);

        string captured;
        string status;
        foreach (_; 0 .. 40)
        {
            auto outputResult = executeTool(makeCall("process",
                `{"action":"output","processId":"` ~ processId ~ `"}`),
                dir);
            assert(!outputResult.failed, outputResult.output);
            captured = outputResult.output;
            auto statusResult = executeTool(makeCall("process",
                `{"action":"status","processId":"` ~ processId ~ `"}`),
                dir);
            assert(!statusResult.failed, statusResult.output);
            status = statusResult.output;
            if (status.indexOf("status: exited") >= 0) break;
            Thread.sleep(msecs(100));
        }
        assert(captured.indexOf("bg-start") >= 0 &&
            captured.indexOf("bg-done") >= 0,
            "background output was not retained: " ~ captured);
        assert(status.indexOf("status: exited") >= 0,
            "background process never completed: " ~ status);
        auto removed = executeTool(makeCall("process",
            `{"action":"remove","processId":"` ~ processId ~ `"}`), dir);
        assert(!removed.failed, removed.output);

        auto interactive = executeTool(makeCall("run",
            `{"program":"cmd.exe","args":["/d","/q","/v:on","/c","set /p line= & echo got:!line!"],"background":true}`),
            dir);
        const interactiveMarker = interactive.output.indexOf("processId: ");
        assert(!interactive.failed && interactiveMarker >= 0,
            "interactive process returned no id: " ~ interactive.output);
        auto interactiveIdBody = interactive.output[
            cast(size_t) interactiveMarker + 11 .. $];
        const interactiveIdEnd = interactiveIdBody.indexOf('\n');
        const interactiveId = interactiveIdEnd >= 0
            ? interactiveIdBody[0 .. cast(size_t) interactiveIdEnd]
            : interactiveIdBody;
        auto wrote = executeTool(makeCall("process",
            `{"action":"write","processId":"` ~ interactiveId ~
            `","input":"hello-stdin\n","closeStdin":true}`), dir);
        assert(!wrote.failed && wrote.output.indexOf("Stdin closed") >= 0,
            "writing process stdin failed: " ~ wrote.output);
        string interactiveOutput;
        foreach (_; 0 .. 40)
        {
            interactiveOutput = executeTool(makeCall("process",
                `{"action":"output","processId":"` ~ interactiveId ~ `"}`),
                dir).output;
            if (interactiveOutput.indexOf("got:hello-stdin") >= 0) break;
            Thread.sleep(msecs(100));
        }
        assert(interactiveOutput.indexOf("got:hello-stdin") >= 0,
            "process did not receive stdin: " ~ interactiveOutput);
        // Wait until removal is legal; output can arrive just before the
        // monitor publishes the terminal status.
        string interactiveStatus;
        foreach (_; 0 .. 40)
        {
            interactiveStatus = executeTool(makeCall("process",
                `{"action":"status","processId":"` ~ interactiveId ~ `"}`),
                dir).output;
            if (interactiveStatus.indexOf("status: exited") >= 0) break;
            Thread.sleep(msecs(50));
        }
        removed = executeTool(makeCall("process",
            `{"action":"remove","processId":"` ~ interactiveId ~ `"}`), dir);
        assert(!removed.failed, removed.output ~ "\n" ~ interactiveStatus);

        auto longBackground = executeTool(makeCall("run",
            `{"program":"cmd.exe","args":["/d","/c","ping -n 30 127.0.0.1 >nul"],"background":true}`),
            dir);
        const longMarker = longBackground.output.indexOf("processId: ");
        assert(!longBackground.failed && longMarker >= 0,
            "long background run returned no id: " ~ longBackground.output);
        auto longIdBody = longBackground.output[
            cast(size_t) longMarker + 11 .. $];
        const longIdEnd = longIdBody.indexOf('\n');
        const longId = longIdEnd >= 0
            ? longIdBody[0 .. cast(size_t) longIdEnd] : longIdBody;
        auto killed = executeTool(makeCall("process",
            `{"action":"kill","processId":"` ~ longId ~ `"}`), dir);
        assert(!killed.failed, killed.output);
        string killedStatus;
        foreach (_; 0 .. 40)
        {
            killedStatus = executeTool(makeCall("process",
                `{"action":"status","processId":"` ~ longId ~ `"}`),
                dir).output;
            if (killedStatus.indexOf("status: killed") >= 0) break;
            Thread.sleep(msecs(100));
        }
        assert(killedStatus.indexOf("status: killed") >= 0,
            "background process tree was not terminated: " ~ killedStatus);
        removed = executeTool(makeCall("process",
            `{"action":"remove","processId":"` ~ longId ~ `"}`), dir);
        assert(!removed.failed, removed.output);
        writeln("Background process keeps id, output, stdin and cancellation");
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
    assert(listResult.output.indexOf("[d] " ~ buildPath(dir, "src") ~
        "  (- bytes)") >= 0,
        "dshell list detached a directory's metadata while sorting: " ~
        listResult.output);
    assert(listResult.output.indexOf("[f] " ~ buildPath(dir, "README.md")) >= 0,
        "dshell list detached a file's metadata while sorting: " ~
        listResult.output);

    mkdirRecurse(buildPath(dir, "src", "nested"));
    write(buildPath(dir, "src", "nested", "extra.d"), "module extra;\n");
    write(buildPath(dir, "src", "nested", "skip.txt"), "skip\n");
    auto recursiveList = executeTool(makeCall("dshell",
        `{"command":"list","recursive":true,"pattern":"**/*.d"}`), dir);
    assert(!recursiveList.failed,
        "dshell recursive filtered list failed: " ~ recursiveList.output);
    assert(recursiveList.output.indexOf("main.d") >= 0 &&
        recursiveList.output.indexOf("extra.d") >= 0,
        "dshell recursive list missed matching files: " ~ recursiveList.output);
    assert(recursiveList.output.indexOf("skip.txt") < 0 &&
        recursiveList.output.indexOf("README.md") < 0,
        "dshell list ignored its pattern: " ~ recursiveList.output);

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

    // Advertise the three natural operations, never the legacy abbreviations.
    foreach (toolset; [builtinToolDefinitions(), nativeOnlyToolDefinitions()])
    {
        bool foundDshell;
        foreach (tool; toolset)
        {
            parseJSON(tool.parametersJson);
            if (tool.name != "dshell") continue;
            foundDshell = true;
            assert(tool.parametersJson.indexOf("\"where\"") >= 0 &&
                tool.parametersJson.indexOf("\"list\"") >= 0 &&
                tool.parametersJson.indexOf("\"info\"") >= 0,
                "dshell must advertise all natural operations");
            assert(tool.parametersJson.indexOf("recursive") >= 0 &&
                tool.parametersJson.indexOf("pattern") >= 0,
                "dshell must advertise recursive filtered discovery");
            assert(tool.parametersJson.indexOf("\"pwd\"") < 0 &&
                tool.parametersJson.indexOf("\"ls\"") < 0 &&
                tool.parametersJson.indexOf("\"stat\"") < 0,
                "dshell must not advertise legacy abbreviations");
        }
        assert(foundDshell, "toolset must advertise full dshell support");
    }
    writeln("dshell advertises full natural operations without legacy aliases");

    // Toolset shapes: default has the shell tool, native-only does not.
    auto defaults = builtinToolDefinitions();
    bool hasShell;
    bool defaultHasDshell;
    bool defaultHasRemove;
    bool defaultHasOpen;
    bool defaultHasWebfetch;
    foreach (tool; defaults)
    {
        if (tool.name == "bash") hasShell = true;
        if (tool.name == "dshell") defaultHasDshell = true;
        if (tool.name == "remove") defaultHasRemove = true;
        if (tool.name == "open") defaultHasOpen = true;
        if (tool.name == "webfetch") defaultHasWebfetch = true;
        assert(tool.name != "glob",
            "glob should remain executable but dshell is primary discovery");
    }
    assert(hasShell, "Default toolset must include the shell tool");
    assert(defaultHasDshell, "Default toolset must include dshell");
    assert(defaultHasRemove, "Default toolset must include remove");
    assert(defaultHasOpen, "Default toolset must include open");
    assert(defaultHasWebfetch, "Default toolset must include webfetch");

    auto natives = nativeOnlyToolDefinitions();
    bool nativeHasShell;
    bool hasRun;
    bool nativeHasDshell;
    bool nativeHasRemove;
    bool nativeHasProcess;
    bool nativeHasOpen;
    bool nativeHasWebfetch;
    foreach (tool; natives)
    {
        if (tool.name == "bash") nativeHasShell = true;
        if (tool.name == "run") hasRun = true;
        if (tool.name == "dshell") nativeHasDshell = true;
        if (tool.name == "remove") nativeHasRemove = true;
        if (tool.name == "process") nativeHasProcess = true;
        if (tool.name == "open") nativeHasOpen = true;
        if (tool.name == "webfetch") nativeHasWebfetch = true;
        assert(tool.name != "glob",
            "native toolset should expose dshell instead of glob");
    }
    assert(!nativeHasShell, "Native toolset must not include the shell tool");
    assert(hasRun, "Native toolset must include the run tool");
    assert(nativeHasDshell, "Native toolset must include dshell");
    assert(nativeHasRemove, "Native toolset must include remove");
    assert(nativeHasProcess, "Native toolset must include process management");
    assert(nativeHasOpen, "Native toolset must include open");
    assert(nativeHasWebfetch, "Native toolset must include webfetch");
    assert(toolSteeringPrompt(true).indexOf("webfetch") >= 0,
        "Steering prompt must advertise webfetch");
    // experimental: websearch - delete with source/auroraopencode/websearch.d
    // Discovery (websearch) stays separate from retrieval (webfetch).
    bool defaultHasWebsearch;
    foreach (tool; defaults)
        if (tool.name == "websearch") defaultHasWebsearch = true;
    bool nativeHasWebsearch;
    foreach (tool; natives)
        if (tool.name == "websearch") nativeHasWebsearch = true;
    assert(defaultHasWebsearch, "Default toolset must include websearch");
    assert(nativeHasWebsearch, "Native toolset must include websearch");
    assert(toolSteeringPrompt(true).indexOf("websearch") >= 0,
        "Steering prompt must advertise websearch");

    // A search with no query fails deterministically before any network call.
    auto missingQuery = executeTool(makeCall("websearch", `{}`), dir);
    assert(missingQuery.failed, "websearch must require a query");
    assert(missingQuery.output.indexOf("query") >= 0,
        "websearch error must mention the missing query: " ~
        missingQuery.output);

    // AURORA_WEBSEARCH=off drops the tool from the toolset and the prompt
    // without any source edit.
    const previousWebSearch = environment.get("AURORA_WEBSEARCH", null);
    environment["AURORA_WEBSEARCH"] = "off";
    bool hiddenWhenDisabled;
    foreach (tool; builtinToolDefinitions())
        if (tool.name == "websearch") hiddenWhenDisabled = true;
    assert(!hiddenWhenDisabled,
        "AURORA_WEBSEARCH=off must remove websearch from the toolset");
    assert(toolSteeringPrompt(true).indexOf("websearch") < 0,
        "disabled websearch must not appear in the steering prompt");
    if (previousWebSearch is null) environment.remove("AURORA_WEBSEARCH");
    else environment["AURORA_WEBSEARCH"] = previousWebSearch;
    assert(toolSteeringPrompt(true).indexOf("websearch") >= 0,
        "websearch must return once the switch is restored");
    writeln("experimental websearch is advertised, validated and switchable");
    assert(toolSteeringPrompt(true).indexOf("no shell") >= 0,
        "Native steering prompt must say there is no shell");
    assert(toolSteeringPrompt(false).indexOf("dshell") >= 0 &&
        toolSteeringPrompt(true).indexOf("dshell") >= 0,
        "Steering prompts must document dshell");
    assert(toolSteeringPrompt(true).indexOf("remove") >= 0,
        "Native steering prompt must mention the remove tool");
    assert(toolSteeringPrompt(true).indexOf("native `open` tool") >= 0,
        "Steering prompt must require the native open tool");
    // The prompt carries a concise execution contract while tool schemas carry
    // parameter syntax, avoiding duplicated instructions and prompt tokens.
    assert(toolSteeringPrompt(false).indexOf("apply_patch") >= 0,
        "Steering prompt must advertise apply_patch");
    assert(toolSteeringPrompt(false).indexOf("update_plan") >= 0,
        "Steering prompt must advertise update_plan");
    assert(toolSteeringPrompt(false).indexOf("# Execution loop") >= 0,
        "Steering prompt must define the execution loop");
    assert(toolSteeringPrompt(false).indexOf(
        "name the remaining unknown") >= 0,
        "Steering prompt must guide exploration from evidence");
    assert(toolSteeringPrompt(false).indexOf(
        "legitimate validation and rereading") >= 0,
        "Steering prompt must preserve justified inspection");
    assert(toolSteeringPrompt(false).indexOf(
        "evidence phase, not a quota") >= 0,
        "Steering prompt must guide verification without a fixed budget");
    assert(toolSteeringPrompt(false).indexOf("within six") < 0 &&
        toolSteeringPrompt(false).indexOf("at most three") < 0,
        "Steering prompt must not impose artificial call quotas");
    assert(toolSteeringPrompt(false).indexOf(
        "Skip a plan for direct answers, quick exploration") >= 0 &&
        toolSteeringPrompt(false).indexOf(
            "A final prose answer ends the turn") >= 0,
        "Steering prompt must scope plans and define a stopping condition");
    assert(toolSteeringPrompt(false).indexOf("# Environment") >
        toolSteeringPrompt(false).indexOf("# Communication"),
        "Dynamic environment should follow stable instructions for caching");

    // Optional verbosity selector. "default" (and any unknown value) must
    // leave the prompt byte-identical, while Concise/Compact append exactly
    // one style section between the stable instructions and the dynamic tail.
    {
        const stock = buildSystemPrompt(false, ".", "auto");
        assert(withoutTimestamp(buildSystemPrompt(false, ".", "auto", "default"))
                == withoutTimestamp(stock),
            "The default verbosity must not change the prompt");
        assert(withoutTimestamp(buildSystemPrompt(false, ".", "auto", ""))
                == withoutTimestamp(stock),
            "A blank verbosity must fall back to the stock prompt");
        assert(withoutTimestamp(buildSystemPrompt(false, ".", "auto", "bogus"))
                == withoutTimestamp(stock),
            "An unknown verbosity must fall back to the stock prompt");
        assert(stock.indexOf("# Response style") < 0,
            "The stock prompt must not carry a response-style section");
        const concise = buildSystemPrompt(false, ".", "auto", "concise");
        const compact = buildSystemPrompt(false, ".", "auto", "compact");
        assert(concise.indexOf("# Response style") > 0 &&
            compact.indexOf("# Response style") > 0,
            "Concise/Compact must add the response-style section");
        assert(withoutTimestamp(concise) != withoutTimestamp(compact),
            "Concise and Compact must be distinct levels");
        // The prompt can ask for shorter reasoning, but its effect depends on
        // the provider and cannot guarantee a token reduction.
        assert(concise.indexOf("internal reasoning") >= 0 &&
            compact.indexOf("internal reasoning") >= 0,
            "Concise/Compact must also steer the internal reasoning");
        // The style section sits after the stable Communication text and
        // before the dynamic Environment block, so the cacheable prefix and
        // the per-request tail both keep their positions.
        assert(concise.indexOf("# Response style") >
            concise.indexOf("# Communication") &&
            concise.indexOf("# Response style") <
            concise.indexOf("# Environment"),
            "The response-style section must stay out of the dynamic tail");
        assert(promptVerbosityNames() ==
            ["default", "concise", "compact", "caveman"],
            "The picker must offer exactly the supported levels");
        assert(promptVerbosityFromName("compact") == PromptVerbosity.compact &&
            promptVerbosityFromName("caveman") == PromptVerbosity.caveman &&
            promptVerbosityFromName("nonsense") == PromptVerbosity.default_,
            "Verbosity name parsing must be strict and safe");
        assert(promptVerbosityName(PromptVerbosity.concise) == "concise" &&
            promptVerbosityName(PromptVerbosity.caveman) == "caveman" &&
            promptVerbosityLabel("default") == "Default" &&
            promptVerbosityLabel("compact") == "Compact" &&
            promptVerbosityLabel("caveman") == "Caveman",
            "Verbosity name/label round-trip must hold");
        // Caveman requests telegraphic output, including the visible answer.
        // It must differ from Compact so the picker levels stay distinct.
        const caveman = buildSystemPrompt(false, ".", "auto", "caveman");
        assert(caveman.indexOf("# Response style") > 0 &&
            caveman.indexOf("like a caveman") > 0 &&
            caveman.indexOf("telegraphic") > 0,
            "Caveman must request telegraphic style");
        assert(caveman.indexOf("final answer as well") > 0,
            "Caveman must request a telegraphic visible answer");
        assert(withoutTimestamp(caveman) != withoutTimestamp(compact) &&
            withoutTimestamp(caveman) != withoutTimestamp(concise),
            "Caveman must be its own level, distinct from Concise/Compact");
        // The standalone directive is what the app's final-answer round
        // appends (that round builds its own minimal prompt), so it must be
        // empty for the default level and identical to the section otherwise.
        assert(promptVerbosityDirective("default").length == 0 &&
            promptVerbosityDirective("").length == 0,
            "The default/blank directive must be empty");
        assert(promptVerbosityDirective("caveman").indexOf("caveman") > 0 &&
            caveman.indexOf(promptVerbosityDirective("caveman")) > 0,
            "The standalone caveman directive must match the prompt section");
        assert(promptVerbosityDirective("concise").indexOf("Response style") > 0 &&
            promptVerbosityDirective("concise") !=
                promptVerbosityDirective("caveman"),
            "The standalone directive must carry the style section and vary");
    }
    writeln("Optional verbosity selector shapes the prompt safely");
    assert(toolSteeringPrompt(false).length < 8_000,
        "Steering prompt should stay concise; tool syntax belongs in schemas");
    // The app can edit its own source; the prompt must forbid the agent from
    // building or killing the process that hosts its session.
    assert(toolSteeringPrompt(false).indexOf(
        "the process running this session") >= 0,
        "Steering prompt must protect the live host process");
    assert(toolSteeringPrompt(false).indexOf(
        "outside the change journal") >= 0,
        "Steering prompt must keep mutations inside the snapshot journal");
    writeln("Default vs native-only toolset shapes OK");


    // The agent-facing rebuild tool is advertised in both toolsets and delegates
    // to the host application: the tool cannot build the locked executable
    // itself, and it reports a clear failure when no handler is installed.
    {
        foreach (tools; [builtinToolDefinitions(), nativeOnlyToolDefinitions()])
        {
            bool hasRebuild;
            foreach (tool; tools)
                if (tool.name == "rebuild") hasRebuild = true;
            assert(hasRebuild, "both toolsets must advertise the rebuild tool");
        }
        auto noHandler = executeTool(makeCall("rebuild", `{}`), dir);
        assert(noHandler.failed &&
            noHandler.output.indexOf("only available inside") >= 0,
            "rebuild without a host handler must fail clearly: " ~
            noHandler.output);
        string capturedReason;
        rebuildRequestHandler = delegate bool(string reason)
        {
            capturedReason = reason;
            return true;
        };
        auto requested = executeTool(makeCall("rebuild",
            `{"reason":"apply the new edit"}`), dir);
        assert(!requested.failed && capturedReason == "apply the new edit",
            "rebuild must forward its reason to the host handler");
        assert(requested.output.indexOf("reports the compiler errors") >= 0,
            "the tool must tell the agent a failed build is reported back: " ~
            requested.output);
        // The app installs the handler on its UI thread but the tool runs on
        // its worker thread, so the global must be shared across threads
        // (module-level variables are thread-local by default in D). Calling it
        // from a worker thread catches a thread-local handler, which reads null
        // here and makes the tool report "only available inside".
        rebuildRequestHandler = null;
        auto capture = new class
        {
            string reason;
            bool reached;
        };
        rebuildRequestHandler = delegate bool(string reason)
        {
            capture.reason = reason;
            capture.reached = true;
            return true;
        };
        auto rebuildWorker = new Thread(delegate()
        {
            executeTool(makeCall("rebuild",
                `{"reason":"from a worker"}`), dir);
        });
        rebuildWorker.start();
        rebuildWorker.join();
        assert(capture.reached && capture.reason == "from a worker",
            "the rebuild handler must be visible to the tool worker thread " ~
            "(it must be __gshared, not thread-local)");
        rebuildRequestHandler = null;
        writeln("Rebuild tool is advertised and reaches the host application");
    }

    // The rebuild awareness module is opt-in: it appears only when registered,
    // and clearing the module set removes it from later prompts.
    {
        setSystemPromptModules([rebuildModule()]);
        const withRebuild = buildSystemPrompt(true, ".", "auto");
        assert(withRebuild.indexOf("Rebuilding Aurora OpenCode") >= 0,
            "a registered rebuild module must appear in the prompt");
        // The notice tells the agent the tool needs no approval and is meant to
        // be used on demand; that guidance is why the section exists.
        assert(withRebuild.indexOf("no user approval") >= 0,
            "the rebuild notice must state that no user approval is needed");
        assert(withRebuild.indexOf("whenever a source change is ready") >= 0,
            "the rebuild notice must say to use the tool when needed");
        setSystemPromptModules(null);
        assert(buildSystemPrompt(true, ".", "auto").indexOf(
            "Rebuilding Aurora OpenCode") < 0,
            "clearing the modules must remove the rebuild section");
        writeln("Rebuild awareness is opt-in and does not leak between prompts");
    }

    // Native open validates targets before asking the OS to launch anything,
    // avoiding shell retries and making missing-path failures deterministic.
    {
        auto missingArgument = executeTool(makeCall("open", `{}`), dir);
        assert(missingArgument.failed &&
            missingArgument.output.indexOf("non-empty `target`") >= 0,
            "open must reject a missing target: " ~ missingArgument.output);
        auto missingFile = executeTool(makeCall("open",
            `{"target":"does-not-exist.html"}`), dir);
        assert(missingFile.failed &&
            missingFile.output.indexOf("target does not exist") >= 0,
            "open must reject a nonexistent file: " ~ missingFile.output);
        writeln("native open validates its target without invoking a shell");
    }

    // write creates missing parent directories, as its description promises.
    {
        auto result = executeTool(makeCall("write",
            `{"filePath":"deep/nested/file.txt","content":"hi"}`), dir);
        assert(!result.failed, "write parent dirs failed: " ~ result.output);
        assert(readText(buildPath(dir, "deep", "nested", "file.txt")) == "hi",
            "write did not create parent directories");
        writeln("write creates missing parent directories");
    }

    // apply_patch: one call adds, updates and deletes several files, the
    // Codex multi-file editing workflow.
    {
        write(buildPath(dir, "keep.txt"), "keep\nold\n");
        write(buildPath(dir, "gone.txt"), "bye\n");
        auto result = executeTool(makeCall("apply_patch",
            `{"patch":"*** Begin Patch\n*** Add File: sub/new.txt\n+hello\n+world\n*** Update File: keep.txt\n@@\n keep\n-old\n+new\n*** Delete File: gone.txt\n*** End Patch"}`),
            dir);
        assert(!result.failed, "apply_patch failed: " ~ result.output);
        assert(readText(buildPath(dir, "sub", "new.txt")) ==
            "hello\nworld", "apply_patch add content wrong");
        assert(readText(buildPath(dir, "keep.txt")) == "keep\nnew\n",
            "apply_patch update wrong: " ~ readText(buildPath(dir, "keep.txt")));
        assert(!exists(buildPath(dir, "gone.txt")),
            "apply_patch delete failed");
        assert(result.additions > 0 && result.deletions > 0,
            "apply_patch must report a diff: " ~ result.output);
        writeln("apply_patch adds, updates and deletes files in one call");
    }

    // Patch context is logical text, not a line-ending contract. A model emits
    // LF patch payloads even when the target uses CRLF or has mixed endings;
    // matching must preserve the file's untouched bytes and still land.
    {
        const mixedPath = buildPath(dir, "mixed.txt");
        write(mixedPath, "alpha\r\nbeta\ngamma\r\n");
        auto result = executeTool(makeCall("apply_patch",
            `{"patch":"*** Begin Patch\n*** Update File: mixed.txt\n@@\n alpha\n-beta\n+changed\n gamma\n*** End Patch"}`), dir);
        assert(!result.failed,
            "apply_patch rejected mixed/CRLF context: " ~ result.output);
        const mixed = readText(mixedPath);
        assert(mixed.indexOf("alpha\r\nchanged\r\ngamma\r\n") >= 0,
            "apply_patch did not preserve CRLF replacement style: " ~ mixed);
        writeln("apply_patch matches CRLF and mixed-line-ending context");
    }

    // Regression: a hunk whose context is absent must fail cleanly. The old
    // code resolved the match position with
    //     const at = oldBlock.length == 0 ? searchPos
    //                                    : content.indexOf(oldBlock, searchPos);
    // which promotes `indexOf`'s signed -1 to `ulong` because the other branch
    // is `size_t`; `at < 0` was therefore dead, `-1` became size_t.max, and
    // the following slice/concatenation copied size_t.max bytes, faulting in
    // msvcr120's memcpy (the `0xC0000005` that killed the app on every
    // apply_patch miss).
    {
        write(buildPath(dir, "keep.txt"), "keep\nold\n");
        auto missing = executeTool(makeCall("apply_patch",
            `{"patch":"*** Begin Patch\n*** Update File: keep.txt\n@@\n not present\n+added\n*** End Patch"}`),
            dir);
        assert(missing.failed,
            "apply_patch with an absent context must fail, not crash");
        assert(missing.output.indexOf("patch context not found") >= 0,
            "apply_patch miss must explain the missing context: " ~
            missing.output);
        assert(readText(buildPath(dir, "keep.txt")) == "keep\nold\n",
            "a failed hunk must not modify the file");
        writeln("apply_patch reports a missing context instead of crashing");
    }

    // update_plan renders a checked list and enforces a single in-progress
    // step, so the transcript can show the plan.
    {
        auto result = executeTool(makeCall("update_plan",
            `{"explanation":"starting","plan":[{"step":"read","status":"completed"},{"step":"write","status":"in_progress"},{"step":"test","status":"pending"}]}`),
            dir);
        assert(!result.failed, "update_plan failed: " ~ result.output);
        assert(result.output.indexOf("[x] read") >= 0 &&
            result.output.indexOf("[>] write") >= 0 &&
            result.output.indexOf("[ ] test") >= 0,
            "update_plan output wrong: " ~ result.output);
        auto bad = executeTool(makeCall("update_plan",
            `{"plan":[{"step":"a","status":"in_progress"},{"step":"b","status":"in_progress"}]}`),
            dir);
        assert(bad.failed, "update_plan must reject two in_progress steps");
        writeln("update_plan renders steps and enforces one in-progress step");

        auto subplan = executeTool(makeCall("update_subplan",
            `{"parent_step":1,"plan":[{"step":"inspect","status":"completed"},` ~
            `{"step":"change","status":"in_progress"}]}`), dir);
        assert(!subplan.failed && subplan.output.indexOf(
            "Subplan for step 1") >= 0,
            "update_subplan did not validate and render child steps");
        auto invalidParent = executeTool(makeCall("update_subplan",
            `{"parent_step":0,"plan":[{"step":"inspect","status":"pending"}]}`),
            dir);
        assert(invalidParent.failed,
            "update_subplan accepted a non-existent parent index");
        writeln("update_subplan validates one-level child checklists");
    }

    // unknown tools report a clear error rather than crashing
    auto unknownResult = executeTool(makeCall("nope", "{}"), dir);
    assert(unknownResult.failed, "unknown tool should fail");

    // Git-independent mutation journal: capture exact bytes, refuse to clobber
    // a later external edit, and make the successful revert another snapshot.
    {
        setOpencodeStateDirectoryForTesting(buildPath(dir, "state"));
        const journalPath = buildPath(dir, "journal.txt");
        write(journalPath, "before\n");
        ChangeContext context;
        context.conversationId = "conversation-1";
        context.turnId = "turn-1";
        auto call = makeCall("edit",
            `{"filePath":"journal.txt","oldString":"before","newString":"after"}`);
        call.id = "journal-edit";
        auto changed = executeTool(call, dir, null, context);
        assert(!changed.failed && readText(journalPath) == "after\n",
            "journaled edit failed: " ~ changed.output);
        auto records = listChangeRecords(dir);
        assert(records.length == 1 && records[0].changeKind == "Modified" &&
            records[0].beforeHash != records[0].afterHash &&
            exists(records[0].beforeBlob) && exists(records[0].afterBlob),
            "journal did not persist the before/after snapshots");

        write(journalPath, "external\n");
        auto conflict = revertChangeRecord(dir, records[0].id, false, context);
        assert(!conflict.succeeded && conflict.conflict &&
            readText(journalPath) == "external\n",
            "revert must preserve a later external edit");
        write(journalPath, "after\n");
        auto reverted = revertChangeRecord(dir, records[0].id, false, context);
        assert(reverted.succeeded && readText(journalPath) == "before\n",
            "single-file snapshot revert failed: " ~ reverted.message);
        records = listChangeRecords(dir);
        assert(records.length == 2 && records[$ - 1].revertOf == records[0].id,
            "revert must itself be journaled and undoable");
        auto undoRevert = revertChangeRecord(dir, records[$ - 1].id,
            false, context);
        assert(undoRevert.succeeded && readText(journalPath) == "after\n",
            "reverting a revert must restore the changed version");
        auto redoRevert = revertChangeRecord(dir, records[0].id,
            false, context);
        assert(redoRevert.succeeded && readText(journalPath) == "before\n",
            "the original change must become revertible again");

        write(buildPath(dir, "one.txt"), "one-old\n");
        write(buildPath(dir, "two.txt"), "two-old\n");
        context.turnId = "turn-2";
        call = makeCall("apply_patch",
            `{"patch":"*** Begin Patch\n*** Update File: one.txt\n@@\n-one-old\n+one-new\n*** Update File: two.txt\n@@\n-two-old\n+two-new\n*** End Patch"}`);
        call.id = "journal-patch";
        changed = executeTool(call, dir, null, context);
        assert(!changed.failed, "journaled multi-file patch failed");
        records = listChangeRecords(dir);
        auto actionRevert = revertChangeRecord(dir, records[$ - 1].id,
            true, context);
        assert(actionRevert.succeeded && actionRevert.files == 2 &&
            readText(buildPath(dir, "one.txt")) == "one-old\n" &&
            readText(buildPath(dir, "two.txt")) == "two-old\n",
            "whole-action revert failed: " ~ actionRevert.message);

        const repeatedPath = buildPath(dir, "repeated.txt");
        write(repeatedPath, "A\n");
        context.turnId = "turn-3";
        call = makeCall("edit",
            `{"filePath":"repeated.txt","oldString":"A","newString":"B"}`);
        call.id = "repeat-1";
        assert(!executeTool(call, dir, null, context).failed);
        call = makeCall("edit",
            `{"filePath":"repeated.txt","oldString":"B","newString":"C"}`);
        call.id = "repeat-2";
        assert(!executeTool(call, dir, null, context).failed);
        records = listChangeRecords(dir);
        auto turnRevert = revertChangeRecord(dir, records[$ - 1].id,
            false, context, true);
        assert(turnRevert.succeeded && readText(repeatedPath) == "A\n",
            "whole-turn revert must collapse repeated edits safely: " ~
            turnRevert.message);
        writeln("standalone mutation journal and conflict-safe reverts OK");
    }

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

    // webfetch: argument validation is deterministic; a live request must
    // return the document body whenever the network is reachable.
    {
        auto missingUrl = executeTool(makeCall("webfetch", `{}`), dir);
        assert(missingUrl.failed, "webfetch must require a url");
        auto badScheme = executeTool(makeCall("webfetch",
            `{"url":"ftp://example.com/x"}`), dir);
        assert(badScheme.failed, "webfetch must reject non-http(s) schemes");

        auto fetched = executeTool(makeCall("webfetch",
            `{"url":"https://vanillaserver.eu/bloodmoon.json","timeout":20000}`),
            dir);
        if (fetched.failed)
        {
            const shown = fetched.output.length < 140
                ? fetched.output : fetched.output[0 .. 140];
            writeln("webfetch live check skipped (no network): ", shown);
        }
        else
        {
            assert(fetched.output.indexOf("bloodmoon") >= 0,
                "webfetch did not return the JSON body: " ~ fetched.output);
            writeln("webfetch fetched a live JSON document (",
                fetched.output.length, " chars)");
        }

        // Deterministic guard: a page whose inline <style>/<script> bodies are
        // larger than the output cap must still surrender its visible text.
        // While those bodies were kept, the CSS alone filled the cap and the
        // real content never reached the model.
        {
            import std.array : appender;
            import std.conv : to;
            import std.exception : collectException;
            import std.socket : AddressFamily, InternetAddress, TcpSocket;

            auto fixture = appender!string();
            fixture.put("<!DOCTYPE html><html><head><title>cap fixture</title>");
            fixture.put("<style>");
            fixture.put(replicate(
                ".fixture-rule-xyz{color:#abcdef;padding:4px;margin:2px;}\n",
                1200));
            fixture.put("</style><script>var leak = 'script-body-marker';</script>");
            fixture.put("<noscript>noscript-body-marker</noscript></head><body>");
            fixture.put("<p>Guard marker: visible paragraph.</p>");
            fixture.put("<!-- comment-body-marker --></body></html>");
            assert(fixture.data.length > 50_000,
                "the fixture must exceed the tool output cap");

            auto listener = new TcpSocket(AddressFamily.INET);
            listener.bind(new InternetAddress("127.0.0.1", 0));
            listener.listen(1);
            const port = (cast(InternetAddress) listener.localAddress).port;

            const response = "HTTP/1.1 200 OK\r\n" ~
                "Content-Type: text/html; charset=utf-8\r\n" ~
                "Content-Length: " ~ to!string(fixture.data.length) ~ "\r\n" ~
                "Connection: close\r\n\r\n" ~ fixture.data;

            auto server = new Thread({
                try
                {
                    auto client = listener.accept();
                    scope (exit) collectException(client.close());
                    auto buffer = new ubyte[4096];
                    collectException(client.receive(buffer));
                    size_t sent;
                    while (sent < response.length)
                    {
                        const written = client.send(response[sent .. $]);
                        if (written <= 0) break;
                        sent += written;
                    }
                }
                catch (Throwable) {}
            });
            server.isDaemon = true;
            server.start();

            auto htmlFetch = executeTool(makeCall("webfetch",
                `{"url":"http://127.0.0.1:` ~ to!string(port) ~ `/"}`), dir);
            if (!htmlFetch.failed)
                server.join();
            collectException(listener.close());

            assert(!htmlFetch.failed,
                "webfetch failed on the local HTML fixture: " ~ htmlFetch.output);
            assert(htmlFetch.output.indexOf("Guard marker: visible paragraph.") >= 0,
                "webfetch lost the page body behind a large inline <style>: " ~
                htmlFetch.output[0 .. (htmlFetch.output.length < 160
                    ? htmlFetch.output.length : 160)]);
            assert(htmlFetch.output.indexOf("fixture-rule-xyz") < 0,
                "webfetch leaked CSS into the page text");
            assert(htmlFetch.output.indexOf("script-body-marker") < 0,
                "webfetch leaked a script body into the page text");
            assert(htmlFetch.output.indexOf("comment-body-marker") < 0,
                "webfetch leaked an HTML comment into the page text");
            writeln("webfetch reduces a CSS-heavy page to its visible text (",
                htmlFetch.output.length, " chars)");
        }
    }

    writeln("Aurora OpenCode Pro tools module test passed.");
    try rmdirRecurse(dir);
    catch (Exception) {}
    return 0;
}
