module auroraopencode.conversationregistry;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationencode : sessionToJson;
import auroraopencode.conversationview;
import auroraopencode.repository : RepositoryRuntime;
import auroraopencode.workerbudget : WorkerBudget;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : msecs;
import std.datetime : Clock;
import std.json : JSONValue, JSONType;
import std.digest.sha : sha256Of;
import std.digest : toHexString;

public enum ConversationOwnerState { waiting, starting, live, retiring, dormant, failed }
public struct ConversationDelivery
{
    string threadId;
    ulong generation;
    ConversationOwnerState state;
    size_t pendingCommands;
    immutable(ActorChange)[] changes;
    string error;
}

private final class Entry
{
    ChatSession model;
    ActorConfiguration config;
    ConversationActor actor;
    ActorCommand[] pending;
    size_t bytes;
    size_t deliveredPending = size_t.max;
    size_t stopAt = size_t.max;
    ulong generation;
    ConversationOwnerState state = ConversationOwnerState.waiting;
    bool changed = true, initialSnapshot = true, snapshotRequested;
    ulong viewRevision;
    immutable(ActorChange)[] finalChanges;
    string error;
}

/// Lifecycle work, graph detachment, retirement and final recovery snapshots
/// run off the window thread. Each live actor still owns its own execution.
public final class ConversationRegistry
{
    private Mutex mutex, joinMutex;
    private Condition wake;
    private Thread owner;
    private WorkerBudget budget;
    private RepositoryRuntime journal;
    private Entry[string] entries;
    private string[] order;
    private size_t cursor;
    private bool closing, closed, joined, statesTaken;
    private void delegate() viewWake;
    private enum maxEntries = 256, maxPending = 128, maxPendingBytes = 1024 * 1024;

    this(RepositoryRuntime journal, size_t workers = 16, void delegate() viewWake = null)
    {
        if (workers < 1 || workers > 256) throw new Exception("Invalid conversation worker capacity");
        mutex = new Mutex(); joinMutex = new Mutex(); wake = new Condition(mutex);
        budget = new WorkerBudget(workers); this.journal = journal; this.viewWake = viewWake;
        owner = new Thread(&run); owner.isDaemon = true; owner.start();
    }

    ActorAdmission register(const ref ChatSession initial, ActorConfiguration config)
    {
        synchronized (mutex)
        {
            if (closing || closed) return ActorAdmission.closed;
            if (initial.id in entries) return ActorAdmission.accepted;
            if (!initial.id.length) throw new Exception("A conversation requires a stable thread ID");
            if (entries.length >= maxEntries) return ActorAdmission.capacity;
        }
        // Only containers are copied here. Serialization, image I/O and actor
        // construction belong to the lifecycle owner, never this caller.
        auto detached = snapshotChatSessions([cast(ChatSession) initial])[0];
        config.request.availableTools = config.request.availableTools.dup;
        synchronized (mutex)
        {
            if (closing || closed) return ActorAdmission.closed;
            if (initial.id in entries) return ActorAdmission.accepted;
            if (entries.length >= maxEntries) return ActorAdmission.capacity;
            auto entry = new Entry(); entry.model = detached; entry.config = config;
            entry.state = ConversationOwnerState.dormant;
            entries[initial.id] = entry; order ~= initial.id; wake.notifyAll();
        }
        notifyView(); return ActorAdmission.accepted;
    }

    ActorAdmission post(string id, ActorCommand command)
    {
        synchronized (mutex)
        {
            if (closing || closed) return ActorAdmission.closed;
            auto found = id in entries;
            if (found is null) return ActorAdmission.closed;
            auto entry = *found;
            if (entry.actor !is null && entry.state != ConversationOwnerState.retiring)
            {
                const result = entry.actor.post(command);
                if (result != ActorAdmission.closed) return result;
            }
            if (command.kind == ActorCommandKind.stop)
                entry.stopAt = entry.pending.length;
            else if (command.kind == ActorCommandKind.snapshot)
                entry.snapshotRequested = true;
            else
            {
                const cost = ActorCommand.sizeof + command.text.length + command.targetId.length +
                    command.imagesJson.length + command.context.length + command.connectionBase.length + command.connectionKey.length;
                if (entry.pending.length >= maxPending || cost > maxPendingBytes - entry.bytes)
                    return ActorAdmission.capacity;
                entry.pending ~= command; entry.bytes += cost;
            }
            if (command.kind != ActorCommandKind.snapshot &&
                (entry.state == ConversationOwnerState.dormant || entry.state == ConversationOwnerState.failed))
                entry.state = ConversationOwnerState.waiting;
            entry.changed = true; wake.notifyAll();
        }
        notifyView(); return ActorAdmission.accepted;
    }

