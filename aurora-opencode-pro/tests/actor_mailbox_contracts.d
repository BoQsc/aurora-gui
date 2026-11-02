module actor_mailbox_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import auroraopencode.workerbudget : WorkerBudget;
import auroraopencode.attachmentstore : AttachmentStore;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse, write, rename;
import std.path : absolutePath, buildPath;
import std.json : parseJSON;
import std.process : environment;
import std.conv : to;
import std.stdio : writeln;

private final class Gate
{
    Mutex mutex; Condition wake; bool entered, released;
    this() { mutex = new Mutex(); wake = new Condition(mutex); }
    void block()
    {
        synchronized (mutex)
        { entered = true; wake.notifyAll(); while (!released) wake.wait(); }
    }
    void waitEntered() { synchronized (mutex) while (!entered) wake.wait(); }
    void release() { synchronized (mutex) { released = true; wake.notifyAll(); } }
}
private final class IdWriter
{
    string[] ids;
    void run() { foreach (_; 0 .. 1000) ids ~= newMessageId(); }
}

int main()
{
    IdWriter[] writers; Thread[] threads;
    foreach (_; 0 .. 8)
    { auto writer = new IdWriter(); writers ~= writer; auto thread = new Thread(&writer.run); threads ~= thread; thread.start(); }
    foreach (thread; threads) thread.join();
    bool[string] unique;
    foreach (writer; writers) foreach (id; writer.ids)
    { assert(!(id in unique), "Concurrent conversations generated the same graph ID"); unique[id] = true; }
    assert(unique.length == 8000);

    const directory = absolutePath("actor-mailbox-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    auto repository = new ConversationRepository(); auto gate = new Gate();
    scope (exit) { gate.release(); repository.close(); }
    auto journal = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    assert(repository.submit(&gate.block)); gate.waitEntered();
    ChatSession initial; initial.id = "mailbox-chat"; initial.model = "fixture";
    ActorConfiguration config;
    // With the real local provider driver, any accidental request here changes
    // its round count and fails the outer proof. The default remains refused.
    config.baseUrl = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "http://127.0.0.1:9");
    config.workspace = directory; config.recordTrace = true;
    auto budget = new WorkerBudget(1);
    auto actor = new ConversationActor(initial, config, journal, budget);
    bool full;
    try new ConversationActor(initial, config, journal, budget);
    catch (ActorCapacityException) { full = true; }
    assert(full && budget.active() == 1);
    assert(actor.post(ActorCommand(ActorCommandKind.start, "Preserve this accepted request")) == ActorAdmission.accepted);
    Thread.sleep(100.msecs); // owner is blocked behind the held journal job
    foreach (i; 0 .. 128)
        assert(actor.post(ActorCommand(ActorCommandKind.steer, "accepted-guidance-" ~ to!string(i))) == ActorAdmission.accepted);
    assert(actor.post(ActorCommand(ActorCommandKind.steer, "rejected-overflow")) == ActorAdmission.capacity);
    const stoppedAt = MonoTime.currTime;
    assert(actor.stop() == ActorAdmission.accepted);
    assert(budget.active() == 1, "Logical Stop released a physically blocked actor worker");
    assert((MonoTime.currTime - stoppedAt).total!"msecs" < 100,
        "Stop waited for storage or a full ordinary command queue");
    assert(actor.post(ActorCommand(ActorCommandKind.snapshot)) == ActorAdmission.accepted);
    const saturated = actor.queueStats();
    assert(saturated.commands == 128 && saturated.commandBytes <= 1024 * 1024);
    gate.release();
    bool stopped;
    const deadline = MonoTime.currTime + 8.seconds;
    while (!stopped && MonoTime.currTime < deadline)
    {
        foreach (change; actor.takeChanges())
            if (change.kind == ActorChangeKind.snapshot)
            {
                auto value = parseJSON(change.text);
                assert(value["queuedGuidance"].array.length == 128);
                assert(value["messages"].array.length == 1, "A cancelled admission produced a provider response");
                stopped = value["turnStatus"].str == "interrupted";
            }
        assert(!actor.fault().length, actor.fault()); Thread.sleep(5.msecs);
    }
    assert(stopped, "The worker never acknowledged Stop and the reserved snapshot");

    // A UI can stop consuming changes while the worker remains productive.
    // Delivery coalesces to an explicit resync instead of growing without bound.
    foreach (i; 0 .. 400)
    {
        while (actor.post(ActorCommand(ActorCommandKind.setDraft, "draft-" ~ to!string(i))) == ActorAdmission.capacity)
        { assert(!actor.fault().length, actor.fault()); Thread.sleep(1.msecs); }
    }
    const changed = MonoTime.currTime + 8.seconds;
    while (!actor.queueStats().resync && MonoTime.currTime < changed)
    { assert(!actor.fault().length, actor.fault()); Thread.sleep(5.msecs); }
    auto bounded = actor.queueStats();
    assert(bounded.resync && bounded.changes <= 256 && bounded.changeBytes <= 1024 * 1024);
    bool resync;
    foreach (change; actor.takeChanges()) if (change.kind == ActorChangeKind.resync) resync = true;
    assert(resync);
    assert(actor.post(ActorCommand(ActorCommandKind.snapshot)) == ActorAdmission.accepted);
    bool snapshot;
    const snapDeadline = MonoTime.currTime + 8.seconds;
    while (!snapshot && MonoTime.currTime < snapDeadline)
    {
        foreach (change; actor.takeChanges())
            if (change.kind == ActorChangeKind.snapshot)
            { snapshot = true; assert(parseJSON(change.text)["queuedGuidance"].array.length == 128); }
        assert(!actor.fault().length, actor.fault()); Thread.sleep(5.msecs);
    }
    assert(snapshot); actor.close();
    assert(budget.active() == 0);
    assert(actor.post(ActorCommand(ActorCommandKind.start, "late")) == ActorAdmission.closed);
    assert(!actor.fault().length, actor.fault());
    const finalState = actor.finalSnapshot();
    assert(parseJSON(finalState)["draft"].str == "draft-399");
    assert(parseJSON(ConversationActor.replay(initial, config, actor.recordedTrace())) == parseJSON(finalState));
    write(buildPath(directory, "final.json"), finalState);
    auto closeGate = new Gate();
    assert(repository.submit(&closeGate.block)); closeGate.waitEntered();
    auto closingInitial = initial; closingInitial.id = "closing-chat";
    auto closingActor = new ConversationActor(closingInitial, config, journal, budget);
    assert(closingActor.post(ActorCommand(ActorCommandKind.start, "Accepted before closing")) == ActorAdmission.accepted);
    Thread.sleep(50.msecs);
    assert(closingActor.post(ActorCommand(ActorCommandKind.steer, "Preserve on exit")) == ActorAdmission.accepted);
    const closeAt = MonoTime.currTime;
    assert(closingActor.requestClose() == ActorAdmission.accepted);
    assert((MonoTime.currTime - closeAt).total!"msecs" < 100 && budget.active() == 1);
    assert(closingActor.post(ActorCommand(ActorCommandKind.start, "too late")) == ActorAdmission.closed);
    closeGate.release(); closingActor.close(); closingActor.close();
    assert(budget.active() == 0 && !closingActor.fault().length, closingActor.fault());
    auto closedState = parseJSON(closingActor.finalSnapshot());
    assert(closedState["messages"].array[0]["content"].str == "Accepted before closing");
    assert(closedState["queuedGuidance"].array[0].str == "Preserve on exit");
    assert(closedState["turnStatus"].str == "interrupted");
    assert(parseJSON(ConversationActor.replay(closingInitial, config, closingActor.recordedTrace())) == closedState);

    auto imageInitial = initial; imageInitial.id = "image-view";
    ChatMessage imageMessage; imageMessage.id = "pixels"; imageMessage.role = "user";
    ChatImageAttachment image; image.mimeType = "image/png"; image.name = "pixel.png";
    image.base64Data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
    imageMessage.images = [image]; imageInitial.messages = [imageMessage]; imageInitial.activeLeafId = imageMessage.id;
    auto imageActor = new ConversationActor(imageInitial, config, null, budget);
    assert(imageActor.post(ActorCommand(ActorCommandKind.snapshot)) == ActorAdmission.accepted);
    bool imageView;
    const imageDeadline = MonoTime.currTime + 5.seconds;
    while (!imageView && MonoTime.currTime < imageDeadline)
    {
        foreach (change; imageActor.takeChanges()) if (change.kind == ActorChangeKind.snapshot)
        {
            auto attachment = parseJSON(change.text)["messages"].array[0]["images"].array[0];
            assert(!("base64Data" in attachment.object) && attachment["blob"].str.length == 64);
            auto store = AttachmentStore(buildPath(opencodeStateDirectory(), "attachments"));
            assert(store.get(attachment["blob"].str) == image.base64Data); imageView = true;
        }
        assert(!imageActor.fault().length, imageActor.fault()); Thread.sleep(2.msecs);
    }
    assert(imageView); imageActor.close();
    rename(buildPath(opencodeStateDirectory(), "attachments"), buildPath(opencodeStateDirectory(), "offline-attachments"));
    assert(parseJSON(ConversationActor.replay(imageInitial, config, imageActor.recordedTrace())) == parseJSON(imageActor.finalSnapshot()));
    const badPath = buildPath(directory, "journal-is-a-directory"); mkdirRecurse(badPath);
    auto failedGate = new Gate();
    assert(repository.submit(&failedGate.block)); failedGate.waitEntered();
    auto brokenJournal = new RepositoryRuntime(repository, badPath);
    auto failedInitial = initial; failedInitial.id = "failed-storage";
    failedInitial.goal = "Preserve the task through storage failure"; failedInitial.goalStatus = "active";
    auto failedActor = new ConversationActor(failedInitial, config, brokenJournal, budget);
    assert(failedActor.post(ActorCommand(ActorCommandKind.start, "Accepted before a failed journal write")) == ActorAdmission.accepted);
    Thread.sleep(50.msecs);
    auto steering = ActorCommand(ActorCommandKind.steer, "Accepted steering");
    steering.imagesJson = `[{"mimeType":"image/png","name":"accepted.png","base64Data":"accepted-pixels"}]`;
    steering.context = "Accepted file context";
    assert(failedActor.post(steering) == ActorAdmission.accepted);
    assert(failedActor.post(ActorCommand(ActorCommandKind.followUp, "Accepted follow-up")) == ActorAdmission.accepted);
    assert(failedActor.post(ActorCommand(ActorCommandKind.setDraft, "Unsent draft retained")) == ActorAdmission.accepted);
    failedGate.release();
    const failedDeadline = MonoTime.currTime + 5.seconds;
    while (!failedActor.isClosed() && MonoTime.currTime < failedDeadline) Thread.sleep(2.msecs);
    assert(failedActor.isClosed() && failedActor.fault().length);
    bool visibleFailure;
    foreach (change; failedActor.takeChanges())
        if (change.kind == ActorChangeKind.fault) { visibleFailure = true; assert(!change.busy); }
    assert(visibleFailure, "A failed owner closed without a reserved terminal notification");
    auto failedState = parseJSON(failedActor.finalSnapshot());
    assert(failedState["turnStatus"].str == "failed" && failedState["goalStatus"].str == "active");
    assert(failedState["queuedFollowUps"].array[0].str == "Accepted before a failed journal write",
        "Storage failure discarded accepted user input before it reached the graph");
    assert(failedState["queuedFollowUps"].array[1].str == "Accepted follow-up" &&
        failedState["queuedGuidance"].array[0].str == "Accepted steering" && failedState["draft"].str == "Unsent draft retained");
    assert(failedState["queuedGuidanceContext"].array[0]["images"].array[0]["base64Data"].str == "accepted-pixels" &&
        failedState["queuedGuidanceContext"].array[0]["text"].str == "Accepted file context",
        "Storage failure discarded an accepted attachment or hidden context");
    failedActor.close();
    bool incomplete;
    try failedActor.recordedTrace(); catch (Exception) { incomplete = true; }
    assert(incomplete, "A failed reduction advertised a complete replay recording");
    writeln("PASS 8000 concurrent IDs, bounded mailbox/view, reserved Stop/snapshot, zero cancelled effects, accepted-input retention and replay");
    return 0;
}
