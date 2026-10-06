module auroraopencode.execution;

import auroraopencode.core : OpenCodeToolCall, ChatImageAttachment;
import auroraopencode.opencode_client : OpenCodeClient, OpenCodeEvent, OpenCodeEventKind;
import auroraopencode.tools : ToolCancellation;
import core.time : MonoTime;

public enum RequestPhase { idle, waiting, streaming, executingTools, stopped, failed, completed }

/// A conversation is the sole owner of its mutable execution state. No fields
/// are copied through a shared root when another conversation is serviced.
public class ThreadEngine
{
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
    OpenCodeEvent[] eventScratch;
    ulong activeRequestId;
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
    int lastColdStartSeconds = -1;
    MonoTime turnStartedAt;
    string turnUserId;
    int turnSessionIndex = -1;
    bool turnTiming;
    bool turnCancelled;
    bool stopPending;
    MonoTime stopRequestedAt;
    bool turnInFlight;

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

    RequestPhase phase;
    ulong transitionRevision;
    ulong partialCheckpointBytes;
    MonoTime partialCheckpointAt;

    this(string baseUrl, string apiKey)
    {
        client = new OpenCodeClient(baseUrl, apiKey);
        cancellation = new ToolCancellation();
    }

    void acceptRequest(ulong requestId)
    {
        activeRequestId = requestId;
        phase = RequestPhase.waiting;
        ++transitionRevision;
    }

    void observe(const ref OpenCodeEvent event)
    {
        if (event.requestId && event.requestId != activeRequestId) return;
        switch (event.kind)
        {
            case OpenCodeEventKind.chatBegin:
            case OpenCodeEventKind.delta: phase = RequestPhase.streaming; break;
            case OpenCodeEventKind.toolCalls: phase = RequestPhase.executingTools; break;
            case OpenCodeEventKind.done: phase = event.cancelled ? RequestPhase.stopped : RequestPhase.completed; break;
            case OpenCodeEventKind.error: phase = RequestPhase.failed; break;
            default: return;
        }
        ++transitionRevision;
    }

    bool busy()
    {
        return stopPending || turnInFlight || turnTiming || client.busy() ||
            compactionClient !is null || pendingToolCalls.length > 0 || pendingToolResults > 0;
    }
}
