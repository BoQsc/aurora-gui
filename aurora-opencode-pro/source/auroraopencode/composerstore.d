module auroraopencode.composerstore;

import auroraopencode.core;
import auroraopencode.conversationactor : ActorCommand, ActorCommandKind, ActorAdmission,
    ActorInputAcknowledgement, ConversationActor;
import auroraopencode.attachmentstore : AttachmentStore;
import auroraopencode.atomicfile : writeFileAtomically, preserveBackupOnNextWrite;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, readText, mkdirRecurse, getSize;
import std.path : buildPath;
import std.json : JSONValue, JSONType, parseJSON;
import std.algorithm : sort;

public enum ComposerAdmission { accepted, capacity, closed, notReady, invalid, storageFailed }
public struct ComposerDraft
{
    string threadId, text, context;
    ChatImageAttachment[] images;
    ulong revision;
}
public struct PendingPrompt
{
    string threadId, behavior, model;
    bool thinking;
    ulong draftRevision;
    ulong order;
    ActorCommand command;
    ChatImageAttachment[] images;
    bool durable, configured, delivered, rejected;
    string error;
}
public struct PromptDispatch { ActorAdmission admission; bool configured; string error; }
public alias PromptDispatcher = PromptDispatch delegate(PendingPrompt);
public struct ComposerSnapshot
{
    bool ready, closed;
    string error;
    ComposerDraft[] drafts;
    PendingPrompt[] pending;
}

/// Drafts and the submission outbox have one disk owner. UI calls only capture
/// immutable text and detached image descriptors. Dispatch follows the saved
/// outbox; deletion follows the actor's durable command acknowledgement.
public final class ComposerStore
{
    private Mutex mutex, joinMutex;
    private Condition wake;
    private Thread worker;
    private string directory, path;
    private ComposerDraft[string] drafts;
    private PendingPrompt[string] pending;
    private ulong revision;
    private ulong nextOrder;
    private bool ready, closing, closed, joined, dirty, writing, loadFailed;
    private string error;
    private PromptDispatcher dispatcher;
    private void delegate() changed;
    private void delegate(string) sink;
    public enum maxDrafts = 256, maxPending = 128;
    public enum size_t memoryBudget = 32 * 1024 * 1024, fileBudget = 8 * 1024 * 1024;

