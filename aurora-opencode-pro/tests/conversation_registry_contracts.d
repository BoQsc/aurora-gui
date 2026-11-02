module conversation_registry_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationregistry;
import auroraopencode.conversationprojection;
import auroraopencode.conversationencode : sessionToJson;
import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import auroraopencode.attachmentstore : AttachmentStore;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse;
import std.json : parseJSON;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.stdio : writeln;

private final class Gate
{
    Mutex mutex; Condition wake; bool entered, released;
    this() { mutex = new Mutex(); wake = new Condition(mutex); }
    void block() { synchronized (mutex) { entered = true; wake.notifyAll(); while (!released) wake.wait(); } }
    void waitEntered() { synchronized (mutex) while (!entered) wake.wait(); }
    void release() { synchronized (mutex) { released = true; wake.notifyAll(); } }
}

int main()
{
    const directory = absolutePath("conversation-registry-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    ActorConfiguration config; config.workspace = directory;
    config.baseUrl = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "http://127.0.0.1:9");
    ChatSession first; first.id = "first"; first.model = "fixture";
    ChatSession second = first; second.id = "second";

    // The physical slot is held behind storage. A second chat remains queued;
    // Stop and shutdown must retain its accepted image without starting HTTP.
    auto repository = new ConversationRepository(); auto gate = new Gate();
    scope (exit) { gate.release(); repository.close(); }
    auto journal = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    assert(repository.submit(&gate.block)); gate.waitEntered();
    auto registry = new ConversationRegistry(journal, 1);
    assert(registry.register(first, config) == ActorAdmission.accepted);
    assert(registry.post(first.id, ActorCommand(ActorCommandKind.start, "Accepted first request")) == ActorAdmission.accepted);
    const admitted = MonoTime.currTime + 5.seconds;
    while (registry.activeWorkers() != 1 && MonoTime.currTime < admitted) Thread.sleep(2.msecs);
    assert(registry.activeWorkers() == 1);
    assert(registry.register(second, config) == ActorAdmission.accepted);
    auto imageCommand = ActorCommand(ActorCommandKind.start, "Accepted capacity-waiting request");
    imageCommand.imagesJson = `[{"mimeType":"image/png","name":"held.png","base64Data":"held-pixels"}]`;
    imageCommand.context = "Accepted hidden file context";
    assert(registry.post(second.id, imageCommand) == ActorAdmission.accepted);
    assert(registry.post(second.id, ActorCommand(ActorCommandKind.stop)) == ActorAdmission.accepted);
    assert(registry.post(second.id, ActorCommand(ActorCommandKind.setDraft, "Draft after Stop")) == ActorAdmission.accepted);
    bool capacityWait;
    foreach (delivery; registry.takeChanges(16))
        if (delivery.threadId == second.id)
            capacityWait = delivery.state == ConversationOwnerState.waiting && delivery.pendingCommands == 2;
    assert(capacityWait && registry.activeWorkers() == 1, "Worker capacity did not have an explicit queued outcome");
    const stoppedAt = MonoTime.currTime; registry.requestClose();
    assert((MonoTime.currTime - stoppedAt).total!"msecs" < 100 && !registry.isClosed());
    assert(registry.post(first.id, ActorCommand(ActorCommandKind.start, "too late")) == ActorAdmission.closed);
    gate.release();
    const closeDeadline = MonoTime.currTime + 10.seconds;
    while (!registry.isClosed() && MonoTime.currTime < closeDeadline) Thread.sleep(2.msecs);
    assert(registry.isClosed() && registry.activeWorkers() == 0);
    registry.close(); registry.close();
    auto firstView = first, secondView = second;
    auto firstProjection = new ConversationProjection(firstView), secondProjection = new ConversationProjection(secondView);
    foreach (delivery; registry.takeChanges(16))
    {
        assert(!delivery.error.length, delivery.error);
        auto result = delivery.threadId == first.id ? firstProjection.apply(firstView, delivery.changes) :
            secondProjection.apply(secondView, delivery.changes);
        assert(!result.error.length && !result.needsSnapshot, result.error);
    }
    auto states = registry.takeClosedSessions(); assert(states.length == 2);
    assert(states[0].messages[0].content == "Accepted first request" && states[0].turnStatus == "interrupted");
    assert(states[1].messages[0].content == imageCommand.text && states[1].draft == "Draft after Stop");
    assert(states[1].messages[1].internal && states[1].messages[1].content == imageCommand.context);
    auto store = AttachmentStore(buildPath(opencodeStateDirectory(), "attachments"));
    assert(store.get(states[1].messages[0].images[0].blob) == "held-pixels");
    assert(sessionToJson(firstView) == sessionToJson(states[0]) && sessionToJson(secondView) == sessionToJson(states[1]),
        "Final shutdown state differed from its immutable projection");

    // Reuse one physical worker across idle conversations. New generations
    // require a full snapshot, so old revisions cannot suppress new changes.
    auto rotating = new ConversationRegistry(null, 1); scope (exit) rotating.close();
    assert(rotating.register(first, config) == ActorAdmission.accepted);
    assert(rotating.register(second, config) == ActorAdmission.accepted);
    string[] ids = [first.id, second.id, first.id];
    ulong[string] generations;
    ChatSession[string] views; views[first.id] = first; views[second.id] = second;
    ConversationProjection[string] projections;
    foreach (round, id; ids)
    {
        const draft = "Rotating draft " ~ to!string(round);
        assert(rotating.post(id, ActorCommand(ActorCommandKind.setDraft, draft)) == ActorAdmission.accepted);
        bool ready;
        const deadline = MonoTime.currTime + 5.seconds;
        while (!ready && MonoTime.currTime < deadline)
        {
            foreach (delivery; rotating.takeChanges(16))
            {
                assert(!delivery.error.length, delivery.error);
                if (!delivery.changes.length) continue;
                if (!(delivery.threadId in generations) || generations[delivery.threadId] != delivery.generation)
                {
                    assert(delivery.changes[0].kind == ActorChangeKind.snapshot);
                    generations[delivery.threadId] = delivery.generation;
                    projections[delivery.threadId] = new ConversationProjection(views[delivery.threadId]);
                }
                auto applied = projections[delivery.threadId].apply(views[delivery.threadId], delivery.changes);
                assert(!applied.error.length, applied.error);
                if (applied.requestSnapshot) rotating.post(delivery.threadId, ActorCommand(ActorCommandKind.snapshot));
            }
            ready = views[id].draft == draft;
            assert(rotating.activeWorkers() <= 1); Thread.sleep(2.msecs);
        }
        assert(ready, "Idle worker eviction failed to deliver the next conversation's state");
        if (round == 0)
        {
            auto next = config; next.outageBudgetMs = 15_000; next.request.contextLimit = 32_000;
            assert(rotating.configure(first.id, next, "model-after-reconfiguration", true) == ActorAdmission.accepted);
        }
    }
    assert(generations[first.id] == 2 && generations[second.id] == 1);
    assert(views[first.id].model == "model-after-reconfiguration" && views[first.id].thinking,
        "Owner recreation discarded a committed session configuration");
    rotating.close();

    // One invalid optional configuration must not block other conversations
    // or discard its own accepted text, goal, image and hidden file context.
    auto failures = new ConversationRegistry(null, 1); scope (exit) failures.close();
    auto invalid = config; invalid.request.contextLimit = -1;
    auto broken = first; broken.id = "unsupported-configuration";
    broken.goal = "Keep this persistent goal"; broken.goalStatus = "active";
    assert(failures.register(broken, invalid) == ActorAdmission.accepted);
    assert(failures.post(broken.id, imageCommand) == ActorAdmission.accepted);
    assert(failures.register(second, config) == ActorAdmission.accepted);
    assert(failures.post(second.id, ActorCommand(ActorCommandKind.setDraft, "Healthy owner still progresses")) == ActorAdmission.accepted);
    bool sawFailure, healthy;
    const failureDeadline = MonoTime.currTime + 5.seconds;
    while ((!sawFailure || !healthy) && MonoTime.currTime < failureDeadline)
    {
        foreach (delivery; failures.takeChanges(16))
        {
            if (delivery.threadId == broken.id && delivery.error.length) sawFailure = true;
            if (delivery.threadId == second.id)
                foreach (change; delivery.changes) if (change.kind == ActorChangeKind.snapshot ||
                    change.kind == ActorChangeKind.metadata || change.kind == ActorChangeKind.metadataPatch)
                {
                    const value = parseJSON(change.text);
                    if (auto draft = "draft" in value.object) healthy = draft.str == "Healthy owner still progresses";
                }
        }
        Thread.sleep(2.msecs);
    }
    assert(sawFailure && healthy, "A construction failure blocked the lifecycle owner");
    failures.close(); auto recovered = failures.takeClosedSessions();
    assert(recovered[0].goalStatus == "active" && recovered[0].queuedFollowUps[0] == imageCommand.text);
    assert(recovered[0].queuedFollowUpContext[0].images[0].base64Data == "held-pixels" &&
        recovered[0].queuedFollowUpContext[0].text == imageCommand.context);
    writeln("PASS bounded lifecycle admission, Stop at capacity, held-storage shutdown, generation resync and isolated construction failure");
    return 0;
}
