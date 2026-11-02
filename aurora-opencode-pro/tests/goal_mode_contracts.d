module goal_mode_contracts;

import auroraopencode.core : ChatMessage, ChatSession, Settings, TaskStep,
    ensureMessageGraph, goalHistoryFromJson, goalHistoryToJson;
import auroraopencode.goalmode;
import auroraopencode.goalmutation : resetTaskForNewGoal;
import std.json : parseJSON;
import auroraopencode.runtime : AgentEventKind, AgentRuntimeEvent,
    projectAgentRuntimeEvents;
import auroraopencode.tools : builtinToolDefinitions, executeTool,
    nativeOnlyToolDefinitions;
import auroraopencode.core : OpenCodeToolCall;
import std.stdio : writeln;
import std.string : indexOf;
import std.utf : toUTF32;

void require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

ChatMessage msg(string role, string content, bool internal = false)
{
    ChatMessage result;
    result.role = role;
    result.content = content;
    result.internal = internal;
    return result;
}

int main()
{
    auto set = parseGoalCommand("/goal all tests pass and lint is clean");
    require(set.kind == GoalCommandKind.set &&
        set.text == "all tests pass and lint is clean",
        "goal text was not parsed");
    require(parseGoalCommand("/goal pause").kind == GoalCommandKind.pause,
        "pause alias was not parsed");
    require(parseGoalCommand("/goal resume").kind == GoalCommandKind.resume,
        "resume alias was not parsed");
    require(parseGoalCommand("/goal clear").kind == GoalCommandKind.clear,
        "clear alias was not parsed");
    require(parseGoalCommand("/goal").kind == GoalCommandKind.show,
        "bare /goal should open/show the goal");
    require(parseGoalCommand("goals are useful").kind == GoalCommandKind.none,
        "ordinary prose must not become a goal command");
    string longGoal;
    foreach (_; 0 .. maxGoalLength + 10) longGoal ~= "é";
    const clamped = clampGoalText(longGoal);
    require(toUTF32(clamped).length == maxGoalLength,
        "goal clamp split or exceeded the character budget");
    Settings defaults;
    require(defaults.autoGoalFromFirstMessage,
        "first-message goal adoption must be enabled by default");
    writeln("PASS goal commands set/show/pause/resume/clear");

    ChatSession session;
    session.goal = "Ship the goal bar";
    session.goalStatus = "active";
    auto prompt = goalPromptBlock(session);
    require(prompt.indexOf("request_input") >= 0 && goalContinuationInstruction(session).indexOf("request_input") >= 0,
        "Goal instructions omitted the validated input boundary");
    require(prompt.indexOf("Ship the goal bar") >= 0 &&
        prompt.indexOf("goal_complete") >= 0,
        "active-goal prompt lacks the goal or completion instruction");
    session.goalStatus = "paused";
    prompt = goalPromptBlock(session);
    require(prompt.indexOf("user paused") >= 0,
        "paused goal prompt must not drive another turn");
    writeln("PASS prompt state follows active/paused goals");

    session.goalStatus = "active";
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length > 0,
        "invented completion evidence was accepted");
    auto receipt = msg("tool", "Saved the requested change");
    receipt.toolName = "write"; receipt.toolCallId = "call-1";
    session.messages ~= receipt;
    ensureMessageGraph(session);
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length == 0,
        "a verified, evidence-backed completion was rejected");
    session.messages[$ - 1].failed = true;
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length > 0,
        "failed completion evidence was accepted");
    session.messages[$ - 1].failed = false;
    require(goalCompletionError(session,
        `{"summary":"done","evidence":[]}`).length > 0,
        "completion without evidence was accepted");
    session.taskSteps = [TaskStep("finish the UI", "pending")];
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length > 0,
        "completion with an open checklist item was accepted");
    session.taskSteps = null;
    session.verificationStatus = "required";
    require(goalCompletionError(session,
        `{"summary":"done","evidence":["call-1"]}`).length > 0,
        "completion with outstanding verification was accepted");
    session.verificationStatus = "not_required";
    writeln("PASS goal completion requires evidence and finished checks");

    ChatSession history;
    history.goal = "first durable goal";
    history.goalStatus = "paused";
    history.goalStartedAt = 10;
    recordGoalSet(history, 10);
    require(history.goalHistory.length == 1 &&
        history.goalHistory[0].outcome == "paused",
        "setting a goal did not append history");
    history.goal = "second durable goal";
    history.goalStatus = "active";
    history.goalStartedAt = 20;
    recordGoalSet(history, 20);
    require(history.goalHistory.length == 2 &&
        history.goalHistory[0].outcome == "replaced" &&
        history.goalHistory[0].closedAt == 20 &&
        history.goalHistory[1].outcome == "active",
        "replacing a goal did not preserve the previous record");
    recordGoalOutcome(history, "completed", 30);
    require(history.goalHistory[1].outcome == "completed" &&
        history.goalHistory[1].closedAt == 30,
        "completion did not close the goal history record");
    const encodedHistory = goalHistoryToJson(history.goalHistory);
    const decodedHistory = goalHistoryFromJson(encodedHistory);
    require(decodedHistory.length == 2 &&
        decodedHistory[0].text == "first durable goal" &&
        decodedHistory[1].outcome == "completed",
        "goal history did not survive JSON round-trip");
    history.goal = "second durable goal";
    history.goalStatus = "active";
    history.goalStartedAt = 40;
    recordGoalSet(history, 40);
    require(history.goalHistory.length == 3,
        "reusing a completed goal text did not create a new history entry");
    writeln("PASS every goal set is retained in per-conversation history");

    ChatSession humanHelp;
    humanHelp.goal = "finish the task";
    humanHelp.goalStatus = "active";
    humanHelp.messages ~= msg("user", "Install and verify the app.");
    humanHelp.messages ~= msg("assistant",
        "I need you to provide the signing certificate before I can continue.");
    humanHelp.activeLeafId = "";
    ensureMessageGraph(humanHelp);
    require(!goalNeedsHumanInput(humanHelp),
        "unvalidated prose paused the goal");
    humanHelp.messages ~= msg("user",
        "The user action above is still required.", true);
    humanHelp.messages ~= msg("assistant",
        "I need you to provide the signing certificate before I can continue.");
    humanHelp.activeLeafId = "";
    ensureMessageGraph(humanHelp);
    require(!goalNeedsHumanInput(humanHelp),
        "repeated prose bypassed the validated input tool");
    ChatSession progressing;
    progressing.goal = "finish the task";
    progressing.goalStatus = "active";
    progressing.messages ~= msg("user", "Install and verify the app.");
    progressing.messages ~= msg("assistant",
        "Installed, ran the checks, and verified the result.");
    ensureMessageGraph(progressing);
    require(!goalNeedsHumanInput(progressing),
        "normal completion prose was mistaken for a human-help request");
    humanHelp.taskStatus = "waiting_input";
    auto input = msg("tool", "Signing identity required");
    input.toolName = "request_input";
    input.toolArgs = `{"reason":"Signing identity is absent from configuration","required_fact":"Signing identity","question":"Which signing identity should be used?","checked":["Signing configuration"],"independent_work_complete":true}`;
    humanHelp.messages ~= input;
    humanHelp.activeLeafId = "";
    ensureMessageGraph(humanHelp);
    require(goalNeedsHumanInput(humanHelp), "validated missing information did not suspend goal continuation");
    humanHelp.messages ~= msg("user", "Use the configured test identity.");
    humanHelp.activeLeafId = "";
    ensureMessageGraph(humanHelp);
    require(!goalNeedsHumanInput(humanHelp), "a user reply did not release the input boundary");
    require(humanHelp.goalStatus == "active", "waiting for input altered the user's goal");
    foreach (text; ["Hello", "What is compaction?", "Remember this reference for later.", "Explain how the renderer works", "Plan the migration without changing files"])
        require(!automaticGoalRequest(text), "ordinary answer became a persistent goal: " ~ text);
    foreach (text; ["Ship the first-message goal", "Implement the migration", "Fix the broken renderer"])
        require(automaticGoalRequest(text), "action request lost automatic goal adoption: " ~ text);
    writeln("PASS automatic goals require action; validated input suspends continuation and a reply releases it");

    foreach (definitions; [nativeOnlyToolDefinitions(), builtinToolDefinitions()])
    {
        size_t found;
        foreach (tool; definitions)
            if (tool.name == "goal_complete") ++found;
        require(found == 1, "goal_complete must be advertised exactly once");
    }
    auto accepted = executeTool(OpenCodeToolCall("g1", "goal_complete",
        `{"summary":"done","evidence":["call-1"]}`), ".");
    require(!accepted.failed, "valid goal_complete was rejected by the tool");
    auto rejected = executeTool(OpenCodeToolCall("g2", "goal_complete",
        `{"summary":"done"}`), ".");
    require(rejected.failed, "goal_complete without evidence was accepted");
    writeln("PASS goal_complete is advertised and validates evidence");

    AgentRuntimeEvent started;
    started.kind = AgentEventKind.threadStarted;
    started.threadId = "t-goal";
    started.payloadJson =
        `{"title":"Goal","goal":"finish it","goalStatus":"paused","goalStartedAt":42,"goalTurns":3,"goalHistory":[{"text":"finish it","outcome":"paused","startedAt":42,"closedAt":0}]}`;
    auto restored = projectAgentRuntimeEvents([started]);
    require(restored.length == 1 && restored[0].goal == "finish it" &&
        restored[0].goalStatus == "paused" &&
        restored[0].goalStartedAt == 42 && restored[0].goalTurns == 3 &&
        restored[0].goalHistory.length == 1 &&
        restored[0].goalHistory[0].text == "finish it",
        "journal projection lost persistent goal state");
    writeln("PASS durable goal state survives journal projection");
    ChatSession contractOnly;
    contractOnly.contract.id = "prior-analysis";
    contractOnly.contract.intent = "analysis";
    contractOnly.contract.requestedOutcome = "Inspect the saved evidence";
    contractOnly.goal = "Deliver the replacement objective";
    resetTaskForNewGoal(contractOnly);
    require(contractOnly.taskArchive.length == 1 &&
        parseJSON(contractOnly.taskArchive[0])["taskContract"]["id"].str == "prior-analysis",
        "Replacing a goal lost an existing task contract with an empty display objective");
    writeln("goal mode contracts passed");
    return 0;
}
