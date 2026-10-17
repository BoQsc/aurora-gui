module plan_consistency_contracts;

import auroraopencode.core;
import auroraopencode.taskflow;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln;
import std.string : indexOf;

void append(ref ChatSession s, string id, string role, string text, string tool = "")
{
    ChatMessage m;
    m.id = id; m.parentId = s.activeLeafId; m.role = role; m.content = text;
    m.toolName = tool; m.toolCallId = tool.length ? id : "";
    s.messages ~= m; s.activeLeafId = id;
}

int main()
{
    ChatSession s;
    append(s, "request", "user", "Implement two document outcomes.");
    acceptTaskRequest(s, s.messages[0].content, "request");
    append(s, "inspect", "tool", "Existing documents inspected", "read");
    append(s, "first-write", "tool", "First document saved", "write");
    const initial = `{"plan":[{"id":"a","step":"First outcome","status":"in_progress","kind":"edit","done":"First document saved"},{"id":"b","step":"Second outcome","status":"pending","kind":"edit","done":"Second document saved"}]}`;
    auto base = parseJSON(initial);
    assert(!planUpdateError(s, initial, null).length);
    s.taskSteps = normalizedPlan(s, base["plan"], null);
    s.contract.work = workContextForPlan(s, s.taskSteps);

    auto extra = parseJSON(initial);
    extra["plan"].array ~= parseJSON(`{"id":"c","step":"Compatibility outcome","status":"pending"}`);
    assert(planUpdateError(s, extra.toString(), s.taskSteps).indexOf("explanation") >= 0);
    extra["explanation"] = "Existing input requires a compatibility outcome to fulfill the requested documents.";
    assert(!planUpdateError(s, extra.toString(), s.taskSteps).length);
    auto extended = normalizedPlan(s, extra["plan"], s.taskSteps);
    rememberPlanRevision(s, extra, s.taskSteps, extended);
    assert(s.contract.decisions.length == 1 && s.contract.decisions[0].indexOf("compatibility") >= 0);
    rememberPlanRevision(s, extra, s.taskSteps, extended);
    assert(s.contract.decisions.length == 1, "The same rationale was duplicated");

    auto jump = parseJSON(initial);
    jump["plan"][0]["status"] = "pending";
    jump["plan"][1]["status"] = "in_progress";
    assert(planUpdateError(s, jump.toString(), s.taskSteps).length);
    jump["explanation"] = "The second document establishes compatibility needed to finish the first.";
    assert(!planUpdateError(s, jump.toString(), s.taskSteps).length);
    auto paused = normalizedPlan(s, jump["plan"], s.taskSteps);
    const position = workContextForPlan(s, paused, jump);
    assert(position.stepId == "b" && position.returnTo == "First outcome");
    assert(position.detourReason == jump["explanation"].str && position.doneWhen == "Second document saved");
    assert(paused[0].status == "pending", "An unfinished outcome was falsely ticked");
    auto explicitDetour = parseJSON(jump.toString());
    explicitDetour["work_context"] = parseJSON(`{"detour_reason":"Compatibility investigation","done_when":"Second outcome saved"}`);
    assert(workContextForPlan(s, paused, explicitDetour).returnTo == "First outcome",
        "A detour without an explicit return point returned to itself");
    auto detoured = snapshotChatSessions([s])[0];
    detoured.taskSteps = paused.dup; detoured.contract.work = position;
    rememberPlanRevision(detoured, jump, s.taskSteps, paused);
    ChatSession restored; restoreActiveTaskState(restored, activeTaskStateJson(detoured));
    assert(restored.contract.work == position && restored.contract.decisions == detoured.contract.decisions);

    auto forward = parseJSON(initial);
    forward["plan"][0]["status"] = "completed";
    forward["plan"][0]["evidence"] = JSONValue(["first-write"]);
    forward["plan"][1]["status"] = "in_progress";
    assert(!planUpdateError(s, forward.toString(), s.taskSteps).length,
        "Normal evidence-backed advancement demanded an explanation");
    auto completed = normalizedPlan(s, forward["plan"], s.taskSteps);

    auto reopen = parseJSON(forward.toString());
    reopen["plan"][0]["status"] = "pending";
    assert(planUpdateError(s, reopen.toString(), completed).length);
    reopen["explanation"] = "The second document exposed a defect in the first document.";
    assert(planUpdateError(s, reopen.toString(), completed).indexOf("reopen_steps") >= 0);
    reopen["reopen_steps"] = JSONValue(["a"]);
    assert(!planUpdateError(s, reopen.toString(), completed).length);
    assert(!normalizedPlan(s, reopen["plan"], completed)[0].evidence.length,
        "Reopened work kept its previous completion receipt as current evidence");
    reopen["reopen_steps"] = JSONValue(["unknown"]);
    assert(planUpdateError(s, reopen.toString(), completed).length);

    auto goalpost = parseJSON(forward.toString());
    goalpost["plan"][0]["done"] = "An additional requirement also works";
    goalpost["explanation"] = "A new requirement was discovered.";
    assert(planUpdateError(s, goalpost.toString(), completed).indexOf("completed acceptance") >= 0);
    auto refinement = parseJSON(initial);
    refinement["plan"][0]["step"] = "First outcome with a clearer title";
    assert(!planUpdateError(s, refinement.toString(), s.taskSteps).length,
        "A title refinement was mistaken for new work");
    refinement["plan"][0]["done"] = "Clarified acceptance condition";
    assert(planUpdateError(s, refinement.toString(), s.taskSteps).length);
    refinement["explanation"] = "Inspection clarified how the requested document is accepted.";
    assert(!planUpdateError(s, refinement.toString(), s.taskSteps).length);

    auto reorder = parseJSON(initial);
    auto first = reorder["plan"][0]; reorder["plan"][0] = reorder["plan"][1]; reorder["plan"][1] = first;
    assert(planUpdateError(s, reorder.toString(), s.taskSteps).length);
    reorder["explanation"] = "Dependency inspection established a better order.";
    assert(!planUpdateError(s, reorder.toString(), s.taskSteps).length);
    auto duplicate = parseJSON(initial);
    duplicate["plan"].array ~= parseJSON(`{"id":"new-a","step":"First outcome","status":"pending"}`);
    duplicate["explanation"] = "Adding the same thing under a new identity.";
    assert(planUpdateError(s, duplicate.toString(), s.taskSteps).indexOf("duplicate plan outcome") >= 0);
    auto replacedId = parseJSON(initial);
    replacedId["plan"][0]["id"] = "different-a";
    replacedId["explanation"] = "Changed the ID without changing the outcome.";
    assert(planUpdateError(s, replacedId.toString(), s.taskSteps).indexOf("unfinished outcome omitted") >= 0);
    writeln("PASS justified additions/reordering, stable IDs, explained detours and return points, ordinary advancement, explicit reopening, acceptance integrity, duplicates and durable rationale");
    return 0;
}
