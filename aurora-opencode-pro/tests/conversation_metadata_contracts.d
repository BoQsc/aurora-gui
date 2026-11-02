module conversation_metadata_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationprojection;
import auroraopencode.conversationencode;
import auroraopencode.runtime : AgentEventKind, applyRuntimeThreadPayload, projectAgentRuntimeEvents;
import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import core.memory : GC;
import std.conv : to;
import std.file : mkdirRecurse;
import std.json : JSONValue, parseJSON;
import std.path : absolutePath, buildPath;
import std.stdio : writeln;

int main()
{
    const directory = absolutePath("conversation-metadata-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    ChatSession initial; initial.id = "metadata-owner"; initial.model = "fixture";
    initial.instructions = "Preserve user constraints"; initial.toolsMode = 0;
    initial.unread = true; initial.projectId = "project";
    initial.objective = "Current objective"; initial.taskStatus = "active";
    ChatMessage anchor; anchor.id = "anchor"; anchor.role = "user"; anchor.content = "Prior instruction";
    initial.messages = [anchor]; initial.activeLeafId = anchor.id;
    initial.compactedThroughMessageId = anchor.id; initial.compactionSummary = "Stored faithful checkpoint";
    initial.taskSteps = [TaskStep("Current step", "in_progress")];
    foreach (revision; 0 .. 200)
    {
        PlanHistoryEntry entry; entry.at = cast(long) revision; entry.source = "update_plan";
        entry.objective = "Historical objective " ~ to!string(revision); entry.status = "active";
        foreach (step; 0 .. 40) entry.steps ~= TaskStep("Recorded step " ~ to!string(step), "completed");
        initial.planHistory ~= entry;
    }
    auto before = GC.allocatedInCurrentThread();
    const taskState = activeTaskStateJson(initial);
    const ordinary = runtimeThreadPayload(initial);
    const allocated = GC.allocatedInCurrentThread() - before;
    assert(allocated < 512 * 1024, "Ordinary state encoding rebuilt 8000 historical plan steps before discarding them");
    assert(!("planHistory" in parseJSON(taskState).object) && !("planHistory" in parseJSON(ordinary).object));
    writeln("metadata_without_8000_history_steps_allocated_bytes=", allocated);

    auto repository = new ConversationRepository(); scope (exit) repository.close();
    auto journal = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    ActorConfiguration config;
    auto actor = new ConversationActor(initial, config, journal); scope (exit) actor.close();
    foreach (i; 0 .. 50)
        assert(actor.post(ActorCommand(ActorCommandKind.setDraft, "Draft " ~ to!string(i))) == ActorAdmission.accepted);
    auto replace = ActorCommand(ActorCommandKind.setGoal, "A replacement goal saved paused"); replace.activate = false;
    assert(actor.post(replace) == ActorAdmission.accepted);
    const deadline = MonoTime.currTime + 15.seconds;
    while (actor.activity().busy && MonoTime.currTime < deadline)
    { assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs); }
    assert(!actor.activity().busy, "Unconsumed presentation blocked metadata settlement");
    ChatSession view = initial; auto projection = new ConversationProjection(view);
    assert(actor.post(ActorCommand(ActorCommandKind.snapshot)) == ActorAdmission.accepted);
    bool snapshot;
    const snapshotDeadline = MonoTime.currTime + 10.seconds;
    while ((!snapshot || actor.activity().busy) && MonoTime.currTime < snapshotDeadline)
    {
        auto changes = actor.takeChanges();
        foreach (change; changes) if (change.kind == ActorChangeKind.snapshot) snapshot = true;
        auto applied = projection.apply(view, changes); assert(!applied.error.length, applied.error);
        if (applied.requestSnapshot) actor.post(ActorCommand(ActorCommandKind.snapshot));
        Thread.sleep(1.msecs);
    }
    assert(snapshot);
    auto tail = projection.apply(view, actor.takeChanges());
    assert(!tail.error.length && !tail.needsSnapshot && !actor.activity().busy);
    const historyAddress = cast(size_t) view.planHistory.ptr;
    size_t patchBytes, patches;
    foreach (i; 0 .. 50)
    {
        const text = "After snapshot " ~ to!string(i);
        assert(actor.post(ActorCommand(ActorCommandKind.setDraft, text)) == ActorAdmission.accepted);
        const patchDeadline = MonoTime.currTime + 5.seconds;
        while (view.draft != text && MonoTime.currTime < patchDeadline)
        {
            auto changes = actor.takeChanges();
            foreach (change; changes) if (change.kind == ActorChangeKind.metadataPatch)
            {
                auto payload = parseJSON(change.text);
                assert(!("planHistory" in payload.object) && !("messages" in payload.object) && !("taskArchive" in payload.object),
                    "A draft patch resent an unchanged history, graph or archive");
                patchBytes += change.text.length; ++patches;
            }
            auto applied = projection.apply(view, changes);
            assert(!applied.error.length && !applied.needsSnapshot, applied.error);
            Thread.sleep(1.msecs);
        }
        assert(view.draft == text && cast(size_t) view.planHistory.ptr == historyAddress,
            "Applying an unrelated draft rebuilt the 8000-step UI history");
    }
    assert(patches == 50 && patchBytes < 16 * 1024);
    writeln("metadata_50_draft_patches_bytes=", patchBytes, " retained_history_steps=8000");
    actor.close(); assert(!actor.fault().length, actor.fault());
    const finalState = parseJSON(actor.finalSnapshot());
    assert(sessionToJson(view) == finalState);
    size_t historyWrites, metadataWrites;
    auto events = journal.history();
    foreach (event; events)
        if (event.kind == AgentEventKind.threadUpdated)
        {
            ++metadataWrites;
            const payload = parseJSON(event.payloadJson);
            if ("planHistory" in payload.object) ++historyWrites;
        }
    assert(metadataWrites >= 101 && historyWrites == 1,
        "Unchanged history was repeated, or pruning at the 200-entry bound hid a changed revision");
    auto restored = projectAgentRuntimeEvents(events);
    assert(restored.length == 1 && sessionToJson(restored[0]) == finalState,
        "Journal-only recovery lost a checkpoint, unread state, instructions, queues or plan revisions");

    // Explicit empty/default values clear fields; repeated metadata replaces
    // arrays instead of duplicating a queue or roster from an earlier snapshot.
    auto cleared = restored[0]; cleared.compactionSummary = ""; cleared.compactedThroughMessageId = "";
    cleared.instructions = ""; cleared.toolsMode = -1; cleared.unread = false; cleared.updatedAt = 0;
    cleared.queuedGuidance = ["One instruction"]; cleared.queuedFollowUps = ["One follow-up"];
    cleared.agents = [AgentSpec("worker", "Worker", "", "", false)];
    cleared.activeAgentId = "worker"; cleared.nextSpeakerId = "orchestrator"; cleared.agentHops = 3;
    auto payload = runtimeThreadJson(cleared, true);
    applyRuntimeThreadPayload(restored[0], payload); applyRuntimeThreadPayload(restored[0], payload);
    assert(sessionToJson(restored[0]) == sessionToJson(cleared), "Metadata replacement changed or duplicated state");
    auto hostile = payload; hostile["id"] = "another-owner";
    hostile["snapshot"] = sessionToJson(initial);
    bool rejected;
    try applyRuntimeThreadPayload(restored[0], hostile); catch (Exception) { rejected = true; }
    assert(rejected && sessionToJson(restored[0]) == sessionToJson(cleared), "A mismatched owner partly rewrote metadata before rejection");
    writeln("PASS journal-only metadata recovery, explicit clears, shared decoding, bounded history revisions and owner isolation");
    return 0;
}
