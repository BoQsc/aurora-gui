module auroraopencode.conversationactor;

import auroraopencode.core;
import auroraopencode.conversationencode;
import auroraopencode.conversationimages : ConversationImages;
import auroraopencode.conversationview;
import auroraopencode.queuedprompts;
import auroraopencode.computeruse : ComputerUseContext;
import auroraopencode.conversationcodec : decodeSessionMetadata, decodeMessages;
import auroraopencode.attachmentstore : AttachmentStore;
import auroraopencode.execution : ThreadEngine, RequestPhase;
import auroraopencode.effectfacts;
import auroraopencode.contextpolicy : checkpointSnippet;
import auroraopencode.completionhandoff : completionHandoffPending, recordedCompletionHandoff;
import auroraopencode.retrypolicy : ProviderRetryPolicy, RetryReason, configuredProviderRetryPolicy;
import auroraopencode.workerbudget : WorkerBudget;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind, ChatStartResult;
import auroraopencode.repository : RepositoryRuntime;
import auroraopencode.runtime : AgentRuntimeEvent, AgentEventKind;
import auroraopencode.requestpolicy : RequestPolicy, prepareAgentRequest;
import auroraopencode.turnpolicy : TurnPolicy, TurnAction, decideTurn, hasIncompleteTaskSteps;
import auroraopencode.toolsettlement : ToolResultPolicy, settleToolResult;
import auroraopencode.toolprotocol : normalizeToolCalls;
import auroraopencode.toolscheduler : scheduleToolBatch, toolWorkspaceRevision;
import auroraopencode.tools : ChangeContext, ToolCancellation;
import auroraopencode.toolprogresspolicy : isPlainDocumentMutation, isSubstantiveMutation, hasExhaustedRepeatedCall;
import auroraopencode.taskflow : acceptTaskRequest, taskInvestigation, restoreBranchTask;
import auroraopencode.taskmutation : applyTaskPlan, applyTaskSubplan;
import auroraopencode.taskpolicy : verificationScope;
import auroraopencode.goalmode : goalActive, recordGoalSet, recordGoalOutcome, clampGoalText, goalContinuationInstruction;
import auroraopencode.planhistory : recordPlanHistory;
import auroraopencode.goalmutation : resetTaskForNewGoal;
import auroraopencode.outputrecovery : answerReplayed, goalAuditStalled, outputRecoveryCount, maxOutputRecoveries;
import auroraopencode.outputguard : outputRecoveryMarker;
import auroraopencode.imagehistory : pruneHistoryImages, completedReplyImageIds;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.thread : Thread;
import core.time : MonoTime, msecs;
import std.datetime : Clock;
import std.conv : to;
import std.format : format;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : buildPath;
import std.string : toLower, strip;
import std.digest.sha : sha256Of;
import std.digest : toHexString;

public enum ActorAdmission { accepted, capacity, closed }
public enum ActorStart { immediate, deferred }
public struct ActorActivity
{
    bool busy, closed;
    size_t unsettled;
    ulong revision;
}
public final class ActorCapacityException : Exception
{ this() { super("Conversation workers are at capacity; no actor was started"); } }
private __gshared WorkerBudget actorWorkers;
shared static this()
{
    import std.process : environment;
    size_t capacity = 16;
    try capacity = to!size_t(environment.get("AURORA_ACTOR_WORKERS", "16")); catch (Exception) {}
    if (capacity < 1 || capacity > 256) capacity = 16;
    actorWorkers = new WorkerBudget(capacity);
}
public enum ActorCommandKind { start, steer, followUp, stop, setGoal, pauseGoal, resumeGoal, snapshot,
    regenerate, editPrompt, continueAnswer, selectBranch, setDraft, retryPending }
public struct ActorCommand
{
    ActorCommandKind kind;
    string text, targetId;
    bool activate = true;
    string imagesJson, context;
}
public struct ActorQueueStats
{
    size_t commands, commandBytes, changes, changeBytes;
    bool resync;
}
public enum ActorChangeKind { metadata, added, updated, delta, usage, resync, snapshot, fault, notice, toolProgress }
/// Values contain immutable strings/scalars only, so readers cannot mutate an
/// execution owner's graph, tool arrays or task state through a UI change.
public struct ActorChange
{
    ActorChangeKind kind;
    ulong revision, requestId;
    string itemId, text;
    bool reasoning, busy;
}
public struct ActorConfiguration
{
    string baseUrl, apiKey, workspace;
    RequestPolicy request;
    TurnPolicy turn;
    bool recordTrace;
    long outageBudgetMs = -1; // capture the configured policy at admission
}

/// The mailbox, provider drain, policies and effect admission run on a single
/// conversation-owned thread. No widget/native-window callbacks are invoked.
/// Desktop adoption waits for optional-feature/command parity; the standalone
/// execution and replay contracts exercise this owner directly.
public final class ConversationActor
{
    private Mutex mutex;
    private Mutex joinMutex;
    private Condition wake;
    private Thread worker;
    private WorkerBudget workerBudget;
    private bool started, ownsWorkerSlot, publishedBusy, sessionTaken;
    private void delegate() viewWake;
    private struct Envelope { ActorCommand command; ulong epoch, serial; }
    private Envelope[] commands;
    private ulong admissionEpoch;
    private ulong nextCommandSerial, currentCommandSerial;
    private ActorCommand currentCommand;
    private bool currentInputRetained;
    private ActorCommand[ulong] unsettledInputs;
    private size_t commandBytes;
    private ActorChange[] changes;
    private size_t changeBytes;
    private bool closing, closed, needsSnapshot;
    private bool joined;
    private bool snapshotPending, hasSnapshot, preserveInputs;
    private ActorChange pendingSnapshot;
    private bool hasFault;
    private ActorChange pendingFault;
    private ulong revision;
    private string failure;
    private ChatSession session;
    private ActorConfiguration config;
    private RepositoryRuntime journal;
    private ThreadEngine engine;
    private bool running;
    private ulong nextRequest;
    private JSONValue[] trace;
    private size_t traceBytes;
    private bool traceTruncated;
    private string initialIdentity, configurationIdentity;
    private bool replaying;
    private bool journalStarted;
    private string[] frameIds;
    private size_t replayId;
    private string frameTime;
    private long frameUnix;
    private MonoTime clockOrigin;
    private long frameMs, outageStartedMs = -1, retryAtMs = -1;
    private uint resendCount;
    private bool quotaWait, offeredTools;
    private ConversationImages images;
    private ConversationToolView[] liveTools;
    private size_t omittedTools;
    private MonoTime lastCheckpoint;
    private size_t checkpointBytes;
    private ToolCancellation activeCancellation;
    private enum maxCommands = 128;
    private enum maxCommandBytes = 1024 * 1024;
    private enum maxChanges = 256;
    private enum maxChangeBytes = 1024 * 1024;

    this(const ref ChatSession initial, ActorConfiguration config, RepositoryRuntime journal,
        WorkerBudget budget = null, ActorStart mode = ActorStart.immediate)
    { this(initial, config, journal, budget, mode == ActorStart.immediate, mode == ActorStart.deferred); }

