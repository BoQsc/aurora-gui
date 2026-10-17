module adaptive_work_contracts;
import auroraopencode.core;
import auroraopencode.taskflow;
import auroraopencode.taskcontinuation;
import auroraopencode.taskcontext;
import auroraopencode.worktracking;
import auroraopencode.runtime;
import std.json : JSONValue, parseJSON;
import std.string : indexOf;
import std.array : replicate;
import std.conv : to;
import std.stdio : writeln;

void update(ref ChatSession s, string text)
{
    const error = planUpdateError(s, text, s.taskSteps);
    assert(!error.length, error);
    auto root = parseJSON(text);
    if ("plan" in root.object) s.taskSteps = normalizedPlan(s, root["plan"], s.taskSteps);
    s.contract.workItems = normalizedWorkItems(s, root, s.taskSteps);
    s.contract.work = workContextForPlan(s, s.taskSteps, root);
}
void tool(ref ChatSession s, string id, string name)
{
    ChatMessage m; m.role = "tool"; m.id = id; m.toolCallId = id; m.toolName = name;
    m.parentId = s.activeLeafId; s.messages ~= m; s.activeLeafId = id;
}
int main()
{
    ChatSession s;
    ChatMessage m; m.role = "user"; m.id = "request"; m.content = "Implement the document compatibility fix.";
    s.messages ~= m; s.activeLeafId = m.id; acceptTaskRequest(s, m.content, m.id);
    const identity = s.contract.id;
    update(s, `{"work_items":[{"id":"first","step":"Write main document","kind":"edit","status":"in_progress"}],"work_context":{"action":"Write main document","next_action":"Review legacy compatibility"}}`);
    assert(s.taskSteps.length == 0 && requiredWorkRemaining(s) && unfinishedTask(s));
    assert(s.contract.work.action == "Write main document");
    tool(s, "write-main", "write");
    update(s, `{"work_items":[{"id":"first","status":"completed","evidence":["write-main"]},{"id":"legacy","step":"Write compatibility document","origin":"discovery","reason":"Legacy format is required by the requested output","status":"in_progress","done":"Compatibility document saved"},{"id":"later","step":"Add optional examples","required":false,"status":"deferred","reason":"Examples are beyond the requested fix"}],"work_context":{"action":"Write compatibility document","detour_reason":"Legacy format discovered","done_when":"Compatibility document saved"}}`);
    assert(s.contract.id == identity && s.contract.workItems.length == 3);
    assert(s.contract.work.returnTo == "Write main document");
    assert(taskContinuation(s, true).action == TaskContinuationAction.continueWork);
    assert(s.contract.work.workItemId == "legacy");
    auto automatic = snapshotChatSessions([s])[0];
    automatic.contract.work.action = "Old action";
    automatic.contract.work.workItemId = "first";
    assert(workContextForPlan(automatic, automatic.taskSteps).action == "Write compatibility document");
    const before = activeTaskStateJson(s);
    auto detail = parseJSON(readPlanText(s, `{"view":"details","limit":1}`));
    assert(detail["total"].integer == 2 && detail["nextOffset"].integer == 1);
    assert(detail["items"][0]["id"].str == "legacy");
    const next = parseJSON(readPlanText(s, `{"view":"details","offset":1,"limit":1}`));
    assert(next["items"][0]["id"].str == "later");
    assert(readPlanText(s, `{}`).indexOf("legacy") >= 0);
    assert(activeTaskStateJson(s) == before, "Reading the plan changed its state");
    update(s, `{"work_items":[{"id":"later","reason":"Optional follow-up, outside current acceptance"}]}`);
    assert(s.contract.workItems[0].step.status == "completed" && s.contract.workItems[1].step.id == "legacy");
    assert(s.contract.workItems.length == 3 && s.contract.work.detourReason.length);
    assert(planUpdateError(s, `{"work_items":[{"id":"legacy","status":"completed","evidence":["missing"]}]}`, s.taskSteps).length);
    assert(planUpdateError(s, `{"work_items":[{"id":"legacy","required":false,"reason":"Skip"}]}`, s.taskSteps).length);
    assert(planUpdateError(s, `{"work_items":[{"id":"legacy","status":"deferred"}]}`, s.taskSteps).length);
    tool(s, "write-legacy", "write");
    update(s, `{"work_items":[{"id":"legacy","status":"completed","evidence":["write-legacy"]}],"work_context":null}`);
    assert(!requiredWorkRemaining(s) && !unfinishedTask(s));
    assert(!s.contract.work.detourReason.length && s.contract.workItems[2].step.status == "deferred");
    const snapshot = activeTaskStateJson(s);
    ChatSession restored; restoreActiveTaskState(restored, snapshot);
    assert(restored.contract.workItems == s.contract.workItems);
    auto copies = snapshotChatSessions([s]);
    copies[0].contract.workItems[0].step.evidence[0] = "changed";
    assert(s.contract.workItems[0].step.evidence[0] == "write-main", "Snapshot shared mutable work data");
    AgentRuntimeEvent event; event.kind = AgentEventKind.threadUpdated; event.threadId = "adaptive"; event.payloadJson = snapshot;
    auto projected = projectAgentRuntimeEvents([event]);
    assert(projected[0].contract.workItems == s.contract.workItems);
    s.messages[$ - 1].taskStateJson = snapshot;
    const leaf = s.activeLeafId;
    acceptTaskRequest(s, "New task: implement another component.", "new");
    assert(!s.contract.workItems.length && s.taskArchive.length == 1);
    s.activeLeafId = leaf; restoreBranchTask(s);
    assert(s.contract.id == identity && s.contract.workItems.length == 3);

    ChatSession parent;
    parent.contract.id = "parent"; parent.objective = "Deliver the project";
    parent.taskSteps = [TaskStep("Implement outcome", "in_progress", "p", "edit", "Outcome works")];
    update(parent, `{"work_items":[{"id":"child","step":"Fix required compatibility","origin":"recovery","reason":"The first attempt exposed a required mismatch","kind":"edit"}]}`);
    assert(parent.contract.workItems[0].parentId == "p");
    tool(parent, "parent-proof", "write");
    const completeParent = `{"plan":[{"id":"p","step":"Implement outcome","status":"completed","evidence":["parent-proof"]}]}`;
    assert(planUpdateError(parent, completeParent, parent.taskSteps).indexOf("required work") >= 0);
    update(parent, `{"work_items":[{"id":"child","status":"completed","evidence":["parent-proof"]}]}`);
    assert(!planUpdateError(parent, completeParent, parent.taskSteps).length);
    assert(parseJSON(readPlanText(parent, `{"view":"details","collection":"outcomes"}`))["items"][0]["done"].str == "Outcome works");
    assert(planUpdateError(parent, `{"work_items":[{"step":"Lost child","parent_id":"absent"}]}`, parent.taskSteps).length);
    assert(readPlanText(parent, `{"view":"details","limit":0}`).indexOf("Error:") == 0);
    auto large = snapshotChatSessions([parent])[0];
    large.contract.workItems = null;
    foreach (i; 0 .. 100)
        large.contract.workItems ~= TaskWorkItem(TaskStep("Required action " ~ to!string(i), "pending", "large-" ~ to!string(i), "edit", "acceptance ".replicate(100)), "p");
    large.contract.workItems ~= TaskWorkItem(TaskStep("Current active detail", "in_progress", "current-detail", "verify", "Current test passes"), "p");
    large.contract.work = workContextForPlan(large, large.taskSteps);
    assert(workTracksPhase(large, 2));
    const context = taskContext(large, "", true, 6000);
    assert(context.length <= 6000 && context.indexOf("Current active detail") >= 0);
    assert(taskContinuation(large, true).remaining.length < 7000, "Long action lists overflowed continuation guidance");
    const tail = parseJSON(readPlanText(large, `{"view":"details","parent_id":"p","offset":96,"limit":12}`));
    assert(tail["total"].integer == 101 && tail["items"].array.length == 5);
    assert(tail["items"][4]["id"].str == "current-detail");
    writeln("PASS incremental discoveries, recovery, follow-ups, evidence, parent accountability and scoped plan reads");
    writeln("PASS mini work without a full plan survives snapshots, compaction state, branch restore and journal replay");
    return 0;
}
