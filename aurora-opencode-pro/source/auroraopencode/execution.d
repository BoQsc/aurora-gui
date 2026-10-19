module auroraopencode.execution;

import auroraopencode.core : OpenCodeToolCall, ChatImageAttachment;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.tools : ToolCancellation;
import auroraopencode.repository : RepositoryRuntime;
import core.time : MonoTime, msecs;
import core.sync.mutex : Mutex;
import auroraopencode.lifecyclediagnostics : logAgentLifecycle, lifecycleErrorCategory;
import std.json : JSONValue;

public import auroraopencode.executionstate : RequestPhase;
import auroraopencode.executionstate : ExecutionState, ExecutionCommand,
    ExecutionCommandKind, reduceExecution;

private final class EffectAdmission
{
    Mutex mutex;
    ToolCancellation cancellation;
    MonoTime queued;
    bool pending = true;
    this(ToolCancellation cancellation)
    { mutex = new Mutex(); this.cancellation = cancellation; queued = MonoTime.currTime; }
    bool start()
    {
        synchronized (mutex)
        {
            if (!pending || cancellation.cancelled()) { pending = false; return false; }
            pending = false;
            return true;
        }
    }
    bool expire(long timeoutMs)
    {
        synchronized (mutex)
        {
            if (!pending || cancellation.cancelled() || MonoTime.currTime - queued < timeoutMs.msecs) return false;
            pending = false;
            return true;
        }
    }
}

/// A conversation is the sole owner of its mutable execution state. No fields
/// are copied through a shared root when another conversation is serviced.
public class ThreadEngine
{
    string threadId;
    int diagnosticRequestsRemaining;
    bool diagnosticActive;
    OpenCodeClient client;
    // experimental: orchestrator - one extra client per participant, so each
    // agent talks to the gateway on its own connection/route exactly like a
    // separate conversation does. Created lazily; empty when the feature is off.
    OpenCodeClient[string] agentClients;
    OpenCodeClient compactionClient;
    OpenCodeEvent[] compactionEvents;
    string compactionOutput;
    string compactionAnchor;
    string compactionLeaf;
    OpenCodeClient titleClient;
    OpenCodeEvent[] titleEvents;
    string titleOutput;
    string titleSessionId;
    bool titlePending;
    int titleAttempts;
    ToolCancellation cancellation;
    private ToolCancellation _effectCancellation;
    private ulong _effectRequestId;
    private EffectAdmission _queuedEffect;
    OpenCodeEvent[] eventScratch;
    private ExecutionState _protocol;
    ref inout(ulong) activeRequestId() inout @property { return _protocol.requestId; }
    int activeRequestSession = -1;
    bool batchingToolResults;
    bool toolTranscriptDirty;
    OpenCodeToolCall[] pendingToolCalls;
    int pendingToolResults;
    ChatImageAttachment[] pendingToolImages;
    bool[string] reportedToolCallIds;
    OpenCodeToolCall[] liveToolCalls;
    OpenCodeToolCall[] preparingToolCalls;
    MonoTime[string] liveToolStartedAt;
    string[string] liveToolOutputs;
    MonoTime lastStreamOutputAt;
    int lastStreamSilenceSeconds = -1;
    int toolRounds;
    bool finalAnswerRequested;
    bool toolContinuationPaused;
    string lastToolSignature;
    int lastToolRepeatCount;
    string lastFailureSignature;
    int lastFailureRepeatCount;
    string pendingProgressGuidance;
    long liveOutputBytes;
    long liveOutputTokens;
    int liveTokenRateTenths;
    long tokenRateBaseTokens;
    MonoTime tokenRateStartedAt;
    bool tokenRateStarted;
    MonoTime rateWindowStartedAt;
    long rateWindowBaseTokens;
    int turnTokenRateTenths;
    int liveTotalTokens;
    bool suppressDoneStatus;
    MonoTime chatStartedAt;
    bool receivedFirstDelta;
    bool contextOverflowRetryUsed;
    bool forceCompactNextRequest;
    int autoContinuePendingSession = -1;
    MonoTime autoContinueRetryAt;
    int autoContinueRetries;
    int autoContinueStreak;
    int lastColdStartSeconds = -1;
    MonoTime turnStartedAt;
    string turnUserId;
    int turnSessionIndex = -1;
    bool turnTiming;
    bool turnCancelled;
    bool stopPending;
    MonoTime stopRequestedAt;
    bool turnInFlight;
    bool toolContinuationPending;
    MonoTime missingWorkSince;

    MonoTime preparingSince;
    long preparingLastBytes;
    int lastPreparingSeconds = -1;
    int lastRetryStatusSeconds = -1;
    int speakerToolRoundsBase = -1;
    bool autoResendPending;
    MonoTime autoResendAt;
    int autoResendSession = -1;
    int autoResendMessage = -1;
    long autoResendResetMs;
    int autoResendCount;
    bool autoResending;
    int lastAutoResendSeconds = -1;

    RequestPhase phase() const @property { return _protocol.phase; }
    ulong transitionRevision() const @property { return _protocol.revision; }
    bool verificationRecorded;
    ulong verifiedWorkspaceRevision;
    string verifiedWorkspace;
    ulong partialCheckpointBytes;
    MonoTime partialCheckpointAt;

    this(string baseUrl, string apiKey)
    {
        client = new OpenCodeClient(baseUrl, apiKey);
        cancellation = new ToolCancellation();
    }

    void acceptRequest(ulong requestId)
    {
        logAgentLifecycle(threadId, requestId, "request.accepted");
        _protocol = reduceExecution(_protocol,
            ExecutionCommand(ExecutionCommandKind.accept, requestId)).state;
    }