    private this(const ref ChatSession initial, ActorConfiguration config, RepositoryRuntime journal,
        WorkerBudget budget, bool launchWorker, bool deferred = false)
    {
        if (!initial.id.length) throw new Exception("A conversation actor requires a stable thread ID");
        if (config.outageBudgetMs < 0)
            config.outageBudgetMs = configuredProviderRetryPolicy().outageBudget.total!"msecs";
        // Configuration arrays are detached from the caller before admission.
        auto initialCopy = initial;
        // Encoder/decoder also gives this worker exclusive mutable containers.
        auto value = sessionToJson(initialCopy);
        initialIdentity = sha256Of(value.toString()).toHexString().idup;
        configurationIdentity = configurationKey(config);
        decodeSessionMetadata(value, session); decodeMessages(value["messages"], session);
        this.config = config; this.config.request.availableTools = config.request.availableTools.dup;
        this.journal = journal;
        if (config.turn.orchestratorEnabled)
            throw new Exception("Conversation actor orchestration adapter is not installed");
        mutex = new Mutex(); joinMutex = new Mutex(); wake = new Condition(mutex);
        clockOrigin = MonoTime.currTime;
        workerBudget = budget is null ? actorWorkers : budget;
        if (launchWorker && launch() != ActorAdmission.accepted) throw new ActorCapacityException();
        else if (!launchWorker && !deferred)
        { closed = true; engine = new ThreadEngine("", "", ProviderRetryPolicy(config.outageBudgetMs.msecs)); }
    }

    /// Bind an actor to its lifecycle owner and enqueue accepted input before
    /// starting physical execution. Admission and Stop remain atomic while idle.
    ActorAdmission launch()
    {
        synchronized (mutex)
        {
            if (closed || closing || joined) return ActorAdmission.closed;
            if (started) return ActorAdmission.accepted;
            if (!workerBudget.acquire()) return ActorAdmission.capacity;
            ownsWorkerSlot = true;
            try
            {
                worker = new Thread(&run); worker.isDaemon = true;
                started = true; worker.start();
            }
            catch (Throwable error)
            { started = false; ownsWorkerSlot = false; worker = null; workerBudget.release(); throw error; }
            return ActorAdmission.accepted;
        }
    }
    void setViewWake(void delegate() callback) { synchronized (mutex) viewWake = callback; }
    ActorActivity activity()
    {
        synchronized (mutex) return ActorActivity(publishedBusy || unsettledInputs.length > 0 ||
            stopPending || snapshotPending, closed, unsettledInputs.length, revision);
    }

    ActorAdmission post(ActorCommand command)
    {
        if (command.kind == ActorCommandKind.stop) return stop();
        synchronized (mutex)
        {
            if (closing || closed) return ActorAdmission.closed;
            if (command.kind == ActorCommandKind.snapshot)
            { snapshotPending = true; wake.notifyAll(); return ActorAdmission.accepted; }
            const cost = ActorCommand.sizeof + command.text.length + command.targetId.length +
                command.imagesJson.length + command.context.length;
            if (commands.length >= maxCommands || unsettledInputs.length >= maxCommands * 2 ||
                cost > maxCommandBytes - commandBytes)
                return ActorAdmission.capacity;
            if (command.kind == ActorCommandKind.regenerate || command.kind == ActorCommandKind.editPrompt ||
                command.kind == ActorCommandKind.selectBranch)
            {
                stopPending = true; ++admissionEpoch;
                if (activeCancellation !is null) activeCancellation.cancel();
            }
            const serial = ++nextCommandSerial;
            unsettledInputs[serial] = command;
            commands ~= Envelope(command, admissionEpoch, serial); commandBytes += cost; wake.notifyAll();
            return ActorAdmission.accepted;
        }
    }

    /// Cancellation bypasses a saturated ordinary command mailbox. The owner
    /// applies the logical Stop before consuming more provider/tool events.
    ActorAdmission stop()
    {
        synchronized (mutex)
        {
            if (closed || closing) return ActorAdmission.closed;
            stopPending = true; pauseOnStop = true; ++admissionEpoch;
            if (activeCancellation !is null) activeCancellation.cancel();
            wake.notifyAll();
            return ActorAdmission.accepted;
        }
    }
    private bool stopPending;
    private bool pauseOnStop;

    immutable(ActorChange)[] takeChanges()
    {
        synchronized (mutex)
        {
            ActorChange[] outgoing;
            if (hasSnapshot) { outgoing ~= pendingSnapshot; hasSnapshot = false; pendingSnapshot = ActorChange.init; }
            outgoing ~= changes;
            auto result = outgoing.idup;
            changes = null; changeBytes = 0;
            if (needsSnapshot)
                result ~= immutable(ActorChange)(ActorChangeKind.resync, revision);
            if (hasFault)
            { result ~= cast(immutable) pendingFault; hasFault = false; pendingFault = ActorChange.init; }
            return result;
        }
    }
    string fault() { synchronized (mutex) return failure; }
    ActorQueueStats queueStats()
    { synchronized (mutex) return ActorQueueStats(commands.length, commandBytes, changes.length, changeBytes, needsSnapshot); }
    bool isClosed() { synchronized (mutex) return closed; }
    ActorAdmission requestClose()
    {
        synchronized (mutex)
        {
            if (closed || closing) return ActorAdmission.closed;
            closing = true;
            if (activeCancellation !is null) activeCancellation.cancel();
            wake.notifyAll();
            return ActorAdmission.accepted;
        }
    }
    void close()
    {
        synchronized (joinMutex)
        {
            if (joined) return;
            requestClose();
            bool finishInline;
            synchronized (mutex) if (!started && !closed) { started = true; finishInline = true; }
            // A deferred actor has no physical job to join. The lifecycle
            // owner applies already accepted inputs with effects disabled.
            if (finishInline) run();
            else if (worker !is null) worker.join();
            joined = true;
        }
    }

