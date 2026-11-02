module composer_store_contracts;

import auroraopencode.core;
import auroraopencode.composerstore;
import auroraopencode.conversationactor;
import auroraopencode.atomicfile;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.file : mkdirRecurse, readText, write;
import std.path : absolutePath, buildPath;
import std.json : parseJSON;
import std.conv : to;
import std.stdio : writeln;
import std.array : replicate;
import std.string : indexOf;

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
    const deadline = MonoTime.currTime + 8.seconds;
    while (!condition() && MonoTime.currTime < deadline) Thread.sleep(2.msecs);
    assert(condition(), "Composer storage did not reach its expected boundary");
}
int main()
{
    const directory = absolutePath("composer-store-" ~ to!string(MonoTime.currTime.ticks)); mkdirRecurse(directory);
    const path = buildPath(directory, "composer-state.json");
    auto gate = new Gate(); size_t writes;
    auto store = new ComposerStore(directory, null, (string data) {
        if (++writes == 1) gate.block(); writeFileAtomically(path, data);
    });
    scope (exit) { gate.release(); store.close(); }
    waitFor(() => store.snapshot().ready);
    ComposerDraft draft; draft.threadId = "chat"; draft.text = "Analyze the attached design.";
    ChatImageAttachment image; image.mimeType = "image/png"; image.name = "large.png"; image.base64Data = "A".replicate(2 * 1024 * 1024);
    image.normalizationVersion = 1; image.width = 1; image.height = 1;
    auto imageValue = imageAttachmentToJson(image);
    assert(imageAttachmentFromJson(imageValue).normalizationVersion == 1, "In-memory image encoding lost its normalization version");
    draft.images = [image]; ulong originalRevision;
    assert(store.edit(draft, originalRevision) == ComposerAdmission.accepted); gate.waitEntered();
    PendingPrompt prompt; prompt.threadId = draft.threadId; prompt.draftRevision = originalRevision;
    prompt.command = ActorCommand(ActorCommandKind.start, draft.text); prompt.images = draft.images;
    prompt.command.connectionBase = "http://fixture.invalid/v1"; prompt.command.connectionKey = "fixture-secret-credential";
    prompt.behavior = "{}"; prompt.model = "fixture";
    string inputId; assert(store.submit(prompt, inputId) == ComposerAdmission.accepted);
    auto observedMutex = new Mutex(); string[] delivered;
    store.setDispatcher((PendingPrompt input) {
        const saved = parseJSON(readText(path)); bool persisted;
        foreach (value; saved["pending"].array) if (value["id"].str == input.command.inputId) persisted = true;
        assert(persisted, "Submission dispatched before its outbox was durable");
        assert(!ConversationActor.oversizedCommand(input.command), "Large inline pixels entered the actor mailbox");
        assert(input.command.imagesJson.length < 1024);
        synchronized (observedMutex) delivered ~= input.command.inputId;
        return PromptDispatch(ActorAdmission.accepted, true);
    });
    const editedAt = MonoTime.currTime; ulong latestRevision;
    ComposerDraft later; later.threadId = "chat";
    foreach (i; 0 .. 10_000)
    {
        later.text = "New draft " ~ to!string(i);
        assert(store.edit(later, latestRevision) == ComposerAdmission.accepted);
    }
    assert((MonoTime.currTime - editedAt).total!"msecs" < 2000, "Draft edits waited for the held storage sink");
    gate.release(); store.flushChecked(); waitFor(() => store.snapshot().pending.length == 1 && store.snapshot().pending[0].delivered);
    assert(writes == 2, "Draft edits created an unbounded write backlog");
    auto saved = parseJSON(readText(path));
    assert(saved["pending"][0]["images"].array.length == 1 && saved["pending"][0]["images"][0]["blob"].str.length == 64);
    assert(readText(path).indexOf("fixture-secret-credential") < 0 && readText(path).length < 4096);
    assert(store.snapshot().pending[0].command.connectionKey == "");
    assert(store.snapshot().pending[0].images[0].normalizationVersion == 1);
    store.acknowledge(ActorInputAcknowledgement("chat", inputId, true)); store.flushChecked();
    auto snapshot = store.snapshot(); assert(!snapshot.pending.length && snapshot.drafts[0].text == "New draft 9999" && snapshot.drafts[0].revision == latestRevision);
    prompt.images = null; prompt.command.text = snapshot.drafts[0].text; prompt.draftRevision = latestRevision;
    assert(store.submit(prompt, inputId) == ComposerAdmission.accepted);
    waitFor(() => store.snapshot().pending.length == 1 && store.snapshot().pending[0].delivered);
    store.acknowledge(ActorInputAcknowledgement("chat", inputId, true)); store.flushChecked();
    assert(!store.snapshot().drafts[0].text.length);
    store.close();

    const failureDir = buildPath(directory, "failure"); mkdirRecurse(failureDir);
    auto failGate = new Gate(); size_t attempts, effects; bool allowWrite;
    auto failing = new ComposerStore(failureDir, null, (string data) {
        if (++attempts == 1) failGate.block();
        bool available; synchronized (observedMutex) available = allowWrite;
        if (!available) throw new Exception("simulated disk failure");
        writeFileAtomically(buildPath(failureDir, "composer-state.json"), data);
    });
    scope (exit) { failGate.release(); failing.close(); }
    waitFor(() => failing.snapshot().ready);
    later.text = "Retain this exact request"; ulong failureRevision;
    failing.edit(later, failureRevision); failGate.waitEntered();
    prompt.command.text = later.text; prompt.draftRevision = failureRevision;
    assert(failing.submit(prompt, inputId) == ComposerAdmission.accepted);
    failing.setDispatcher((PendingPrompt value) { ++effects; return PromptDispatch(ActorAdmission.accepted, true); });
    failGate.release(); bool rejected;
    try failing.flushChecked(); catch (Exception) { rejected = true; }
    assert(rejected && effects == 0 && !failing.snapshot().pending[0].durable);
    synchronized (observedMutex) allowWrite = true;
    failing.retry(); failing.flushChecked(); waitFor(() => failing.snapshot().pending[0].delivered);
    assert(effects == 1);
    failing.close();
    auto restored = new ComposerStore(failureDir); scope (exit) restored.close(); waitFor(() => restored.snapshot().ready);
    snapshot = restored.snapshot(); assert(snapshot.pending.length == 1 && snapshot.pending[0].durable && !snapshot.pending[0].delivered);
    assert(snapshot.pending[0].command.text == later.text && snapshot.pending[0].command.connectionKey == "");
    restored.acknowledge(ActorInputAcknowledgement("chat", inputId, false)); restored.flushChecked();
    assert(restored.snapshot().pending[0].rejected && restored.snapshot().drafts[0].text == later.text);
    restored.edit(later, latestRevision); restored.flushChecked(); assert(!restored.snapshot().pending.length); restored.close();

    const corruptDir = buildPath(directory, "corrupt"); mkdirRecurse(corruptDir);
    const corruptPath = buildPath(corruptDir, "composer-state.json"); write(corruptPath, "{broken"); write(corruptPath ~ ".bak", "{also broken");
    auto corrupt = new ComposerStore(corruptDir); waitFor(() => corrupt.snapshot().ready);
    assert(corrupt.snapshot().error.length && corrupt.edit(later, latestRevision) == ComposerAdmission.storageFailed);
    corrupt.retry(); corrupt.close(); assert(readText(corruptPath) == "{broken" && readText(corruptPath ~ ".bak") == "{also broken");
    const orderDir = buildPath(directory, "ordering"); mkdirRecurse(orderDir);
    auto ordered = new ComposerStore(orderDir); scope (exit) ordered.close(); waitFor(() => ordered.snapshot().ready);
    string[] submissionIds;
    foreach (text; ["A1", "A2", "B1"])
    {
        auto next = prompt; next.threadId = text[0] == 'A' ? "a" : "b"; next.command.text = text;
        next.command.imagesJson = ""; next.images = null; next.draftRevision = 0;
        string id; assert(ordered.submit(next, id) == ComposerAdmission.accepted); submissionIds ~= id;
    }
    ordered.flushChecked(); bool allowA; string[] effectsOrder;
    ordered.setDispatcher((PendingPrompt input) {
        synchronized (observedMutex)
        {
            if (input.command.text == "A1" && !allowA) return PromptDispatch(ActorAdmission.capacity, true);
            effectsOrder ~= input.command.text; return PromptDispatch(ActorAdmission.accepted, true);
        }
    });
    waitFor(() => ordered.snapshot().pending[2].delivered);
    assert(!ordered.snapshot().pending[1].delivered, "A later same-chat submission overtook a blocked predecessor");
    synchronized (observedMutex) allowA = true;
    waitFor(() => ordered.snapshot().pending[1].delivered);
    synchronized (observedMutex) assert(effectsOrder == ["B1", "A1", "A2"]);
    ordered.close();
    auto orderedRecovery = new ComposerStore(orderDir); waitFor(() => orderedRecovery.snapshot().ready);
    snapshot = orderedRecovery.snapshot();
    foreach (i; 0 .. 3) assert(snapshot.pending[i].command.inputId == submissionIds[i] && !snapshot.pending[i].delivered);
    orderedRecovery.close();

    version (Windows)
    {
        import core.sys.windows.windows : CreateFileW, CloseHandle, GENERIC_READ, FILE_SHARE_READ, FILE_SHARE_WRITE,
            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, INVALID_HANDLE_VALUE;
        import std.utf : toUTF16z;
        const protectedPath = buildPath(directory, "protected.json");
        write(protectedPath, "{corrupt"); write(protectedPath ~ ".bak", `{"good":true}`);
        preserveBackupOnNextWrite(protectedPath);
        auto handle = CreateFileW(toUTF16z(protectedPath), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
            null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        assert(handle != INVALID_HANDLE_VALUE);
        bool failed; try writeFileAtomically(protectedPath, `{"replacement":true}`); catch (Exception) { failed = true; }
        assert(failed && readText(protectedPath ~ ".bak") == `{"good":true}`, "Failed installation destroyed the recovered backup");
        CloseHandle(handle); writeFileAtomically(protectedPath, `{"replacement":true}`);
        assert(readText(protectedPath ~ ".bak") == `{"good":true}`);
        writeFileAtomically(protectedPath, `{"later":true}`);
        assert(readText(protectedPath ~ ".bak") == `{"replacement":true}`, "Backup protection did not retire after a successful installation");
    }
    writeln("PASS 10000 edits coalesce to two writes, saved-before-dispatch, large-image references, secret exclusion, newer-draft preservation, write-failure recovery, pending replay and corrupt-file preservation");
    return 0;
}
