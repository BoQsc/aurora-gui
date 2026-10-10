module parallel_tool_batch_test;

import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.opencode_client : OpenCodeEventKind;
import std.conv : to;
import auroraopencode.tools : executeTool, ToolCancellation, ChangeContext, runFilesystemHelperMode;
import std.array : replicate;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.datetime : Clock;
import std.string : indexOf;

int main(string[] args)
{
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
