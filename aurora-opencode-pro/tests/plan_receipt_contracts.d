module plan_receipt_contracts;

import auroraopencode.core;
import auroraopencode.taskflow;
import auroraopencode.worktracking;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln;
import std.string : indexOf;

void append(ref ChatSession s, string id, string tool, bool failed = false, string check = "", string receiptScope = "")
{
    ChatMessage m;
    m.id = id; m.parentId = s.activeLeafId;
    m.role = "tool"; m.toolName = tool; m.toolCallId = id;
    m.failed = failed; m.verificationCheck = check; m.verificationScope = receiptScope;
    if (tool == "run") m.toolArgs = check.length ? `{"program":"python","args":["-m","unittest"]}`
        : `{"program":"git","args":["status","--short"]}`;
    s.messages ~= m; s.activeLeafId = id;
}

int main()
{
    assert(inferredPlanKind("Run manifest, API-surface, consumer, and Unicode conformance checks") == "verify");
    assert(inferredPlanKind("Execute the regression suite") == "verify");
    assert(inferredPlanKind("Test whether the vendored tree is pristine or actively forked") == "research");
    assert(inferredPlanKind("Move modules and adapt generator/tests") == "edit");
    ChatSession s;
    ChatMessage user; user.id = "request"; user.role = "user"; user.content = "Implement and verify the package.";
    s.messages = [user]; s.activeLeafId = user.id;
    acceptTaskRequest(s, user.content, user.id);
    s.verificationScope = "checkout|generation|5";
    append(s, "edit", "write");
    const initial = `{"plan":[{"id":"verify","step":"Run the package conformance checks","status":"in_progress"}]}`;
    s.taskSteps = normalizedPlan(s, parseJSON(initial)["plan"], null);
    assert(s.taskSteps[0].kind == "verify");
    auto done = parseJSON(initial); done["plan"][0]["status"] = "completed";
    assert(planUpdateError(s, done.toString(), s.taskSteps).indexOf("accepted current check") >= 0,
        "A write receipt ticked a checking outcome");
    append(s, "check", "run", false, "unittest", s.verificationScope);
    done["plan"][0]["evidence"] = JSONValue(["edit", "check"]);
    assert(!planUpdateError(s, done.toString(), s.taskSteps).length,
        "A valid check was rejected because its context included an edit receipt");
    auto mixedEdit = parseJSON(`{"plan":[{"id":"change","step":"Write the package","kind":"edit","status":"completed","evidence":["edit","check"]}]}`);
    assert(!planUpdateError(s, mixedEdit.toString(), null).length,
        "An edit with supporting check evidence was rejected");
    done["plan"][0]["evidence"] = JSONValue(["made-up"]);
    auto error = planUpdateError(s, done.toString(), s.taskSteps);
    assert(error.indexOf("verify") >= 0 && error.indexOf("unknown tool-call ID") >= 0);
    append(s, "failed", "run", true, "unittest", s.verificationScope);
    done["plan"][0]["evidence"] = JSONValue(["failed", "check"]);
    assert(planUpdateError(s, done.toString(), s.taskSteps).indexOf("the tool failed") >= 0);
    done["plan"][0]["evidence"] = JSONValue(["edit"]);
    assert(planUpdateError(s, done.toString(), s.taskSteps).indexOf("Compatible recorded toolCallId receipts: check") >= 0,
        "Mismatch did not identify a usable recorded receipt");
    s.verificationScope = "checkout|generation|6";
    done["plan"][0]["evidence"] = JSONValue(["check"]);
    assert(planUpdateError(s, done.toString(), s.taskSteps).indexOf("No compatible receipt") >= 0,
        "A historical check certified current completion");
    append(s, "fresh", "run", false, "unittest", s.verificationScope);
    done["plan"][0]["evidence"] = JSONValue(["edit", "check", "fresh"]);
    assert(!planUpdateError(s, done.toString(), s.taskSteps).length);
    const retainedLeaf = s.activeLeafId;
    append(s, "other-branch", "run", false, "unittest", s.verificationScope);
    s.activeLeafId = retainedLeaf;
    done["plan"][0]["evidence"] = JSONValue(["other-branch"]);
    assert(planUpdateError(s, done.toString(), s.taskSteps).indexOf("outside the active task") >= 0);
    writeln("PASS verification classification, mixed receipts, failed/unknown/branch rejection, current source and repair guidance");

    // Existing plans written by the previous classifier must recover too.
    s.taskSteps[0].kind = "edit";
    done["plan"][0]["evidence"] = JSONValue(["fresh"]);
    const fixed = normalizedPlan(s, done["plan"], s.taskSteps);
    assert(fixed[0].kind == "verify" && !planUpdateError(s, done.toString(), s.taskSteps).length,
        "Legacy pending check remained misclassified or required a ceremonial explanation");
    auto completed = s.taskSteps.dup; completed[0].status = "completed";
    assert(normalizedPlan(s, done["plan"], completed)[0].kind == "edit",
        "A recorded historical completion was rewritten");
    auto explicitKind = parseJSON(initial); explicitKind["plan"][0]["kind"] = "research";
    assert(normalizedPlan(s, explicitKind["plan"], null)[0].kind == "research");

    auto work = parseJSON(`{"work_items":[{"id":"check-work","parent_id":"verify","step":"Run the package conformance checks","status":"completed","evidence":["edit","fresh"]}]}`);
    const parents = normalizedPlan(s, parseJSON(initial)["plan"], null);
    assert(!workItemsError(s, work, parents).length);
    s.contract.workItems = normalizedWorkItems(s, work, parents);
    assert(s.contract.workItems[0].step.kind == "verify");
    s.contract.workItems[0].step.status = "in_progress"; s.contract.workItems[0].step.kind = "edit";
    auto patch = parseJSON(`{"work_items":[{"id":"check-work","status":"completed","evidence":["fresh"]}]}`);
    assert(!workItemsError(s, patch, parents).length &&
        normalizedWorkItems(s, patch, parents)[0].step.kind == "verify");
    append(s, "observed", "run");
    s.contract.workItems = null;
    auto research = parseJSON(`{"plan":[{"id":"inspect","step":"Test whether the tree is pristine","status":"completed","evidence":["observed"]}]}`);
    assert(normalizedPlan(s, research["plan"], null)[0].kind == "research");
    assert(!planUpdateError(s, research.toString(), null).length,
        "A successful observational command was rejected as research");
    writeln("PASS existing pending plans, explicit categories, historical completions, incremental work records and observational commands");
    return 0;
}
