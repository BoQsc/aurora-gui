module auroraopencode.conversationregistry;

import auroraopencode.core;
import auroraopencode.conversationactor;
import auroraopencode.conversationencode : sessionToJson;
import auroraopencode.conversationview;
import auroraopencode.conversationcoordination;
import auroraopencode.conversationconfiguration : decodeActorBehavior, actorBehaviorJson;
import auroraopencode.conversationcodec : decodeSessionMetadata;
import auroraopencode.repository : RepositoryRuntime;
import auroraopencode.workerbudget : WorkerBudget;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : msecs;
import std.datetime : Clock;
import std.json : JSONValue, JSONType, parseJSON;
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
public struct ConversationTrace
{
    string threadId;
    ulong generation;
    string initial, behavior, recording, finalState;
}
public alias ConversationTraceSink = void delegate(ConversationTrace);

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
    string traceInitial;
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
    private ConversationTraceSink traceSink;
    private string[] traceErrors;
    private CoordinationEffect[] dispatches;
    private CoordinationEffect[string] reports, cancellations;
    private string[string] assignedRounds, cancelledRounds, currentRounds;
    private string[][string] childrenByParent;
    private size_t coordinationBytes;
    private enum maxEntries = 256, maxPending = 128, maxPendingBytes = 1024 * 1024;

    this(RepositoryRuntime journal, size_t workers = 16, void delegate() viewWake = null,
        ConversationTraceSink traceSink = null)
    {
        if (workers < 1 || workers > 256) throw new Exception("Invalid conversation worker capacity");
        mutex = new Mutex(); joinMutex = new Mutex(); wake = new Condition(mutex);
        budget = new WorkerBudget(workers); this.journal = journal; this.viewWake = viewWake;
        this.traceSink = traceSink;
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
            if (command.kind == ActorCommandKind.stop || command.kind == ActorCommandKind.regenerate ||
                command.kind == ActorCommandKind.editPrompt || command.kind == ActorCommandKind.selectBranch)
                stopDescendants(id);
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

    ActorAdmission configure(string id, ActorConfiguration config, string model, bool thinking)
    { return post(id, ConversationActor.configurationCommand(config, model, thinking)); }

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
                            // bind already reserved the initial snapshot. A
                            // second request during serialization only repeats
                            // a large graph and its layout work.
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
    string[] traceFailures() { synchronized (mutex) return traceErrors.dup; }
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
        if (entry.config.recordTrace && traceSink !is null) entry.traceInitial = sessionToJson(entry.model).toString();
        auto actor = ConversationActor.adopt(entry.model, entry.config, journal, budget);
        actor.setViewWake(&notify);
        actor.setCoordinator(&coordinate);
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
        if (entry.traceInitial.length && traceSink !is null)
        {
            try traceSink(ConversationTrace(parseJSON(entry.traceInitial)["id"].str, entry.generation,
                entry.traceInitial, actorBehaviorJson(entry.config).toString(), actor.recordedTrace(), actor.finalSnapshot()));
            catch (Exception traceError)
            { synchronized (mutex) if (traceErrors.length < 16) traceErrors ~= traceError.msg; }
            entry.traceInitial = "";
        }
        const config = actor.finalConfiguration();
        auto model = actor.takeFinalSession();
        // Hydrated pixels are transient. Failed, not-yet-archived input keeps
        // its pixels in the private recovery model until storage can save it.
        foreach (ref message; model.messages)
            foreach (ref image; message.images) if (image.blob.length) image.base64Data = "";
        synchronized (mutex)
        {
            entry.model = model; entry.config = cast(ActorConfiguration) config; entry.actor = null; entry.error = error;
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
            entry.finalChanges = [ActorChange(ActorChangeKind.snapshot, ++entry.viewRevision, 0, "", snapshot, false,
                !entry.error.length && entry.model.turnStatus == "running" && waitingForChildren(entry.model))].idup;
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
            CoordinationEffect control; bool hasControl;
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
                    if (cancellations.length) { control = cancellations[cancellations.keys[0]]; hasControl = true; }
                    else if (reports.length) { control = reports[reports.keys[0]]; hasControl = true; }
                    else if (dispatches.length) { control = dispatches[0]; hasControl = true; }
                    else { wake.wait(20.msecs); continue; }
                }
            }
            try
            {
                if (hasControl)
                {
                    if (!applyCoordination(control))
                        synchronized (mutex) wake.wait(20.msecs);
                }
                else if (snapshotNext !is null) publishState(snapshotNext);
                else if (retireNext !is null) retire(retireNext);
                else if (startNext !is null)
                {
                    bind(startNext);
                    if (finish) retire(startNext);
                }
            }
            catch (Throwable error)
            {
                if (hasControl)
                {
                    synchronized (mutex)
                    {
                        removeCoordination(control);
                        auto failed = CoordinationEffect(CoordinationKind.failure, control.owner, control.round,
                            "Child coordination failed: " ~ error.msg);
                        reports[control.owner] = failed;
                    }
                    continue;
                }
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

    private static size_t coordinationCost(const ref CoordinationEffect effect)
    { return CoordinationEffect.sizeof + effect.owner.length + effect.round.length + effect.payload.length +
        effect.behavior.length + effect.connectionBase.length + effect.connectionKey.length; }

    private void stopDescendants(string id)
    {
        auto round = id in currentRounds;
        if (round is null) return;
        cancelledRounds[id] = *round;
        foreach (childId; childrenByParent[id])
            if (auto child = childId in entries)
            {
                if ((*child).actor !is null) (*child).actor.stop();
                else { (*child).stopAt = (*child).pending.length; (*child).state = ConversationOwnerState.waiting; }
            }
    }

    private bool coordinate(CoordinationEffect effect)
    {
        synchronized (mutex)
        {
            if (closed) return false;
            if (closing) return effect.kind != CoordinationKind.dispatch;
            if (!(effect.owner in entries)) return false;
            if (effect.kind == CoordinationKind.cancel)
            {
                cancellations[effect.owner] = effect; cancelledRounds[effect.owner] = effect.round;
                if (auto round = effect.owner in currentRounds)
                    if (*round == effect.round)
                        foreach (id; childrenByParent[effect.owner])
                            if (auto child = id in entries)
                            {
                                if ((*child).actor !is null) (*child).actor.stop();
                                else { (*child).stopAt = (*child).pending.length; (*child).state = ConversationOwnerState.waiting; }
                            }
            }
            else if (effect.kind == CoordinationKind.report)
            {
                if (effect.payload.length > 512 * 1024)
                {
                    const parent = parseJSON(effect.payload)["parent"].str;
                    effect = CoordinationEffect(CoordinationKind.failure, parent, effect.round,
                        "Child report exceeded the handoff budget. The complete child conversation was preserved: " ~ effect.owner);
                }
                reports[effect.owner] = effect;
            }
            else
            {
                const cost = coordinationCost(effect);
                if (dispatches.length >= 64 || cost > 1024 * 1024 - coordinationBytes) return false;
                dispatches ~= effect; coordinationBytes += cost;
            }
            wake.notifyAll();
        }
        return true;
    }
    private void removeCoordination(const ref CoordinationEffect effect)
    {
        if (effect.kind == CoordinationKind.cancel)
        { if (auto pending = effect.owner in cancellations) if (pending.round == effect.round) cancellations.remove(effect.owner); }
        else if (effect.kind == CoordinationKind.report || effect.kind == CoordinationKind.failure)
        { if (auto pending = effect.owner in reports) if (pending.round == effect.round && pending.payload == effect.payload) reports.remove(effect.owner); }
        else if (dispatches.length)
        { coordinationBytes -= coordinationCost(dispatches[0]); dispatches = dispatches[1 .. $]; }
    }
    private bool applyCoordination(const ref CoordinationEffect effect)
    {
        if (effect.kind == CoordinationKind.cancel)
        {
            // Cancellation was reserved synchronously, including each already
            // registered child. Dispatch also checks that fence after posting.
        }
        else if (effect.kind == CoordinationKind.report || effect.kind == CoordinationKind.failure)
        {
            const parent = effect.kind == CoordinationKind.failure ? effect.owner : parseJSON(effect.payload)["parent"].str;
            auto command = ActorCommand(effect.kind == CoordinationKind.failure ? ActorCommandKind.coordinationFailed : ActorCommandKind.childReport,
                effect.payload, effect.round);
            if (post(parent, command) == ActorAdmission.capacity) return false;
        }
        else
        {
            bool cancelled;
            synchronized (mutex) if (auto round = effect.owner in cancelledRounds) cancelled = *round == effect.round;
            if (!cancelled)
            {
                const state = parseJSON(effect.payload);
                size_t missing;
                synchronized (mutex)
                {
                    foreach (child; state["children"].array) if (!child["reported"].boolean && !(child["id"].str in entries)) ++missing;
                    if (missing > maxEntries - entries.length) throw new Exception("Conversation capacity cannot admit this child round");
                    currentRounds[effect.owner] = effect.round;
                    childrenByParent[effect.owner] = null;
                    foreach (child; state["children"].array) if (!child["reported"].boolean) childrenByParent[effect.owner] ~= child["id"].str;
                }
                auto behavior = parseJSON(effect.behavior);
                auto config = decodeActorBehavior(ActorConfiguration.init, behavior);
                config.baseUrl = effect.connectionBase; config.apiKey = effect.connectionKey;
                config.recordTrace = effect.recordTrace;
                config.quickTitle = false;
                foreach (child; state["children"].array)
                {
                    if (child["reported"].boolean) continue;
                    const id = child["id"].str;
                    bool assigned;
                    synchronized (mutex) if (auto round = id in assignedRounds) assigned = *round == effect.round;
                    if (assigned) continue;
                    ChatSession seed; decodeSessionMetadata(child["seed"], seed);
                    if (register(seed, config) != ActorAdmission.accepted) throw new Exception("Child registration was not admitted");
                    if (configure(id, config, seed.model, seed.thinking) != ActorAdmission.accepted)
                        throw new Exception("Child configuration was not admitted");
                    auto command = ActorCommand(ActorCommandKind.startAssignment, child["task"].str, effect.round);
                    command.context = child["seed"].toString();
                    if (post(id, command) != ActorAdmission.accepted)
                        throw new Exception("Child assignment was not admitted");
                    bool cancelledAfterAdmission;
                    synchronized (mutex)
                    {
                        assignedRounds[id] = effect.round;
                        if (auto stopped = effect.owner in cancelledRounds) cancelledAfterAdmission = *stopped == effect.round;
                    }
                    if (cancelledAfterAdmission) post(id, ActorCommand(ActorCommandKind.stop));
                }
            }
        }
        synchronized (mutex) removeCoordination(effect);
        return true;
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
