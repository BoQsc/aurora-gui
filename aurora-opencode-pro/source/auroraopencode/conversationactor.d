module auroraopencode.conversationactor;

import auroraopencode.planprogress : planProgressGuidance;

import auroraopencode.core;
import auroraopencode.conversationencode;
import auroraopencode.conversationimages : ConversationImages;
import auroraopencode.conversationview;
import auroraopencode.conversationmetadata : MetadataDelta;
import auroraopencode.conversationjobs : ConversationJobs, ModelJobKind;
import auroraopencode.conversationcoordination;
import auroraopencode.inputidentity : inputRecorded, markInputCommitted;
import auroraopencode.orchestrator : experimentalOrchestratorEnsureRoster, experimentalOrchestratorIsRouter,
    experimentalOrchestratorIdentityBlock, experimentalOrchestratorAgentModel, OrchestratorAssignment;
import auroraopencode.agentresult : subagentResult;
public import auroraopencode.conversationconfiguration : ActorConfiguration;
import auroraopencode.conversationconfiguration : actorBehaviorJson, decodeActorBehavior, configurationKey;
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
import auroraopencode.toolsettlement : ToolResultPolicy, settleToolResult, advanceToolTaskState;
import auroraopencode.toolprotocol : normalizeToolCalls;
import auroraopencode.toolscheduler : scheduleToolBatch, toolWorkspaceRevision;
import auroraopencode.tools : ChangeContext, ToolCancellation;
import auroraopencode.taskflow : acceptTaskRequest, taskInvestigation, restoreBranchTask, executionRecoveryDue, executionDiagnosisMarker;
import auroraopencode.taskmutation : applyTaskPlan, applyTaskSubplan;
import auroraopencode.taskpolicy : verificationScope;
import auroraopencode.goalmode : goalActive, recordGoalSet, recordGoalOutcome, clampGoalText, goalContinuationInstruction;
import auroraopencode.planhistory : recordPlanHistory;
import auroraopencode.goalmutation : resetTaskForNewGoal, restoreGoalTask;
import auroraopencode.outputrecovery : answerReplayed, goalAuditStalled, taskAuditStalled, outputRecoveryCount, maxOutputRecoveries, unfinishedTaskRecoveryInstruction;
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

public enum ActorAdmission { accepted, capacity, closed, invalid }
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
    regenerate, editPrompt, continueAnswer, selectBranch, setDraft, retryPending, configure, setTitle, selectView,
    startAssignment, childReport, coordinationFailed }
public struct ActorCommand
{
    ActorCommandKind kind;
    string text, targetId;
    bool activate = true;
    string imagesJson, context;
    string connectionBase, connectionKey;
    string inputId;
}
public struct ActorInputAcknowledgement { string threadId, inputId; bool retained; }
public alias ActorInputReceiver = void delegate(ActorInputAcknowledgement);
public struct ActorQueueStats
{
    size_t commands, commandBytes, changes, changeBytes;
    bool resync;
}
public enum ActorChangeKind { metadata, added, updated, delta, usage, resync, snapshot, fault, notice, toolProgress, metadataPatch, inputCommitted }
private enum EventLane { turn, title, compaction }
/// Values contain immutable strings/scalars only, so readers cannot mutate an
/// execution owner's graph, tool arrays or task state through a UI change.
public struct ActorChange
{
    ActorChangeKind kind;
    ulong revision, requestId;
    string itemId, text;
    bool reasoning, busy;
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
    private bool started, ownsWorkerSlot, publishedBusy, publishedJobs, sessionTaken, reducing;
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
    private bool[string] offeredToolNames;
    private bool viewed = true;
    private long clientBudgetMs;
    private long initialBudgetMs;
    private ActorConfiguration roundConfig, batchConfig;
    private string roundModel;
    private uint diagnosticRemaining;
    private bool diagnosticActive, diagnosticUsed;
    private ConversationImages images;
    private ConversationToolView[] liveTools;
    private bool preparingTools;
    private MonoTime preparingToolsAt;
    private size_t omittedTools;
    private const(PlanHistoryEntry)[] encodedHistorySource;
    private JSONValue encodedPlanHistory;
    private bool hasEncodedHistory;
    private MetadataDelta journalMetadata, viewMetadata;
    private MonoTime lastCheckpoint;
    private size_t checkpointBytes;
    private ToolCancellation activeCancellation;
    private ToolCancellation backgroundCancellation;
    private ConversationJobs jobs;
    private CoordinationReceiver coordinator;
    private ActorInputReceiver inputReceiver;
    private struct SeenInput { bool settled, retained; }
    private SeenInput[string] seenInputs;
    private bool waitingChildren, coordinationRecovered;
    private enum maxCommands = 128;
    private enum maxCommandBytes = 1024 * 1024;
    public static size_t commandCost(const ref ActorCommand command)
    { return ActorCommand.sizeof + command.text.length + command.targetId.length + command.imagesJson.length + command.context.length +
        command.connectionBase.length + command.connectionKey.length + command.inputId.length; }
    public static bool oversizedCommand(const ref ActorCommand command) { return commandCost(command) > maxCommandBytes; }
    private enum maxChanges = 256;
    private enum maxChangeBytes = 1024 * 1024;

    this(const ref ChatSession initial, ActorConfiguration config, RepositoryRuntime journal,
        WorkerBudget budget = null, ActorStart mode = ActorStart.immediate)
    { this(initial, config, journal, budget, mode == ActorStart.immediate, mode == ActorStart.deferred); }

