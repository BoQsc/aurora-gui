module request_scope_contracts;

import auroraopencode.core;
import auroraopencode.taskflow;
import auroraopencode.taskcontinuation;
import auroraopencode.contextpolicy : durableTaskPrompt;
import auroraopencode.taskpolicy : requiredEvidence;
import auroraopencode.turnpolicy;
import std.conv : to;
import std.stdio : writeln;
import std.string : indexOf;

void request(ref ChatSession s, string text)
{
    ChatMessage m; m.id = "request-" ~ to!string(s.messages.length);
    m.parentId = s.activeLeafId; m.role = "user"; m.content = text;
    s.messages ~= m; s.activeLeafId = m.id;
    acceptTaskRequest(s, text, m.id);
}

int main()
{
    // Reduced from the real trading/fullscreen chat, retaining the conflicting
    // ownership and acceptance rather than unrelated private tool output.
    ChatSession s;
    request(s, "Ensure 1 on 1 exactness to mockup");
    s.objective = "Make the production trading panel match the standalone mockup with a fresh render";
    s.contract.id = s.contract.startMessageId = "request-0";
    s.contract.intent = s.contract.currentIntent = "implementation";
    s.contract.requestedOutcome = "Ensure 1 on 1 exactness to mockup";
    s.contract.constraints = ["1:1 mockup; trade_scrap and trade_all_items regressions"];
    s.taskSteps = [TaskStep("Match the production panel 1:1 to the mockup with custom rows and fresh evidence", "in_progress", "exact", "edit")];
    s.goal = "Ensure 1 on 1 exactness to mockup"; s.goalStatus = "paused";
    s.contract.goal = s.goal;
    s.turnStatus = "completed"; s.verificationStatus = "required";
    const old = activeTaskStateJson(s);
    request(s, "Fix fullscreen switching immediately, globally across the running world and map selector.");
    writeln("Fullscreen request objective: ", s.objective);
    writeln("Inherited checklist rows: ", s.taskSteps.length);
    writeln("Inherited verification categories: ", requiredEvidence(s));
    assert(s.objective == s.messages[$-1].content && !s.taskSteps.length,
        "A new action inherited the paused trading task");
    assert(s.taskArchive.length == 1 && s.taskArchive[0] == old,
        "Suspending old work must preserve its exact recoverable state");
    assert(!requiredEvidence(s).length, "Old mockup acceptance contaminated the fullscreen request");
    assert(s.goalStatus == "paused", "New work resumed the paused goal");
    auto context = durableTaskPrompt(s, true);
    assert(context.indexOf("Background") >= 0 && context.indexOf("mockup") >= 0,
        "Compaction lost the background work needed to interpret later references");
    assert(taskContinuation(s, true).action == TaskContinuationAction.continueWork,
        "The rewrite stopped enforcing useful action on the current request");
    const current = s.contract.id;
    request(s, "Why is it still not switching immediately?");
    assert(s.contract.id == current && s.contract.currentIntent == "diagnosis");
    assert(taskContinuation(s, true).action == TaskContinuationAction.continueWork,
        "A why-question settled instead of investigating and resolving the failure");
    request(s, "continue");
    assert(s.contract.id == current && taskContinuation(s, true).action != TaskContinuationAction.settle);
    ChatSession restored; restoreActiveTaskState(restored, activeTaskStateJson(s));
    assert(restored.contract == s.contract && restored.objective == s.objective);
    s.taskStatus = "completed"; s.taskSteps = null; s.verificationStatus = "passed";
    request(s, "continue");
    assert(s.contract.id == current && s.contract.currentIntent == "conversation",
        "Continue resurrected an arbitrary unfinished archived task");
    request(s, "Thanks");
    assert(taskContinuation(s, true).action == TaskContinuationAction.settle);
    import auroraopencode.worktracking : readPlanText;
    assert(readPlanText(s, `{"task_id":"request-0","view":"details"}`).indexOf("exact") >= 0);
    import auroraopencode.goalmutation : restoreGoalTask;
    restoreGoalTask(s);
    assert(s.contract.goal == s.goal && s.taskSteps.length == 1 && s.taskSteps[0].id == "exact",
        "Explicit goal resume failed to restore its own archived work");

    ChatSession goal;
    request(goal, "Build the billing package, preserving its API and refund rules.");
    goal.goal = goal.objective; goal.goalStatus = "active";
    goal.contract.constraints = ["Refunds use the original UTC month"];
    goal.taskSteps = [TaskStep("Deliver invoices", "pending", "invoice")];
    const goalId = goal.contract.id;
    request(goal, "Change IDs to be unique per account and add CSV; preserve the original goal.");
    assert(goal.contract.id == goalId && goal.taskSteps.length == 1 && goal.contract.constraints.length == 1,
        "A requirement change discarded the active long-horizon goal");
    goal.taskStatus = "waiting_input";
    request(goal, "The customer rate is 0.0175.");
    assert(goal.contract.id == goalId && goal.taskStatus == "active");
    writeln("PASS current-request ownership; exact background preservation; pause, explanation, resume, restart, completed-continue, casual reply and active-goal amendment");
    return 0;
}
