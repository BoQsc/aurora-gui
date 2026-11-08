module auroraopencode.outputrecovery;

import auroraopencode.core : ChatMessage, ChatSession, activeMessagePath;
import auroraopencode.outputguard : outputFailurePrefix, outputRecoveryMarker;
import auroraopencode.goalmode : goalActive, goalCompletionAuditMarker;
import auroraopencode.taskcontinuation : taskContinuationMarker, taskAwaitingInput;
import std.string : startsWith, strip;

/// This bounds consecutive unusable provider responses, never useful task work.
enum maxOutputRecoveries = 3;

private bool usefulTool(string name)
{
    return name != "update_plan" && name != "update_subplan" &&
        name != "read_plan" && name != "task_blocker" && name != "request_input";
}

int outputRecoveryCount(const ref ChatSession session)
{
    int count;
    foreach (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if ((message.role == "user" && !message.internal) ||
            (message.role == "tool" && !message.failed && usefulTool(message.toolName))) count = 0;
        else if (message.internal && message.content.startsWith(outputRecoveryMarker)) ++count;
    }
    return count;
}

/// Goal and task continuation audits are not provider-format failures. The
/// continuation counter that triggered them is still in the transcript, so a
/// recovery request would be rejected again and append another failure bubble
/// without new evidence. Report one failure and let the user continue.
bool auditStallIssue(string issue)
{
    return issue == "goal_audit_stalled" || issue == "task_audit_stalled";
}

/// A recovery request is useful only for provider output that can change on a
/// resend. Goal/task audits keep the continuation counter that produced them,
/// so they stop after one report instead of repeating the same failure.
bool outputRecoveryAllowed(string issue, bool exhausted, bool toolsEnabled,
    bool stopped, bool aborting, bool explanationOnly)
{
    return !auditStallIssue(issue) && !exhausted && toolsEnabled &&
        !stopped && !aborting && !explanationOnly;
}

/// After an audit stop, automatic continuation must wait for a real user
/// message. Otherwise the next automatic turn sees the same unfinished task
/// state and produces another audit failure.
bool suppressAuditContinuation(bool auditStalled, bool automaticContinuation)
{
    return auditStalled && automaticContinuation;
}

/// A surfaced output failure ends its audit interval. Without this boundary a
/// later retry sees the same stale continuation prompts and is rejected again
/// before the provider has a chance to act.
private bool endsAuditInterval(const ref ChatMessage message)
{
    return message.role == "assistant" && message.failed &&
        message.error.startsWith(outputFailurePrefix);
}

bool answerReplayed(const ref ChatSession session)
{
    const path = activeMessagePath(session);
    if (path.length < 2) return false;
    const ref current = session.messages[path[$ - 1]];
    if (current.role != "assistant" || current.toolCalls.length || !current.content.strip.length)
        return false;
    foreach_reverse (index; path[0 .. $ - 1])
    {
        const ref previous = session.messages[index];
        if ((previous.role == "user" && !previous.internal) || previous.role == "tool") return false;
        if (previous.role != "assistant" || previous.failed) continue;
        if (previous.toolCalls.length) return false;
        if (goalActive(session) && current.content.strip == previous.content.strip) return true;
        return previous.content.length >= 512 && current.content.startsWith(previous.content) &&
            current.content.length - previous.content.length <= previous.content.length / 5;
    }
    return false;
}

/// A goal audit must produce an action or completion call. Changing the prose
/// alone cannot make an endless succession of final answers useful.
bool goalAuditStalled(const ref ChatSession session)
{
    if (!goalActive(session) || taskAwaitingInput(session)) return false;
    int audits;
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (endsAuditInterval(message)) break;
        if ((message.role == "user" && !message.internal) ||
            (message.role == "tool" && usefulTool(message.toolName) &&
                !message.content.startsWith("Tool call skipped:"))) break;
        if (message.internal && message.content.startsWith("Persistent goal continuation:")) ++audits;
    }
    return audits >= 1;
}

/// A completion audit already sent in the current interval. It keeps the
/// repair to one turn: reporting the same prose again is a real stall.
bool goalCompletionAuditPending(const ref ChatSession session)
{
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (endsAuditInterval(message)) break;
        if ((message.role == "user" && !message.internal) ||
            (message.role == "tool" && usefulTool(message.toolName) &&
                !message.content.startsWith("Tool call skipped:"))) break;
        if (message.internal && message.content.startsWith(goalCompletionAuditMarker))
            return true;
    }
    return false;
}

/// A goal continuation that returned prose only is repaired by one completion
/// audit turn first: the goal may already be finished and merely unrecorded, and
/// pausing it there is the "partially completed with limitations and remaining
/// work" state users report. Only a second prose-only reply ends the goal.
bool goalCompletionAuditNeeded(const ref ChatSession session)
{
    return goalAuditStalled(session) && !goalCompletionAuditPending(session);
}

/// Bound consecutive no-action continuations, including short or varied prose.
/// Any real user instruction or nonadministrative tool attempt starts a new
/// interval. Productive long work has no global turn limit.
bool taskAuditStalled(const ref ChatSession session)
{
    if (taskAwaitingInput(session)) return false;
    int continuations;
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (endsAuditInterval(message)) break;
        if ((message.role == "user" && !message.internal) ||
            (message.role == "tool" && usefulTool(message.toolName))) break;
        if (message.internal && message.content.startsWith(taskContinuationMarker)) ++continuations;
    }
    return continuations >= 1;
}