    ConversationDelivery[] takeChanges(size_t maximumConversations = 4)
    {
        ConversationDelivery[] result;
        synchronized (mutex)
        {
            if (!order.length || !maximumConversations) return result;
            const begin = cursor % order.length;
            foreach (offset; 0 .. order.length)
            {
                const index = (begin + offset) % order.length;
                auto entry = entries[order[index]];
                size_t pending = entry.pending.length;
                immutable(ActorChange)[] changes = entry.finalChanges;
                entry.finalChanges = null;
                if (entry.actor !is null && entry.state != ConversationOwnerState.retiring)
                {
                    auto updates = entry.actor.takeChanges();
                    pending += entry.actor.activity().unsettled;
                    if (entry.initialSnapshot)
                    {
                        bool snapshot;
                        foreach (change; updates) if (change.kind == ActorChangeKind.snapshot) snapshot = true;
                        if (snapshot) entry.initialSnapshot = false;
                        else
                        {
                            updates = null;
                            entry.actor.post(ActorCommand(ActorCommandKind.snapshot));
                        }
                    }
                    changes ~= updates;
                }
                if (entry.changed || changes.length || pending != entry.deliveredPending)
                {
                    result ~= ConversationDelivery(order[index], entry.generation, entry.state,
                        pending, changes, entry.error);
                    entry.deliveredPending = pending;
                    entry.changed = false; cursor = (index + 1) % order.length;
                    if (result.length >= maximumConversations) break;
                }
            }
        }
        return result;
    }

    size_t activeWorkers() { return budget.active(); }
    bool isClosed() { synchronized (mutex) return closed; }
    void requestClose()
    {
        synchronized (mutex)
        {
            if (closing || closed) return;
            closing = true;
            foreach (entry; entries) if (entry.actor !is null) entry.actor.requestClose();
            wake.notifyAll();
        }
    }
    void close()
    {
        synchronized (joinMutex)
        { if (joined) return; requestClose(); owner.join(); joined = true; }
    }
    ChatSession[] takeClosedSessions()
    {
        synchronized (mutex)
        {
            if (!closed || statesTaken) throw new Exception("Close the conversation registry before transferring final state");
            ChatSession[] result;
            foreach (id; order) { result ~= entries[id].model; entries[id].model = ChatSession.init; }
            statesTaken = true; return result;
        }
    }

    private void notifyView() { if (viewWake !is null) viewWake(); }
    private void notify()
    { synchronized (mutex) wake.notifyAll(); notifyView(); }

    private void bind(Entry entry)
    {
        // Entry.model is lifecycle-owned while starting; callers can append
        // immutable commands but cannot replace this graph with a stale view.
        auto actor = ConversationActor.adopt(entry.model, entry.config, journal, budget);
        actor.setViewWake(&notify);
        synchronized (mutex)
        {
            entry.actor = actor; entry.model = ChatSession.init;
            ++entry.generation; entry.initialSnapshot = true; entry.finalChanges = null;
            entry.snapshotRequested = false; entry.viewRevision = 0;
            entry.error = "";
            foreach (i, command; entry.pending)
            {
                if (entry.stopAt == i) actor.stop();
                if (actor.post(command) != ActorAdmission.accepted)
                    throw new Exception("Lifecycle command transfer exceeded its reserved mailbox");
            }
            if (entry.stopAt == entry.pending.length) actor.stop();
            entry.pending = null; entry.bytes = 0; entry.stopAt = size_t.max;
            actor.post(ActorCommand(ActorCommandKind.snapshot));
            if (closing) actor.requestClose();
            else if (actor.launch() != ActorAdmission.accepted)
                throw new Exception("Conversation worker capacity changed during lifecycle admission");
            entry.state = closing ? ConversationOwnerState.retiring : ConversationOwnerState.live;
            entry.changed = true;
        }
        notifyView();
    }

    private void retire(Entry entry, string forcedError = "")
    {
        auto actor = entry.actor;
        actor.close();
        const activity = actor.activity();
        const error = forcedError.length ? forcedError : actor.fault();
        auto model = actor.takeFinalSession();
        // Hydrated pixels are transient. Failed, not-yet-archived input keeps
        // its pixels in the private recovery model until storage can save it.
        foreach (ref message; model.messages)
            foreach (ref image; message.images) if (image.blob.length) image.base64Data = "";
        synchronized (mutex)
        {
            entry.model = model; entry.actor = null; entry.error = error;
            entry.state = entry.pending.length || entry.stopAt != size_t.max ? ConversationOwnerState.waiting :
                error.length ? ConversationOwnerState.failed : ConversationOwnerState.dormant;
            entry.initialSnapshot = false; entry.viewRevision = activity.revision;
        }
        publishState(entry);
    }

