module plan_progress_contracts;

import auroraopencode.core;
import auroraopencode.planprogress;
import auroraopencode.tools : executeTool, nativeOnlyToolDefinitions;
import auroraopencode.goalmode : goalCompletionError;
import auroraopencode.controlhistory : controlStateKind, ControlStateKind;
import std.json : parseJSON;
import std.string : indexOf;
import std.stdio : writeln;

void main()
{
    ChatSession session;
    void append(string role, string text, string tool = "", bool failed = false, bool internal = false)
    {
        ChatMessage message;
        message.id = newMessageId(); message.parentId = session.activeLeafId;
        message.role = role; message.content = text; message.toolName = tool;
        message.failed = failed; message.internal = internal;
        session.messages ~= message; session.activeLeafId = message.id;
    }
    append("user", "Investigate, implement and verify the fix");
    append("tool", "source", "read");
    assert(!planProgressGuidance(session).length, "Quick lookup acquired planning debt");
    append("tool", "source", "read"); append("tool", "source", "read");
    auto reminder = planProgressGuidance(session);
    assert(reminder.indexOf("update_plan") >= 0);
    append("user", reminder, "", false, true);
    assert(controlStateKind(session.messages[$ - 1]) == ControlStateKind.progress,
        "Plan guidance escaped bounded control-history retirement");
    assert(!planProgressGuidance(session).length, "Same checkpoint repeated after durable replay");
    session.taskSteps = [TaskStep("Find cause", "in_progress"), TaskStep("Fix", "pending"), TaskStep("Verify", "pending")];
    session.taskSteps[0].kind = "research";
    append("tool", "Plan updated", "update_plan");
    append("tool", "Failed write", "write", true);
    assert(planProgress(session).phase == 0, "Failed action advanced the phase");
    append("tool", "Written", "write");
    reminder = planProgressGuidance(session);
    assert(reminder.indexOf("Work has moved into editing or verification") >= 0,
        "Editing left the research checklist stale");
    assert(session.taskSteps[0].status == "in_progress", "Harness fabricated completion");
    append("user", reminder, "", false, true);
    assert(!planProgressGuidance(session).length);
    append("tool", "Check passed", "verify");
    assert(planProgressGuidance(session).length, "Verification did not trigger a new phase checkpoint");
    append("tool", "Plan updated", "update_plan");
    session.taskSteps[0].kind = "verify";
    foreach (_; 0 .. planProgressWindow - 1) append("tool", "source", "read");
    append("tool", "Child updated", "update_subplan");
    assert(planProgress(session).results == planProgressWindow - 1,
        "Child upkeep refreshed the parent or counted as substantive work");
    append("tool", "source", "read");
    reminder = planProgressGuidance(session);
    assert(reminder.indexOf("Plan upkeep") >= 0);
    append("user", reminder, "", false, true);
    assert(!planProgressGuidance(session).length);
    // Reload has exactly the same decision without process-local counters.
    auto restored = session;
    assert(!planProgressGuidance(restored).length);
    foreach (_; 0 .. planProgressWindow) append("tool", "source", "read");
    assert(planProgressGuidance(session).length, "Long phase lost periodic upkeep");
    session.taskStatus = "waiting_input";
    assert(!planProgressGuidance(session).length);
    session.taskStatus = "active";
    append("user", "Here is the missing fact");
    assert(planProgress(session).results == 0 && !planProgressGuidance(session).length);
    const answer = `{"summary":"Compaction retains a summary of earlier context."}`;
    auto executed = executeTool(OpenCodeToolCall("answer-complete", "goal_complete", answer), ".");
    assert(!executed.failed, "Native tool contradicted answer-only completion policy");
    ChatSession answerGoal;
    answerGoal.goal = "What is compaction?"; answerGoal.goalStatus = "active";
    assert(!goalCompletionError(answerGoal, answer).length);
    answerGoal.goal = "Implement and verify compaction";
    assert(goalCompletionError(answerGoal, answer).length,
        "Action goal lost its evidence requirement");
    foreach (tool; nativeOnlyToolDefinitions()) if (tool.name == "goal_complete")
    {
        const schema = parseJSON(tool.parametersJson);
        assert(schema["required"].array.length == 1,
            "Wire schema still requires fabricated receipts for answer-only goals");
    }
    writeln("PASS shared plan checkpoints follow phases, preserve outcomes, survive reload and never block tools");
}