    this(string directory, void delegate() changed = null, void delegate(string) sink = null)
    {
        this.directory = directory; path = buildPath(directory, "composer-state.json");
        this.changed = changed; this.sink = sink;
        mutex = new Mutex(); joinMutex = new Mutex(); wake = new Condition(mutex);
        worker = new Thread(&run); worker.isDaemon = true; worker.start();
    }
    private void notify() { if (changed !is null) changed(); }
    void setDispatcher(PromptDispatcher value) { synchronized (mutex) { dispatcher = value; wake.notifyAll(); } }
    ComposerSnapshot snapshot()
    {
        synchronized (mutex)
        {
            ComposerSnapshot value; value.ready = ready; value.closed = closed; value.error = error;
            foreach (draft; drafts) { draft.images = draft.images.dup; value.drafts ~= draft; }
            foreach (prompt; pending)
            {
                prompt.images = prompt.images.dup;
                prompt.command.connectionBase = ""; prompt.command.connectionKey = "";
                value.pending ~= prompt;
            }
            value.pending.sort!((a, b) => a.order < b.order);
            return value;
        }
    }
    ComposerAdmission edit(ComposerDraft value, out ulong savedRevision)
    {
        savedRevision = 0; value.images = value.images.dup;
        synchronized (mutex)
        {
            if (closing || closed) return ComposerAdmission.closed;
            if (!ready) return ComposerAdmission.notReady;
            if (loadFailed) return ComposerAdmission.storageFailed;
            if (!value.threadId.length) return ComposerAdmission.invalid;
            if (!(value.threadId in drafts) && drafts.length >= maxDrafts) return ComposerAdmission.capacity;
            const old = value.threadId in drafts;
            if (cost(value) > memoryBudget - retainedBytes() + (old is null ? 0 : cost(*old))) return ComposerAdmission.capacity;
            value.revision = ++revision; savedRevision = value.revision; drafts[value.threadId] = value;
            // Editing supersedes rejected submissions for this composer only.
            string[] remove;
            foreach (id, prompt; pending) if (prompt.threadId == value.threadId && prompt.rejected) remove ~= id;
            foreach (id; remove) pending.remove(id);
            dirty = true; wake.notifyAll();
        }
        return ComposerAdmission.accepted;
    }
    ComposerAdmission submit(PendingPrompt value, out string inputId)
    {
        inputId = ""; value.images = value.images.dup;
        synchronized (mutex)
        {
            if (closing || closed) return ComposerAdmission.closed;
            if (!ready) return ComposerAdmission.notReady;
            if (loadFailed) return ComposerAdmission.storageFailed;
            if (!value.threadId.length || (!value.command.text.length && !value.command.context.length &&
                !value.command.imagesJson.length && !value.images.length)) return ComposerAdmission.invalid;
            if (error.length) return ComposerAdmission.storageFailed;
            if (value.command.imagesJson.length) return ComposerAdmission.invalid;
            if (value.command.kind != ActorCommandKind.start && value.command.kind != ActorCommandKind.steer &&
                value.command.kind != ActorCommandKind.followUp && value.command.kind != ActorCommandKind.editPrompt)
                return ComposerAdmission.invalid;
            if (pending.length >= maxPending || cost(value) > memoryBudget - retainedBytes()) return ComposerAdmission.capacity;
            value.command.inputId = newMessageId(); inputId = value.command.inputId;
            value.order = ++nextOrder;
            value.durable = value.configured = value.delivered = value.rejected = false; value.error = "";
            pending[inputId] = value; dirty = true; wake.notifyAll();
        }
        notify(); return ComposerAdmission.accepted;
    }
    void acknowledge(ActorInputAcknowledgement acknowledgement)
    {
        synchronized (mutex)
        {
            if (closed) return;
            auto found = acknowledgement.inputId in pending;
            if (found is null || found.threadId != acknowledgement.threadId) return;
            const prompt = *found;
            if (acknowledgement.retained)
            {
                pending.remove(acknowledgement.inputId);
                if (auto draft = prompt.threadId in drafts)
                    if (draft.revision == prompt.draftRevision)
                    { draft.text = draft.context = ""; draft.images = null; draft.revision = ++revision; }
            }
            else { found.rejected = true; found.error = "The submitted input was not accepted. Its draft was preserved."; }
            dirty = true; wake.notifyAll();
        }
        notify();
    }
    void retry() { synchronized (mutex) if (!loadFailed && !closed) { error = ""; dirty = true; wake.notifyAll(); } }
    void flushChecked()
    {
        synchronized (mutex)
        {
            while (!ready || dirty || writing) wake.wait();
            if (error.length) throw new Exception(error);
        }
    }
    void requestClose() { synchronized (mutex) { closing = true; wake.notifyAll(); } }
    void close()
    {
        synchronized (joinMutex) { if (joined) return; requestClose(); worker.join(); joined = true; }
    }
    private static size_t cost(const ref ComposerDraft value)
    {
        size_t result = ComposerDraft.sizeof + value.threadId.length + value.text.length + value.context.length;
        foreach (image; value.images) result += ChatImageAttachment.sizeof + image.base64Data.length + image.name.length + image.mimeType.length;
        return result;
    }
    private static size_t cost(const ref PendingPrompt value)
    {
        auto result = PendingPrompt.sizeof + value.threadId.length + value.behavior.length + value.model.length +
            value.command.text.length + value.command.targetId.length + value.command.context.length + value.command.imagesJson.length +
            value.command.inputId.length + value.command.connectionBase.length + value.command.connectionKey.length;
        foreach (image; value.images) result += ChatImageAttachment.sizeof + image.base64Data.length + image.name.length + image.mimeType.length;
        return result;
    }
    private size_t retainedBytes()
    { size_t result; foreach (draft; drafts) result += cost(draft); foreach (prompt; pending) result += cost(prompt); return result; }

