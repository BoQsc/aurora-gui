module goal_settle_contracts;

// An active goal must never settle into an idle chat that still advertises
// itself as active, and a question or side investigation answered inside a goal
// thread must not end the goal's continuation forever. These are the exact
// reported states: "the goal keeps stopping without reaching the goal, the goal
// is active but doing nothing".

import auroraopencode.core : ChatMessage, ChatSession, TaskStep, TaskWorkItem,
    ensureMessageGraph;
import auroraopencode.contextpolicy : durableTaskPrompt;
import auroraopencode.executioncontrol : executionRecoveryMarker, executionState;
import auroraopencode.goalmode : goalAnswerDelivered, goalCompletionError;
import auroraopencode.outputguard : outputRecoveryMarker;
import auroraopencode.requestintent : workRestrictionRequest;
import auroraopencode.taskflow : taskInvestigation;
import auroraopencode.turnpolicy : TurnAction, TurnDecision, TurnPolicy, decideTurn;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf, startsWith;

void require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

ChatMessage msg(string role, string content, bool internal = false,
    string toolName = "", bool failed = false)
{
    ChatMessage message;
    message.role = role;
    message.content = content;
    message.internal = internal;
    message.toolName = toolName;
    message.failed = failed;
    return message;
}

/// Append after the graph already has ids, so the new tail stays on the
/// active branch instead of becoming an unreferenced side chain.
void appendLinked(ref ChatSession session, ChatMessage message)
{
    ensureMessageGraph(session);
    message.id = "settle-" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    session.messages ~= message;
    session.activeLeafId = message.id;
}

ChatSession sessionWith(string goal)
{
    ChatSession session;
    session.id = "goal-settle";
    session.goal = goal;
    session.goalStatus = "active";
    session.taskStatus = "active";
    session.turnStatus = "completed";
    session.contract.id = "task-1";
    session.contract.intent = "implementation";
    session.contract.currentIntent = "implementation";
    session.contract.goal = goal;
    session.contract.requestedOutcome = goal;
    session.objective = goal;
    session.messages ~= msg("user", goal);
    return session;
}

TurnDecision decide(ref ChatSession session, bool toolsEnabled = true)
{
    ensureMessageGraph(session);
    TurnPolicy policy;
    policy.toolsEnabled = toolsEnabled;
    return decideTurn(session, policy);
}

