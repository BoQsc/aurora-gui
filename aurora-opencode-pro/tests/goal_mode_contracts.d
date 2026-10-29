module goal_mode_contracts;

import auroraopencode.core : ChatSession, TaskStep;
import auroraopencode.goalmode;
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
    writeln("PASS goal commands set/show/pause/resume/clear");

    ChatSession session;
    session.goal = "Ship the goal bar";
    session.goalStatus = "active";
    auto prompt = goalPromptBlock(session);
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
        `{"summary":"done","evidence":["call-1"]}`).length == 0,
        "a verified, evidence-backed completion was rejected");
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
        `{"title":"Goal","goal":"finish it","goalStatus":"paused","goalStartedAt":42,"goalTurns":3}`;
    auto restored = projectAgentRuntimeEvents([started]);
    require(restored.length == 1 && restored[0].goal == "finish it" &&
        restored[0].goalStatus == "paused" &&
        restored[0].goalStartedAt == 42 && restored[0].goalTurns == 3,
        "journal projection lost persistent goal state");
    writeln("PASS durable goal state survives journal projection");
    writeln("goal mode contracts passed");
    return 0;
}