    private this(const ref ChatSession initial, ActorConfiguration config, RepositoryRuntime journal,
        WorkerBudget budget, bool launchWorker, bool deferred = false, bool adopt = false)
    {
        if (!initial.id.length) throw new Exception("A conversation actor requires a stable thread ID");
        if (config.outageBudgetMs < 0)
            config.outageBudgetMs = configuredProviderRetryPolicy().outageBudget.total!"msecs";
        initialBudgetMs = config.outageBudgetMs;
        if (config.request.contextLimit < 0) throw new Exception("Conversation context budget cannot be negative");
        // Immutable text/pixels may be shared. Detach only mutable containers;
        // production admission must not stringify an entire long transcript.
        auto initialCopy = cast(ChatSession) initial;
        session = adopt ? initialCopy : snapshotChatSessions([initialCopy])[0];
        waitingChildren = waitingForChildren(session);
        foreach (message; session.messages) if (message.inputId.length && message.inputCommitted) seenInputs[message.inputId] = SeenInput(true, true);
        foreach (contexts; [session.queuedGuidanceContext, session.queuedFollowUpContext])
            foreach (context; contexts) if (context.inputId.length && context.inputCommitted) seenInputs[context.inputId] = SeenInput(true, true);
        if (config.recordTrace)
            initialIdentity = sha256Of(sessionToJson(session).toString()).toHexString().idup;
        configurationIdentity = configurationKey(config);
        this.config = config; this.config.request.availableTools = config.request.availableTools.dup;
        this.journal = journal;
        mutex = new Mutex(); joinMutex = new Mutex(); wake = new Condition(mutex);
        journalMetadata = new MetadataDelta(); viewMetadata = new MetadataDelta();
        jobs = new ConversationJobs(&notify); backgroundCancellation = new ToolCancellation();
        clockOrigin = MonoTime.currTime;
        workerBudget = budget is null ? actorWorkers : budget;
        if (launchWorker && launch() != ActorAdmission.accepted) throw new ActorCapacityException();
        else if (!launchWorker && !deferred)
        { closed = true; engine = new ThreadEngine("", "", ProviderRetryPolicy(config.outageBudgetMs.msecs)); }
    }

