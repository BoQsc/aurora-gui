module tool_control_contracts;

import auroraopencode.core : OpenCodeToolCall, setOpencodeStateDirectoryForTesting;
import auroraopencode.tools : ToolCancellation, ChangeContext;
import auroraopencode.toolscheduler : scheduleToolBatch, toolWorkspaceRevision;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import core.thread : Thread;
import core.time : MonoTime, seconds, msecs;
import std.conv : to;
import std.file : mkdirRecurse;
import std.path : absolutePath;
import std.json : parseJSON;
import std.stdio : writeln;

private OpenCodeEvent terminal(OpenCodeClient client, long timeoutMs)
{
    const deadline = MonoTime.currTime + timeoutMs.msecs;
    OpenCodeEvent[] events;
    while (MonoTime.currTime < deadline)
    {
        client.drain(events);
        foreach (event; events)
            if (event.kind == OpenCodeEventKind.toolResult && !event.toolRunning) return event;
        Thread.sleep(5.msecs);
    }
    assert(false, "Tool did not settle within deadline");
}

int main()
{
    const root = absolutePath("tool-control-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(root);
    setOpencodeStateDirectoryForTesting(root ~ "/state");
    auto owner = new OpenCodeClient("http://127.0.0.1:9", "");
    auto control = new OpenCodeClient("http://127.0.0.1:9", "");
    auto token = new ToolCancellation();
    scheduleToolBatch(owner, 1, [OpenCodeToolCall("holder", "run",
        `{"program":"python","args":["-u","-c","import time; print('holding',flush=True); time.sleep(5)"]}`)],
        root, token, ChangeContext.init);
    bool running;
    const deadline = MonoTime.currTime + 2.seconds;
    while (!running && MonoTime.currTime < deadline)
    {
        scheduleToolBatch(control, 2, [OpenCodeToolCall("inspect", "tool_status", "{}")],
            root, new ToolCancellation(), ChangeContext.init);
        auto result = terminal(control, 500);
        assert(!result.toolFailed, result.text);
        foreach (row; parseJSON(result.text)["workspace"]["running"].array)
            if (row["tool"].str == "run" && row["exclusive"].boolean) running = true;
    }
    assert(running, "Native tool status did not identify the workspace writer");
    scheduleToolBatch(control, 3, [OpenCodeToolCall("plan", "update_plan",
        `{"plan":[{"step":"Wait for transfer","status":"in_progress"}]}`)],
        root, new ToolCancellation(), ChangeContext.init);
    auto plan = terminal(control, 500);
    assert(!plan.toolFailed, "Plan update waited for the workspace writer: " ~ plan.text);
    token.cancel();
    assert(terminal(owner, 2500).toolFailed);
    writeln("Tool inspection and plan updates remain available during a workspace writer; Stop releases it");
    const revision = toolWorkspaceRevision(root);
    ChangeContext explanation;
    explanation.computer.present = true;
    explanation.computer.explanationOnly = true;
    scheduleToolBatch(control, 4, [OpenCodeToolCall("query", "run",
        `{"program":"python","args":["-c","print('hardware info')"]}`)],
        root, new ToolCancellation(), explanation);
    auto query = terminal(control, 2500);
    assert(!query.toolFailed && !query.workspaceChanged && toolWorkspaceRevision(root) == revision);
    writeln("Read-only explanation commands do not manufacture code changes or invalidate verification");
    return 0;
}
