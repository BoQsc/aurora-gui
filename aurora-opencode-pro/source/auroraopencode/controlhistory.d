module auroraopencode.controlhistory;

import auroraopencode.core : ChatSession, ChatMessage, activeMessagePath;
import auroraopencode.taskcontinuation : taskContinuationMarker;
import std.string : startsWith;

enum durableTaskCheckpointPrefix =
    "Durable task-state checkpoint. This supersedes earlier task-state " ~
    "checkpoints; keep the transcript and tool results in their original order.";
enum controlHistoryBoundary = "Internal control-history boundary.\n";
enum progressGuidancePrefix = "Progress guidance: ";
enum controlHistoryLimit = 32;

/// Reusable control records that are explicitly superseded by a newer record
/// of the same kind. Only the newest of each kind needs to reach the provider;
/// keeping the whole streak sent thousands of stale copies.
enum ControlStateKind { none, checkpoint, continuation, progress }

ControlStateKind controlStateKind(const ref ChatMessage message)
{
    if (!message.internal || message.images.length) return ControlStateKind.none;
    if (message.content.startsWith(durableTaskCheckpointPrefix))
        return ControlStateKind.checkpoint;
    if (message.content.startsWith(taskContinuationMarker))
        return ControlStateKind.continuation;
    if (message.content.startsWith(progressGuidancePrefix) ||
        message.content.startsWith("Plan progress checkpoint: "))
        return ControlStateKind.progress;
    return ControlStateKind.none;
}

bool supersededControlState(const ref ChatMessage message)
{
    return controlStateKind(message) != ControlStateKind.none;
}

bool turnControlState(const ref ChatMessage message)
{
    if (!message.internal || message.images.length) return false;
    if (supersededControlState(message)) return true;
    foreach (prefix; ["Execution recovery:", "Execution obstacle:", "Persistent goal continuation:", "Continuation request:",
        "Proactive action checkpoint:", "Agent output recovery:",
        "Execution diagnosis checkpoint:", "Completion handoff requested:",
        "The user resumed the", "The user started the", "The user updated the"])
        if (message.content.startsWith(prefix)) return true;
    return false;
}

/// Compact only at a new human turn, and only after a bounded batch of control
/// messages. Live tool rounds retain an identical prefix for provider caching.
bool controlHistoryCompactionNeeded(const ref ChatSession session, bool constrainedWindow = false)
{
    size_t count;
    bool humanAfterBoundary;
    foreach (index; activeMessagePath(session))
    {
        const message = session.messages[index];
        if (message.internal && message.content.startsWith(controlHistoryBoundary))
        {
            count = 0;
            humanAfterBoundary = false;
        }
        else if (message.role == "user" && !message.internal)
            humanAfterBoundary = true;
        else if (supersededControlState(message)) ++count;
    }
    if (constrainedWindow) return count >= 2;
    if (!humanAfterBoundary || count < controlHistoryLimit) return false;
    // A boundary belongs immediately after a real request, before any of that
    // request's tools/control state. Never change projection mid-turn.
    const path = activeMessagePath(session);
    return path.length && session.messages[path[$ - 1]].role == "user" &&
        !session.messages[path[$ - 1]].internal;
}
