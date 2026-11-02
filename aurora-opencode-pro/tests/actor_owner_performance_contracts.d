module actor_owner_performance_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.workerbudget : WorkerBudget;
import core.memory : GC;
import core.time : MonoTime;
import std.array : replicate;
import std.conv : to;
import std.stdio : writeln;

int main()
{
    ChatSession initial; initial.id = "long-owner-model";
    initial.messages.length = 10_000;
    const body = "Long-horizon evidence and exact user constraints. ".replicate(48);
    foreach (i, ref message; initial.messages)
    {
        message.id = "message-" ~ to!string(i); message.role = i % 2 ? "assistant" : "user";
        message.parentId = i ? initial.messages[i - 1].id : ""; message.content = body;
    }
    initial.activeLeafId = initial.messages[$ - 1].id;
    ActorConfiguration config;
    auto budget = new WorkerBudget(1);
    auto before = GC.allocatedInCurrentThread(); auto began = MonoTime.currTime;
    auto detached = new ConversationActor(initial, config, null, budget, ActorStart.deferred);
    const allocated = GC.allocatedInCurrentThread() - before;
    writeln("owner_10000_detach_us=", (MonoTime.currTime - began).total!"usecs",
        " allocated_bytes=", allocated, " logical_body_bytes=", body.length * initial.messages.length);
    assert(allocated < body.length * initial.messages.length / 2,
        "Production admission serialized or copied long immutable transcript text");
    initial.messages[0].content = "UI-owned edit";
    detached.close(); auto independent = detached.takeFinalSession();
    assert(independent.messages[0].content == body, "Admission shared mutable graph containers with presentation");
    before = GC.allocatedInCurrentThread(); began = MonoTime.currTime;
    auto transferred = ConversationActor.adopt(independent, config, null, budget);
    const adopted = GC.allocatedInCurrentThread() - before;
    writeln("owner_10000_transfer_us=", (MonoTime.currTime - began).total!"usecs", " allocated_bytes=", adopted);
    assert(!independent.messages.length && !independent.id.length && adopted < 1024 * 1024,
        "Lifecycle transfer duplicated the graph or retained a second mutable owner");
    transferred.close(); auto finalState = transferred.takeFinalSession();
    assert(finalState.messages.length == 10_000 && finalState.messages[0].content == body && budget.active() == 0);
    bool recordingDisabled;
    try transferred.recordedTrace(); catch (Exception) { recordingDisabled = true; }
    assert(recordingDisabled);
    writeln("PASS 10000-message admission shares immutable evidence, detaches mutable graph and transfers ownership once");
    return 0;
}
