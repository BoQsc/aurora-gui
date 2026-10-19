module agent_workflow_contracts;

import auroraopencode.core;
import auroraopencode.taskflow;
import auroraopencode.taskcontinuation;
import auroraopencode.requestintent : requestIntent, RequestIntent;
import std.conv : to;
import std.json : JSONValue, parseJSON;
import std.stdio : writeln;

void append(ref ChatSession session, string role, string content, string tool = "")
{
    ChatMessage message;
    message.id = "m" ~ to!string(session.messages.length);
    message.parentId = session.activeLeafId;
    message.role = role;
    message.content = content;
    message.toolName = tool;
    message.toolCallId = tool.length ? "call-" ~ message.id : "";
    session.messages ~= message;
    session.activeLeafId = message.id;
    if (role == "user") acceptTaskRequest(session, content, message.id);
}

int main()
{
    foreach (request; ["Plan how to fix the parser without changing files.", "Please plan the migration.",
            "Help me plan the refactor."])
        assert(requestIntent(request) == RequestIntent.analysis, request);
    assert(requestIntent("Plan the migration, then implement it.") == RequestIntent.implementation);
    writeln("PASS explicit planning requests enter analysis; combined plan-and-implement requests retain action intent");

    ChatSession session;
    append(session, "user", "Fix the parser.");
    append(session, "tool", "Parser updated", "edit");
    assert(taskHasActionEvidence(session));
    session.verificationStatus = "required";
    append(session, "user", "What remains?");
    assert(taskHasActionEvidence(session), "A status question hid the task's existing edit");
    assert(taskContinuation(session, true).action == TaskContinuationAction.settle);
    append(session, "user", "Continue the task.");
    assert(taskHasActionEvidence(session), "Resuming hid the edit and demanded another mutation");
    session.verificationStatus = "passed";
    assert(!unfinishedTask(session), "Completed edits and checks still demanded another edit after resume");
    const finishedLeaf = session.activeLeafId;
    append(session, "user", "Fix the remaining Unicode parser case.");
    assert(!taskHasActionEvidence(session), "A new corrective request reused an earlier edit");
    append(session, "tool", "Unicode case updated", "edit");
    assert(taskHasActionEvidence(session));
    session.activeLeafId = finishedLeaf;
    assert(taskHasActionEvidence(session), "A different branch changed the original task's evidence");
    ChatSession restored;
    restored.messages = session.messages.dup;
    restored.activeLeafId = session.activeLeafId;
    restoreActiveTaskState(restored, activeTaskStateJson(session));
    assert(taskHasActionEvidence(restored), "Resumed evidence did not survive task-state restoration");
    append(session, "user", "New task: fix the serializer.");
    assert(!taskHasActionEvidence(session), "Another task inherited the parser edit");
    writeln("PASS resume/questions retain evidence; corrections, new tasks and branches keep their boundaries");

    ChatSession research;
    append(research, "user", "Investigate the parser failure.");
    research.taskSteps = [TaskStep("Investigate failure", "in_progress", "inspect", "research", "Inspect parser source")];
    append(research, "tool", "Current plan: investigate failure", "read_plan");
    const finish = `{"plan":[{"id":"inspect","step":"Investigate failure","status":"completed"}]}`;
    assert(planUpdateError(research, finish, research.taskSteps).length,
        "Reading the plan certified research without inspecting any source");
    assert(!taskHasActionEvidence(research, true));
    append(research, "tool", "Parser source and failing branch", "read");
    assert(!planUpdateError(research, finish, research.taskSteps).length);
    assert(taskHasActionEvidence(research, true));
    writeln("PASS plan inspection cannot certify research; actual source inspection can");

    ChatSession child;
    append(child, "user", "Fix the parser.");
    append(child, "tool", "Parser changed", "edit");
    child.taskStatus = "completed";
    auto state = parseJSON(activeTaskStateJson(child));
    state["taskActionEvidence"] = true;
    ChatMessage receipt;
    receipt.internal = true;
    receipt.failed = true;
    receipt.taskStateJson = state.toString();
    assert(!evidenceKind(receipt).length, "A failed handoff certified an action");
    receipt.failed = false;
    child.verificationStatus = "failed";
    state = parseJSON(activeTaskStateJson(child));
    state["taskActionEvidence"] = true;
    receipt.taskStateJson = state.toString();
    assert(!evidenceKind(receipt).length, "A handoff with failed verification certified completion");
    child.verificationStatus = "passed";
    state = parseJSON(activeTaskStateJson(child));
    state["taskActionEvidence"] = true;
    receipt.taskStateJson = state.toString();
    assert(evidenceKind(receipt) == "action");
    writeln("PASS failed handoffs/checks supply no completion evidence; a successful receipt remains usable");
    return 0;
}
