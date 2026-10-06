module parallel_tool_batch_test;

import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : OpenCodeToolCall;
import auroraopencode.opencode_client : OpenCodeEventKind;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.datetime : Clock;
import std.string : indexOf;

int main()
{
    const workspace = buildPath(tempDir(), "aurora-parallel-" ~
        to!string(Clock.currTime.stdTime));
    mkdirRecurse(workspace);
    write(buildPath(workspace, "fixture.txt"), "parallel fixture");
    foreach (count; [1, 2, 3, 4, 5, 9, 17])
    foreach (iteration; 0 .. 20)
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
    writeln("PASS: 140 actual tool batches; every call completes exactly once; mutation barriers preserved.");
    return 0;
}