    /// The lifecycle owner already detached this model from presentation.
    /// Transfer its containers once, clearing the old owner's top-level value.
    public static ConversationActor adopt(ref ChatSession initial, ActorConfiguration config,
        RepositoryRuntime journal, WorkerBudget budget)
    {
        auto result = new ConversationActor(initial, config, journal, budget, false, true, true);
        initial = ChatSession.init; return result;
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
    void setCoordinator(CoordinationReceiver callback) { synchronized (mutex) coordinator = callback; }
    void setInputReceiver(ActorInputReceiver callback) { synchronized (mutex) inputReceiver = callback; }
    bool knowsInput(string id) { synchronized (mutex) return id.length && (id in seenInputs) !is null; }
    ActorActivity activity()
    {
        synchronized (mutex) return ActorActivity(publishedBusy || publishedJobs || unsettledInputs.length > 0 ||
            stopPending || snapshotPending || reducing, closed, unsettledInputs.length, revision);
    }

    ActorAdmission post(ActorCommand command)
    {
        if (!validInputIdentity(command)) return ActorAdmission.invalid;
        if (command.kind == ActorCommandKind.stop) return stop();
        ActorInputReceiver receiver; SeenInput seen;
        synchronized (mutex)
        {
            if (closing || closed) return ActorAdmission.closed;
            auto previous = command.inputId.length ? command.inputId in seenInputs : null;
            if (previous !is null) { seen = *previous; receiver = inputReceiver; }
            else
            {
            if (command.kind == ActorCommandKind.snapshot)
            { snapshotPending = true; wake.notifyAll(); return ActorAdmission.accepted; }
            const cost = commandCost(command);
            if (commands.length >= maxCommands || unsettledInputs.length >= maxCommands * 2 ||
                cost > maxCommandBytes - commandBytes)
                return ActorAdmission.capacity;
            if (command.kind == ActorCommandKind.regenerate || command.kind == ActorCommandKind.editPrompt ||
                command.kind == ActorCommandKind.selectBranch || command.kind == ActorCommandKind.startAssignment)
            {
                stopPending = true; ++admissionEpoch;
                if (activeCancellation !is null) activeCancellation.cancel();
                backgroundCancellation.cancel();
            }
            const serial = ++nextCommandSerial;
            if (command.inputId.length) seenInputs[command.inputId] = SeenInput.init;
            unsettledInputs[serial] = command;
            commands ~= Envelope(command, admissionEpoch, serial); commandBytes += cost; wake.notifyAll();
            return ActorAdmission.accepted;
            }
        }
        if (seen.settled && receiver !is null)
            try receiver(ActorInputAcknowledgement(session.id, command.inputId, seen.retained));
            catch (Exception) { return ActorAdmission.capacity; }
        return ActorAdmission.accepted;
    }
    public static bool validInputIdentity(const ref ActorCommand command)
    {
        if (!command.inputId.length) return true;
        return command.inputId.length <= 256 &&
            (command.kind == ActorCommandKind.start || command.kind == ActorCommandKind.steer ||
             command.kind == ActorCommandKind.followUp || command.kind == ActorCommandKind.editPrompt) &&
            (command.text.length || command.imagesJson.length || command.context.length);
    }

    ActorAdmission configure(ActorConfiguration next, string model, bool thinking)
    { return post(configurationCommand(next, model, thinking)); }

    public static ActorCommand configurationCommand(ActorConfiguration next, string model, bool thinking)
    {
        auto value = actorBehaviorJson(next); value["model"] = model; value["thinking"] = thinking;
        auto command = ActorCommand(ActorCommandKind.configure, value.toString());
        command.connectionBase = next.baseUrl; command.connectionKey = next.apiKey;
        return command;
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
            backgroundCancellation.cancel();
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
            backgroundCancellation.cancel();
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
    private void notifyView()
    {
        void delegate() callback;
        synchronized (mutex) callback = viewWake;
        if (callback !is null) callback();
    }
    private void emit(ActorChangeKind kind, string text = "", string id = "", bool reasoning = false)
    {
        if (replaying) return;
        scope (exit) notifyView();
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
                pendingSnapshot = ActorChange(kind, revision, engine is null ? 0 : engine.activeRequestId, id, text, reasoning, running || waitingChildren);
                hasSnapshot = true;
                return;
            }
            else if (changes.length >= maxChanges || changeBytes > maxChangeBytes || cost > maxChangeBytes - changeBytes)
            {
                changes = null; changeBytes = 0; needsSnapshot = true; return;
            }
            changes ~= ActorChange(kind, revision, engine is null ? 0 : engine.activeRequestId, id, text, reasoning, running || waitingChildren);
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
        auto payload = runtimeThreadJson(session, true); payload["planHistory"] = historyJson();
        auto durable = journalMetadata.update(payload);
        if (durable.value.object.length) publish(AgentEventKind.threadUpdated, durable.value.toString());
        bool deliver;
        synchronized (mutex) deliver = !needsSnapshot;
        if (deliver)
        {
            auto update = viewMetadata.update(headerView());
            emit(update.complete ? ActorChangeKind.metadata : ActorChangeKind.metadataPatch, update.value.toString());
        }
    }
    private JSONValue historyJson()
    {
        if (!hasEncodedHistory || encodedHistorySource.ptr != session.planHistory.ptr ||
            encodedHistorySource.length != session.planHistory.length)
        {
            encodedPlanHistory = planHistoryToJson(session.planHistory);
            encodedHistorySource = session.planHistory; hasEncodedHistory = true;
        }
        return encodedPlanHistory;
    }
    private JSONValue headerView()
    {
        auto value = sessionMetaToJson(session, false);
        value["planHistory"] = historyJson();
        ConversationExecutionView execution;
        execution.phase = preparingTools ? "preparing_tools" : to!string(engine.phase);
        if (waitingChildren) execution.phase = "waiting_agents";
        execution.routingKey = engine.client.openCodeSession();
        execution.requestModel = roundModel; execution.diagnosticReview = diagnosticActive || config.request.diagnosticReview;
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
        { ChatMessage message; message.role = "assistant"; if (config.turn.orchestratorEnabled) message.authorId = session.activeAgentId; append(message); }
    }
    private void internalNote(string text)
    {
        ChatMessage message; message.role = "user"; message.internal = true; message.content = text;
        append(message);
    }
    private static ChatPromptContext promptContext(const ref ActorCommand command)
    {
        ChatPromptContext context; context.text = command.context;
        context.inputId = command.inputId;
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
    private void appendUser(string text, ChatPromptContext context = ChatPromptContext.init, bool steering = false)
    {
        diagnosticRemaining = 0; diagnosticActive = false; diagnosticUsed = false;
        ChatMessage message; message.role = "user"; message.content = text; message.images = context.images;
        message.inputId = context.inputId;
        message.inputCommitted = context.inputCommitted;
        append(message); acceptTaskRequest(session, text, session.activeLeafId, steering);
        if (context.text.length)
        {
            ChatMessage detail; detail.role = "user"; detail.internal = true; detail.content = context.text;
            detail.inputId = context.inputId;
            detail.inputCommitted = context.inputCommitted;
            append(detail);
        }
    }
    private void userRequest(string text, ChatPromptContext context = ChatPromptContext.init)
    {
        cancelChildren();
        resetOutage();
        appendUser(text, context);
        session.turnStatus = "running"; running = true; engine.turnCancelled = false;
        metadata(); if (!preserveInputs) request();
    }
    private void request()
    {
        if (engine.turnCancelled) return;
        preparingTools = false; liveTools = null; omittedTools = 0;
        if (diagnosticActive && !diagnosticRemaining) finishDiagnostic();
        const diagnostic = config.diagnosticModel.length && diagnosticRemaining > 0;
        const budget = diagnostic && (config.outageBudgetMs <= 0 || config.outageBudgetMs > 15_000) ? 15_000 : config.outageBudgetMs;
        if (clientBudgetMs != budget)
        {
            engine.client.closeSession();
            engine.client = new OpenCodeClient(config.baseUrl, config.apiKey, ProviderRetryPolicy(budget.msecs));
            engine.client.setEventWake(&notify); clientBudgetMs = budget;
        }
        refreshVerification();
        if (images.prepare(session, config.request.imageLimit)) engine.invalidateProjection();
        auto policy = config.request;
        if (config.turn.orchestratorEnabled)
        {
            experimentalOrchestratorEnsureRoster(session);
            policy.orchestratorEnabled = true;
            policy.orchestratorRouter = experimentalOrchestratorIsRouter(session, session.activeAgentId);
            policy.identityBlock ~= experimentalOrchestratorIdentityBlock(session, session.activeAgentId);
        }
        policy.summaryOnly = !goalActive(session) && (policy.summaryOnly || completionHandoffPending(session));
        diagnosticActive = diagnostic && !policy.summaryOnly;
        if (diagnosticActive)
        {
            --diagnosticRemaining; policy.diagnosticReview = true; policy.compactionEnabled = true;
            if (policy.contextLimit <= 0 || policy.contextLimit > 64_000) policy.contextLimit = 64_000;
        }
        else diagnosticRemaining = 0;
        policy.revision.graph = engine.graphRevision;
        auto prepared = prepareAgentRequest(session, policy, engine.projection);
        roundConfig = config;
        roundConfig.request = policy;
        roundModel = diagnosticActive ? config.diagnosticModel : session.model;
        if (!diagnosticActive && config.turn.orchestratorEnabled)
        {
            const overrideModel = experimentalOrchestratorAgentModel(session, session.activeAgentId);
            if (overrideModel.length) roundModel = overrideModel;
        }
        offeredTools = prepared.tools.length > 0;
        offeredToolNames = null;
        foreach (tool; prepared.tools) offeredToolNames[tool.name] = true;
        if (prepared.checkpointCreated) metadata();
        const id = ++nextRequest;
        engine.client.setOpenCodeSession(sessionRoutingKey(session));
        engine.acceptRequest(id); running = true; session.turnStatus = "running";
        metadata();
        if (!replaying)
        {
        auto receiver = engine.client;
        auto admission = new ToolCancellation();
        synchronized (mutex)
        {
            activeCancellation = admission;
            if (stopPending || closing) admission.cancel();
        }
        auto model = roundModel;
        auto thinking = diagnosticActive ? false : session.thinking;
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
        if (config.modelCompaction && prepared.checkpointCreated)
        {
            auto messages = jobs.prepareCompaction(session, prepared.oldAnchor, prepared.oldSummary, policy.contextLimit,
                prepared.summaryByteBudget);
            if (messages.length) startJob(ModelJobKind.compaction, messages);
        }
    }
    private void startJob(ModelJobKind kind, ChatRequestMessage[] messages)
    {
        ToolCancellation gate;
        synchronized (mutex)
        {
            gate = backgroundCancellation;
            if (stopPending || closing) gate.cancel();
        }
        jobs.start(kind, ++nextRequest, messages, config, session.model, sessionRoutingKey(session), frameMs, replaying, journal, gate);
    }
    private void tryTitle()
    {
        if (!config.quickTitle || waitingChildren || preserveInputs || engine.turnCancelled || retryAtMs >= 0 ||
            engine.phase == RequestPhase.waiting || engine.phase == RequestPhase.streaming) return;
        auto messages = jobs.prepareTitle(session);
        if (!messages.length) return;
        metadata(); startJob(ModelJobKind.title, messages);
    }
    private bool beginDiagnostic()
    {
        if (!config.diagnosticModel.length || diagnosticUsed || diagnosticActive) return false;
        diagnosticRemaining = 4; diagnosticUsed = true; return true;
    }
    private void finishDiagnostic()
    {
        diagnosticRemaining = 0; diagnosticActive = false;
        internalNote(executionDiagnosisMarker ~ "Independent read-only review has ended. The main model must assess its recorded findings and apply the next useful fix or verification. A diagnosis is not task completion.");
    }
    private void coordinate(CoordinationKind kind, string round, string payload)
    {
        if (replaying) return;
        CoordinationReceiver receiver;
        synchronized (mutex) receiver = coordinator;
        auto effect = CoordinationEffect(kind, session.id, round, payload);
        if (kind == CoordinationKind.dispatch)
        {
            effect.behavior = actorBehaviorJson(config).toString();
            effect.connectionBase = config.baseUrl; effect.connectionKey = config.apiKey;
            effect.recordTrace = config.recordTrace;
        }
        if (receiver is null || !receiver(effect)) throw new Exception("Conversation coordination is unavailable or at capacity; its durable intent was preserved");
    }
    private void cancelChildren()
    {
        if (!waitingChildren) return;
        const state = parseJSON(session.orchestrationState);
        waitingChildren = false; session.orchestrationState = "";
        coordinate(CoordinationKind.cancel, state["round"].str, "");
    }
    private void dispatchChildren(const(OrchestratorAssignment)[] assignments)
    {
        auto previous = session.orchestrationState.length ? parseJSON(session.orchestrationState) : JSONValue.init;
        cancelChildren();
        const round = messageId(); string[] childIds;
        foreach (assignment; assignments)
        {
            string existing;
            if (previous.type == JSONType.object)
                foreach (child; previous["children"].array) if (child["agent"].str == assignment.agentId) existing = child["id"].str;
            childIds ~= existing.length ? existing : "t-" ~ messageId();
        }
        auto next = dispatchState(session, round, assignments, childIds);
        if (previous.type == JSONType.object)
            foreach (old; previous["children"].array)
            {
                bool retained;
                foreach (child; next["children"].array) if (child["agent"].str == old["agent"].str) retained = true;
                if (!retained) { old["reported"] = true; next["children"].array ~= old; }
            }
        session.orchestrationState = next.toString();
        waitingChildren = true; running = false; engine.activeRequestId = 0;
        session.turnStatus = "running"; session.activeAgentId = "orchestrator"; session.nextSpeakerId = "";
        jobs.close(); metadata();
        coordinate(CoordinationKind.dispatch, round, session.orchestrationState);
    }
    private void reportAssignment()
    {
        if (!session.parentSessionId.length || !session.parentDispatchId.length) return;
        auto note = subagentResult(session); metadata();
        JSONValue result; result["parent"] = session.parentSessionId; result["child"] = session.id;
        result["note"] = messageToJson(note);
        coordinate(CoordinationKind.report, session.parentDispatchId, result.toString());
    }
    private void acceptChildReport(const ref ActorCommand command)
    {
        if (!waitingChildren || preserveInputs) return;
        auto state = parseJSON(session.orchestrationState);
        if (state["round"].str != command.targetId) return;
        auto result = parseJSON(command.text);
        if (result["parent"].str != session.id) return;
        foreach (ref child; state["children"].array)
            if (child["id"].str == result["child"].str && !child["reported"].boolean)
            {
                ChatSession decoded; decodeMessages(JSONValue([result["note"]]), decoded);
                if (decoded.messages.length != 1 || decoded.messages[0].authorId != child["agent"].str ||
                    decoded.messages[0].role != "user" || !decoded.messages[0].internal)
                    throw new Exception("Child report identity did not match its assignment");
                append(decoded.messages[0]); child["reported"] = true;
                session.orchestrationState = state.toString(); waitingChildren = waitingForChildren(session); metadata();
                if (!waitingChildren)
                {
                    session.activeAgentId = "orchestrator";
                    running = true; engine.turnCancelled = false; applySteering(); request();
                }
                return;
            }
    }
    private void fail(string text, bool terminal = true)
    {
        preparingTools = false; liveTools = null; omittedTools = 0;
        if (engine.phase != RequestPhase.failed)
        {
            OpenCodeEvent failure; failure.kind = OpenCodeEventKind.error;
            failure.requestId = engine.activeRequestId; failure.text = text; engine.observe(failure);
        }
        ensureAssistant(); session.messages[$ - 1].error = text; session.messages[$ - 1].failed = true;
        running = !terminal;
        session.turnStatus = terminal ? "failed" : "running";
        session.taskStatus = terminal ? "blocked" : "active";
        if (terminal) { retryAtMs = -1; if (!viewed) session.unread = true; }
        updateLast(); metadata();
        if (terminal) { publish(AgentEventKind.turnFailed, "{}"); reportAssignment(); }
    }
    private void applyStop(bool pauseGoal = true)
    {
        const wasRunning = running || waitingChildren;
        const previousStatus = session.turnStatus;
        retryAtMs = -1;
        diagnosticRemaining = 0; diagnosticActive = false;
        cancelChildren();
        jobs.close();
        synchronized (mutex) backgroundCancellation = new ToolCancellation();
        engine.stop(); engine.client.cancel();
        engine.client.closeSession();
        engine.client = new OpenCodeClient(config.baseUrl, config.apiKey, engine.retryPolicy);
        engine.client.setEventWake(&notify); engine.client.setOpenCodeSession(sessionRoutingKey(session));
        running = false; session.turnStatus = wasRunning || pauseGoal ? "interrupted" : previousStatus;
        if (!viewed && (wasRunning || pauseGoal)) session.unread = true;
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
        liveTools = null; omittedTools = 0; preparingTools = false;
        if (wasRunning && session.messages.length && session.messages[$ - 1].role == "assistant")
        { session.messages[$ - 1].finishReason = "cancelled"; updateLast(); }
        metadata();
        if (wasRunning || pauseGoal) publish(AgentEventKind.turnInterrupted, "{}");
        if (wasRunning) reportAssignment();
    }
    private void applyCommand(ActorCommand command)
    {
        if (inputRecorded(session, command.inputId)) { currentInputRetained = true; return; }
        if (inputRecorded(session, command.inputId, false))
        {
            currentInputRetained = true;
            bool queued;
            foreach (contexts; [session.queuedGuidanceContext, session.queuedFollowUpContext])
                foreach (context; contexts) if (context.inputId == command.inputId) queued = true;
            if (queued) return;
            // Resume an append interrupted before its command commit, keeping
            // the original prompt node and already persisted hidden context.
            string promptId; bool hasContext;
            foreach (message; session.messages) if (message.inputId == command.inputId)
            { if (!message.internal) promptId = message.id; else hasContext = true; }
            if (promptId.length)
            {
                cancelChildren();
                if (!hasContext && command.context.length)
                {
                    ChatMessage detail; detail.role = "user"; detail.internal = true;
                    detail.content = command.context; detail.inputId = command.inputId; append(detail);
                }
                acceptTaskRequest(session, command.text, promptId);
                running = true; session.turnStatus = "running"; engine.turnCancelled = false; resetOutage();
                metadata(); if (!preserveInputs) request(); return;
            }
        }
        final switch (command.kind)
        {
            case ActorCommandKind.start:
                if (waitingChildren && !command.text.length && !command.imagesJson.length && !command.context.length) break;
                if (running || waitingChildren) { enqueue(command, false); break; }
                if (command.text.length || command.imagesJson.length || command.context.length)
                    userRequest(command.text, promptContext(command));
                else if (session.queuedFollowUps.length && (!session.messages.length || session.turnStatus == "completed" || session.turnStatus == "idle" || !session.turnStatus.length))
                {
                    auto next = takeQueuedPrompt(session, false); userRequest(next.text, next.context);
                }
                else if (!preserveInputs) { resetOutage(); engine.turnCancelled = false; applySteering(); request(); }
                break;
            case ActorCommandKind.steer:
                if (running || waitingChildren || preserveInputs) enqueue(command, true);
                else userRequest(command.text, promptContext(command));
                break;
            case ActorCommandKind.followUp:
                if (running || waitingChildren || preserveInputs) enqueue(command, false);
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
                    if (running || waitingChildren) { session.queuedGuidance ~= "The user updated the persistent goal:\n" ~ goal; metadata(); }
                    else if (!session.messages.length) userRequest(goal);
                    else { internalNote(goalContinuationInstruction(session)); engine.turnCancelled = false; request(); }
                }
                break;
            case ActorCommandKind.pauseGoal:
                if (session.goal.length)
                {
                    session.goalStatus = "paused"; recordGoalOutcome(session, "paused", frameUnix); metadata();
                    if ((running || waitingChildren) && !preserveInputs) applyStop();
                }
                break;
            case ActorCommandKind.resumeGoal:
                if (!session.goal.length) { emit(ActorChangeKind.notice, "There is no saved goal to resume"); break; }
                restoreGoalTask(session);
                session.goalStatus = "active"; recordGoalOutcome(session, "active", frameUnix); metadata();
                if (!preserveInputs)
                {
                    if (running || waitingChildren) { session.queuedGuidance ~= goalContinuationInstruction(session); metadata(); }
                    else { internalNote(goalContinuationInstruction(session)); engine.turnCancelled = false; request(); }
                }
                break;
            case ActorCommandKind.snapshot:
                auto snapshot = headerView(); viewMetadata.reset(snapshot);
                snapshot["messages"] = messagesToJson(session.messages);
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
                if (running || waitingChildren || !onBranch || index == size_t.max || session.messages[index].role != "assistant" || session.messages[index].failed)
                { emit(ActorChangeKind.notice, "Continue requires an assistant response on the current idle branch"); break; }
                internalNote("Continuation request: continue the current task from its durable objective and recorded evidence. Keep the current branch and successful results; do not repeat material already present.");
                if (!preserveInputs) { resetOutage(); engine.turnCancelled = false; request(); }
                break;
            }
            case ActorCommandKind.setDraft: session.draft = command.text; metadata(); break;
            case ActorCommandKind.setTitle:
                jobs.cancel(ModelJobKind.title); session.title = command.text; session.titleManual = true; metadata(); break;
            case ActorCommandKind.selectView:
                viewed = command.activate;
                if (viewed) session.unread = false;
                metadata(); break;
            case ActorCommandKind.configure:
            {
                ActorConfiguration next;
                string model;
                bool thinking;
                try
                {
                    auto value = parseJSON(command.text);
                    next = decodeActorBehavior(config, value);
                    if (next.request.contextLimit < 0) throw new Exception("Conversation context budget cannot be negative");
                    model = value["model"].str; thinking = value["thinking"].boolean;
                }
                catch (Exception error)
                { emit(ActorChangeKind.notice, "Configuration was not changed: " ~ error.msg); break; }
                if (command.connectionBase.length) next.baseUrl = command.connectionBase;
                if (command.connectionBase.length || command.connectionKey.length) next.apiKey = command.connectionKey;
                config = next; session.model = model; session.thinking = thinking;
                if (!config.quickTitle) jobs.cancel(ModelJobKind.title);
                if (!config.modelCompaction) jobs.cancel(ModelJobKind.compaction);
                if (!config.diagnosticModel.length) diagnosticRemaining = 0;
                engine.retryPolicy = ProviderRetryPolicy(config.outageBudgetMs.msecs);
                engine.client.setCredentials(config.baseUrl, config.apiKey);
                engine.invalidateProjection(); metadata();
                break;
            }
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
            case ActorCommandKind.childReport: acceptChildReport(command); break;
            case ActorCommandKind.coordinationFailed:
                if (waitingChildren && parseJSON(session.orchestrationState)["round"].str == command.targetId)
                { applyStop(false); fail(command.text); }
                break;
            case ActorCommandKind.startAssignment:
            {
                if (!session.parentSessionId.length || !command.targetId.length)
                { emit(ActorChangeKind.notice, "An assignment requires its parent and dispatch identity"); break; }
                const same = session.parentDispatchId == command.targetId;
                if (command.context.length)
                {
                    ChatSession seed; decodeSessionMetadata(parseJSON(command.context), seed);
                    if (seed.id != session.id || seed.parentSessionId != session.parentSessionId)
                        throw new Exception("Assignment metadata belongs to another child");
                    session.agents = seed.agents; session.instructions = seed.instructions;
                    session.activeAgentId = seed.activeAgentId; session.projectId = seed.projectId; session.toolsMode = seed.toolsMode;
                }
                session.parentDispatchId = command.targetId;
                if (same && session.turnStatus == "completed") { reportAssignment(); break; }
                if (preserveInputs) { enqueue(command, false); break; }
                if (!same || !session.messages.length)
                {
                    ChatMessage task; task.role = "user"; task.internal = true; task.authorId = session.subagentId;
                    task.content = "Task from the orchestrator: " ~ command.text ~ "\nWork with the available tools, then report the result concisely.";
                    append(task); acceptTaskRequest(session, command.text, session.activeLeafId);
                }
                else internalNote("Resume the preserved assignment using its recorded evidence: " ~ command.text);
                resetOutage(); engine.turnCancelled = false; running = true; session.turnStatus = "running";
                metadata(); request(); break;
            }
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
            if (diagnosticActive) { finishDiagnostic(); request(); return; }
            if (!goalActive(session) && completionHandoffPending(session)) completeFromEvidence();
            else fail("Provider requested tools that were unavailable for this request. No tool was executed.");
            return;
        }
        OpenCodeToolCall[] allowed;
        foreach (call; calls)
            if (call.name in offeredToolNames) allowed ~= call;
            else
            {
                ChatMessage skipped; skipped.role = "tool"; skipped.failed = true;
                skipped.toolCallId = call.id; skipped.toolName = call.name; skipped.toolArgs = call.arguments;
                skipped.toolState = ToolState.failed;
                skipped.content = "No tool was executed: this tool was not offered for the request. Use only the supplied structured tools.";
                append(skipped); engine.reportedToolCallIds[call.id] = true;
            }
        engine.pendingToolResults = cast(int) allowed.length;
        if (!allowed.length)
        {
            engine.pendingToolCalls = null; engine.reportedToolCallIds = null;
            if (diagnosticActive)
            {
                internalNote(executionDiagnosisMarker ~ "The review requested an unavailable tool. Use only the supplied read-only tools and report findings for the main model.");
                request(); return;
            }
            if (outputRecoveryCount(session) >= maxOutputRecoveries)
                fail("Provider repeatedly requested unavailable tools. The task was preserved; no unavailable tool was executed.");
            else
            {
                internalNote(outputRecoveryMarker ~ "The requested tools were not available. Choose a useful action from the supplied tools; do not invent tool names.");
                request();
            }
            return;
        }
        calls = allowed;
        auto token = new ToolCancellation(); engine.cancellation = token;
        batchConfig = roundConfig;
        liveTools = null; omittedTools = 0; preparingTools = false;
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
        const workspace = batchConfig.workspace;
        ChangeContext context; context.conversationId = session.id; context.turnId = to!string(id);
        context.diagnosticReadOnly = batchConfig.request.diagnosticReview;
        context.developerCaptured = true; context.developer = batchConfig.developer;
        context.computer = ComputerUseContext(true, sessionRoutingKey(session),
            batchConfig.baseUrl, batchConfig.apiKey, roundModel, false, cast(uint) id);
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
        const workspace = batchConfig.workspace;
        const current = workspaceRevision(workspace);
        const currentScope = verificationScope(workspace, current);
        const priorVerificationStatus = session.verificationStatus;
        const priorVerificationScope = session.verificationScope;
        if (session.verificationStatus == "passed" && session.verificationScope != currentScope)
        { session.verificationStatus = "required"; session.taskStatus = "active"; }
        session.verificationScope = currentScope;
        const verificationWorkspace = event.verificationWorkspace.length ? event.verificationWorkspace : workspace;
        auto policy = ToolResultPolicy(batchConfig.request.nestedPlans, workspace, verificationWorkspace,
            frameTime, workspaceRevision(verificationWorkspace));
        policy.orchestratorEnabled = batchConfig.turn.orchestratorEnabled;
        policy.routingHalted = engine.pendingRouting.halt;
        auto settled = settleToolResult(session, event, admission.arguments, policy);
        append(settled.message);
        if (!settled.message.failed)
        {
            engine.pendingRouting.accept(settled.routing);
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
        advanceToolTaskState(session, settled, event, admission.arguments,
            priorVerificationStatus, priorVerificationScope);
        engine.pendingToolImages ~= event.images;
        if (!diagnosticActive && !settled.message.failed && (settled.acceptedVerification || event.workspaceChanged)) diagnosticUsed = false;
        metadata();
        if (--engine.pendingToolResults > 0) return;
        engine.pendingToolCalls = null; engine.reportedToolCallIds = null;
        liveTools = null; omittedTools = 0; preparingTools = false;
        if (config.turn.orchestratorEnabled)
        {
            const routing = engine.pendingRouting.take();
            if (routing.halt)
            {
                if (routing.question.length) session.contract.blocker = routing.question;
                session.taskStatus = routing.status; session.turnStatus = "completed";
                running = false; engine.activeRequestId = 0;
                if (!viewed) session.unread = true;
                ChatMessage reply; reply.role = "assistant";
                reply.content = routing.question.length ? routing.question : settled.message.content; append(reply);
                publish(AgentEventKind.turnCompleted, "{}"); metadata(); reportAssignment(); return;
            }
            if (routing.assignments.length) { dispatchChildren(routing.assignments); return; }
        }
        if (engine.pendingToolImages.length)
        {
            ChatMessage images; images.role = "user"; images.internal = true;
            images.content = "Image evidence from the preceding tool results. Inspect the actual pixels before acting.";
            images.images = engine.pendingToolImages; engine.pendingToolImages = null; append(images);
            pruneHistoryImages(session, activeMessagePath(session), config.request.imageLimit);
        }
        if (!diagnosticActive && executionRecoveryDue(session))
        {
            internalNote(executionDiagnosisMarker ~ "Repeated tools added no supported outcome. Reject the unsuccessful hypothesis and inspect a reduced failing case or a different source.");
            beginDiagnostic();
        }
        applySteering();
        const progressGuidance = planProgressGuidance(session);
        if (progressGuidance.length) internalNote(progressGuidance);
        request();
    }
    private void applySteering()
    {
        if (!session.queuedGuidance.length) return;
        while (session.queuedGuidance.length)
        { auto next = takeQueuedPrompt(session, true); appendUser(next.text, next.context, true); }
        metadata();
    }
    private void completed(const ref OpenCodeEvent event)
    {
        preparingTools = false; liveTools = null; omittedTools = 0;
        resetOutage();
        refreshVerification();
        ensureAssistant(); auto message = &session.messages[$ - 1];
        message.finishReason = event.finishReason; message.promptTokens = event.promptTokens;
        message.completionTokens = event.completionTokens; message.totalTokens = event.totalTokens;
        message.retiredImages = completedReplyImageIds(session, message.id, config.request.imageLimit);
        updateLast();
        if (event.cancelled) { applyStop(); return; }
        if (diagnosticActive) { finishDiagnostic(); applySteering(); request(); return; }
        const auditStall = goalAuditStalled(session) || (config.request.toolsEnabled && taskAuditStalled(session));
        if (answerReplayed(session) || auditStall)
        {
            if (outputRecoveryCount(session) >= maxOutputRecoveries)
            { fail("Provider output repeatedly added no progress. Retry continues the preserved task and goal."); return; }
            internalNote(outputRecoveryMarker ~ (auditStall ? unfinishedTaskRecoveryInstruction : "The response added no new action or evidence. Continue the unfinished task with a different useful action."));
            beginDiagnostic();
            request(); return;
        }
        auto policy = config.turn; policy.toolsEnabled = config.request.toolsEnabled; policy.finishReason = event.finishReason;
        policy.diagnosticAvailable = config.diagnosticModel.length > 0;
        policy.pendingChildren = waitingChildren;
        const decision = decideTurn(session, policy);
        if (decision.diagnosticRequests > 0) beginDiagnostic();
        if (decision.action == TurnAction.applySteering) applySteering();
        if (decision.recordedSummary.length)
        { ChatMessage summary; summary.role = "assistant"; summary.content = decision.recordedSummary; append(summary); }
        if (decision.guidance.length) internalNote(decision.guidance);
        if (decision.clearBlocker) session.contract.blocker = "";
        if (decision.advanceGoal) ++session.goalTurns;
        if (decision.advanceHop) ++session.agentHops;
        if (decision.clearNextSpeaker) session.nextSpeakerId = "";
        if (decision.nextSpeaker.length) session.activeAgentId = decision.nextSpeaker;
        session.taskStatus = decision.taskStatus; session.turnStatus = decision.turnStatus;
        // The settle starts no further request, so an active goal must not stay
        // "active" with nothing running. The actor has no goal bar to refresh; it
        // records the same outcome the UI applies.
        if (decision.settleGoal == "completed")
        { session.goalStatus = "completed"; recordGoalOutcome(session, "completed", frameUnix); }
        else if (decision.settleGoal == "paused" && goalActive(session))
        { session.goalStatus = "paused"; recordGoalOutcome(session, "paused", frameUnix); }
        if (decision.action == TurnAction.reportChild) session.turnStatus = "completed";
        if (decision.continues()) { metadata(); request(); return; }
        running = false; engine.activeRequestId = 0;
        if (!viewed) session.unread = true;
        if (session.messages.length && session.messages[$ - 1].id == session.activeLeafId)
        { session.messages[$ - 1].taskStateJson = activeTaskStateJson(session); updateLast(); }
        publish(AgentEventKind.turnCompleted, "{}"); metadata();
        reportAssignment();
        if ((decision.action == TurnAction.settle || decision.action == TurnAction.waitInput) &&
            session.queuedFollowUps.length)
        {
            // A queued follow-up opens only now that the agent has stopped; it
            // never ends scheduled work early.
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
        if (diagnosticActive)
        {
            ensureAssistant(); session.messages[$ - 1].failed = true; session.messages[$ - 1].error = event.text; updateLast();
            finishDiagnostic(); applySteering(); request(); return;
        }
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
            if (outputRecoveryCount(session) > 0) beginDiagnostic();
            internalNote(outputRecoveryMarker ~ "The provider returned unusable output. Use the structured tool protocol and take a different useful action; do not repeat the rejected output.");
            request(); return;
        }
        if (outageStartedMs < 0) outageStartedMs = frameMs;
        const decision = engine.retryPolicy.resend(event.text, resendCount,
            (frameMs - outageStartedMs).msecs, false, event.retryExhausted);
        if (!decision.retry) { fail(event.text); return; }
        retryAtMs = frameMs + decision.delayMs; quotaWait = decision.reason == RetryReason.quotaLimit;
        fail(event.text, false);
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
            case OpenCodeEventKind.toolCallDelta:
                const now = MonoTime.currTime;
                if (preparingTools && now - preparingToolsAt < 50.msecs) break;
                preparingToolsAt = now;
                preparingTools = true; liveTools = null; omittedTools = 0;
                foreach (i, call; event.toolCalls)
                {
                    if (i >= 64) { ++omittedTools; continue; }
                    ConversationToolView view;
                    view.id = call.id.length ? call.id : "preparing-" ~ to!string(i);
                    view.name = call.name; view.arguments = checkpointSnippet(call.arguments, 2048);
                    view.output = "Preparing tool arguments; no tool has started.";
                    liveTools ~= view;
                }
                metadata();
                break;
            case OpenCodeEventKind.toolCalls: toolsRequested(event); break;
            case OpenCodeEventKind.toolResult: toolResult(event); break;
            case OpenCodeEventKind.done: completed(event); break;
            case OpenCodeEventKind.error: failed(event); break;
            case OpenCodeEventKind.models:
            case OpenCodeEventKind.modelsError: break;
        }
    }
    private void frame(ActorCommand command, OpenCodeEvent event, bool provider,
        JSONValue recorded = JSONValue.init, bool preserve = false, EventLane lane = EventLane.turn)
    {
        synchronized (mutex) reducing = true;
        scope (exit)
        {
            synchronized (mutex) { reducing = false; publishedBusy = running; publishedJobs = jobs.busy(); }
            notifyView();
        }
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
            auto baseline = runtimeThreadJson(session, true); baseline["planHistory"] = historyJson();
            journalMetadata.reset(baseline);
        }
        if (provider && lane != EventLane.turn)
        {
            const kind = lane == EventLane.title ? ModelJobKind.title : ModelJobKind.compaction;
            if (jobs.accept(kind, event, session, kind == ModelJobKind.title ? config.quickTitle : config.modelCompaction))
            { engine.invalidateProjection(); metadata(); }
            if (event.kind == OpenCodeEventKind.usage || event.kind == OpenCodeEventKind.done)
                emit(ActorChangeKind.usage, eventJson(event).toString());
        }
        else if (provider) applyEvent(event); else applyCommand(command);
        if (!coordinationRecovered)
        {
            coordinationRecovered = true;
            if (waitingChildren && !preserveInputs)
            {
                const state = parseJSON(session.orchestrationState);
                coordinate(CoordinationKind.dispatch, state["round"].str, session.orchestrationState);
            }
        }
        tryTitle();
        if (!provider && command.inputId.length && inputRecorded(session, command.inputId, false) && !inputRecorded(session, command.inputId))
        {
            JSONValue acknowledgement; acknowledgement["committedInput"] = command.inputId;
            publish(AgentEventKind.threadUpdated, acknowledgement.toString());
            markInputCommitted(session, command.inputId);
            emit(ActorChangeKind.inputCommitted, command.inputId);
        }
        if (replaying)
        { if (replayId != frameIds.length) throw new Exception("Replay did not consume its recorded message IDs"); return; }
        if (!config.recordTrace || traceTruncated) return;
        if (!facts.complete) { trace = null; traceTruncated = true; return; }
        JSONValue value;
        value["provider"] = provider; value["command"] = cast(int) command.kind; value["text"] = command.text;
        value["lane"] = cast(int) lane;
        value["target"] = command.targetId; value["activate"] = command.activate;
        value["images"] = command.imagesJson; value["context"] = command.context;
        value["inputId"] = command.inputId;
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
            jobs.close();
            if (engine !is null) engine.close();
            if (ownsWorkerSlot) workerBudget.release();
            synchronized (mutex) { closed = true; wake.notifyAll(); }
            notifyView();
        }
        try
        {
            engine = new ThreadEngine(config.baseUrl, config.apiKey, ProviderRetryPolicy(config.outageBudgetMs.msecs)); engine.threadId = session.id;
            clientBudgetMs = config.outageBudgetMs;
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
                foreach (kind; [ModelJobKind.title, ModelJobKind.compaction])
                {
                    const lane = kind == ModelJobKind.title ? EventLane.title : EventLane.compaction;
                    jobs.drain(kind, events);
                    foreach (event; events)
                    {
                        synchronized (mutex) if (stopPending || closing) break;
                        frame(ActorCommand.init, event, true, JSONValue.init, false, lane);
                    }
                    if (jobs.expired(kind, (MonoTime.currTime - clockOrigin).total!"msecs"))
                        frame(ActorCommand.init, jobs.timeout(kind), true, JSONValue.init, false, lane);
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
        ActorInputReceiver receiver;
        synchronized (mutex)
        {
            receiver = inputReceiver;
            if (input.command.inputId.length) seenInputs[input.command.inputId] = SeenInput(true, currentInputRetained);
        }
        if (input.command.inputId.length && receiver !is null)
        {
            // This owner has already received the durable journal ack. The
            // subscriber only records immutable admission state, never widgets.
            try receiver(ActorInputAcknowledgement(session.id, input.command.inputId, currentInputRetained));
            catch (Exception error) { emit(ActorChangeKind.notice, "Input acknowledgement could not be delivered: " ~ error.msg); }
        }
        synchronized (mutex) unsettledInputs.remove(input.serial);
        currentCommandSerial = 0;
        notifyView();
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
        { context.text = command.context ~ "\nUnparsed image input retained for recovery:\n" ~ command.imagesJson; context.inputId = command.inputId; }
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
            case ActorCommandKind.setTitle: session.title = command.text; session.titleManual = true; break;
            case ActorCommandKind.selectView:
                if (command.activate) session.unread = false;
                break;
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
            engine = null; images = null; encodedHistorySource = null; encodedPlanHistory = JSONValue.init;
            journalMetadata.clear(); viewMetadata.clear(); return result;
        }
    }
    ActorConfiguration finalConfiguration()
    {
        if (!isClosed()) throw new Exception("Close the actor before reading its configuration");
        auto result = config; result.request.availableTools = config.request.availableTools.dup; return result;
    }
    string recordedTrace()
    {
        if (!isClosed()) throw new Exception("Close the actor before reading its trace");
        if (!config.recordTrace) throw new Exception("Actor diagnostic recording was not enabled");
        if (traceTruncated) throw new Exception("Actor diagnostic trace is incomplete or exceeded its recording budget");
        JSONValue value;
        value["schema"] = 7; value["initial"] = initialIdentity;
        value["outageBudgetMs"] = initialBudgetMs;
        value["configuration"] = configurationIdentity; value["frames"] = JSONValue(trace);
        return value.toString();
    }

