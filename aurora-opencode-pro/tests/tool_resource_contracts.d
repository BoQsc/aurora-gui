module tool_resource_contracts;

import auroraopencode.core;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent;
import auroraopencode.tools : ToolCancellation, ChangeContext;
import auroraopencode.toolscheduler : ToolBatch;
import auroraopencode.workscheduler : WorkItem, WorkScheduler;
import auroraopencode.toolsettlement : settleToolResult, ToolResultPolicy;
import auroraopencode.conversationcodec : decodeMessages;
import auroraopencode.runtime : readAgentRuntimeEvents, projectAgentRuntimeEvents;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.time : MonoTime, msecs, seconds;
import std.file : exists, mkdirRecurse, write, tempDir;
import std.path : absolutePath, buildPath;
import std.conv : to;
import std.json : parseJSON;
import std.stdio : writeln;

private final class HeldWorker : WorkItem
{
    Mutex mutex; Condition wake; bool entered, released;
    this(string directory)
    { mutex = new Mutex(); wake = new Condition(mutex); workspace = directory; exclusive = true; }
    override void execute()
    {
        synchronized (mutex)
        {
            entered = true; wake.notifyAll();
            while (!released) wake.wait();
        }
    }
    void waitEntered() { synchronized (mutex) while (!entered) wake.wait(); }
    void release() { synchronized (mutex) { released = true; wake.notifyAll(); } }
    override void settle(ulong revision) {}
}

int main()
{
    const directory = buildPath(tempDir(), "tool-resources-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(directory);
    auto client = new OpenCodeClient("", "");
    auto scheduler = new WorkScheduler(1, 1);
    auto gate = new HeldWorker(directory);
    scope (exit) { gate.release(); scheduler.close(); client.closeSession(); }
    assert(scheduler.submit(gate)); gate.waitEntered();
    ToolBatch start(string id, ToolCancellation cancellation, long deadline = 30_000,
        bool forceDeadline = false)
    {
        auto batch = new ToolBatch(client, 1,
            [OpenCodeToolCall(id, "write", `{"filePath":"` ~ id ~ `.txt","content":"effect"}`)],
            directory, cancellation, ChangeContext.init);
        batch.workspaceLane = scheduler; batch.controlLane = scheduler;
        batch.queueTimeoutMs = deadline; batch.queueDeadlineWhileActive = forceDeadline;
        batch.start(); return batch;
    }
    auto expired = start("expired", new ToolCancellation(), 25, true);
    auto saturated = start("saturated", new ToolCancellation());
    saturated.wait(); expired.wait();
    auto cancellation = new ToolCancellation();
    auto cancelled = start("cancelled", cancellation);
    cancellation.cancel(); cancelled.wait();
    OpenCodeEvent[] events; client.drain(events);
    bool queued;
    OpenCodeEvent[string] terminal;
    foreach (event; events)
    {
        if (event.toolRunning)
        {
            assert(event.toolState == ToolState.queued);
            queued = true;
        }
        else terminal[event.toolCallId] = event;
    }
    assert(queued && terminal.length == 3);
    assert(terminal["expired"].toolState == ToolState.resourceBlocked);
    assert(terminal["saturated"].toolState == ToolState.resourceBlocked);
    assert(terminal["cancelled"].toolState == ToolState.cancelled);
    foreach (name; ["expired", "saturated", "cancelled"])
        assert(!exists(buildPath(directory, name ~ ".txt")), "A blocked/cancelled tool executed");
    assert(scheduler.status().length == 1, "Logical cancellation released the physical worker");

    ChatSession session;
    ToolResultPolicy policy;
    auto settled = settleToolResult(session, terminal["expired"], "{}", policy);
    assert(settled.message.failed && settled.message.toolState == ToolState.resourceBlocked);
    const record = `{"id":"result","role":"tool","toolName":"write","failed":true,"toolState":"resource_blocked","content":"Not executed"}`;
    decodeMessages(parseJSON("[" ~ record ~ "]"), session);
    assert(session.messages[0].toolState == ToolState.resourceBlocked);
    const journal = buildPath(directory, "events.jsonl");
    write(journal, `{"schema":1,"sequence":1,"type":"item.added","threadId":"chat","itemId":"result","payload":` ~ record ~ "}\n");
    auto replayed = projectAgentRuntimeEvents(readAgentRuntimeEvents(journal));
    assert(replayed.length == 1 && replayed[0].messages[0].toolState == ToolState.resourceBlocked);

    // A queued tool with a short deadline must wait for the active worker and
    // then run; the forced-deadline case above covers the no-progress guard.
    auto waited = start("waited", new ToolCancellation(), 30_000, false);
    assert(!exists(buildPath(directory, "waited.txt")), "A queued tool ran before its worker was free");
    gate.release();
    waited.wait();
    auto success = start("success", new ToolCancellation()); success.wait();
    client.drain(events);
    bool running, completed;
    foreach (event; events)
    {
        if (event.toolRunning)
        {
            if (event.toolStarted)
            {
                running = true;
                assert(event.toolState == ToolState.running);
            }
            else
            {
                assert(event.toolState == ToolState.queued);
                queued = true;
            }
        }
        else terminal[event.toolCallId] = event;
        if (!event.toolRunning && (event.toolCallId == "waited" || event.toolCallId == "success"))
            completed = true;
    }
    assert(terminal["waited"].toolState == ToolState.completed,
        "waited state=" ~ to!string(terminal["waited"].toolState) ~
        " failed=" ~ to!string(terminal["waited"].toolFailed) ~
        " text=" ~ terminal["waited"].text ~
        " file=" ~ to!string(exists(buildPath(directory, "waited.txt"))));
    assert(terminal["success"].toolState == ToolState.completed);
    assert(running && completed && exists(buildPath(directory, "waited.txt")) &&
        exists(buildPath(directory, "success.txt")));
    assert(scheduler.status().length == 0, "Completed tools retained a worker");
    scheduler.close();
    auto closed = start("closed", new ToolCancellation()); closed.wait();
    client.drain(events);
    assert(events[$ - 1].toolState == ToolState.cancelled && !exists(buildPath(directory, "closed.txt")));
    writeln("PASS queued/running/resource-blocked/cancelled/completed outcomes, no blocked effects, physical lease retention and durable state replay");
    return 0;
}