    private void notify() { synchronized (mutex) wake.notifyAll(); }
    private void emit(ActorChangeKind kind, string text = "", string id = "", bool reasoning = false)
    {
        if (replaying) return;
        scope (exit)
        {
            void delegate() callback;
            synchronized (mutex) callback = viewWake;
            if (callback !is null) callback();
        }
        synchronized (mutex)
        {
            publishedBusy = running;
            ++revision;
            if (kind == ActorChangeKind.fault)
            {
                pendingFault = ActorChange(kind, revision, engine is null ? 0 : engine.activeRequestId,
                    "", checkpointSnippet(text, 8 * 1024), false, false);
                hasFault = true; return;
            }
            if (needsSnapshot && kind != ActorChangeKind.snapshot && kind != ActorChangeKind.fault) return;
            const cost = ActorChange.sizeof + text.length + id.length;
            if (kind == ActorChangeKind.snapshot)
            {
                changes = null; changeBytes = 0; needsSnapshot = false;
                pendingSnapshot = ActorChange(kind, revision, engine is null ? 0 : engine.activeRequestId, id, text, reasoning, running);
                hasSnapshot = true;
                return;
            }
            else if (changes.length >= maxChanges || changeBytes > maxChangeBytes || cost > maxChangeBytes - changeBytes)
            {
                changes = null; changeBytes = 0; needsSnapshot = true; return;
            }
            changes ~= ActorChange(kind, revision, engine is null ? 0 : engine.activeRequestId, id, text, reasoning, running);
            changeBytes += cost;
        }
    }
    private void publish(AgentEventKind kind, string payload, string item = "")
    {
        if (replaying || journal is null) return;
        AgentRuntimeEvent event;
        event.kind = kind; event.threadId = session.id; event.itemId = item;
        event.payloadJson = payload;
        // This owner may wait for durable admission. The window never waits
        // for it, and the separate cancellation signal remains available.
        if (!journal.publish(event)) throw new Exception("Conversation journal admission failed; effects were not started");
    }
    private string messageId()
    {
        if (replaying)
        {
            if (replayId >= frameIds.length) throw new Exception("Replay generated an unexpected message");
            return frameIds[replayId++];
        }
        auto id = newMessageId(); frameIds ~= id; return id;
    }
    private void append(ChatMessage message)
    {
        images.archive(message);
        message.id = messageId(); message.parentId = session.activeLeafId;
        if (!message.time.length) message.time = frameTime;
        session.messages ~= message; session.activeLeafId = message.id; session.updatedAt = frameUnix;
        if (currentCommandSerial) currentInputRetained = true;
        engine.invalidateProjection();
        publish(AgentEventKind.itemAdded, runtimeMessagePayload(message), message.id);
        emit(ActorChangeKind.added, viewJson(messageToJson(message)), message.id);
    }
    private void updateLast()
    {
        if (!session.messages.length) return;
        const ref message = session.messages[$ - 1];
        engine.invalidateProjection();
        publish(AgentEventKind.itemUpdated, runtimeMessagePayload(message), message.id);
        emit(ActorChangeKind.updated, viewJson(messageToJson(message)), message.id);
    }
    private string viewJson(JSONValue value)
    {
        if (replaying) return "";
        // Presentation needs attachment metadata, while the execution owner
        // retains pixels for request preparation. Never duplicate the pixels
        // into the pending UI mailbox or its full-resync slot.
        auto attachments = AttachmentStore(buildPath(opencodeStateDirectory(), "attachments"));
        attachments.externalize(value);
        return value.toString();
    }
    private void metadata()
    {
        if (currentCommandSerial && currentCommand.kind != ActorCommandKind.editPrompt)
            currentInputRetained = true;
        publish(AgentEventKind.threadUpdated, runtimeThreadPayload(session));
        emit(ActorChangeKind.metadata, headerView().toString());
    }
    private JSONValue headerView()
    {
        auto value = sessionMetaToJson(session);
        ConversationExecutionView execution;
        execution.phase = to!string(engine.phase);
        execution.routingKey = engine.client.openCodeSession();
        execution.resendCount = resendCount;
        execution.retryRemainingMs = retryAtMs < 0 ? -1 : retryAtMs > frameMs ? retryAtMs - frameMs : 0;
        execution.toolRounds = engine.toolRounds;
        execution.selectedImages = images.lastRequest.selectedImages;
        execution.selectedImageBytes = images.lastRequest.selectedBytes;
        execution.imageSizeReads = images.lastRequest.sizeReads;
        execution.imageBlobReads = images.lastRequest.blobReads;
        execution.tools = liveTools; execution.omittedTools = omittedTools;
        value["execution"] = executionViewJson(execution);
        return value;
    }
    private void resetOutage()
    { outageStartedMs = -1; resendCount = 0; retryAtMs = -1; quotaWait = false; }
    private void ensureAssistant()
    {
        if (!session.messages.length || session.messages[$ - 1].role != "assistant" ||
            session.messages[$ - 1].id != session.activeLeafId || session.messages[$ - 1].toolCalls.length)
        { ChatMessage message; message.role = "assistant"; append(message); }
    }
    private void internalNote(string text)
    {
        ChatMessage message; message.role = "user"; message.internal = true; message.content = text;
        append(message);
    }
    private static ChatPromptContext promptContext(const ref ActorCommand command)
    {
        ChatPromptContext context; context.text = command.context;
        if (command.imagesJson.length)
        {
            auto values = parseJSON(command.imagesJson);
            if (values.type != JSONType.array) throw new Exception("Prompt images must be an array");
            foreach (image; values.array) context.images ~= imageAttachmentFromJson(image);
        }
        return context;
    }
    private void enqueue(ActorCommand command, bool steering)
    {
        auto context = promptContext(command);
        ChatMessage attachment; attachment.images = context.images; images.archive(attachment);
        context.images = attachment.images;
        foreach (ref image; context.images) image.base64Data = "";
        queuePrompt(session, command.text, context, steering); metadata();
    }
    private void appendUser(string text, ChatPromptContext context = ChatPromptContext.init)
    {
        ChatMessage message; message.role = "user"; message.content = text; message.images = context.images;
        append(message); acceptTaskRequest(session, text, session.activeLeafId);
        if (context.text.length)
        {
            ChatMessage detail; detail.role = "user"; detail.internal = true; detail.content = context.text;
            append(detail);
        }
    }
    private void userRequest(string text, ChatPromptContext context = ChatPromptContext.init)
    {
        resetOutage();
        appendUser(text, context);
        session.turnStatus = "running"; running = true; engine.turnCancelled = false;
        metadata(); if (!preserveInputs) request();
    }
    private void request()
    {
        if (engine.turnCancelled) return;
        refreshVerification();
        if (images.prepare(session, config.request.imageLimit)) engine.invalidateProjection();
        auto policy = config.request;
        policy.summaryOnly = !goalActive(session) && (policy.summaryOnly || completionHandoffPending(session));
        policy.revision.graph = engine.graphRevision;
        auto prepared = prepareAgentRequest(session, policy, engine.projection);
        offeredTools = prepared.tools.length > 0;
        if (prepared.checkpointCreated) metadata();
        const id = ++nextRequest;
        engine.client.setOpenCodeSession(sessionRoutingKey(session));
        engine.acceptRequest(id); running = true; session.turnStatus = "running";
        metadata();
        if (replaying) return;
        auto receiver = engine.client;
        auto admission = new ToolCancellation();
        synchronized (mutex)
        {
            activeCancellation = admission;
            if (stopPending || closing) admission.cancel();
        }
        auto model = session.model;
        auto thinking = session.thinking;
        void launch()
        {
            if (admission.cancelled()) return;
            const accepted = receiver.startChatMessages(prepared.messages, prepared.tools, model, thinking, id);
            if (accepted != ChatStartResult.accepted)
            {
                OpenCodeEvent event; event.kind = OpenCodeEventKind.error; event.requestId = id;
                event.text = "Provider request admission failed: " ~ to!string(accepted);
                receiver.pushLocalEvent(event);
            }
        }
        if (journal is null) launch();
        else if (!engine.dispatchAfterCommit(journal, id, &launch))
            throw new Exception("Request effect could not be queued for durable admission");
    }
    private void fail(string text)
    {
        if (engine.phase != RequestPhase.failed)
        {
            OpenCodeEvent failure; failure.kind = OpenCodeEventKind.error;
            failure.requestId = engine.activeRequestId; failure.text = text; engine.observe(failure);
        }
        ensureAssistant(); session.messages[$ - 1].error = text; session.messages[$ - 1].failed = true;
        running = false; session.turnStatus = "failed"; session.taskStatus = "blocked";
        updateLast(); metadata(); publish(AgentEventKind.turnFailed, "{}");
    }
    private void applyStop(bool pauseGoal = true)
    {
        const wasRunning = running;
        const previousStatus = session.turnStatus;
        retryAtMs = -1;
        engine.stop(); engine.client.cancel();
        engine.client.closeSession();
        engine.client = new OpenCodeClient(config.baseUrl, config.apiKey, engine.retryPolicy);
        engine.client.setEventWake(&notify); engine.client.setOpenCodeSession(sessionRoutingKey(session));
        running = false; session.turnStatus = wasRunning || pauseGoal ? "interrupted" : previousStatus;
        if (pauseGoal && goalActive(session)) { session.goalStatus = "paused"; recordGoalOutcome(session, "paused", frameUnix); }
        foreach (call; engine.pendingToolCalls)
            if (!(call.id in engine.reportedToolCallIds))
            {
                ChatMessage cancelled; cancelled.role = "tool"; cancelled.failed = true;
                cancelled.toolCallId = call.id; cancelled.toolName = call.name; cancelled.toolArgs = call.arguments;
                cancelled.toolState = ToolState.cancelled;
                cancelled.content = "Stopped: no completed result was accepted. The physical effect may have started; inspect its state before retrying.";
                append(cancelled);
            }
        engine.pendingToolCalls = null; engine.pendingToolResults = 0;
        engine.pendingToolImages = null; engine.reportedToolCallIds = null;
        liveTools = null; omittedTools = 0;
        if (wasRunning && session.messages.length && session.messages[$ - 1].role == "assistant")
        { session.messages[$ - 1].finishReason = "cancelled"; updateLast(); }
        metadata();
        if (wasRunning || pauseGoal) publish(AgentEventKind.turnInterrupted, "{}");
    }
    private void applyCommand(ActorCommand command)
    {
        final switch (command.kind)
        {
            case ActorCommandKind.start:
                if (running) { enqueue(command, false); break; }
                if (command.text.length || command.imagesJson.length || command.context.length)
                    userRequest(command.text, promptContext(command));
                else if (!session.messages.length && session.queuedFollowUps.length)
                {
                    auto next = takeQueuedPrompt(session, false); userRequest(next.text, next.context);
                }
                else if (!preserveInputs) { resetOutage(); engine.turnCancelled = false; request(); }
                break;
            case ActorCommandKind.steer:
                if (running || preserveInputs) enqueue(command, true);
                else userRequest(command.text, promptContext(command));
                break;
            case ActorCommandKind.followUp:
                if (running || preserveInputs) enqueue(command, false);
                else userRequest(command.text, promptContext(command));
                break;
            case ActorCommandKind.stop: applyStop(command.text != "preserve-goal"); break;
            case ActorCommandKind.setGoal:
                const goal = clampGoalText(command.text.strip());
                if (!goal.length) { emit(ActorChangeKind.notice, "A goal requires a completion condition"); break; }
                const changed = session.goal != goal;
                session.goal = goal; session.goalStatus = command.activate ? "active" : "paused";
                session.goalStartedAt = frameUnix; session.goalTurns = 0;
                if (changed) resetTaskForNewGoal(session);
                recordGoalSet(session, frameUnix); metadata();
                if (command.activate && !preserveInputs)
                {
                    if (running) { session.queuedGuidance ~= "The user updated the persistent goal:\n" ~ goal; metadata(); }
                    else if (!session.messages.length) userRequest(goal);
                    else { internalNote(goalContinuationInstruction(session)); engine.turnCancelled = false; request(); }
                }
                break;
            case ActorCommandKind.pauseGoal:
                if (session.goal.length)
                {
                    session.goalStatus = "paused"; recordGoalOutcome(session, "paused", frameUnix); metadata();
                    if (running && !preserveInputs) applyStop();
                }
                break;
            case ActorCommandKind.resumeGoal:
                if (!session.goal.length) { emit(ActorChangeKind.notice, "There is no saved goal to resume"); break; }
                session.goalStatus = "active"; recordGoalOutcome(session, "active", frameUnix); metadata();
                if (!preserveInputs)
                {
                    if (running) { session.queuedGuidance ~= goalContinuationInstruction(session); metadata(); }
                    else { internalNote(goalContinuationInstruction(session)); engine.turnCancelled = false; request(); }
                }
                break;
            case ActorCommandKind.snapshot:
                auto snapshot = headerView(); snapshot["messages"] = messagesToJson(session.messages);
                emit(ActorChangeKind.snapshot, viewJson(snapshot)); break;
            case ActorCommandKind.regenerate:
            case ActorCommandKind.editPrompt:
            case ActorCommandKind.selectBranch:
            {
                const index = messageIndex(command.targetId);
                if (index == size_t.max ||
                    (command.kind == ActorCommandKind.regenerate && session.messages[index].role != "assistant") ||
                    (command.kind == ActorCommandKind.editPrompt && (session.messages[index].role != "user" || session.messages[index].internal)))
                { emit(ActorChangeKind.notice, "The requested message is unavailable for this branch action"); break; }
                session.activeLeafId = command.kind == ActorCommandKind.selectBranch
                    ? session.messages[index].id : session.messages[index].parentId;
                restoreBranchTask(session); engine.invalidateProjection(); metadata();
                if (command.kind == ActorCommandKind.editPrompt && preserveInputs)
                { userRequest(command.text, promptContext(command)); break; }
                if (preserveInputs || command.kind == ActorCommandKind.selectBranch) break;
                resetOutage();
                engine.turnCancelled = false;
                if (command.kind == ActorCommandKind.editPrompt) userRequest(command.text, promptContext(command));
                else request();
                break;
            }
            case ActorCommandKind.continueAnswer:
            {
                const index = messageIndex(command.targetId);
                bool onBranch;
                foreach (position; activeMessagePath(session)) if (position == index) onBranch = true;
                if (running || !onBranch || index == size_t.max || session.messages[index].role != "assistant" || session.messages[index].failed)
                { emit(ActorChangeKind.notice, "Continue requires an assistant response on the current idle branch"); break; }
                internalNote("Continuation request: continue the current task from its durable objective and recorded evidence. Keep the current branch and successful results; do not repeat material already present.");
                if (!preserveInputs) { resetOutage(); engine.turnCancelled = false; request(); }
                break;
            }
            case ActorCommandKind.setDraft: session.draft = command.text; metadata(); break;
            case ActorCommandKind.retryPending:
                if (retryAtMs < 0 || frameMs < retryAtMs || engine.turnCancelled) break;
                if (!quotaWait && !engine.retryPolicy.available((frameMs - outageStartedMs).msecs))
                {
                    retryAtMs = -1; running = false; session.turnStatus = "failed"; session.taskStatus = "blocked";
                    metadata(); break;
                }
                retryAtMs = -1;
                if (quotaWait) { outageStartedMs = frameMs; resendCount = 0; quotaWait = false; }
                else ++resendCount;
                if (session.messages.length && session.messages[$ - 1].role == "assistant" && session.messages[$ - 1].failed)
                    session.activeLeafId = session.messages[$ - 1].parentId;
                applySteering(); request(); break;
        }
    }
    private size_t messageIndex(string id)
    {
        foreach (i, message; session.messages) if (message.id == id) return i;
        return size_t.max;
    }
    private ulong workspaceRevision(string workspace)
    {
        return to!ulong(effectFact("workspace.revision\n" ~ workspace,
            () => to!string(toolWorkspaceRevision(workspace))));
    }
    private void refreshVerification()
    {
        const current = verificationScope(config.workspace, workspaceRevision(config.workspace));
        if (session.verificationStatus == "passed" && session.verificationScope != current)
        { session.verificationStatus = "required"; session.taskStatus = "active"; }
        session.verificationScope = current;
    }
    private void toolsRequested(const ref OpenCodeEvent event)
    {
        ensureAssistant();
        if (!config.request.toolsEnabled) { fail("Provider requested tools while tool access was disabled. No tool was executed."); return; }
        auto calls = normalizeToolCalls(event.toolCalls, session.messages, session.activeLeafId, event.requestId);
        if (!calls.length) { fail("Provider returned an empty tool batch"); return; }
        auto assistant = &session.messages[$ - 1];
        assistant.toolCalls = calls.dup;
        assistant.promptTokens = event.promptTokens; assistant.completionTokens = event.completionTokens;
        assistant.totalTokens = event.totalTokens; updateLast();
        engine.pendingToolCalls = calls.dup; engine.pendingToolResults = cast(int) calls.length;
        engine.reportedToolCallIds = null; ++engine.toolRounds;
        resetOutage();
        if (!offeredTools)
        {
            foreach (call; calls)
            {
                ChatMessage skipped; skipped.role = "tool"; skipped.failed = true;
                skipped.toolCallId = call.id; skipped.toolName = call.name; skipped.toolArgs = call.arguments;
                skipped.toolState = ToolState.failed;
                skipped.content = "No tool was executed: this request offered no tools.";
                append(skipped);
            }
            engine.pendingToolCalls = null; engine.pendingToolResults = 0;
            if (!goalActive(session) && completionHandoffPending(session)) completeFromEvidence();
            else fail("Provider requested tools that were unavailable for this request. No tool was executed.");
            return;
        }
        if (hasExhaustedRepeatedCall(session, calls))
        {
            foreach (call; calls)
            {
                ChatMessage skipped; skipped.role = "tool"; skipped.toolName = call.name;
                skipped.toolCallId = call.id; skipped.toolArgs = call.arguments; skipped.failed = true;
                skipped.toolState = ToolState.failed;
                skipped.content = "This exact call already ran repeatedly in unchanged task state. No tool ran; choose a different action.";
                append(skipped);
            }
            engine.pendingToolCalls = null; engine.pendingToolResults = 0;
            if (outputRecoveryCount(session) >= maxOutputRecoveries) fail("Repeated tool calls added no progress; the task and goal were preserved.");
            else { internalNote(outputRecoveryMarker ~ "Change the unsuccessful approach and continue with a useful action."); request(); }
            return;
        }
        auto token = new ToolCancellation(); engine.cancellation = token;
        liveTools = null; omittedTools = 0;
        foreach (i, call; calls)
        {
            if (i >= 64) { ++omittedTools; continue; }
            ConversationToolView view;
            view.id = call.id; view.name = call.name;
            view.arguments = checkpointSnippet(call.arguments, 2048);
            view.output = "Queued: waiting for durable admission and a tool worker.";
            liveTools ~= view;
        }
        metadata();
        synchronized (mutex)
        {
            activeCancellation = token;
            if (stopPending || closing) token.cancel();
        }
        if (replaying) return;
        auto receiver = engine.client;
        const id = engine.activeRequestId;
        const workspace = config.workspace;
        ChangeContext context; context.conversationId = session.id; context.turnId = to!string(id);
        context.diagnosticReadOnly = config.request.diagnosticReview;
        context.computer = ComputerUseContext(true, sessionRoutingKey(session),
            config.baseUrl, config.apiKey, session.model, false, cast(uint) id);
        void launch()
        { if (!token.cancelled()) scheduleToolBatch(receiver, id, calls, workspace, token, context); }
        if (journal is null) launch();
        else if (!engine.dispatchAfterCommit(journal, id, &launch))
            throw new Exception("Tool intent was not admitted; no tools were started");
    }
    private void toolResult(const ref OpenCodeEvent event)
    {
        if (event.toolRunning)
        {
            if (event.toolCallId in engine.reportedToolCallIds) return;
            foreach (ref view; liveTools)
                if (view.id == event.toolCallId)
                {
                    if (view.name != event.toolName) return;
                    view.state = event.toolState;
                    view.started = view.started || event.toolStarted;
                    view.elapsedMs = event.elapsedMs;
                    view.output = checkpointSnippet(event.text, 2048);
                    emit(ActorChangeKind.toolProgress, toolViewJson(view).toString(), view.id);
                    break;
                }
            return;
        }
        const admission = engine.admitToolResult(event.toolCallId);
        if (!admission.accepted) return;
        foreach (ref view; liveTools)
            if (view.id == event.toolCallId)
            {
                view.state = event.toolState; view.elapsedMs = event.elapsedMs;
                view.output = checkpointSnippet(event.text, 2048);
                emit(ActorChangeKind.toolProgress, toolViewJson(view).toString(), view.id);
                break;
            }
        const workspace = config.workspace;
        const current = workspaceRevision(workspace);
        const currentScope = verificationScope(workspace, current);
        if (session.verificationStatus == "passed" && session.verificationScope != currentScope)
        { session.verificationStatus = "required"; session.taskStatus = "active"; }
        session.verificationScope = currentScope;
        const verificationWorkspace = event.verificationWorkspace.length ? event.verificationWorkspace : workspace;
        const policy = ToolResultPolicy(config.request.nestedPlans, workspace, verificationWorkspace,
            frameTime, workspaceRevision(verificationWorkspace));
        auto settled = settleToolResult(session, event, admission.arguments, policy);
        append(settled.message);
        if (!settled.message.failed)
        {
            if (event.toolName == "update_plan") applyTaskPlan(session, admission.arguments);
            if (event.toolName == "update_subplan") applyTaskSubplan(session, admission.arguments);
            if (event.toolName == "goal_complete")
            {
                session.goalStatus = "completed"; session.goalTurns = 0; session.taskStatus = "completed";
                recordGoalOutcome(session, "completed", frameUnix);
            }
            if (event.toolName == "request_input" || event.toolName == "task_blocker")
            { session.taskStatus = "waiting_input"; session.contract.blocker = parseJSON(admission.arguments)["reason"].str; }
        }
        const prose = !settled.message.failed && isPlainDocumentMutation(event.toolName, admission.arguments);
        if (!prose && (event.workspaceChanged || isSubstantiveMutation(event.toolName, settled.message.failed,
                event.diffAdditions, event.diffDeletions, event.diffText)))
        { session.verificationStatus = "required"; session.taskStatus = "active"; }
        else if (settled.checkerAttempt && !settled.scopedVerification)
        { session.verificationStatus = "required"; if (session.taskStatus != "waiting_input") session.taskStatus = "active"; }
        else if (settled.acceptedVerification)
        {
            session.verificationStatus = "passed";
            if (session.taskStatus != "waiting_input" && !taskInvestigation(session))
                session.taskStatus = hasIncompleteTaskSteps(session) ? "active" : "completed";
        }
        engine.pendingToolImages ~= event.images;
        metadata();
        if (--engine.pendingToolResults > 0) return;
        engine.pendingToolCalls = null; engine.reportedToolCallIds = null;
        liveTools = null; omittedTools = 0;
        if (engine.pendingToolImages.length)
        {
            ChatMessage images; images.role = "user"; images.internal = true;
            images.content = "Image evidence from the preceding tool results. Inspect the actual pixels before acting.";
            images.images = engine.pendingToolImages; engine.pendingToolImages = null; append(images);
            pruneHistoryImages(session, activeMessagePath(session), config.request.imageLimit);
        }
        applySteering(); request();
    }
    private void applySteering()
    {
        if (!session.queuedGuidance.length) return;
        while (session.queuedGuidance.length)
        { auto next = takeQueuedPrompt(session, true); appendUser(next.text, next.context); }
        metadata();
    }
    private void completed(const ref OpenCodeEvent event)
    {
        resetOutage();
        refreshVerification();
        ensureAssistant(); auto message = &session.messages[$ - 1];
        message.finishReason = event.finishReason; message.promptTokens = event.promptTokens;
        message.completionTokens = event.completionTokens; message.totalTokens = event.totalTokens;
        message.retiredImages = completedReplyImageIds(session, message.id, config.request.imageLimit);
        updateLast();
        if (event.cancelled) { applyStop(); return; }
        if (answerReplayed(session) || goalAuditStalled(session))
        {
            if (outputRecoveryCount(session) >= maxOutputRecoveries)
            { fail("Provider output repeatedly added no progress. Retry continues the preserved task and goal."); return; }
            internalNote(outputRecoveryMarker ~ "The response added no new action or evidence. Continue the unfinished task with a different useful action.");
            request(); return;
        }
        auto policy = config.turn; policy.toolsEnabled = config.request.toolsEnabled; policy.finishReason = event.finishReason;
        const decision = decideTurn(session, policy);
        if (decision.action == TurnAction.applySteering) applySteering();
        if (decision.recordedSummary.length)
        { ChatMessage summary; summary.role = "assistant"; summary.content = decision.recordedSummary; append(summary); }
        if (decision.guidance.length) internalNote(decision.guidance);
        if (decision.clearBlocker) session.contract.blocker = "";
        if (decision.advanceGoal) ++session.goalTurns;
        session.taskStatus = decision.taskStatus; session.turnStatus = decision.turnStatus;
        metadata();
        if (decision.continues()) { request(); return; }
        running = false; engine.activeRequestId = 0;
        if (session.messages.length && session.messages[$ - 1].id == session.activeLeafId)
        { session.messages[$ - 1].taskStateJson = activeTaskStateJson(session); updateLast(); }
        publish(AgentEventKind.turnCompleted, "{}"); metadata();
        if (decision.action == TurnAction.settle && session.queuedFollowUps.length)
        {
            auto next = takeQueuedPrompt(session, false); userRequest(next.text, next.context);
        }
    }
    private void completeFromEvidence()
    {
        ChatMessage summary; summary.role = "assistant"; summary.content = recordedCompletionHandoff(session);
        append(summary);
        OpenCodeEvent done; done.kind = OpenCodeEventKind.done; done.requestId = engine.activeRequestId;
        done.finishReason = "stop"; engine.observe(done); completed(done);
    }
    private void failed(const ref OpenCodeEvent event)
    {
        if (!goalActive(session) && completionHandoffPending(session))
        {
            ensureAssistant(); session.messages[$ - 1].failed = true;
            session.messages[$ - 1].error = event.text; updateLast(); completeFromEvidence(); return;
        }
        if (event.outputIssue.length)
        {
            ensureAssistant(); session.messages[$ - 1].failed = true;
            session.messages[$ - 1].error = event.text; updateLast();
            if (outputRecoveryCount(session) >= maxOutputRecoveries)
            { fail("Provider output repeatedly failed protocol validation. Retry continues the preserved task and goal."); return; }
            internalNote(outputRecoveryMarker ~ "The provider returned unusable output. Use the structured tool protocol and take a different useful action; do not repeat the rejected output.");
            request(); return;
        }
        fail(event.text);
        if (outageStartedMs < 0) outageStartedMs = frameMs;
        const decision = engine.retryPolicy.resend(event.text, resendCount,
            (frameMs - outageStartedMs).msecs, false, event.retryExhausted);
        if (!decision.retry) return;
        retryAtMs = frameMs + decision.delayMs; quotaWait = decision.reason == RetryReason.quotaLimit;
        running = true; session.turnStatus = "running"; session.taskStatus = "active"; metadata();
    }
    private void applyEvent(const ref OpenCodeEvent event)
    {
        if (engine.turnCancelled || (event.requestId && event.requestId != engine.activeRequestId)) return;
        engine.observe(event);
        final switch (event.kind)
        {
            case OpenCodeEventKind.chatBegin: ensureAssistant(); break;
            case OpenCodeEventKind.delta:
                ensureAssistant();
                if (event.reasoning) session.messages[$ - 1].reasoning ~= event.text;
                else session.messages[$ - 1].content ~= event.text;
                engine.invalidateProjection();
                emit(ActorChangeKind.delta, event.text, session.activeLeafId, event.reasoning);
                checkpointBytes += event.text.length;
                if (checkpointBytes >= 64 * 1024 || lastCheckpoint == MonoTime.init ||
                    MonoTime.currTime - lastCheckpoint >= 500.msecs)
                {
                    publish(AgentEventKind.itemUpdated, runtimeMessagePayload(session.messages[$ - 1]), session.activeLeafId);
                    checkpointBytes = 0; lastCheckpoint = MonoTime.currTime;
                }
                break;
            case OpenCodeEventKind.usage: emit(ActorChangeKind.usage, eventJson(event).toString()); break;
            case OpenCodeEventKind.toolCallDelta: break;
            case OpenCodeEventKind.toolCalls: toolsRequested(event); break;
            case OpenCodeEventKind.toolResult: toolResult(event); break;
            case OpenCodeEventKind.done: completed(event); break;
            case OpenCodeEventKind.error: failed(event); break;
            case OpenCodeEventKind.models:
            case OpenCodeEventKind.modelsError: break;
        }
    }
    private void frame(ActorCommand command, OpenCodeEvent event, bool provider,
        JSONValue recorded = JSONValue.init, bool preserve = false)
    {
        auto facts = recorded.type == JSONType.object ? new EffectFacts(recorded["facts"])
            : config.recordTrace ? new EffectFacts() : null;
        auto previous = installEffectFacts(facts); scope (exit) installEffectFacts(previous);
        replayId = 0; frameIds = null;
        preserveInputs = replaying ? recorded["preserve"].boolean : preserve;
        if (replaying)
        {
            frameTime = recorded["time"].str; frameUnix = recorded["unix"].integer;
            frameMs = recorded["elapsedMs"].integer;
            foreach (id; recorded["ids"].array) frameIds ~= id.str;
        }
        else
        {
            const now = Clock.currTime; frameUnix = now.toUnixTime();
            frameTime = format("%02d:%02d", now.hour, now.minute);
            frameMs = (MonoTime.currTime - clockOrigin).total!"msecs";
        }
        if (!journalStarted)
        {
            images = new ConversationImages(buildPath(opencodeStateDirectory(), "attachments"));
            images.archive(session);
            journalStarted = true;
            if (!replaying && journal !is null)
            {
                auto payload = parseJSON(runtimeThreadPayload(session));
                payload["snapshot"] = sessionToJson(session);
                publish(AgentEventKind.threadStarted, payload.toString());
            }
        }
        if (provider) applyEvent(event); else applyCommand(command);
        if (replaying)
        { if (replayId != frameIds.length) throw new Exception("Replay did not consume its recorded message IDs"); return; }
        if (!config.recordTrace || traceTruncated) return;
        if (!facts.complete) { trace = null; traceTruncated = true; return; }
        JSONValue value;
        value["provider"] = provider; value["command"] = cast(int) command.kind; value["text"] = command.text;
        value["target"] = command.targetId; value["activate"] = command.activate;
        value["images"] = command.imagesJson; value["context"] = command.context;
        value["preserve"] = preserveInputs;
        value["event"] = eventJson(event); value["time"] = frameTime; value["unix"] = frameUnix;
        value["elapsedMs"] = frameMs;
        value["ids"] = JSONValue(frameIds); value["facts"] = facts.toJson();
        const bytes = value.toString().length;
        if (bytes > 8 * 1024 * 1024 - traceBytes)
        { trace = null; traceTruncated = true; return; }
        traceBytes += bytes; trace ~= value;
    }
    private void run()
    {
        scope (exit)
        {
            if (engine !is null) engine.close();
            if (ownsWorkerSlot) workerBudget.release();
            synchronized (mutex) { closed = true; wake.notifyAll(); }
        }
        try
        {
            engine = new ThreadEngine(config.baseUrl, config.apiKey, ProviderRetryPolicy(config.outageBudgetMs.msecs)); engine.threadId = session.id;
            engine.client.setEventWake(&notify); engine.client.setOpenCodeSession(sessionRoutingKey(session));
            OpenCodeEvent[] events;
            while (true)
            {
                Envelope[] pending; bool stop, finish, snapshot, pause; ulong epoch;
                synchronized (mutex)
                {
                    stop = stopPending; stopPending = false; finish = closing;
                    pause = pauseOnStop; pauseOnStop = false;
                    epoch = admissionEpoch; snapshot = snapshotPending; snapshotPending = false;
                    pending = commands; commands = null; commandBytes = 0;
                }
                if (stop || finish)
                    foreach (input; pending)
                        if (finish || input.epoch < epoch)
                            processInput(input, true);
                if (stop || (finish && running)) frame(ActorCommand(ActorCommandKind.stop,
                    pause || finish ? "" : "preserve-goal"), OpenCodeEvent.init, false);
                if (finish) return;
                foreach (input; pending)
                    if (!stop || input.epoch >= epoch) processInput(input, false);
                engine.client.drain(events, 64, 256 * 1024);
                foreach (event; events)
                {
                    synchronized (mutex) if (stopPending || closing) break;
                    frame(ActorCommand.init, event, true);
                }
                if (retryAtMs >= 0 && (MonoTime.currTime - clockOrigin).total!"msecs" >= retryAtMs)
                    frame(ActorCommand(ActorCommandKind.retryPending), OpenCodeEvent.init, false);
                if (snapshot) frame(ActorCommand(ActorCommandKind.snapshot), OpenCodeEvent.init, false);
                synchronized (mutex)
                    if (!commands.length && !stopPending && !closing && !snapshotPending && !engine.client.hasPendingEvents()) wake.wait(20.msecs);
            }
        }
        catch (Throwable error)
        {
            preserveUnsettledInput(error.msg);
            running = false; session.turnStatus = "failed"; session.taskStatus = "blocked";
            if (config.recordTrace) { traceTruncated = true; trace = null; }
            emit(ActorChangeKind.fault, error.msg);
        }
    }