    private JSONValue imageValues(ChatImageAttachment[] images, AttachmentStore attachments)
    {
        auto values = JSONValue.emptyArray;
        foreach (image; images) values.array ~= imageAttachmentToJson(image);
        attachments.externalize(values); return values;
    }
    private static ChatImageAttachment[] readImages(const ref JSONValue values)
    { ChatImageAttachment[] images; foreach (value; values.array) images ~= imageAttachmentFromJson(value); return images; }
    private string encode(ref ComposerDraft[] draftCopy, ref PendingPrompt[] promptCopy)
    {
        auto attachments = AttachmentStore(buildPath(directory, "attachments"));
        JSONValue root; root["version"] = 1; root["drafts"] = JSONValue.emptyArray; root["pending"] = JSONValue.emptyArray;
        foreach (ref draft; draftCopy)
        {
            JSONValue value; value["thread"] = draft.threadId; value["revision"] = cast(long) draft.revision;
            value["text"] = draft.text; value["context"] = draft.context; value["images"] = imageValues(draft.images, attachments);
            draft.images = readImages(value["images"]); root["drafts"].array ~= value;
        }
        foreach (ref prompt; promptCopy)
        {
            if (prompt.command.imagesJson.length)
            {
                auto existing = parseJSON(prompt.command.imagesJson); attachments.externalize(existing);
                prompt.command.imagesJson = existing.toString();
            }
            if (prompt.images.length)
            {
                auto values = imageValues(prompt.images, attachments); prompt.images = readImages(values);
                prompt.command.imagesJson = values.toString();
            }
            if (ConversationActor.oversizedCommand(prompt.command))
            { prompt.rejected = true; prompt.error = "The prompt and hidden text exceed the 1 MiB command budget. The original submission was preserved."; }
            JSONValue value; value["thread"] = prompt.threadId; value["behavior"] = prompt.behavior;
            value["order"] = cast(long) prompt.order;
            value["model"] = prompt.model; value["thinking"] = prompt.thinking; value["draftRevision"] = cast(long) prompt.draftRevision;
            value["id"] = prompt.command.inputId; value["kind"] = cast(int) prompt.command.kind;
            value["text"] = prompt.command.text; value["target"] = prompt.command.targetId;
            value["context"] = prompt.command.context;
            value["images"] = prompt.command.imagesJson.length ? parseJSON(prompt.command.imagesJson) : JSONValue.emptyArray;
            value["rejected"] = prompt.rejected; value["error"] = prompt.error;
            root["pending"].array ~= value;
        }
        const encoded = root.toString(); if (encoded.length > fileBudget) throw new Exception("Composer recovery data exceeds its 8 MiB storage budget. Pending inputs were preserved in memory.");
        return encoded;
    }
    private void decode(JSONValue root)
    {
        if (root["version"].integer != 1 || root["drafts"].array.length > maxDrafts || root["pending"].array.length > maxPending)
            throw new Exception("Invalid composer recovery data");
        ComposerDraft[string] loadedDrafts; PendingPrompt[string] loadedPrompts; ulong latest, latestOrder;
        bool[ulong] orders;
        auto attachments = AttachmentStore(buildPath(directory, "attachments")); attachments.externalize(root);
        foreach (value; root["drafts"].array)
        {
            ComposerDraft draft; draft.threadId = value["thread"].str; draft.text = value["text"].str; draft.context = value["context"].str;
            if (!draft.threadId.length || draft.threadId in loadedDrafts || value["revision"].integer < 0) throw new Exception("Invalid composer draft identity");
            draft.revision = cast(ulong) value["revision"].integer; draft.images = readImages(value["images"]);
            if (latest < draft.revision) latest = draft.revision; loadedDrafts[draft.threadId] = draft;
        }
        foreach (value; root["pending"].array)
        {
            PendingPrompt prompt; prompt.threadId = value["thread"].str; prompt.behavior = value["behavior"].str;
            prompt.model = value["model"].str; prompt.thinking = value["thinking"].boolean;
            if (value["draftRevision"].integer < 0) throw new Exception("Invalid composer submission revision");
            prompt.draftRevision = cast(ulong) value["draftRevision"].integer; prompt.command.inputId = value["id"].str;
            if (value["order"].integer <= 0) throw new Exception("Invalid composer submission order");
            prompt.order = cast(ulong) value["order"].integer;
            if (prompt.order in orders) throw new Exception("Duplicate composer submission order");
            orders[prompt.order] = true; if (latestOrder < prompt.order) latestOrder = prompt.order;
            prompt.command.kind = cast(ActorCommandKind) value["kind"].integer;
            prompt.command.text = value["text"].str; prompt.command.context = value["context"].str;
            prompt.command.targetId = value["target"].str; prompt.command.imagesJson = value["images"].toString();
            prompt.images = readImages(value["images"]);
            prompt.rejected = value["rejected"].boolean; prompt.error = value["error"].str; prompt.durable = true;
            if (!prompt.threadId.length || !prompt.command.inputId.length || prompt.command.inputId in loadedPrompts ||
                !ConversationActor.validInputIdentity(prompt.command)) throw new Exception("Invalid composer submission identity");
            loadedPrompts[prompt.command.inputId] = prompt;
        }
        size_t loadedBytes; foreach (draft; loadedDrafts) loadedBytes += cost(draft); foreach (prompt; loadedPrompts) loadedBytes += cost(prompt);
        if (loadedBytes > memoryBudget) throw new Exception("Composer recovery data exceeds its memory budget");
        synchronized (mutex) { drafts = loadedDrafts; pending = loadedPrompts; revision = latest; nextOrder = latestOrder; }
    }
    private void load()
    {
        bool found; string failure;
        foreach (candidate; [path, path ~ ".bak"])
        {
            if (!exists(candidate)) continue;
            found = true;
            try
            {
                if (getSize(candidate) > fileBudget) throw new Exception("Composer recovery file is larger than 8 MiB");
                decode(parseJSON(readText(candidate)));
                if (candidate != path) preserveBackupOnNextWrite(path);
                return;
            }
            catch (Exception e) { failure = e.msg; }
        }
        if (found) { synchronized (mutex) { loadFailed = true; error = "Composer recovery is unreadable; its files were preserved: " ~ failure; } }
    }
    private void run()
    {
        scope (exit) { synchronized (mutex) { closed = true; wake.notifyAll(); } notify(); }
        try load(); catch (Exception e) { synchronized (mutex) { loadFailed = true; error = e.msg; } }
        synchronized (mutex) { ready = true; wake.notifyAll(); } notify();
        while (true)
        {
            ComposerDraft[] draftCopy; PendingPrompt[] promptCopy; bool save; PromptDispatcher dispatch;
            synchronized (mutex)
            {
                if (closing && !dirty) return;
                if (dirty && !loadFailed)
                {
                    foreach (draft; drafts) { draft.images = draft.images.dup; draftCopy ~= draft; }
                    foreach (prompt; pending) { prompt.images = prompt.images.dup; promptCopy ~= prompt; }
                    promptCopy.sort!((a, b) => a.order < b.order);
                    dirty = false; writing = true; save = true;
                }
                dispatch = closing || error.length ? null : dispatcher;
                if (!save && dispatch is null) { wake.wait(20.msecs); continue; }
            }
            if (save)
            {
                string failure;
                try
                {
                    const encoded = encode(draftCopy, promptCopy); mkdirRecurse(directory);
                    if (sink !is null) sink(encoded); else writeFileAtomically(path, encoded);
                }
                catch (Exception e) { failure = e.msg; }
                synchronized (mutex)
                {
                    error = failure; writing = false;
                    if (!failure.length)
                    {
                        foreach (draft; draftCopy) if (auto current = draft.threadId in drafts)
                            if (current.revision == draft.revision) *current = draft;
                        foreach (prompt; promptCopy) if (auto current = prompt.command.inputId in pending)
                        {
                            current.images = prompt.images; current.command.imagesJson = prompt.command.imagesJson; current.durable = true;
                            if (prompt.rejected) { current.rejected = true; current.error = prompt.error; }
                        }
                    }
                    wake.notifyAll();
                }
                notify(); if (failure.length) continue;
            }
            PendingPrompt[] deliver;
            synchronized (mutex)
            {
                dispatch = closing || dirty || error.length ? null : dispatcher;
                if (dispatch !is null) foreach (prompt; pending) if (prompt.durable && !prompt.delivered && !prompt.rejected) deliver ~= prompt;
            }
            deliver.sort!((a, b) => a.order < b.order);
            bool[string] blocked;
            foreach (prompt; deliver)
            {
                if (prompt.threadId in blocked) continue;
                PromptDispatch result;
                try result = dispatch(prompt);
                catch (Exception e)
                {
                    synchronized (mutex) error = "Submission dispatch failed; its saved intent was preserved: " ~ e.msg;
                    notify(); break;
                }
                if (result.admission != ActorAdmission.accepted) blocked[prompt.threadId] = true;
                synchronized (mutex)
                    if (auto current = prompt.command.inputId in pending)
                    {
                        current.configured = result.configured;
                        current.delivered = result.admission == ActorAdmission.accepted;
                        if (result.admission == ActorAdmission.invalid)
                        { current.rejected = true; current.error = result.error.length ? result.error : "The submitted input was rejected. Its draft was preserved."; dirty = true; }
                    }
            }
            if (deliver.length) notify();
            synchronized (mutex) if (!dirty && !closing) wake.wait(20.msecs);
        }
    }
}
