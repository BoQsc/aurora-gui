module actor_attachment_command_contracts;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.repository : ConversationRepository, RepositoryRuntime;
import auroraopencode.runtime : projectAgentRuntimeEvents;
import auroraopencode.queuedprompts : takeQueuedPrompt;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, rename;
import std.json : JSONValue, JSONType, parseJSON;
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
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", "");
    assert(base.length, "Run test_actor_images.py");
    const directory = absolutePath("actor-input-images-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(buildPath(directory, "state"));
    auto repository = new ConversationRepository(); auto gate = new Gate();
    scope (exit) { gate.release(); repository.close(); }
    auto journal = new RepositoryRuntime(repository, buildPath(directory, "events.jsonl"));
    assert(repository.submit(&gate.block)); gate.waitEntered();
    ChatSession initial; initial.id = "image-input"; initial.model = "actor-images";
    ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture";
    config.workspace = directory; config.recordTrace = true; config.request.contextLimit = 64_000;
    auto actor = new ConversationActor(initial, config, journal);
    ChatImageAttachment image; image.name = "input.png"; image.mimeType = "image/png";
    image.base64Data = "fixture-input-pixels";
    ActorCommand first; first.kind = ActorCommandKind.start; first.text = "Analyze this first attachment.";
    first.imagesJson = JSONValue([imageAttachmentToJson(image)]).toString(); first.context = "Hidden first file evidence.";
    auto second = first; second.kind = ActorCommandKind.followUp; second.text = "Analyze this second attachment.";
    second.context = "Hidden second file evidence.";
    assert(actor.post(first) == ActorAdmission.accepted);
    assert(actor.post(second) == ActorAdmission.accepted);
    gate.release();
    bool done; JSONValue latest;
    const deadline = MonoTime.currTime + 15.seconds;
    while (!done && MonoTime.currTime < deadline)
    {
        foreach (change; actor.takeChanges())
        {
            assert(change.kind != ActorChangeKind.fault, change.text);
            if (change.kind == ActorChangeKind.metadata) latest = parseJSON(change.text);
        }
        if (latest.type == JSONType.object)
            done = latest["turnStatus"].str == "completed" && !("queuedFollowUps" in latest.object);
        assert(!actor.fault().length, actor.fault()); Thread.sleep(2.msecs);
    }
    assert(done); actor.close(); assert(!actor.fault().length, actor.fault());
    const state = parseJSON(actor.finalSnapshot());
    assert(latest["execution"]["routingKey"].str == "aurora-" ~ state["messages"].array[0]["id"].str,
        "A new conversation retained the default provider route");
    size_t humanImages, contexts, answers;
    foreach (message; state["messages"].array)
    {
        if (message["role"].str == "assistant") ++answers;
        if (auto images = "images" in message.object) if (images.array.length) ++humanImages;
        if (auto internal = "internal" in message.object)
            if (internal.boolean && message["content"].str.length) ++contexts;
    }
    assert(humanImages == 2 && contexts == 2 && answers == 2, "Queued attachment or hidden context was lost");
    bool durableQueue;
    foreach (event; journal.history())
    {
        const value = parseJSON(event.payloadJson);
        if (value.type != JSONType.object) continue;
        if (auto queued = "queuedFollowUpContext" in value.object)
            if (queued.array.length)
            {
                const attachment = queued.array[0]["images"].array[0];
                assert(attachment["blob"].str.length == 64 &&
                    (!("base64Data" in attachment.object) || !attachment["base64Data"].str.length));
                durableQueue = true;
                auto projected = projectAgentRuntimeEvents([event]);
                assert(projected.length == 1 && projected[0].queuedFollowUpContext[0].images[0].blob.length == 64,
                    "Journal projection dropped queued image references");
            }
    }
    assert(durableQueue, "Queued images bypassed durable admission");
    const trace = actor.recordedTrace();
    const attachments = buildPath(opencodeStateDirectory(), "attachments");
    rename(attachments, attachments ~ "-offline"); config.baseUrl = "http://127.0.0.1:1";
    assert(parseJSON(ConversationActor.replay(initial, config, trace)) == state);

    // Removing a middle queued entry must move its optional context with it.
    ChatSession queue; queue.queuedFollowUps = ["plain", "image", "plain tail"];
    ChatPromptContext detail; detail.text = "body"; detail.images = [image];
    queue.queuedFollowUpContext = [ChatPromptContext.init, detail];
    auto saved = snapshotChatSessions([queue]); queue.queuedFollowUpContext[1].images[0].name = "changed";
    assert(saved[0].queuedFollowUpContext[1].images[0].name == "input.png");
    auto removed = takeQueuedPrompt(queue, false, 0); assert(removed.text == "plain");
    removed = takeQueuedPrompt(queue, false); assert(removed.text == "image" && removed.context.text == "body");
    removed = takeQueuedPrompt(queue, false); assert(removed.text == "plain tail" && !removed.context.images.length);
    writeln("PASS image-bearing commands, durable queued context, aligned removal, detached snapshots and offline replay");
    return 0;
}
