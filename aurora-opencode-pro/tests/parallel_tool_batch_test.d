module parallel_tool_batch_test;

import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.opencode_client : OpenCodeEventKind;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.file : readText;
import auroraopencode.websearch : experimentalWebSearchExecute;
import std.typecons : tuple;
import std.file : thisExePath;
import core.thread : Thread;
import core.time : msecs;
import auroraopencode.tools : executeTool, ToolCancellation, ChangeContext, runFilesystemHelperMode;
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
    if (args.length == 3 && args[1] == "--aurora-filesystem-tool")
    {
        auto request = parseJSON(readText(args[2]));
        auto fields = parseJSON(request["arguments"].str);
        if ("_fixtureProgress" in fields.object)
        {
            write(request["progressPath"].str, "Fixture scan progress");
            Thread.sleep(msecs(1800));
        }
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
    assert(progress.length > 0 && progress[0].indexOf("Filesystem host PID") >= 0);
    auto offsetRead = executeTool(OpenCodeToolCall("offset", "read",
        `{"filePath":"long.txt","offset":2,"limit":1}`), workspace);
    assert(!offsetRead.failed && offsetRead.output.indexOf("2: last") >= 0);
    foreach (spec; [
        OpenCodeToolCall("grep-progress", "grep", `{"pattern":"fixture","path":"fixture.txt"}`),
        OpenCodeToolCall("glob-progress", "glob", `{"pattern":"*.txt"}`),
        OpenCodeToolCall("list-progress", "dshell", `{"command":"list"}`)])
    {
        string snapshots;
        auto result = executeTool(spec, workspace, null, ChangeContext.init,
            (string text) { snapshots ~= text ~ "\n"; });
        assert(!result.failed, result.output);
        assert(snapshots.indexOf("no new progress for") >= 0, snapshots);
        assert(snapshots.indexOf("Latest matches:") >= 0, snapshots);
    }
    JSONValue processArgs;
    processArgs["program"] = thisExePath();
    processArgs["args"] = JSONValue([JSONValue("--quiet-fixture")]);
    string processProgress;
    auto quiet = executeTool(OpenCodeToolCall("quiet", "run", processArgs.toString()),
        workspace, null, ChangeContext.init, (string text) { processProgress ~= text ~ "\n"; });
    assert(!quiet.failed, quiet.output);
    assert(quiet.output.indexOf("fixture output") >= 0);
    assert(processProgress.indexOf("no new output for 1s") >= 0, processProgress);
    auto stopToken = new ToolCancellation();
    auto stopped = executeTool(OpenCodeToolCall("stop", "run", processArgs.toString()),
        workspace, stopToken, ChangeContext.init, (string text) { stopToken.cancel(); });
    assert(stopped.failed && stopped.output.indexOf("stopped by user") >= 0, stopped.output);
    string hostedProgress;
    auto hosted = executeTool(OpenCodeToolCall("host-progress", "read",
        `{"filePath":"fixture.txt","_fixtureProgress":true}`), workspace,
        null, ChangeContext.init, (string text) { hostedProgress ~= text ~ "\n"; });
    assert(!hosted.failed, hosted.output);
    assert(hostedProgress.indexOf("Fixture scan progress") >= 0, hostedProgress);
    assert(hostedProgress.indexOf("no new progress for 1s") >= 0, hostedProgress);
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