    void observe(const ref OpenCodeEvent event)
    {
        if (event.kind == OpenCodeEventKind.chatBegin ||
            event.kind == OpenCodeEventKind.toolCalls ||
            event.kind == OpenCodeEventKind.done || event.kind == OpenCodeEventKind.error)
        {
            JSONValue details;
            details["cancelled"] = event.cancelled;
            details["finishReason"] = event.finishReason;
            details["promptTokens"] = event.promptTokens;
            details["completionTokens"] = event.completionTokens;
            if (event.kind == OpenCodeEventKind.error)
            {
                details["errorCategory"] = lifecycleErrorCategory(event.text);
                details["outputIssue"] = event.outputIssue;
            }
            const stage = event.kind == OpenCodeEventKind.chatBegin ? "request.stream_started"
                : event.kind == OpenCodeEventKind.toolCalls ? "request.tools_requested"
                : event.kind == OpenCodeEventKind.done ? "request.done" : "request.failed";
            logAgentLifecycle(threadId, event.requestId, stage, details);
        }
        ExecutionCommand command;
        command.requestId = event.requestId;
        command.cancelled = event.cancelled;
        switch (event.kind)
        {
            case OpenCodeEventKind.chatBegin:
            case OpenCodeEventKind.delta: command.kind = ExecutionCommandKind.delta; break;
            case OpenCodeEventKind.toolCalls: command.kind = ExecutionCommandKind.toolsRequested; break;
            case OpenCodeEventKind.done: command.kind = ExecutionCommandKind.complete; break;
            case OpenCodeEventKind.error: command.kind = ExecutionCommandKind.fail; break;
            default: return;
        }
        _protocol = reduceExecution(_protocol, command).state;
    }

    void stop()
    {
        toolContinuationPending = false;
        if (turnInFlight || pendingToolResults > 0 || _queuedEffect !is null)
            logAgentLifecycle(threadId, activeRequestId, "execution.cancelled");
        _protocol = reduceExecution(_protocol, ExecutionCommand(ExecutionCommandKind.stop)).state;
        turnCancelled = true;
        cancellation.cancel();
        if (_effectCancellation !is null) _effectCancellation.cancel();
    }

    /// Effects own detached inputs. The repository acknowledges all earlier
    /// intents before launching them; a local Stop revokes queued admissions
    /// immediately, including effects that have not reached a worker yet.
    bool dispatchAfterCommit(RepositoryRuntime journal, ulong requestId,
        void delegate() effect)
    {
        if (_effectCancellation is null || _effectRequestId != requestId)
        {
            _effectCancellation = new ToolCancellation();
            _effectRequestId = requestId;
        }
        auto admission = _effectCancellation;
        auto queued = new EffectAdmission(admission);
        _queuedEffect = queued;
        auto receiver = client;
        logAgentLifecycle(threadId, requestId, "effect.waiting_for_commit");
        void fail(string error)
        {
            if (admission.cancelled()) return;
            logAgentLifecycle(threadId, requestId, "effect.commit_failed");
            OpenCodeEvent event;
            event.kind = OpenCodeEventKind.error;
            event.requestId = requestId;
            event.text = "Request was not started: " ~ error;
            receiver.pushLocalEvent(event);
        }
        return journal.afterCommitted(delegate() {
            if (queued.start())
            {
                JSONValue details;
                details["queuedMs"] = (MonoTime.currTime - queued.queued).total!"msecs";
                logAgentLifecycle(threadId, requestId, "effect.started", details);
                effect();
            }
            else logAgentLifecycle(threadId, requestId, "effect.revoked");
        }, &fail);
    }

    /// A tool batch must not look like a running scan while its durable
    /// admission never reaches the scheduler. Revocation fences late callbacks.
    bool expireQueuedEffect(long timeoutMs = 30_000)
    {
        const expired = _queuedEffect !is null && _queuedEffect.expire(timeoutMs);
        if (expired) logAgentLifecycle(threadId, activeRequestId, "effect.commit_deadline");
        return expired;
    }

    bool effectPending()
    {
        if (_queuedEffect is null) return false;
        synchronized (_queuedEffect.mutex)
            return _queuedEffect.pending && !_queuedEffect.cancellation.cancelled();
    }

    struct ResultAdmission { bool accepted; string arguments; }
    ResultAdmission admitToolResult(string id)
    {
        if (!id.length || id in reportedToolCallIds) return ResultAdmission.init;
        foreach (call; pendingToolCalls)
            if (call.id == id)
            {
                reportedToolCallIds[id] = true;
                return ResultAdmission(true, call.arguments);
            }
        return ResultAdmission.init;
    }

    void remapSessionInsertion(int index)
    {
        foreach (slot; [&activeRequestSession, &turnSessionIndex,
            &autoResendSession, &autoContinuePendingSession])
            if (*slot >= index) ++*slot;
    }

    void remapSessionRemoval(int index)
    {
        foreach (slot; [&activeRequestSession, &turnSessionIndex,
            &autoResendSession, &autoContinuePendingSession])
            if (*slot == index) *slot = -1;
            else if (*slot > index) --*slot;
    }

    void close()
    {
        logAgentLifecycle(threadId, activeRequestId, "execution.closed");
        stop();
        client.closeSession();
        foreach (agent; agentClients) agent.closeSession();
        if (compactionClient !is null) compactionClient.closeSession();
        if (titleClient !is null) titleClient.closeSession();
    }

    bool busy()
    {
        return stopPending || turnInFlight || turnTiming || toolContinuationPending || client.busy() ||
            compactionClient !is null || pendingToolCalls.length > 0 || pendingToolResults > 0;
    }
}
