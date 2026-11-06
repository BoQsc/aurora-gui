module goal_settle_contracts;

// An active goal must never settle into an idle chat that still advertises
// itself as active, and a question or side investigation answered inside a goal
// thread must not end the goal's continuation forever. These are the exact
// reported states: "the goal keeps stopping without reaching the goal, the goal
// is active but doing nothing".

import auroraopencode.core : ChatMessage, ChatSession, TaskStep,
    ensureMessageGraph;
import auroraopencode.contextpolicy : durableTaskPrompt;
import auroraopencode.goalmode : goalAnswerDelivered;
import auroraopencode.requestintent : workRestrictionRequest;
import auroraopencode.taskflow : taskInvestigation;
import auroraopencode.turnpolicy : TurnAction, TurnDecision, TurnPolicy, decideTurn;
import std.stdio : writeln;
import std.string : indexOf;

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

    // An explicit restriction holds the goal, but never leaves it claiming to be
    // active while no turn runs.
    {
        auto session = sessionWith(actionGoal);
        session.messages ~= msg("user", "Just explain why it failed. Do not edit anything.");
        session.messages ~= msg("assistant", "It failed because the step was never recorded.");
        session.taskSteps ~= TaskStep("Fix the step", "in_progress", "s1", "", "Done", []);
        require(workRestrictionRequest("Just explain why it failed. Do not edit anything."),
            "an explain-only request was not treated as a restriction");
        const decision = decide(session);
        require(!decision.continues(), "an explain-only request continued the goal");
        require(decision.settleGoal == "paused",
            "an explained goal stayed active with no running turn");
    }

    // No tools means the goal cannot progress; the settle pauses it instead of
    // leaving an active goal with nothing running.
    {
        auto session = sessionWith(actionGoal);
        session.messages ~= msg("assistant", "Working on it.");
        const decision = decide(session, false);
        require(!decision.continues(), "a tool-free request continued goal work");
        require(decision.settleGoal == "paused",
            "a tool-free settle left the goal active");
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
        // pauses rather than claiming completion.
        auto session = sessionWith("Explain why the goal stops without reaching completion");
        session.verificationStatus = "required";
        session.messages ~= msg("assistant", "It stops because the settle left the goal active.");
        const decision = decide(session);
        require(decision.settleGoal == "paused",
            "an answer goal with outstanding verification was completed");
    }

    // A failed reply is not a delivered answer.
    {
        auto session = sessionWith("Why did the goal stop?");
        session.messages ~= msg("assistant", "partial", false, "", true);
        ensureMessageGraph(session);
        require(!goalAnswerDelivered(session),
            "a failed reply counted as a delivered answer");
    }

    // A goal waiting for validated input is not paused: it is still the user's
    // move and the goal stays active.
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
        require(decision.action == TurnAction.waitInput,
            "a validated input wait did not wait for the user");
        require(decision.settleGoal.length == 0,
            "a validated input wait paused the active goal");
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

    writeln("goal settle contracts passed");
    return 0;
}
