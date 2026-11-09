module engine_policy_contracts;

import auroraopencode.core;
import auroraopencode.turnpolicy;
import auroraopencode.requestpolicy;
import auroraopencode.completionhandoff : completionHandoffMarker;
import std.conv : to;
import std.string : indexOf;
import std.stdio : writeln;

void append(ref ChatSession session, string role, string text, bool internal = false)
{
    ChatMessage message;
    message.id = "m" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    message.role = role; message.content = text; message.internal = internal;
    session.activeLeafId = message.id;
    session.messages ~= message;
}

int main()
{
    ChatSession session;
    append(session, "user", "Implement and verify the requested feature.");
    append(session, "assistant", "The current attempt failed.");
    session.verificationStatus = "failed";
    TurnPolicy turn;
    auto decision = decideTurn(session, turn);
    assert(decision.action == TurnAction.settle && decision.taskStatus == "verifying",
        "A failed check was presented as completed when tools are unavailable");
    session.taskSteps = [TaskStep("Implement", "in_progress"), TaskStep("Verify", "pending")];
    turn.toolsEnabled = true;
    decision = decideTurn(session, turn);
    assert(decision.action == TurnAction.request && decision.guidance.indexOf("unfinished") >= 0);
    session.queuedGuidance = ["Preserve compatibility"];
    assert(decideTurn(session, turn).action == TurnAction.applySteering);
    turn.cancelled = true;
    assert(decideTurn(session, turn).action == TurnAction.interrupted);
    assert(session.queuedGuidance.length == 1 && session.taskSteps[0].status == "in_progress",
        "Decision evaluation mutated the source state");

    session = ChatSession.init;
    append(session, "user", "Summarize the result.");
    append(session, "assistant", "The requested result is recorded.");
    turn = TurnPolicy.init;
    turn.orchestratorEnabled = true;
    turn.pendingChildren = true;
    session.agents = [AgentSpec("router", "Router", "", "", true)];
    session.activeAgentId = "router";
    assert(decideTurn(session, turn).action == TurnAction.waitChildren);
    session.parentSessionId = "parent";
    assert(decideTurn(session, turn).action == TurnAction.reportChild);
    session.parentSessionId = "";
    session.agents = null;
    session.goal = "Deliver every requested outcome";
    session.goalStatus = "active";
    session.goalTurns = 100;
    append(session, "user", "Continue the task.");
    turn.toolsEnabled = true;
    assert(decideTurn(session, turn).advanceGoal, "Useful long goals inherited a turn cap");
    turn.toolsEnabled = false;
    assert(!decideTurn(session, turn).advanceGoal,
        "A goal without tool access started an unusable continuation");
    turn.toolsEnabled = true;
    session.goal = "Review the current plan";
    append(session, "user", "Review the current plan and reply READY.");
    assert(!decideTurn(session, turn).advanceGoal,
        "An analysis goal auto-continued after its answer");
    session.goal = "Deliver every requested outcome";
    append(session, "user", "Answer only: what is the current status?");
    assert(!decideTurn(session, turn).advanceGoal, "An answer-only question resumed the active goal");
    append(session, "user", "Finish the requested task.");
    session.goalStatus = "completed";
    append(session, "user", completionHandoffMarker ~ "Summarize existing evidence", true);
    append(session, "assistant", "");
    decision = decideTurn(session, turn);
    assert(decision.action == TurnAction.settle && decision.recordedSummary.length,
        "A failed summary handoff started another summary loop");

    session = ChatSession.init;
    session.instructions = "Use the project's naming conventions";
    session.goal = "Finish the task";
    session.goalStatus = "active";
    append(session, "user", "Finish the requested task.");
    RequestPolicy request;
    request.toolsEnabled = true;
    request.baseSystemPrompt = "Captured system instructions";
    request.availableTools = [OpenCodeToolDef("read", "Read", "{}"), OpenCodeToolDef("write", "Write", "{}"),
        OpenCodeToolDef("goal_complete", "Complete", "{}"), OpenCodeToolDef("update_subplan", "Subplan", "{}")];
    auto prepared = prepareAgentRequest(session, request);
    assert(prepared.tools.length == 3 && prepared.messages[0].content.indexOf(session.instructions) >= 0);
    request.diagnosticReview = true;
    prepared = prepareAgentRequest(session, request);
    assert(prepared.tools.length == 1 && prepared.tools[0].name == "read",
        "Diagnostic requests acquired mutation or completion capabilities");
    request.summaryOnly = true;
    prepared = prepareAgentRequest(session, request);
    assert(!prepared.tools.length);
    assert(request.availableTools.length == 4, "Filtering mutated the admitted capability snapshot");
    request = RequestPolicy.init; request.toolsEnabled = true;
    request.availableTools = [OpenCodeToolDef("read", "Read", "{}"), OpenCodeToolDef("edit", "Edit", "{}")];
    session = ChatSession.init;
    session.contract.intent = "implementation";
    session.contract.requestedOutcome = "Reveal Export when hovering Checkpoint";
    session.taskSteps = [TaskStep("Move Export", "completed")];
    session.verificationStatus = "passed";
    append(session, "user", session.contract.requestedOutcome);
    prepared = prepareAgentRequest(session, request);
    assert(prepared.messages[$ - 1].content.indexOf("Outcome check before the final reply") >= 0);
    assert(prepared.messages[$ - 1].content.indexOf("hovering Checkpoint") >= 0);
    assert(prepared.tools.length == 2 && session.taskSteps[0].status == "completed",
        "Outcome reconciliation restricted tools or rewrote completion");
    session.taskSteps[0].status = "in_progress";
    assert(prepareAgentRequest(session, request).messages[$ - 1].content.indexOf("Outcome check before the final reply") < 0);
    writeln("PASS turn decisions preserve evidence, steering, goals and delegation; request modes isolate capabilities");
    return 0;
}
