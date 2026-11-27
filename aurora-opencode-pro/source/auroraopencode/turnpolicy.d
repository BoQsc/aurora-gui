module auroraopencode.turnpolicy;

import auroraopencode.core : ChatSession, activeMessagePath;
import auroraopencode.executioncontrol : executionState, executionShouldContinue;
import auroraopencode.taskflow : taskInvestigation;
import auroraopencode.worktracking : requiredWorkRemaining;
import auroraopencode.goalmode : goalActive, goalNeedsHumanInput, goalContinuationInstruction,
    goalInputContinuesInstruction, goalIsAnswerTurn, goalAnswerDelivered, goalOutstandingWork;
import auroraopencode.completionhandoff : completionHandoffNeeded, completionHandoffPending,
    recordedCompletionHandoff;
import auroraopencode.orchestrator : experimentalOrchestratorIsRouter, experimentalOrchestratorAgentName;
import auroraopencode.contextpolicy : latestActualUserRequest;
import auroraopencode.requestintent : RequestIntent, actionApprovalRequest, requestIntent, workRestrictionRequest;
import auroraopencode.planmode : planModeProposalPending;
import auroraopencode.outputrecovery : goalAuditStalled, goalAuditRecoveryCount;
import auroraopencode.agentloop : recoverAgent;
import std.string : strip;

enum TurnAction { settle, failed, interrupted, applySteering, request, waitInput, waitChildren, reportChild }

struct TurnPolicy
{
    bool cancelled, toolsEnabled, orchestratorEnabled, pendingChildren, diagnosticAvailable;
    bool strictPlan;
    int speakerToolRoundsBase = -1;
    int toolRounds;
    string finishReason;
}

