module duplicate_launch_contracts;

// Reopening the same program while its supervised copy still runs must not stack
// a second window: the runner names the running record so the old instance can be
// closed first, and `allowMultiple` opts into another copy deliberately.

import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : ToolExecution, clearFinishedSupervisedProcesses,
    executeTool, installDeveloperToolSource, listSupervisedProcesses,
    requestAllSupervisedProcessKills, requestSupervisedProcessKill,
    restoreDeveloperToolSource;
import core.thread : Thread;
import core.time : msecs;
import std.file : mkdirRecurse, tempDir;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : indexOf, replace;

private string processIdOf(ToolExecution result)
{
    const marker = result.output.indexOf("processId: ");
    assert(marker >= 0, "launch returned no process id: " ~ result.output);
    auto body = result.output[cast(size_t) marker + 11 .. $];
    const end = body.indexOf('\n');
    return end >= 0 ? body[0 .. cast(size_t) end] : body;
}

private bool running(string id)
{
    foreach (process; listSupervisedProcesses())
        if (process.id == id) return process.running;
    return false;
}

int main()
{
    const root = buildPath(tempDir(), "aurora-duplicate-launch-contracts");
    mkdirRecurse(root);
    // Own checkout identity so the fixture never contends with a live app.
    mkdirRecurse(buildPath(root, ".git"));
    setOpencodeStateDirectoryForTesting(buildPath(root, "state"));
    const previous = installDeveloperToolSource("");
    scope (exit)
    {
        requestAllSupervisedProcessKills();
        clearFinishedSupervisedProcesses();
        restoreDeveloperToolSource(previous);
    }

    version (Windows)
        const payload = `{"program":"ping.exe","args":["-n","120","127.0.0.1"],"background":true}`;
    else
        const payload = `{"program":"sleep","args":["120"],"background":true}`;

    auto first = executeTool(OpenCodeToolCall("first", "run", payload), root);
    assert(!first.failed, "the first launch failed: " ~ first.output);
    const firstId = processIdOf(first);

    auto second = executeTool(OpenCodeToolCall("second", "run", payload), root);
    assert(!second.failed, "relaunching the same command failed: " ~ second.output);
    assert(second.output.indexOf("Replaced the stale copy") >= 0,
        "the relaunch did not report replacing the stale copy: " ~ second.output);
    assert(second.output.indexOf(firstId) >= 0,
        "the relaunch does not name the copy it replaced (" ~ firstId ~ "): " ~
        second.output);
    assert(!running(firstId),
        "the stale copy is still running after the relaunch");
    const secondId = processIdOf(second);
    assert(secondId != firstId && running(secondId),
        "the replacement copy is not running");
    writeln("PASS relaunching the same command closes the stale copy first");

    // A different command of the same program is distinct work, never replaced.
    auto distinct = executeTool(OpenCodeToolCall("distinct", "run",
        payload.replace(`"120"`, `"90"`)), root);
    assert(!distinct.failed,
        "a different command of the same program failed: " ~ distinct.output);
    const distinctId = processIdOf(distinct);
    assert(distinctId != secondId && running(secondId),
        "a different command disturbed the running copy");
    writeln("PASS a different command of the same program leaves the other copy alone");

    // allowMultiple keeps the old copy on purpose.
    auto forced = executeTool(OpenCodeToolCall("forced", "run",
        payload.replace(`"background":true`,
            `"background":true,"allowMultiple":true`)), root);
    assert(!forced.failed,
        "allowMultiple did not permit a second copy: " ~ forced.output);
    const forcedId = processIdOf(forced);
    assert(forcedId != secondId && running(secondId) && running(forcedId),
        "allowMultiple replaced the running copy instead of keeping both");
    writeln("PASS allowMultiple keeps both copies running");

    foreach (id; [forcedId, distinctId, secondId])
        requestSupervisedProcessKill(id);
    foreach (_; 0 .. 200)
    {
        if (!running(forcedId) && !running(distinctId) && !running(secondId)) break;
        Thread.sleep(msecs(25));
    }
    assert(!running(forcedId) && !running(distinctId) && !running(secondId),
        "closing the copies failed");

    auto again = executeTool(OpenCodeToolCall("again", "run", payload), root);
    assert(!again.failed,
        "relaunching after the previous copies stopped failed: " ~ again.output);
    writeln("PASS relaunching after the old copies stopped works");
    writeln("duplicate launch contracts passed");
    return 0;
}