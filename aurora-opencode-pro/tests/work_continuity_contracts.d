module work_continuity_contracts;
import auroraopencode.core;
import auroraopencode.taskflow;
import auroraopencode.taskcontinuation;
import auroraopencode.taskpolicy;
import auroraopencode.runtime;
import std.json : JSONValue, parseJSON;
import std.conv : to;
import std.stdio : writeln;

void append(ref ChatSession s, string role, string content, string tool = "")
{
    ChatMessage m;
    m.id = "m" ~ to!string(s.messages.length); m.parentId = s.activeLeafId;
    m.role = role; m.content = content; m.toolName = tool;
    if (tool.length) m.toolCallId = "call-" ~ m.id;
    s.messages ~= m; s.activeLeafId = m.id;
}
void request(ref ChatSession s, string content)
{ append(s, "user", content); acceptTaskRequest(s, content, s.activeLeafId); }

int main()
{
    ChatSession s;
    request(s, "Implement the parser and retain regression tests.");
    const identity = s.contract.id;
    append(s, "tool", "Acceptance recorded", "write");
    s.taskSteps = [TaskStep("Define acceptance", "completed", "accept", "edit", "Acceptance saved", [s.messages[$-1].id]),
        TaskStep("Fix parser", "in_progress", "fix", "edit", "Invalid input rejected"),
        TaskStep("Verify parser", "pending", "verify", "verify", "Regression tests pass")];
    s.verificationStatus = "required";
    const detour = parseJSON(`{"work_context":{"action":"Migrate old parser records","next_action":"Run regression tests","detour_reason":"Old records have no stable IDs","done_when":"Legacy input keeps its IDs","return_to":"Fix parser edge cases"}}`);
    s.contract.work = workContextForPlan(s, s.taskSteps, detour);
    const position = s.contract.work;
    assert(position.stepId == "fix" && position.returnTo == "Fix parser edge cases");
    request(s, "Investigate why the old parser records fail. Do not edit anything.");
    assert(s.contract.id == identity && s.contract.intent == "implementation");
    assert(s.taskArchive.length == 0 && s.taskSteps.length == 3 && s.contract.work == position);
    assert(taskInvestigation(s) && taskContinuation(s, true).action == TaskContinuationAction.settle);
    assert(s.verificationStatus == "required");
    request(s, "Compare the rendering failure with the parser failure.");
    assert(requiredEvidence(s).length == 0, "A side investigation changed parent acceptance criteria");
    request(s, "Continue and finish the parser.");
    assert(!taskInvestigation(s) && s.contract.id == identity && s.contract.work == position);

    const partial = parseJSON(`{"plan":[{"id":"fix","step":"Fix parser edge cases","status":"in_progress"},{"id":"verify","step":"Verify parser","status":"pending"}]}`);
    assert(!planUpdateError(s, partial.toString(), s.taskSteps).length);
    auto updated = normalizedPlan(s, partial["plan"], s.taskSteps);
    assert(updated.length == 3 && updated[0] == s.taskSteps[0], "Completed outcome or proof was dropped");
    auto context = workContextForPlan(s, updated);
    assert(context == position, "Renaming the active outcome lost its detour return point");
    auto nested = [NestedPlan(2, [TaskStep("Migration acceptance", "pending", "child")])];
    auto reordered = [updated[2], updated[0], updated[1]];
    auto retained = retainNestedWork(updated, reordered, nested);
    assert(retained.length == 1 && retained[0].parentStep == 3 && retained[0].steps[0].id == "child");
    assert(workContextForPlan(s, reordered).stepId == "fix");
    auto cleared = workContextForPlan(s, updated, parseJSON(`{"work_context":null}`));
    assert(cleared.action == "Fix parser edge cases" && !cleared.detourReason.length && !cleared.returnTo.length);
    assert(cleared.nextAction == "Verify parser");
    auto changedNext = updated.dup;
    changedNext[2].status = "completed";
    assert(workContextForPlan(s, changedNext).nextAction == "", "Completed next action remained current");
    updated[1].status = "completed"; updated[2].status = "in_progress";
    auto advanced = workContextForPlan(s, updated);
    assert(advanced.stepId == "verify" && !advanced.detourReason.length);

    auto bad = parseJSON(partial.toString());
    bad["work_context"] = parseJSON(`{"action":"Migrate","detour_reason":"Required compatibility"}`);
    assert(planUpdateError(s, bad.toString(), s.taskSteps).length, "A detour had no exit condition");
    bad["work_context"] = parseJSON(`{"step_id":"other","action":"Migrate"}`);
    assert(planUpdateError(s, bad.toString(), s.taskSteps).length);
    s.taskSteps = normalizedPlan(s, partial["plan"], s.taskSteps);
    s.contract.work = position;
    const checkpoint = activeTaskStateJson(s);
    ChatSession restored; restoreActiveTaskState(restored, checkpoint);
    assert(restored.contract.work == position && restored.taskSteps == s.taskSteps);
    auto snapshot = snapshotChatSessions([s]);
    assert(snapshot[0].contract.work == position);
    AgentRuntimeEvent event; event.kind = AgentEventKind.threadUpdated; event.threadId = "continuity";
    event.payloadJson = checkpoint;
    auto replay = projectAgentRuntimeEvents([event]);
    assert(replay[0].contract.work == position);
    s.messages[$-1].taskStateJson = checkpoint;
    const originalLeaf = s.activeLeafId;
    request(s, "New task: implement another component.");
    assert(s.contract.id != identity && !s.contract.work.action.length && s.taskArchive.length == 1);
    s.activeLeafId = originalLeaf; restoreBranchTask(s);
    assert(s.contract.id == identity && s.contract.work == position);
    assert(s.taskSteps.length == 3);

    // Historical completed checks remain in the plan while fresh verification
    // still gates completion after a later mutation.
    ChatSession history;
    request(history, "Implement two stages and verify them.");
    append(history, "tool", "Tests passed", "run");
    history.messages[$-1].toolArgs = `{"program":"python","args":["-m","unittest"]}`;
    history.messages[$-1].verificationCheck = "unittest";
    history.taskSteps = [TaskStep("Verify first stage", "completed", "v1", "verify", "Tests pass", [history.messages[$-1].id]),
        TaskStep("Implement second stage", "in_progress", "s2", "edit", "Second stage works")];
    history.verificationStatus = "required";
    const remaining = `{"plan":[{"id":"s2","step":"Implement second stage","status":"in_progress"}]}`;
    assert(!planUpdateError(history, remaining, history.taskSteps).length);
    history.taskSteps = normalizedPlan(history, parseJSON(remaining)["plan"], history.taskSteps);
    assert(history.taskSteps.length == 2 && unfinishedTask(history));
    ChatSession legacy;
    append(legacy, "user", "Implement the legacy project.");
    const legacyAnchor = legacy.activeLeafId;
    legacy.objective = "Implement the legacy project."; legacy.taskStatus = "active";
    legacy.taskSteps = [TaskStep("Legacy implementation", "in_progress")];
    request(legacy, "Investigate the old format.");
    assert(taskInvestigation(legacy) && legacy.contract.startMessageId == legacyAnchor);
    writeln("PASS parent objective, investigations, completed outcomes, stable nested parents, detour position, branch restore, replay and verification gates");
    return 0;
}
