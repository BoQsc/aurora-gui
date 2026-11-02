module composer_actor_contracts;

import auroraopencode.core;
import auroraopencode.composerstore;
import auroraopencode.conversationactor;
import auroraopencode.conversationregistry;
import auroraopencode.conversationconfiguration : actorBehaviorJson, decodeActorBehavior;
import auroraopencode.conversationencode;
import auroraopencode.repository;
import auroraopencode.runtime : projectAgentRuntimeEvents;
import auroraopencode.tools : nativeOnlyToolDefinitions, buildSystemPrompt;
import auroraopencode.attachmentstore : AttachmentStore;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : mkdirRecurse, write, readText;
import std.path : absolutePath, buildPath;
import std.process : environment;
import std.json : parseJSON;
import std.stdio : writeln;
import std.digest.sha : sha256Of;
import std.digest : toHexString;

private final class Gate
{
    Mutex mutex; Condition wake; bool entered, released;
    this() { mutex = new Mutex(); wake = new Condition(mutex); }
    void block() { synchronized (mutex) { entered = true; wake.notifyAll(); while (!released) wake.wait(); } }
    void waitEntered() { synchronized (mutex) while (!entered) wake.wait(); }
    void release() { synchronized (mutex) { released = true; wake.notifyAll(); } }
}
private void waitFor(bool delegate() condition)
{
    const deadline = MonoTime.currTime + 12.seconds;
    while (!condition() && MonoTime.currTime < deadline) Thread.sleep(2.msecs);
    assert(condition(), "Composer/actor integration did not reach its expected boundary");
}
int main()
{
    const base = environment.get("AURORA_CONTRACT_PROVIDER_BASE", ""); assert(base.length, "Run test_composer_actor.py");
    const directory = absolutePath("composer-actor-" ~ to!string(MonoTime.currTime.ticks));
    mkdirRecurse(directory); setOpencodeStateDirectoryForTesting(directory);
    write(buildPath(directory, "evidence.md"), "ACTUAL_EVIDENCE: recorded design tradeoffs");
    auto repository = new ConversationRepository(); auto journal = new RepositoryRuntime(repository, buildPath(directory, "runtime-events.jsonl"));
    auto gate = new Gate(); scope (exit) { gate.release(); repository.close(); }
    assert(repository.submit(&gate.block)); gate.waitEntered();
    auto store = new ComposerStore(directory); scope (exit) store.close(); waitFor(() => store.snapshot().ready);
    auto registry = new ConversationRegistry(journal, 1, null, null, &store.acknowledge); scope (exit) registry.close();
    ChatSession session; session.id = "composer-http"; session.model = "composer-http";
    ActorConfiguration config; config.baseUrl = base; config.apiKey = "fixture-private-connection-key"; config.workspace = directory;
    config.outageBudgetMs = 3000; config.request.toolsEnabled = true; config.request.contextLimit = 64_000;
    config.request.availableTools = nativeOnlyToolDefinitions(); config.request.baseSystemPrompt = buildSystemPrompt(true, directory, "win32", "auto");
    registry.register(session, config);
    store.setDispatcher((PendingPrompt input) {
        const saved = parseJSON(readText(buildPath(directory, "composer-state.json"))); bool found;
        foreach (pending; saved["pending"].array) if (pending["id"].str == input.command.inputId) found = true;
        assert(found, "Actor admission preceded durable outbox storage");
        auto behavior = parseJSON(input.behavior); auto captured = decodeActorBehavior(config, behavior);
        bool configured = input.configured;
        if (!configured)
        {
            const admission = registry.configure(input.threadId, captured, input.model, input.thinking);
            if (admission != ActorAdmission.accepted) return PromptDispatch(admission, false);
            configured = true;
        }
        return PromptDispatch(registry.post(input.threadId, input.command), configured);
    });
    ComposerDraft draft; draft.threadId = session.id; draft.text = "Analyze the tradeoffs using evidence.md and the attached image.";
    ChatImageAttachment image; image.mimeType = "image/png"; image.name = "pixel.png";
    image.base64Data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
    image.normalizationVersion = 1; image.width = image.height = image.originalWidth = image.originalHeight = 1;
    image.originalBlob = sha256Of(image.base64Data).toHexString().idup; image.originalMimeType = image.mimeType; image.originalDetail = true;
    draft.images = [image]; ulong draftRevision; assert(store.edit(draft, draftRevision) == ComposerAdmission.accepted);
    PendingPrompt input; input.threadId = session.id; input.model = session.model; input.draftRevision = draftRevision;
    input.behavior = actorBehaviorJson(config).toString(); input.command = ActorCommand(ActorCommandKind.start, draft.text); input.images = draft.images;
    input.command.connectionBase = base; input.command.connectionKey = config.apiKey;
    string inputId; assert(store.submit(input, inputId) == ComposerAdmission.accepted);
    waitFor(() => store.snapshot().pending.length == 1 && store.snapshot().pending[0].delivered);
    auto newer = ComposerDraft.init; newer.threadId = session.id; newer.text = "Unsubmitted text typed while saving";
    ulong newerRevision; assert(store.edit(newer, newerRevision) == ComposerAdmission.accepted);
    gate.release();
    ChatSession[] recovered;
    waitFor(() {
        recovered = projectAgentRuntimeEvents(journal.history());
        return recovered.length == 1 && recovered[0].turnStatus == "completed" && !store.snapshot().pending.length;
    });
    registry.close(); store.flushChecked();
    recovered = projectAgentRuntimeEvents(journal.history());
    assert(store.snapshot().drafts[0].text == newer.text && store.snapshot().drafts[0].revision == newerRevision);
    auto states = registry.takeClosedSessions(); assert(states.length == 1);
    size_t users, reads;
    foreach (message; states[0].messages)
    {
        if (message.role == "user" && !message.internal)
        {
            ++users; assert(message.inputId == inputId && message.inputCommitted && message.images.length == 1);
            assert(message.images[0].originalDetail && message.images[0].normalizationVersion == 1 && message.images[0].originalBlob == image.originalBlob);
        }
        if (message.role == "tool" && message.toolName == "read" && !message.failed) ++reads;
    }
    assert(users == 1 && reads == 1);
    auto canonical = sessionToJson(states[0]), savedState = sessionToJson(recovered[0]);
    auto attachments = AttachmentStore(buildPath(directory, "attachments")); attachments.externalize(canonical); attachments.externalize(savedState);
    if (canonical != savedState)
    {
        write(buildPath(directory, "canonical.json"), canonical.toString());
        write(buildPath(directory, "recovered.json"), savedState.toString());
    }
    assert(canonical == savedState, "Durable outbox and actor journal recovered different transcripts");
    store.close(); auto reopened = new ComposerStore(directory); waitFor(() => reopened.snapshot().ready);
    assert(!reopened.snapshot().pending.length && reopened.snapshot().drafts[0].text == newer.text); reopened.close();
    writeln("PASS durable composer -> bounded registry -> HTTP -> native read -> committed-input ack -> outbox cleanup; concurrent new draft and image references survive reload");
    return 0;
}
