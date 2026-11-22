module auroraopencode.turnpolicy;

import auroraopencode.core : ChatSession, ChatMessage, activeMessagePath;
import auroraopencode.taskcontinuation : taskAwaitingInput;
import auroraopencode.executioncontrol : executionState, executionShouldContinue;
import auroraopencode.taskflow : taskInvestigation;
import auroraopencode.worktracking : requiredWorkRemaining;
import auroraopencode.goalmode : goalActive, goalNeedsHumanInput, goalContinuationInstruction,
    goalAuditRecoveryInstruction, goalInputContinuesInstruction, goalIsAnswerTurn,
    goalAnswerDelivered;
import auroraopencode.completionhandoff : completionHandoffNeeded, completionHandoffPending,
    recordedCompletionHandoff;
import auroraopencode.orchestrator : experimentalOrchestratorIsRouter, experimentalOrchestratorAgentName;
import auroraopencode.contextpolicy : latestActualUserRequest;
import auroraopencode.requestintent : RequestIntent, actionApprovalRequest,
    requestIntent, workRestrictionRequest;
import auroraopencode.planmode : planModeProposalPending;
import auroraopencode.outputguard : outputRecoveryMarker;
import auroraopencode.outputrecovery : goalAuditStalled, goalAuditRecoveryCount,
    maxGoalAuditRecoveries;
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