int main()
{
    const actionGoal = "Investigate and fix the goal continuation in Aurora OpenCode.";

    // A side investigation answered inside the goal thread keeps the goal
    // working: its answer is delivered and the objective still owns the work.
    {
        auto session = sessionWith(actionGoal);
        session.messages ~= msg("assistant", "I inspected the turn policy.");
        session.contract.currentIntent = "analysis";
        require(taskInvestigation(session),
            "the fixture must exercise an answered side investigation");
        const decision = decide(session);
        require(decision.action == TurnAction.request && decision.continues(),
            "an answered investigation inside an active goal stopped the goal");
        require(decision.advanceGoal, "the continuation was not a goal turn");
        require(decision.settleGoal.length == 0,
            "a continuing goal was also recorded as settled");
    }
    {
        auto session = sessionWith(actionGoal);
        session.messages ~= msg("user", "What is left?");
        session.messages ~= msg("assistant", "Two outcomes remain.");
        require(!workRestrictionRequest("What is left?"),
            "a plain question was treated as a work restriction");
        const decision = decide(session);
        require(decision.continues(),
            "an answered question inside an active goal stopped the goal");
    }
    // Once that side question is answered, the continuation must not present it
    // as the current deliverable again: doing so makes the model repeat the
    // answer on every resume instead of advancing the goal.
    {
        auto session = sessionWith(actionGoal);
        session.messages ~= msg("user", "Does the metal break sound play?");
        ensureMessageGraph(session);
        require(durableTaskPrompt(session, true).indexOf(
                "Current request: Does the metal break sound play?") >= 0,
            "the unanswered side question was not the current deliverable");
        ChatMessage answer = msg("assistant", "Yes — it plays.");
        answer.id = "side-answer";
        answer.parentId = session.activeLeafId;
        session.messages ~= answer;
        session.activeLeafId = answer.id;
        require(goalAnswerDelivered(session),
            "the delivered side answer was not detected");
        const prompt = durableTaskPrompt(session, true);
        require(prompt.indexOf("Current request: Does the metal break sound play?") < 0,
            "an answered side question was re-presented as the deliverable");
        require(prompt.indexOf("The latest request asks for an explanation") < 0,
            "the answered side question still demanded an explanation");
        require(prompt.indexOf("already been answered") >= 0,
            "the continuation did not state that the side request was answered");
    }

    // An explicit restriction holds the goal. The agent's turn settling must
    // not pause the user's goal: only the user pauses.
    {
        auto session = sessionWith(actionGoal);
        session.messages ~= msg("user", "Just explain why it failed. Do not edit anything.");
        session.messages ~= msg("assistant", "It failed because the step was never recorded.");
        session.taskSteps ~= TaskStep("Fix the step", "in_progress", "s1", "", "Done", []);
        require(workRestrictionRequest("Just explain why it failed. Do not edit anything."),
            "an explain-only request was not treated as a restriction");
        const decision = decide(session);
        require(!decision.continues(), "an explain-only request continued the goal");
        require(decision.settleGoal.length == 0,
            "the agent paused a goal the user had not paused");
        require(session.goalStatus == "active",
            "an explained goal was paused by the turn settle");
    }

    // No tools means the goal cannot progress in this turn. The goal stays
    // active for the user's next move instead of being paused by the app.
    {
        auto session = sessionWith(actionGoal);
        session.messages ~= msg("assistant", "Working on it.");
        const decision = decide(session, false);
        require(!decision.continues(), "a tool-free request continued goal work");
        require(decision.settleGoal.length == 0,
            "a tool-free settle paused the goal");
        require(session.goalStatus == "active",
            "a tool-free settle changed the user's goal state");
    }

    // An answer-shaped goal is finished by its delivered reply: it completes
    // instead of idling as active or looping in a work turn.
    {
        auto session = sessionWith("Explain why the goal stops without reaching completion");
        session.verificationStatus = "not_required";
        session.messages ~= msg("assistant", "It stops because the settle left the goal active.");
        ensureMessageGraph(session);
        require(goalAnswerDelivered(session), "the delivered reply was not detected");
        const decision = decide(session);
        require(!decision.continues(),
            "an answer goal acquired a forced work turn after its answer");
        require(decision.settleGoal == "completed",
            "an answered goal was left active instead of completed");
    }
    {
        // The same goal with outstanding verification still has work left, so it
        // neither completes nor pauses; the work stays active.
        auto session = sessionWith("Explain why the goal stops without reaching completion");
        session.verificationStatus = "required";
        session.messages ~= msg("assistant", "It stops because the settle left the goal active.");
        const decision = decide(session);
        require(decision.settleGoal.length == 0,
            "an answer goal with outstanding verification was completed or paused");
        require(session.goalStatus == "active",
            "outstanding verification was turned into an app pause");
    }

    // A failed reply is not a delivered answer.
    {
        auto session = sessionWith("Why did the goal stop?");
        session.messages ~= msg("assistant", "partial", false, "", true);
        ensureMessageGraph(session);
        require(!goalAnswerDelivered(session),
            "a failed reply counted as a delivered answer");
    }

    // A request for validated input must not stop a goal chat. The referenced
    // "Aurora Designer Check" chat ended as waiting_input while its goal still
    // owned unfinished work, so the user saw the goal stop on a question. The
    // recorded request stays in the transcript and the goal keeps working.
    {
        auto session = sessionWith(actionGoal);
        session.taskStatus = "waiting_input";
        auto call = msg("assistant", "");
        call.toolName = "";
        session.messages ~= call;
        ChatMessage tool = msg("tool", "Recorded the missing fact", false, "request_input");
        tool.toolCallId = "call-input";
        tool.toolArgs = `{"reason":"The deployment target is missing",` ~
            `"required_fact":"Deployment target",` ~
            `"question":"Which server should receive the build?",` ~
            `"checked":["Local settings have no target"],` ~
            `"independent_work_complete":true}`;
        session.messages ~= tool;
        const decision = decide(session);
        require(decision.action == TurnAction.request && decision.continues(),
            "a validated input request stopped the active goal chat");
        require(decision.advanceGoal, "the input continuation was not a goal turn");
        require(decision.taskStatus == "active",
            "the goal kept the waiting_input task status");
        require(decision.guidance.indexOf("does not stop for a question") >= 0,
            "the input continuation did not tell the agent to keep working");
        require(decision.settleGoal.length == 0,
            "the input continuation settled the active goal");
    }

    // A queued follow-up opens the next turn at once, so the chat is not idle
    // and the goal keeps owning that work instead of being paused under it.
    {
        auto session = sessionWith(actionGoal);
        session.messages ~= msg("assistant", "Working on it.");
        session.queuedFollowUps ~= "Also update the docs.";
        const decision = decide(session, false);
        require(decision.settleGoal.length == 0,
            "a queued follow-up paused the goal it continues");
    }

    // Reported: the referenced "Aurora Designer Check" chat answered its goal
    // continuation with prose only while a checklist outcome and verification
    // were still open. The turn settled and the chat sat idle while the goal
    // still advertised itself as active. The app spends recovery turns on real
    // work and never parks the goal: a model that keeps answering with prose
    // gets an escalated directive, not a pause.
    {
        auto session = sessionWith(actionGoal);
        session.contract.currentIntent = "analysis";
        session.verificationStatus = "required";
        session.taskSteps ~= TaskStep("Reach the strict target", "pending",
            "step-strict", "", "No frame over budget", []);
        session.messages ~= msg("user",
            "Persistent goal continuation: " ~ actionGoal, true);
        session.messages ~= msg("assistant",
            "The last change is live; the strict target remains open.");
        const decision = decide(session);
        require(decision.continues() && decision.advanceGoal,
            "a stalled goal continuation settled instead of recovering");
        require(decision.guidance.startsWith("Agent output recovery:"),
            "the goal recovery did not use the bounded output-recovery turn");
        require(decision.settleGoal.length == 0,
            "the goal recovery also paused or completed the goal");
        require(session.goalStatus == "active",
            "the goal recovery changed the user's goal state");
        foreach (_; 0 .. 5)
            appendLinked(session, msg("user",
                outputRecoveryMarker ~ " keep going", true));
        appendLinked(session, msg("assistant", "Still summarizing."));
        const escalated = decide(session);
        require(escalated.action == TurnAction.request && escalated.advanceGoal,
            "a goal that never acted was parked instead of receiving another action turn");
        require(escalated.guidance.length > 0,
            "the stalled goal did not queue an escalated directive");
        require(escalated.settleGoal.length == 0,
            "the stalled goal was recorded as settled or paused");
        require(escalated.guidance.indexOf("Progress audit") >= 0,
            "the repeated stall did not change strategy");
        require(session.goalStatus == "active",
            "a stalled goal no longer owns its work");
        require(escalated.taskStatus != "completed",
            "stopping a stalled goal fabricated completion of its work");
    }

    // The shared execution-recovery budget bounds ordinary retries. It must not
    // settle an active goal with open outcomes: that used to end the turn with
    // "Press Continue", parking the user's goal between attempts.
    {
        auto session = sessionWith(actionGoal);
        session.taskSteps ~= TaskStep("Implement the fix", "in_progress",
            "step-impl", "", "Behavior fixed", []);
        const state = executionState(session, false);
        require(state.remaining.length > 0,
            "the recovery fixture must have an open outcome");
        appendLinked(session, msg("user", executionRecoveryMarker ~
            `{"fingerprint":"` ~ state.fingerprint ~ `","attempts":2}`, true));
        const decision = decide(session);
        require(decision.action == TurnAction.request && decision.continues(),
            "the execution-recovery budget settled an active goal");
        require(decision.advanceGoal,
            "the escalated recovery was not recorded as a goal turn");
        require(decision.guidance.indexOf("Persistent goal recovery") >= 0,
            "the goal recovery did not escalate the approach");
        require(decision.settleGoal.length == 0,
            "the execution-recovery boundary paused the goal");
    }

    // A goal never completes with deferred work, including an optional
    // follow-up that an ordinary task may park.
    {
        auto session = sessionWith("Explain why goals stop early");
        session.verificationStatus = "not_required";
        TaskWorkItem item;
        item.step = TaskStep("Run the remaining platform check", "deferred",
            "work-deferred", "verify", "Check passes", []);
        item.origin = "discovery";
        item.reason = "optional follow-up";
        item.required = false;
        session.contract.workItems ~= item;
        const error = goalCompletionError(session,
            `{"summary":"The explanation is complete."}`);
        require(error.indexOf("deferred") >= 0,
            "goal_complete accepted a deferred work item: " ~ error);
    }
    {
        auto session = sessionWith(actionGoal);
        session.verificationStatus = "not_required";
        ChatMessage edit = msg("tool", "Edited the turn policy", false, "edit");
        edit.toolCallId = "edit-1";
        appendLinked(session, edit);
        session.taskSteps ~= TaskStep("Fix the stop", "completed", "step-fix",
            "edit", "Goal runs", ["edit-1"]);
        const error = goalCompletionError(session,
            `{"summary":"The fix is in; the documentation update is deferred to a later turn.",` ~
            `"evidence":["edit-1"]}`);
        require(error.indexOf("deferred") >= 0,
            "goal_complete accepted deferred completion prose: " ~ error);
    }

    // A control surface may not offer goal_complete at all. When every recorded
    // outcome is complete and supported, the answer names no gap, and nothing is
    // deferred, the goal closes from durable state instead of prompting forever.
    {
        auto session = sessionWith(actionGoal);
        session.verificationStatus = "passed";
        ChatMessage edit = msg("tool", "Edited the turn policy", false, "edit");
        edit.toolCallId = "edit-done";
        appendLinked(session, edit);
        session.taskSteps ~= TaskStep("Fix the stop", "completed", "step-fix",
            "edit", "Goal runs", ["edit-done"]);
        appendLinked(session, msg("user",
            "Persistent goal continuation: " ~ actionGoal, true));
        appendLinked(session, msg("assistant",
            "All recorded outcomes are complete and the checks passed."));
        const done = decide(session);
        require(done.settleGoal == "completed" && !done.continues(),
            "a fully supported goal without a completion call kept running");
        require(done.taskStatus == "completed",
            "the completed goal did not close its task state");
    }
    {
        auto session = sessionWith(actionGoal);
        session.verificationStatus = "passed";
        ChatMessage edit = msg("tool", "Edited the turn policy", false, "edit");
        edit.toolCallId = "edit-done";
        appendLinked(session, edit);
        session.taskSteps ~= TaskStep("Fix the stop", "completed", "step-fix",
            "edit", "Goal runs", ["edit-done"]);
        appendLinked(session, msg("user",
            "Persistent goal continuation: " ~ actionGoal, true));
        appendLinked(session, msg("assistant",
            "The fix is in.\nRemaining work: update the documentation."));
        const gap = decide(session);
        require(gap.settleGoal.length == 0 && gap.continues(),
            "a goal whose answer named remaining work was completed from state");
    }
    {
        auto session = sessionWith(actionGoal);
        session.verificationStatus = "passed";
        ChatMessage edit = msg("tool", "Edited the turn policy", false, "edit");
        edit.toolCallId = "edit-done";
        appendLinked(session, edit);
        session.taskSteps ~= TaskStep("Fix the stop", "completed", "step-fix",
            "edit", "Goal runs", ["edit-done"]);
        TaskWorkItem deferredItem;
        deferredItem.step = TaskStep("Run the remaining platform check",
            "deferred", "work-deferred", "verify", "Check passes", []);
        deferredItem.origin = "discovery";
        deferredItem.reason = "optional follow-up";
        deferredItem.required = false;
        session.contract.workItems ~= deferredItem;
        appendLinked(session, msg("user",
            "Persistent goal continuation: " ~ actionGoal, true));
        appendLinked(session, msg("assistant",
            "All recorded outcomes are complete and the checks passed."));
        const parked = decide(session);
        require(parked.settleGoal.length == 0 && parked.continues(),
            "a goal with deferred work was completed from durable state");
    }

    // The reported refusal: the user pauses an unmet goal, asks why the agent
    // is refusing, and the app answers by restarting the paused goal's
    // outstanding verification. The delivered answer must end the turn; the
    // paused work waits for an explicit Start instead.
    {
        auto session = sessionWith(actionGoal);
        session.goalStatus = "paused";
        session.verificationStatus = "required";
        session.messages ~= msg("assistant", "The strict result is not certifiable yet.");
        session.messages ~= msg("user", "Why are you refusing?");
        session.messages ~= msg("assistant", "I was refusing to certify an unmeasured result.");
        const decision = decide(session);
        require(!decision.continues(),
            "an answer-only question restarted a paused goal's outstanding work");
        require(decision.settleGoal.length == 0,
            "a settle after an answered question rewrote the paused goal");
        require(decision.taskStatus == "verifying",
            "the paused goal's outstanding verification was dropped");
    }
    // The same paused goal continues when the user asks for the work again.
    {
        auto session = sessionWith(actionGoal);
        session.goalStatus = "paused";
        session.verificationStatus = "required";
        session.messages ~= msg("assistant", "The strict result is not certifiable yet.");
        session.messages ~= msg("user", "I said to ensure by developing");
        const decision = decide(session);
        require(decision.continues() && decision.guidance.length,
            "an action request did not resume the paused goal's work");
    }
    // A cause question also asks for the repair, not for a prose-only answer.
    // The app pauses a goal whenever a turn settles, so treating this as an
    // explanation left the reported problem unsolved behind a refusal.
    {
        auto session = sessionWith(actionGoal);
        session.goalStatus = "paused";
        session.verificationStatus = "required";
        session.messages ~= msg("assistant", "The strict result is not certifiable yet.");
        session.messages ~= msg("user", "we need to know what is producing problems");
        const decision = decide(session);
        require(decision.continues() && decision.guidance.length,
            "a cause question did not resume the paused goal's diagnosis");
    }
    // A completed goal keeps its paused-like hold on leftover work.
    {
        auto session = sessionWith(actionGoal);
        session.goalStatus = "completed";
        session.verificationStatus = "required";
        session.messages ~= msg("user", "What is left?");
        const decision = decide(session);
        require(!decision.continues(),
            "an answered question restarted a completed goal's leftover work");
    }

    writeln("goal settle contracts passed");
    return 0;
}
