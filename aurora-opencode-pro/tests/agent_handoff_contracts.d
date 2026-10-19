module agent_handoff_contracts;

import auroraopencode.core;
import auroraopencode.agentresult : subagentResult;
import auroraopencode.taskflow : acceptTaskRequest, taskHasActionEvidence, evidenceKind;
import std.conv : to;
import std.json : parseJSON;
import std.stdio : writeln;
import std.string : indexOf;

void append(ref ChatSession child, string role, string text, string tool = "", bool failed = false, bool changed = false)
{
    ChatMessage message;
    message.id = "m" ~ to!string(child.messages.length);
    message.parentId = child.activeLeafId;
    message.role = role; message.content = text; message.toolName = tool;
    message.failed = failed; message.workspaceChanged = changed;
    child.messages ~= message;
    child.activeLeafId = message.id;
}

void assign(ref ChatSession child, string task)
{
    append(child, "user", "Task from the orchestrator: " ~ task);
    child.messages[$ - 1].internal = true;
    child.messages[$ - 1].authorId = child.subagentId;
    child.turnStatus = "running";
    acceptTaskRequest(child, task, child.activeLeafId);
}

int main()
{
    ChatSession child;
    child.parentSessionId = "hub"; child.subagentId = "builder"; child.title = "Builder";
    assign(child, "Write the first document.");
    append(child, "tool", "First document written", "write", false, true);
    append(child, "assistant", "First document completed.");
    auto report = subagentResult(child);
    assert(!report.failed && report.workspaceChanged && child.taskStatus == "completed");
    assert(evidenceKind(report) == "action");
    const firstSummary = child.activeLeafId;
    append(child, "assistant", "An answer from a different branch.");
    child.activeLeafId = firstSummary;
    report = subagentResult(child);
    assert(report.content.indexOf("First document completed.") >= 0);
    assert(report.content.indexOf("different branch") < 0);
    writeln("PASS successful handoff uses the selected branch and carries current effects");

    assign(child, "Inspect the second document.");
    append(child, "tool", "Second document inspected", "read");
    append(child, "assistant", "Second document has a missing heading.");
    report = subagentResult(child);
    assert(!report.failed && !report.workspaceChanged);
    assert(evidenceKind(report) == "research");
    assert(report.content.indexOf("First document completed.") < 0);
    writeln("PASS a reused research agent cannot inherit an earlier assignment's mutation");

    assign(child, "Fix the missing heading.");
    append(child, "assistant", "Preparing the heading correction.");
    append(child, "tool", "Edit failed", "edit", true);
    append(child, "assistant", "Provider failure after a partial answer", "", true);
    report = subagentResult(child);
    assert(report.failed && child.taskStatus == "active" && !report.workspaceChanged);
    assert(report.content.indexOf("(no output)") >= 0);
    assert(report.content.indexOf("Second document has") < 0);
    assert(!evidenceKind(report).length);
    writeln("PASS failure/empty output cannot certify completion or replay an older answer");

    append(child, "tool", "Heading written", "edit", false, true);
    append(child, "assistant", "Heading saved; checking formatting.");
    child.verificationStatus = "failed";
    report = subagentResult(child);
    assert(report.failed && child.taskStatus == "active");
    assert(report.content.indexOf("checking formatting") >= 0 && !evidenceKind(report).length);
    child.verificationStatus = "passed";
    child.taskSteps = [TaskStep("Check heading", "pending", "heading", "verify")];
    report = subagentResult(child);
    assert(report.failed && child.taskStatus == "active");
    child.taskSteps = null;
    child.turnStatus = "interrupted";
    report = subagentResult(child);
    assert(report.failed && child.taskStatus == "active");
    child.turnStatus = "running";
    report = subagentResult(child);
    assert(!report.failed && child.taskStatus == "completed");
    writeln("PASS failed checks, open outcomes and interruption remain incomplete");

    assign(child, "Fix the document's encoding.");
    append(child, "tool", "Encoding changed", "edit", false, true);
    append(child, "assistant", "Encoding corrected.");
    assign(child, "Fix the remaining Unicode case.");
    assert(!taskHasActionEvidence(child), "An internal corrective assignment reused an earlier edit");
    report = subagentResult(child);
    assert(report.failed && !report.workspaceChanged && report.content.indexOf("Encoding corrected.") < 0);
    append(child, "tool", "Unicode case changed", "edit", false, true);
    append(child, "assistant", "Unicode case corrected.");
    report = subagentResult(child);
    assert(!report.failed && report.workspaceChanged);
    assert(parseJSON(report.taskStateJson)["taskActionEvidence"].boolean);
    writeln("PASS corrective assignments require fresh action and a fresh reply");
    return 0;
}