    private void processInput(Envelope input, bool preserve)
    {
        currentCommandSerial = input.serial; currentCommand = input.command; currentInputRetained = false;
        frame(input.command, OpenCodeEvent.init, false, JSONValue.init, preserve);
        synchronized (mutex) unsettledInputs.remove(input.serial);
        currentCommandSerial = 0;
    }

    private void preserveUnsettledInput(string error)
    {
        import std.algorithm : sort;
        ActorCommand[ulong] remaining;
        bool pause;
        synchronized (mutex)
        {
            failure = error; pause = pauseOnStop || closing;
            closing = true; remaining = unsettledInputs;
            unsettledInputs = null; commands = null; commandBytes = 0;
        }
        auto serials = remaining.keys; serials.sort();
        foreach (serial; serials)
        {
            if (serial == currentCommandSerial && currentInputRetained) continue;
            retainAcceptedInput(session, remaining[serial], frameUnix);
        }
        if (pause && goalActive(session))
        { session.goalStatus = "paused"; recordGoalOutcome(session, "paused", frameUnix); }
    }

    public static void retainAcceptedInput(ref ChatSession session, const ref ActorCommand command, long timestamp)
    {
            ChatPromptContext context;
            try context = promptContext(command);
            catch (Exception)
            { context.text = command.context ~ "\nUnparsed image input retained for recovery:\n" ~ command.imagesJson; }
            switch (command.kind)
            {
                case ActorCommandKind.start:
                case ActorCommandKind.followUp:
                case ActorCommandKind.editPrompt:
                    if (command.text.length || command.imagesJson.length || command.context.length)
                        queuePrompt(session, command.text, context, false);
                    break;
                case ActorCommandKind.steer:
                    if (command.text.length || command.imagesJson.length || command.context.length)
                        queuePrompt(session, command.text, context, true);
                    break;
                case ActorCommandKind.setDraft: session.draft = command.text; break;
                case ActorCommandKind.setGoal:
                    const goal = clampGoalText(command.text.strip());
                    const changed = session.goal != goal;
                    session.goal = goal;
                    if (session.goal.length)
                    {
                        session.goalStatus = command.activate ? "active" : "paused";
                        session.goalStartedAt = timestamp; session.goalTurns = 0;
                        if (changed) resetTaskForNewGoal(session);
                        recordGoalSet(session, timestamp);
                    }
                    break;
                case ActorCommandKind.pauseGoal:
                    if (session.goal.length) session.goalStatus = "paused";
                    break;
                case ActorCommandKind.resumeGoal:
                    if (session.goal.length) session.goalStatus = "active";
                    break;
                default: break;
            }
    }

