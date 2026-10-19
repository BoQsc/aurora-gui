module auroraopencode.agentresult;

import auroraopencode.core : ChatSession, ChatMessage, activeTaskStateJson;
import auroraopencode.taskflow : taskMessagePath, taskActionPath, taskInstruction,
    taskHasActionEvidence, taskInvestigation;
import auroraopencode.taskcontinuation : unfinishedTask, taskAwaitingInput;
import std.json : parseJSON;

/// Only the selected branch's latest instruction can supply this turn's reply.
private string resultSummary(const ref ChatSession child)
{
    foreach_reverse (index; taskMessagePath(child))
    {
        const ref message = child.messages[index];
        if (taskInstruction(child, message)) break;
        if (message.role == "assistant" && !message.internal && message.failed) return "";
        if (message.role == "assistant" && !message.internal && !message.failed && message.content.length)
            return message.content;
    }
    return "";
}

/// Build the parent's durable handoff without promoting an incomplete child or
/// borrowing a reply/effect from an earlier assignment or another branch.
ChatMessage subagentResult(ref ChatSession child)
{
    const summary = resultSummary(child);
    const interrupted = child.turnStatus == "interrupted" || child.turnStatus == "failed";
    if (child.taskStatus == "waiting_input" && !taskAwaitingInput(child))
    { child.taskStatus = "active"; child.contract.blocker = ""; }
    if (child.taskStatus != "blocked" && child.taskStatus != "waiting_input" && child.taskStatus != "failed")
        child.taskStatus = interrupted || !summary.length || unfinishedTask(child) || taskInvestigation(child)
            ? "active" : "completed";

    ChatMessage note;
    note.role = "user";
    note.internal = true;
    note.authorId = child.subagentId;
    note.failed = child.taskStatus != "completed";
    foreach (index; taskActionPath(child))
        if (child.messages[index].workspaceChanged && !child.messages[index].failed)
            note.workspaceChanged = true;
    auto receipt = parseJSON(activeTaskStateJson(child));
    receipt["taskActionEvidence"] = !note.failed && taskHasActionEvidence(child, child.contract.intent == "analysis");
    note.taskStateJson = receipt.toString();
    note.content = "Subagent \"" ~ child.title ~ "\" (" ~ child.subagentId ~
        ") reported " ~ child.taskStatus ~ "." ~ (summary.length ? "\n" ~ summary : " (no output)");
    return note;
}