    public static string replay(const ref ChatSession initial, ActorConfiguration config, string recordedTrace)
    {
        const recording = parseJSON(recordedTrace);
        if (config.outageBudgetMs < 0) config.outageBudgetMs = recording["outageBudgetMs"].integer;
        if (recording["schema"].integer != 7 ||
            recording["initial"].str != sha256Of(sessionToJson(initial).toString()).toHexString() ||
            recording["configuration"].str != configurationKey(config))
            throw new Exception("Actor replay initial state or behavioral configuration does not match the recording");
        auto owner = new ConversationActor(initial, config, null, null, false);
        scope (exit) { owner.jobs.close(); owner.engine.close(); }
        owner.running = false; owner.nextRequest = 0; owner.replaying = true;
        foreach (entry; recording["frames"].array)
        {
            ActorCommand command; command.kind = cast(ActorCommandKind) entry["command"].integer; command.text = entry["text"].str;
            command.targetId = entry["target"].str; command.activate = entry["activate"].boolean;
            command.imagesJson = entry["images"].str; command.context = entry["context"].str;
            command.inputId = entry["inputId"].str;
            owner.frame(command, eventFromJson(entry["event"]), entry["provider"].boolean, entry, false, cast(EventLane) entry["lane"].integer);
        }
        return sessionToJson(owner.session).toString();
    }
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
