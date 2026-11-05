module auroraopencode.turnpolicy;

import auroraopencode.core : ChatSession;
import auroraopencode.taskcontinuation : taskContinuation, TaskContinuationAction,
    taskAwaitingInput;
import auroraopencode.taskflow : taskInvestigation;
import auroraopencode.worktracking : requiredWorkRemaining;
import auroraopencode.goalmode : goalActive, goalNeedsHumanInput, goalContinuationInstruction,
    goalIsAnswerTurn;
import auroraopencode.completionhandoff : completionHandoffNeeded, completionHandoffPending,
    recordedCompletionHandoff;
import auroraopencode.orchestrator : experimentalOrchestratorIsRouter, experimentalOrchestratorAgentName;
import auroraopencode.contextpolicy : latestActualUserRequest;
import auroraopencode.requestintent : answerOnlyRequest;

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
    void request(string guidance, string status, bool active = true)
    {
        result.action = TurnAction.request;
        result.turnStatus = "running";
        if (active) result.taskStatus = "active";
        result.guidance = guidance;
        result.status = status;
    }
    // A handoff saved by an older build is completed from recorded evidence;
    // new summary rounds and permission-repair rounds are never started. Work
    // continues only by following the remaining plan steps.
    if (!goalActive(session) && settled && completionHandoffPending(session) &&
        completionHandoffNeeded(session, policy.finishReason))
        result.recordedSummary = recordedCompletionHandoff(session);
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
        request(continuation.guidance(), replan ? "Revising the plan for the blocked step…" : "Following the plan…");
        if (replan && policy.diagnosticAvailable) result.diagnosticRequests = 4;
        return result;
    }
    // A goal that needs tools cannot progress through a request that offers
    // none, and an answer/analysis goal is finished by its reply. Both settle
    // instead of auto-continuing into a loop the model cannot break.
    if (goalActive(session) && policy.toolsEnabled &&
        !goalIsAnswerTurn(session.goal) &&
        !session.queuedFollowUps.length &&
        !answerOnlyRequest(latestActualUserRequest(session)) && !taskInvestigation(session))
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
    else if (session.contract.currentIntent == "analysis" && session.contract.intent == "analysis")
        // Reproducing a defect is a successful diagnostic outcome. Keep the
        // failed receipt, but do not turn an analysis into an authorized repair.
        result.taskStatus = "completed";
    else if (session.verificationStatus == "required" || session.verificationStatus == "failed")
    {
        result.taskStatus = "verifying";
        result.status = "Answer complete · verification is still required.";
    }
    else result.taskStatus = "completed";
    return result;
}
