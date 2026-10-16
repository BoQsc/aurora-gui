module parallel_tool_batch_test;

import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.opencode_client : OpenCodeEventKind;
import auroraopencode.opencode_client : OpenCodeClient;
import auroraopencode.toolscheduler : scheduleToolBatch;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.file : readText;
import auroraopencode.websearch : experimentalWebSearchExecute;
import std.typecons : tuple;
import std.file : thisExePath;
import core.thread : Thread;
import core.time : msecs, MonoTime;
import auroraopencode.tools : executeTool, ToolCancellation, ChangeContext, runFilesystemHelperMode;
import auroraopencode.readprogress : ReadProgress, decodeReadProgress;
import auroraopencode.searchprogress : SearchProgress, decodeSearchProgress;
import std.array : replicate;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.datetime : Clock;
import std.string : indexOf;

int main(string[] args)
{
    if (args.length == 2 && args[1] == "--quiet-fixture")
    {
        Thread.sleep(msecs(1200));
        writeln("fixture output");
        return 0;
    }
    if (args.length == 2 && args[1] == "--long-quiet-fixture")
    {
        Thread.sleep(msecs(60_000));
        return 0;
    }
    const helper = runFilesystemHelperMode(args);
    if (helper >= 0) return helper;
    const workspace = buildPath(tempDir(), "aurora-parallel-" ~
        to!string(Clock.currTime.stdTime));
    mkdirRecurse(workspace);
    write(buildPath(workspace, "fixture.txt"), "parallel fixture");
    auto token = new ToolCancellation();
    token.cancel();
    auto cancelled = executeTool(OpenCodeToolCall("cancel", "read",
        `{"filePath":"fixture.txt"}`), workspace, token);
    assert(cancelled.failed && cancelled.output.indexOf("cancelled") >= 0);
    write(buildPath(workspace, "long.txt"), "x".replicate(2 * 1024 * 1024) ~ "\nlast\n");
    string[] progress;
    auto longLine = executeTool(OpenCodeToolCall("long", "read",
        `{"filePath":"long.txt"}`), workspace, null, ChangeContext.init, (string text) { progress ~= text; });
    assert(!longLine.failed, longLine.output);
    assert(longLine.output.indexOf("line truncated") >= 0);
    assert(longLine.output.indexOf("2: last") >= 0);
    // A read reports its own measured activity (an encoded ReadProgress), never
    // the generic filesystem-host status line that non-read tools use.
    assert(progress.length > 0 && progress[0].indexOf("Filesystem host PID") < 0,
        "a read must not report the generic filesystem-host status line");
    ReadProgress firstRead;
    assert(decodeReadProgress(progress[0], firstRead) &&
        firstRead.path.indexOf("long.txt") >= 0, progress[0]);
    auto offsetRead = executeTool(OpenCodeToolCall("offset", "read",
        `{"filePath":"long.txt","offset":2,"limit":1}`), workspace);
    assert(!offsetRead.failed && offsetRead.output.indexOf("2: last") >= 0);
    foreach (spec; [
        OpenCodeToolCall("grep-progress", "grep", `{"pattern":"fixture","path":"fixture.txt"}`),
        OpenCodeToolCall("glob-progress", "glob", `{"pattern":"*.txt"}`),
        OpenCodeToolCall("list-progress", "dshell", `{"command":"list"}`)])
    {
        // A scan this small can finish before its host publishes a snapshot, so
        // the measured summary is asserted from the tool's own output - the text
        // the UI shows. Decoding of live snapshots is covered by the blocked scan
        // below, which cannot finish quickly.
        auto result = executeTool(spec, workspace);
        assert(!result.failed, result.output);
        // A search reports its measured scan summary; a directory listing reports
        // the scanned entries it walked.
        assert(result.output.indexOf(spec.name == "dshell" ? "Scan complete." : "Checked ") >= 0,
            result.output);
        assert(result.output.indexOf("fixture.txt") >= 0, result.output);
    }
    // A blocked host publishes measured search snapshots: the observer decodes
    // them, sees the published totals, sees the silence, and cancels.
    SearchProgress blockedScan;
    bool blockedQuiet;
    auto blockedToken = new ToolCancellation();
    auto blocked = executeTool(OpenCodeToolCall("grep-blocked", "grep",
        `{"pattern":"needle","path":"fixture.txt","_fixtureBlocked":true,"_fixtureProgress":true,"timeout":5000}`),
        workspace, blockedToken, ChangeContext.init, (string payload) {
            SearchProgress update;
            if (decodeSearchProgress(payload, update)) blockedScan = update;
            if (blockedScan.lastActivityMs >= 1000 && blockedScan.files == 77)
            {
                blockedQuiet = true;
                blockedToken.cancel();
            }
        });
    assert(blockedQuiet && blocked.failed && blockedScan.partial &&
        blockedScan.terminal, blocked.output);
    assert(blockedScan.totalsKnown && blockedScan.files == 77 &&
        blockedScan.latest.length > 0 &&
        blockedScan.latest[$ - 1].indexOf("large-log.txt") >= 0, blocked.output);
    assert(blocked.output.indexOf("incomplete") >= 0, blocked.output);
    JSONValue processArgs;
    processArgs["program"] = thisExePath();
    processArgs["args"] = JSONValue([JSONValue("--quiet-fixture")]);
    string processProgress;
    auto quiet = executeTool(OpenCodeToolCall("quiet", "run", processArgs.toString()),
        workspace, null, ChangeContext.init, (string text) { processProgress ~= text ~ "\n"; });
    assert(!quiet.failed, quiet.output);
    assert(quiet.output.indexOf("fixture output") >= 0);
    assert(processProgress.indexOf("no new output for 1s") >= 0, processProgress);
    auto controlClient = new OpenCodeClient("http://127.0.0.1:9", "");
    auto commandBatch = scheduleToolBatch(controlClient, 501,
        [OpenCodeToolCall("occupied", "run", processArgs.toString())],
        workspace, new ToolCancellation(), ChangeContext.init);
    Thread.sleep(200.msecs);
    const inspectStarted = MonoTime.currTime;
    auto inspectBatch = scheduleToolBatch(controlClient, 502,
        [OpenCodeToolCall("control", "process", `{"action":"list"}`)],
        workspace, new ToolCancellation(), ChangeContext.init);
    inspectBatch.wait();
    assert((MonoTime.currTime - inspectStarted) < 500.msecs,
        "Process controls were blocked by a running workspace command");
    commandBatch.wait();
    processArgs["args"] = JSONValue([JSONValue("--long-quiet-fixture")]);
    auto handedOff = executeTool(OpenCodeToolCall("handoff", "run", processArgs.toString()),
        workspace);
    assert(!handedOff.failed && !handedOff.verification.passed, handedOff.output);
    const idStart = handedOff.output.indexOf("processId: ");
    assert(idStart >= 0, handedOff.output);
    auto idBody = handedOff.output[cast(size_t) idStart + 11 .. $];
    const processId = idBody[0 .. idBody.indexOf("\n")];
    auto status = executeTool(OpenCodeToolCall("inspect", "process",
        `{"action":"status","processId":"` ~ processId ~ `"}`), workspace);
    assert(!status.failed && status.output.indexOf("status: running") >= 0, status.output);
    executeTool(OpenCodeToolCall("kill", "process",
        `{"action":"kill","processId":"` ~ processId ~ `"}`), workspace);
    processArgs["args"] = JSONValue([JSONValue("--quiet-fixture")]);
    auto stopToken = new ToolCancellation();
    auto stopped = executeTool(OpenCodeToolCall("stop", "run", processArgs.toString()),
        workspace, stopToken, ChangeContext.init, (string text) { stopToken.cancel(); });
    assert(stopped.failed && stopped.output.indexOf("stopped by user") >= 0, stopped.output);
    // A host that blocks (here: it publishes one snapshot, then stops) leaves the
    // read measured but quiet: the observer decodes the published byte count,
    // sees the silence, and cancels. The snapshot comes from the fixture host
    // named by AURORA_FILESYSTEM_HOST, which the test runner always provides.
    ReadProgress hostedRead;
    bool quietSeen;
    auto hostedToken = new ToolCancellation();
    auto hosted = executeTool(OpenCodeToolCall("host-progress", "read",
        `{"filePath":"fixture.txt","_fixtureBlocked":true,"_fixtureProgress":true,"timeout":5000}`),
        workspace, hostedToken, ChangeContext.init, (string payload) {
            ReadProgress update;
            if (decodeReadProgress(payload, update)) hostedRead = update;
            if (hostedRead.lastActivityMs >= 1000 && hostedRead.bytesRead == 2500)
            {
                quietSeen = true;
                hostedToken.cancel();
            }
        });
    assert(quietSeen && hosted.failed && hostedRead.terminal, hosted.output);
    assert(hostedRead.bytesRead == 2500 && hostedRead.fraction() == 0.25 &&
        hostedRead.path.indexOf("fixture.txt") >= 0, hosted.output);
    assert(hosted.output.indexOf("incomplete") >= 0, hosted.output);
    bool searchRunnerUsed;
    auto search = experimentalWebSearchExecute(`{"query":"fixture"}`, workspace,
        (string[] argv, string workdir, int timeout) {
            searchRunnerUsed = true;
            assert(workdir == workspace && timeout == 40000);
            return tuple(`{"result":{"content":[{"type":"text","text":"fixture search result"}]}}`, false);
        });
    assert(searchRunnerUsed && !search[1] && search[0].indexOf("fixture search result") >= 0);
    foreach (count; [1, 2, 3, 4, 5, 9, 17])
    foreach (iteration; 0 .. 2)
    {
        OpenCodeToolCall[] calls;
        foreach (index; 0 .. count)
            calls ~= OpenCodeToolCall("call-" ~ to!string(index), "read",
                `{"filePath":"fixture.txt"}`);
        // Exercise two read lanes separated by an exclusive mutation.
        calls ~= OpenCodeToolCall("barrier", "write",
            `{"filePath":"barrier.txt","content":"barrier fixture"}`);
        calls ~= OpenCodeToolCall("after-barrier", "read",
            `{"filePath":"barrier.txt"}`);
        auto events = OpenCodeRoot.executeToolBatchForTesting(calls, workspace);
        size_t[string] seen;
        foreach (event; events)
        {
            if (event.kind != OpenCodeEventKind.toolResult || event.toolRunning)
                continue;
            assert(event.requestId == 123);
            assert(!event.toolFailed, event.text);
            ++seen[event.toolCallId];
            if (event.toolCallId == "after-barrier")
                assert(event.text.indexOf("barrier fixture") >= 0);
        }
        foreach (call; calls)
            assert(call.id in seen && seen[call.id] == 1,
                "Missing or duplicated result: " ~ call.id ~
                " in lane of " ~ to!string(count));
        assert(seen.length == calls.length);
    }
    writeln("PASS: 14 actual tool batches; every call completes exactly once; mutation barriers preserved.");
    return 0;
}