    /// Read after close: the worker has relinquished all model/trace ownership.
    string finalSnapshot()
    {
        if (!isClosed() || sessionTaken) throw new Exception("Actor final state is unavailable or was already transferred");
        return sessionToJson(session).toString();
    }
    ChatSession takeFinalSession()
    {
        synchronized (joinMutex)
        {
            if (!isClosed() || sessionTaken) throw new Exception("Actor final state is unavailable or was already transferred");
            auto result = session; session = ChatSession.init; sessionTaken = true;
            engine = null; images = null; return result;
        }
    }
    string recordedTrace()
    {
        if (!isClosed()) throw new Exception("Close the actor before reading its trace");
        if (traceTruncated) throw new Exception("Actor diagnostic trace is incomplete or exceeded its recording budget");
        JSONValue value;
        value["schema"] = 4; value["initial"] = initialIdentity;
        value["outageBudgetMs"] = config.outageBudgetMs;
        value["configuration"] = configurationIdentity; value["frames"] = JSONValue(trace);
        return value.toString();
    }

    public static string replay(const ref ChatSession initial, ActorConfiguration config, string recordedTrace)
    {
        const recording = parseJSON(recordedTrace);
        if (config.outageBudgetMs < 0) config.outageBudgetMs = recording["outageBudgetMs"].integer;
        if (recording["schema"].integer != 4 ||
            recording["initial"].str != sha256Of(sessionToJson(initial).toString()).toHexString() ||
            recording["configuration"].str != configurationKey(config))
            throw new Exception("Actor replay initial state or behavioral configuration does not match the recording");
        auto owner = new ConversationActor(initial, config, null, null, false);
        scope (exit) owner.engine.close();
        owner.running = false; owner.nextRequest = 0; owner.replaying = true;
        foreach (entry; recording["frames"].array)
        {
            ActorCommand command; command.kind = cast(ActorCommandKind) entry["command"].integer; command.text = entry["text"].str;
            command.targetId = entry["target"].str; command.activate = entry["activate"].boolean;
            command.imagesJson = entry["images"].str; command.context = entry["context"].str;
            owner.frame(command, eventFromJson(entry["event"]), entry["provider"].boolean, entry);
        }
        return sessionToJson(owner.session).toString();
    }
}