/// A value decision: no I/O, clocks, widgets, callbacks or mutable runtime.
/// The execution owner applies the recorded transition and dispatches effects.
struct TurnDecision
{
    TurnAction action;
    string turnStatus, taskStatus, guidance, recordedSummary, status, nextSpeaker;
    /// Outcome an active goal takes when this settle starts no further turn:
    /// "completed" for an answer goal whose reply is delivered, "paused" when a
    /// goal spent its whole recovery budget without a useful action. Routine
    /// settles never pause the goal: the user's pause stays the normal control.
    string settleGoal;
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
    // An active action goal never stops for a question. The reported "Aurora
    // Designer Check" chat ended as waiting_input while its goal still owned
    // unfinished work: the agent asked which host backend to use and the app
    // left the goal active with no running turn. The goal continues until the
    // requested outcome is complete or the user pauses it, so the recorded
    // input request is carried into the next goal turn instead of settling.
    const goalKeepsRunning = goalActive(session) && policy.toolsEnabled &&
        !goalIsAnswerTurn(session.goal) &&
        !workRestrictionRequest(latestActualUserRequest(session));
    if (goalNeedsHumanInput(session) && !goalKeepsRunning)
    {
        result.action = TurnAction.waitInput;
        result.turnStatus = "completed";
        result.taskStatus = "waiting_input";
        result.status = "Waiting for required information. Reply to continue.";
        return result;
    }
    const execution = executionState(session, policy.strictPlan);
    const settled = !executionShouldContinue(session, policy.toolsEnabled, execution);
    void request(string guidance, string status, bool active = true)
    {
        result.action = TurnAction.request;
        result.turnStatus = "running";
        if (active) result.taskStatus = "active";
        result.guidance = guidance;
        result.status = status;
    }
    // experimental: planmode - the gate already refused the mutation and the
    // agent stopped to present the plan. Wait for the user's approval instead
    // of starting execution recovery for what the gate intentionally blocked.
    if (settled && planModeProposalPending(session))
    {
        result.turnStatus = "completed";
        result.taskStatus = "waiting_input";
        result.status = "Plan proposed · approve or adjust it to continue.";
        result.clearDiagnostic = true;
        return result;
    }
    // A handoff saved by an older build is completed from recorded evidence;
    // new summary rounds and permission-repair rounds are never started. Work
    // continues only by following the remaining plan steps.
    if (!goalActive(session) && settled && completionHandoffPending(session) &&
        completionHandoffNeeded(session, policy.finishReason))
        result.recordedSummary = recordedCompletionHandoff(session);
    // A settled turn whose request carried no tools and whose reply is empty
    // ends with nothing to show. Re-ask with the tools it was missing instead
    // of reporting a completed turn that produced no result.
    else if (settled && !policy.toolsEnabled)
    {
        string reply;
        foreach (index; activeMessagePath(session))
        {
            const ref message = session.messages[index];
            if (message.role == "assistant" && !message.internal && !message.failed &&
                !message.toolCalls.length) reply = message.content;
        }
        if (!reply.strip.length)
        {
            result.action = TurnAction.request;
            result.turnStatus = "running";
            result.taskStatus = "active";
            result.guidance = "The previous request offered no tools and produced an empty reply. " ~
                "Use the available tools to deliver the result now, then state the outcome.";
            result.status = "Retrying with tools…";
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
        const state = execution;
        // A paused or completed persistent goal no longer owns automatic work.
        // Its leftover checklist and verification must not restart a turn after
        // an answer-only request: the user asked "why are you refusing", the
        // reply was delivered, and the app then injected "Execution recovery:
        // the requested work has an unresolved outcome" for work the user had
        // just paused. That read as the agent refusing to do anything at all,
        // and it repeated until output recovery failed the turn. Only a new
        // action request ("ensure it by developing") or a cause question that
        // authorizes the repair keeps the work going.
        const humanRequest = latestActualUserRequest(session);
        const actionRequest = requestIntent(humanRequest) == RequestIntent.implementation ||
            requestIntent(humanRequest) == RequestIntent.continuation ||
            requestIntent(humanRequest) == RequestIntent.diagnosis ||
            requestIntent(humanRequest) == RequestIntent.changeRequest ||
            actionApprovalRequest(humanRequest);
        if (session.goal.length && session.goalStatus != "active" &&
            !session.queuedFollowUps.length && !actionRequest)
        {
            result.turnStatus = "completed";
            result.taskStatus = state.verificationRequired ? "verifying" : "active";
            result.status = "Answer complete · the paused goal's remaining work waits for Start.";
            return result;
        }
        if (state.attempts >= 2)
        {
            // A host fault is not a substantive failure. The answer already
            // delivered stays intact and the recorded work stays active; the
            // turn ends as interrupted by the environment, not failed.
            if (state.transientFailure)
            {
                result.action = TurnAction.interrupted;
                result.turnStatus = "interrupted";
                result.taskStatus = state.verificationRequired ? "verifying" : "active";
                result.status = "Tool host unavailable; the delivered answer and remaining work are preserved. Retry when the host responds.";
                result.clearDiagnostic = true;
                return result;
            }
            // The recovery budget is an internal control boundary, not a
            // user-facing failure. Ending the turn as failed painted an error
            // over an answer that was already delivered and stopped the chat on
            // bookkeeping the user could not act on. Keep the answer and the
            // recorded work, end normally, and let Continue open the next round.
            result.turnStatus = "completed";
            result.taskStatus = state.verificationRequired ? "verifying" : "active";
            result.status = "Unfinished work remains recorded. Press Continue to resume it.";
            result.clearDiagnostic = true;
            return result;
        }
        request(state.guidance(), state.attempts ? "Recovering the unresolved outcome…" : "Completing the requested outcome…");
        if (state.attempts && policy.diagnosticAvailable) result.diagnosticRequests = 1;
        return result;

    }
    // A goal that needs tools cannot progress through a request that offers
    // none, and an answer/analysis goal is finished by its reply. Both settle
    // instead of auto-continuing into a loop the model cannot break. A queued
    // follow-up does not end goal work early; it opens once the agent stops.
    // A question or side investigation answered inside a goal thread does not
    // end the goal either: its reply is already delivered and the objective
    // still owns the work. Only an explicit restriction ("just explain", "do not
    // edit") holds the continuation until the user lifts it. Leaving the goal
    // active but idle was the reported "goal stopped and does nothing" state.
    // A goal continuation answered with prose only has not advanced the goal.
    // Requesting the same continuation again replayed the refusal, and settling
    // left the active goal with no running turn. Spend the output recovery turn
    // on a concrete action instead, within a bounded budget. A goal that spends
    // that budget without a useful action is stopped and paused: repeating the
    // request only replayed the same refusal while the goal kept running.
    if (goalKeepsRunning)
    {
        if (goalNeedsHumanInput(session))
        {
            // The request_input stays in the transcript as recorded context.
            // Waiting for the answer would stop a goal chat, so continue with
            // the next concrete action and the best supported default.
            result.advanceGoal = true;
            result.clearBlocker = true;
            request(goalInputContinuesInstruction,
                "Continuing the goal without stopping for the question…");
            return result;
        }
        if (!goalAuditStalled(session))
        {
            result.advanceGoal = true;
            request(goalContinuationInstruction(session), "Continuing toward the goal…");
            return result;
        }
        // Recovery is bounded. Once the model has answered a stalled goal turn
        // without any useful action for the whole budget, another "take an
        // action" request only replays the same refusal: the reported thread
        // answered "pause the active goal, this session cannot call
        // goal_complete" four times while the app queued the next recovery,
        // growing the prompt to 386k tokens. Stop the goal and keep its
        // recorded work for Start instead of looping without progress.
        if (goalAuditRecoveryCount(session) >= maxGoalAuditRecoveries)
        {
            result.turnStatus = "completed";
            result.taskStatus = "active";
            result.status = "Goal stopped after repeated turns without progress · press Start to resume.";
            result.settleGoal = "paused";
            return result;
        }
        result.advanceGoal = true;
        request(outputRecoveryMarker ~ goalAuditRecoveryInstruction,
            "Recovering the goal…");
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
    // This settle starts no further turn. An answer goal finished by its
    // delivered reply is complete. Every other goal keeps its recorded work
    // active: the app and the agent never pause the user's goal, so Continue is
    // the explicit way back and only the user can pause it. A queued follow-up
    // opens the next turn immediately, so that chat is not idle and the goal
    // keeps owning the follow-up's work.
    if (goalActive(session) && !session.queuedFollowUps.length)
    {
        const outstanding = hasIncompleteTaskSteps(session) ||
            session.verificationStatus == "required" ||
            session.verificationStatus == "failed";
        result.settleGoal = goalIsAnswerTurn(session.goal) && !outstanding &&
            goalAnswerDelivered(session) ? "completed" : "";
    }
    return result;
}
