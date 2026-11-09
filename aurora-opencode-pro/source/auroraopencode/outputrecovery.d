module auroraopencode.outputrecovery;

import auroraopencode.core : ChatMessage, ChatSession, activeMessagePath;
import auroraopencode.outputguard : outputFailurePrefix, outputRecoveryMarker;
import auroraopencode.goalmode : goalActive;
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

/// Progress audits are distinct from provider wire-format failures.
bool auditStallIssue(string issue)
{
    return issue == "goal_audit_stalled" || issue == "task_audit_stalled";
}

/// Both execution owners recover unfinished work within one shared budget.
bool outputRecoveryAllowed(string issue, bool exhausted, bool toolsEnabled,
    bool stopped, bool aborting, bool explanationOnly)
{
    return !exhausted && toolsEnabled &&
        !stopped && !aborting && !explanationOnly;
}

enum unfinishedTaskRecoveryInstruction = " The reply claimed completion but recorded work or verification remains. " ~
    "Use the normal tools to close the specific gap in durable task state. Conventional direct test scripts/programs produce receipts; " ~
    "arbitrary custom checks can use run with check and inputs. For a finished persistent goal, call goal_complete with the existing evidence. " ~
    "Do not repeat passing checks, add scope, or ask the user to restart the task.";

/// Recovery starts a fresh audit interval while retaining the shared retry
/// count. Otherwise the same stale continuation immediately rejects a repair.
private bool endsAuditInterval(const ref ChatMessage message)
{
    return (message.role == "assistant" && message.failed &&
        message.error.startsWith(outputFailurePrefix)) ||
        (message.internal && message.content.startsWith(outputRecoveryMarker));
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

/// An unfinished task that returned prose instead of useful work.
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