private string configurationKey(const ref ActorConfiguration config)
{
    import std.traits : FieldNameTuple, isIntegral, isSomeString;
    import auroraopencode.projectioncache : ProjectionRevision;
    JSONValue value;
    value["workspace"] = config.workspace;
    value["outageBudgetMs"] = config.outageBudgetMs;
    static foreach (member; ["request", "turn"])
    {{
        value[member] = JSONValue.emptyObject;
        static foreach (name; FieldNameTuple!(typeof(__traits(getMember, ActorConfiguration.init, member))))
        {{
            alias T = typeof(__traits(getMember, __traits(getMember, ActorConfiguration.init, member), name));
            const field = __traits(getMember, __traits(getMember, config, member), name);
            static if (is(T == bool) || isSomeString!T) value[member][name] = field;
            else static if (isIntegral!T) value[member][name] = cast(long) field;
            else static if (is(T == OpenCodeToolDef[]))
            {
                value[member][name] = JSONValue.emptyArray;
                foreach (tool; field)
                    value[member][name].array ~= JSONValue([tool.name, tool.description, tool.parametersJson]);
            }
            else static if (is(T == ProjectionRevision))
                value[member][name] = JSONValue([cast(long) field.graph, cast(long) field.capabilities]);
            else static assert(false, "Unrecorded actor policy field: " ~ name);
        }}
    }}
    return sha256Of(value.toString()).toHexString().idup;
}