/// One settlement decision for desktop and actors. Failed attempts change the
/// next operation, never ownership of unfinished work.
struct TurnDecision
{
    TurnAction action;
    string turnStatus, taskStatus, guidance, recordedSummary, status, nextSpeaker;
    string settleGoal;
    bool advanceHop, clearNextSpeaker, clearDiagnostic, clearBlocker, advanceGoal;
    int diagnosticRequests;
    int recoveryDelayMs;

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
    void request(string guidance, string status, int delayMs = 0)
    {
        result.action = TurnAction.request;
        result.turnStatus = "running";
        result.taskStatus = "active";
        result.guidance = guidance;
        result.status = status;
        result.recoveryDelayMs = delayMs;
    }
    if (policy.cancelled)
    {
        result.action = TurnAction.interrupted;
        result.turnStatus = "interrupted";
        if (!result.taskStatus.length) result.taskStatus = "active";
        return result;
    }
    if (session.queuedGuidance.length)
    {
        request("", "Applying queued guidance…");
        result.action = TurnAction.applySteering;
        return result;
    }
    // These boundaries belong to the user, not to an internal attempt counter.
    if (planModeProposalPending(session))
    {
        result.action = TurnAction.waitInput;
        result.turnStatus = "completed";
        result.taskStatus = "waiting_input";
        result.status = "Plan proposed · approve or adjust it to continue.";
        return result;
    }
    const humanRequest = latestActualUserRequest(session);
    const ownsGoal = goalActive(session) && policy.toolsEnabled &&
        !goalIsAnswerTurn(session.goal) && !workRestrictionRequest(humanRequest);
    if (goalNeedsHumanInput(session) && !ownsGoal)
    {
        result.action = TurnAction.waitInput;
        result.turnStatus = "completed";
        result.taskStatus = "waiting_input";
        result.status = "Independent work complete · awaiting required information.";
        return result;
    }
    const execution = executionState(session, policy.strictPlan);
    const unfinished = executionShouldContinue(session, policy.toolsEnabled, execution);
    if (policy.orchestratorEnabled && session.agents.length &&
        !(session.parentSessionId.length && unfinished))
    {
        if (session.parentSessionId.length)
        { result.action = TurnAction.reportChild; return result; }
        if (policy.pendingChildren)
        { result.action = TurnAction.waitChildren; return result; }
        const speaker = session.activeAgentId;
        const router = experimentalOrchestratorIsRouter(session, speaker);
        string next = session.nextSpeakerId;
        if (!next.length && !router) next = "orchestrator";
        const didWork = policy.speakerToolRoundsBase >= 0 && policy.toolRounds > policy.speakerToolRoundsBase;
        if (next == "orchestrator" && !router && !didWork) next = "";
        result.advanceHop = true;
        if (next.length)
        {
            request(next == "orchestrator" && speaker.length && speaker != "orchestrator"
                ? "Multi-agent update: participant " ~ experimentalOrchestratorAgentName(session, speaker) ~
                    " finished. Assess its actual results against the requested outcome and continue unfinished work."
                : "", "Continuing with " ~ next ~ "…");
            result.nextSpeaker = next; result.clearNextSpeaker = true;
            return result;
        }
        result.clearNextSpeaker = router;
    }
    result.clearDiagnostic = true;
    if (unfinished)
    {
        const intent = requestIntent(humanRequest);
        const authorized = intent == RequestIntent.implementation || intent == RequestIntent.continuation ||
            intent == RequestIntent.diagnosis || intent == RequestIntent.changeRequest || actionApprovalRequest(humanRequest);
        if (session.goal.length && session.goalStatus != "active" &&
            !session.queuedFollowUps.length && !authorized)
        {
            result.turnStatus = "completed";
            result.status = "Answer complete · goal remains paused.";
            return result;
        }
        const recovery = recoverAgent(session, "unfinished_outcome", execution.attempts);
        request(execution.guidance() ~ "\n" ~ recovery.guidance,
            execution.attempts ? "Recovering the unresolved outcome…" : "Completing the requested outcome…",
            recovery.delayMs);
        result.advanceGoal = ownsGoal;
        if (execution.attempts == 1 && policy.diagnosticAvailable) result.diagnosticRequests = 1;
        return result;
    }
    if (ownsGoal)
    {
        result.advanceGoal = true;
        if (goalNeedsHumanInput(session))
        {
            result.clearBlocker = true;
            request(goalInputContinuesInstruction, "Continuing independent goal work…");
        }
        else if (goalAuditStalled(session))
        {
            const recovery = recoverAgent(session, "goal_without_action", goalAuditRecoveryCount(session));
            request(recovery.guidance, "Recovering the goal…", recovery.delayMs);
        }
        else request(goalContinuationInstruction(session), "Continuing toward the goal…");
        return result;
    }
    if (!goalActive(session) && completionHandoffPending(session) &&
        completionHandoffNeeded(session, policy.finishReason))
        result.recordedSummary = recordedCompletionHandoff(session);
    else
    {
        bool delivered;
        foreach_reverse (index; activeMessagePath(session))
        {
            const ref message = session.messages[index];
            if (message.internal) continue;
            // Only this terminal reply counts. An earlier progress message
            // cannot conceal a later empty answer after tools have run.
            if (message.role == "assistant")
                delivered = !message.failed && !message.toolCalls.length && message.content.strip.length > 0;
            break;
        }
        if (!delivered)
        {
            const recovery = recoverAgent(session, "empty_answer");
            request(recovery.guidance, "Recovering an empty response…", recovery.delayMs);
            return result;
        }
    }
    result.turnStatus = "completed";
    result.clearBlocker = session.taskStatus == "waiting_input";
    if (session.contract.currentIntent == "analysis" && session.contract.intent == "analysis")
        result.taskStatus = "completed";
    else if (session.verificationStatus == "required" || session.verificationStatus == "failed")
        result.taskStatus = "verifying";
    else if (taskInvestigation(session) || requiredWorkRemaining(session) ||
        (policy.strictPlan && hasIncompleteTaskSteps(session))) result.taskStatus = "active";
    else result.taskStatus = "completed";
    if (goalActive(session) && !session.queuedFollowUps.length && goalIsAnswerTurn(session.goal) &&
        !goalOutstandingWork(session) && goalAnswerDelivered(session)) result.settleGoal = "completed";
    return result;
}