    private void publishState(Entry entry)
    {
        auto value = sessionToJson(entry.model);
        referencePixels(value);
        ConversationExecutionView execution;
        execution.phase = entry.error.length || entry.model.turnStatus == "failed" ? "failed" :
            entry.model.turnStatus == "completed" ? "completed" : entry.model.turnStatus == "interrupted" ? "cancelled" : "idle";
        execution.routingKey = sessionRoutingKey(entry.model); value["execution"] = executionViewJson(execution);
        const snapshot = value.toString();
        synchronized (mutex)
        {
            entry.finalChanges = [ActorChange(ActorChangeKind.snapshot, ++entry.viewRevision, 0, "", snapshot)].idup;
            entry.snapshotRequested = false;
            entry.changed = true;
        }
        notifyView();
    }

    private void run()
    {
        scope (exit) { synchronized (mutex) closed = true; notifyView(); }
        while (true)
        {
            Entry retireNext, startNext, snapshotNext;
            bool finish;
            synchronized (mutex)
            {
                finish = closing;
                foreach (id; order)
                {
                    auto entry = entries[id];
                    if (entry.actor !is null && (finish || entry.actor.isClosed()))
                    { retireNext = entry; entry.state = ConversationOwnerState.retiring; break; }
                }
                if (retireNext is null)
                    foreach (id; order)
                    {
                        auto entry = entries[id];
                        if (entry.actor is null && entry.state != ConversationOwnerState.failed &&
                            (entry.pending.length || entry.stopAt != size_t.max))
                        { startNext = entry; break; }
                    }
                if (startNext !is null && !finish && budget.active() >= budget.capacity)
                {
                    foreach (id; order)
                    {
                        auto candidate = entries[id];
                        if (candidate.actor !is null && !candidate.actor.activity().busy)
                        { retireNext = candidate; candidate.state = ConversationOwnerState.retiring; break; }
                    }
                    startNext = null;
                }
                if (startNext !is null) startNext.state = ConversationOwnerState.starting;
                if (retireNext is null && startNext is null)
                    foreach (id; order)
                        if (entries[id].actor is null && entries[id].snapshotRequested)
                        { snapshotNext = entries[id]; break; }
                if (retireNext is null && startNext is null && snapshotNext is null)
                {
                    if (finish) return;
                    wake.wait(20.msecs); continue;
                }
            }
            try
            {
                if (snapshotNext !is null) publishState(snapshotNext);
                else if (retireNext !is null) retire(retireNext);
                else if (startNext !is null)
                {
                    bind(startNext);
                    if (finish) retire(startNext);
                }
            }
            catch (Throwable error)
            {
                auto entry = snapshotNext !is null ? snapshotNext : retireNext !is null ? retireNext : startNext;
                if (entry.actor !is null)
                { retire(entry, error.msg); continue; }
                synchronized (mutex)
                {
                    preservePending(entry);
                    entry.state = ConversationOwnerState.failed; entry.error = error.msg;
                    entry.model.turnStatus = "failed"; entry.model.taskStatus = "blocked";
                    entry.changed = true; entry.snapshotRequested = false;
                }
                if (snapshotNext is null) publishState(entry);
                notifyView();
            }
        }
    }

    private void preservePending(Entry entry)
    {
        // Construction can fail before an actor exists. Keep exact accepted
        // input in a recoverable model rather than silently dropping it.
        const timestamp = Clock.currTime.toUnixTime();
        foreach (command; entry.pending) ConversationActor.retainAcceptedInput(entry.model, command, timestamp);
        if (entry.stopAt != size_t.max && entry.model.goalStatus == "active") entry.model.goalStatus = "paused";
        entry.pending = null; entry.bytes = 0; entry.stopAt = size_t.max;
    }
}

private void referencePixels(ref JSONValue value)
{
    if (value.type == JSONType.array) foreach (ref child; value.array) referencePixels(child);
    else if (value.type == JSONType.object)
    {
        if (auto data = "base64Data" in value.object)
            if (data.type == JSONType.string && data.str.length && "mimeType" in value.object)
            {
                value["blob"] = sha256Of(data.str).toHexString().idup;
                value["attachmentError"] = "Accepted image remains in the execution owner's recovery state; durable storage is unavailable";
                value.object.remove("base64Data");
            }
        foreach (ref child; value.object) referencePixels(child);
    }
}