private JSONValue eventJson(const ref OpenCodeEvent event)
{
    import std.traits : FieldNameTuple, isIntegral, isFloatingPoint, isSomeString;
    auto value = JSONValue.emptyObject;
    static foreach (name; FieldNameTuple!OpenCodeEvent)
    {{
        alias T = typeof(__traits(getMember, OpenCodeEvent.init, name));
        const field = __traits(getMember, event, name);
        static if (is(T == bool) || isSomeString!T) value[name] = field;
        else static if (isIntegral!T || is(T == enum)) value[name] = cast(long) field;
        else static if (is(T == OpenCodeToolCall[]))
        {
            value[name] = JSONValue.emptyArray;
            foreach (call; field)
            { JSONValue item; item["id"] = call.id; item["name"] = call.name; item["arguments"] = call.arguments; value[name].array ~= item; }
        }
        else static if (is(T == ChatImageAttachment[]))
        { value[name] = JSONValue.emptyArray; foreach (image; field) value[name].array ~= imageAttachmentToJson(image); }
        else static if (is(T == string[])) value[name] = JSONValue(field);
        else static if (is(T == int[string]))
        { value[name] = JSONValue.emptyObject; foreach (key, count; field) value[name][key] = count; }
        else static assert(false, "Unrecorded provider event field: " ~ name);
    }}
    return value;
}
private OpenCodeEvent eventFromJson(JSONValue value)
{
    import std.traits : FieldNameTuple, isIntegral, isSomeString;
    OpenCodeEvent event;
    static foreach (name; FieldNameTuple!OpenCodeEvent)
    {{
        alias T = typeof(__traits(getMember, OpenCodeEvent.init, name));
        auto field = value[name];
        static if (is(T == bool)) __traits(getMember, event, name) = field.boolean;
        else static if (isSomeString!T) __traits(getMember, event, name) = field.str;
        else static if (isIntegral!T || is(T == enum)) __traits(getMember, event, name) = cast(T) field.integer;
        else static if (is(T == OpenCodeToolCall[]))
            foreach (call; field.array) event.toolCalls ~= OpenCodeToolCall(call["id"].str, call["name"].str, call["arguments"].str);
        else static if (is(T == ChatImageAttachment[]))
            foreach (image; field.array) event.images ~= imageAttachmentFromJson(image);
        else static if (is(T == string[]))
            foreach (item; field.array) __traits(getMember, event, name) ~= item.str;
        else static if (is(T == int[string]))
            foreach (key, count; field.object) __traits(getMember, event, name)[key] = cast(int) count.integer;
        else static assert(false, "Unreplayed provider event field: " ~ name);
    }}
    return event;
}
