module auroraopencode.turnpolicy;

import auroraopencode.core : ChatSession;
import auroraopencode.taskcontinuation : taskContinuation, TaskContinuationAction,
    taskAwaitingInput, proactiveActionGuidance;
import auroraopencode.taskflow : taskInvestigation;
import auroraopencode.worktracking : requiredWorkRemaining;
import auroraopencode.goalmode : goalActive, goalNeedsHumanInput, goalContinuationInstruction;
import auroraopencode.completionhandoff : completionHandoffNeeded, completionHandoffPending,
    completionHandoffMarker, completionHandoffInstruction, recordedCompletionHandoff;
import auroraopencode.orchestrator : experimentalOrchestratorIsRouter, experimentalOrchestratorAgentName;

enum TurnAction { settle, interrupted, applySteering, request, waitInput, waitChildren, reportChild }

struct TurnPolicy
{
    bool cancelled, toolsEnabled, orchestratorEnabled, pendingChildren, diagnosticAvailable;
    bool strictPlan;
    int speakerToolRoundsBase = -1;
    int toolRounds;
    string finishReason;
}

/// A value decision: no I/O, clocks, widgets, callbacks or mutable runtime.
/// The execution owner applies the recorded transition and dispatches effects.
struct TurnDecision
{
    TurnAction action;
    string turnStatus, taskStatus, guidance, recordedSummary, status, nextSpeaker;
    bool advanceHop, clearNextSpeaker, clearDiagnostic, clearBlocker, advanceGoal;
    int diagnosticRequests;

    bool continues() const
    {
        return action == TurnAction.request || action == TurnAction.applySteering ||
            action == TurnAction.waitChildren;
    }
}

bool hasIncompleteTaskSteps(const ref ChatSession session)
{
    foreach (step; session.taskSteps) if (step.status != "completed") return true;
    foreach (plan; session.nestedPlans)
        foreach (step; plan.steps) if (step.status != "completed") return true;
    return requiredWorkRemaining(session);
}

TurnDecision decideTurn(const ref ChatSession session, const TurnPolicy policy)
{
    TurnDecision result;
    result.turnStatus = session.turnStatus;
    result.taskStatus = session.taskStatus;
    if (policy.cancelled)
    {
        result.action = TurnAction.interrupted;
        result.turnStatus = "interrupted";
        if (!result.taskStatus.length) result.taskStatus = "active";
        return result;
    }
    if (session.queuedGuidance.length)
    {
        result.action = TurnAction.applySteering;
        result.turnStatus = "running";
        result.taskStatus = "active";
        result.status = "Applying queued guidance…";
        return result;
    }
    if (goalNeedsHumanInput(session))
    {
        result.action = TurnAction.waitInput;
        result.turnStatus = "completed";
        result.taskStatus = "waiting_input";
        result.status = "Waiting for required information. Reply to continue.";
        return result;
    }
    const continuation = taskContinuation(session, policy.toolsEnabled, policy.strictPlan);
    const settled = continuation.action == TaskContinuationAction.settle;
    const proactive = policy.toolsEnabled ? proactiveActionGuidance(session) : "";
    void request(string guidance, string status, bool active = true)
    {
        result.action = TurnAction.request;
        result.turnStatus = "running";
        if (active) result.taskStatus = "active";
        result.guidance = guidance;
        result.status = status;
    }
    if (settled && proactive.length)
    {
        request(proactive, "Choosing a reasonable default and continuing…");
        return result;
    }
    if (!goalActive(session) && settled && completionHandoffNeeded(session, policy.finishReason))
    {
        if (completionHandoffPending(session)) result.recordedSummary = recordedCompletionHandoff(session);
        else
        {
            request(completionHandoffMarker ~ completionHandoffInstruction, "Summarizing completed work…", false);
            return result;
        }
    }
    if (policy.orchestratorEnabled && session.agents.length &&
        !(session.parentSessionId.length && !settled))
    {
        if (session.parentSessionId.length && settled)
        {
            result.action = TurnAction.reportChild;
            return result;
        }
        if (policy.pendingChildren)
        {
            result.action = TurnAction.waitChildren;
            return result;
        }
        const speaker = session.activeAgentId;
        const router = experimentalOrchestratorIsRouter(session, speaker);
        string next = session.nextSpeakerId;
        if (!next.length && !router) next = "orchestrator";
        const didWork = policy.speakerToolRoundsBase >= 0 && policy.toolRounds > policy.speakerToolRoundsBase;
        if (next == "orchestrator" && !router && !didWork) next = "";
        result.advanceHop = true;
        if (session.agentHops >= 8) next = "";
        if (next.length)
        {
            string review;
            if (next == "orchestrator" && speaker.length && speaker != "orchestrator")
                review = "Multi-agent update: participant \"" ~ experimentalOrchestratorAgentName(session, speaker) ~
                    "\" finished its turn. Review the work in this conversation against the user's goal, " ~
                    "then either assign the next task or call finish.";
            request(review, "Continuing with " ~ next ~ "…");
            result.nextSpeaker = next;
            result.clearNextSpeaker = true;
            return result;
        }
        result.clearNextSpeaker = router;
    }
    result.clearDiagnostic = true;
    result.clearBlocker = session.taskStatus == "waiting_input" && !taskAwaitingInput(session);
    if (result.clearBlocker) result.taskStatus = "active";
    if (!settled)
    {
        const replan = continuation.action == TaskContinuationAction.replan;
        request(continuation.guidance(), replan ? "Changing diagnosis for the unfinished outcome…" : "Continuing unfinished work…");
        if (replan && policy.diagnosticAvailable) result.diagnosticRequests = 4;
        return result;
    }
    if (goalActive(session) && !session.queuedFollowUps.length)
    {
        result.advanceGoal = true;
        request(goalContinuationInstruction(session), "Continuing toward the goal…");
        return result;
    }
    result.turnStatus = "completed";
    if (result.taskStatus == "waiting_input")
        result.status = "Independent work complete · awaiting required information.";
    else if (taskInvestigation(session))
        result.taskStatus = session.verificationStatus == "required" || session.verificationStatus == "failed" ? "verifying" : "active";
    else if (hasIncompleteTaskSteps(session))
    {
        result.taskStatus = "active";
        result.status = "Answer complete · task still has checklist items.";
    }
    else if (session.verificationStatus == "required" || session.verificationStatus == "failed")
    {
        result.taskStatus = "verifying";
        result.status = "Answer complete · verification is still required.";
    }
    else result.taskStatus = "completed";
    return result;
}
