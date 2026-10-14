module auroraopencode.controlhistory;

import auroraopencode.core : ChatSession, ChatMessage, activeMessagePath;
import auroraopencode.taskcontinuation : taskContinuationMarker;
import std.string : startsWith;

enum durableTaskCheckpointPrefix =
    "Durable task-state checkpoint. This supersedes earlier task-state " ~
    "checkpoints; keep the transcript and tool results in their original order.";
enum controlHistoryBoundary = "Internal control-history boundary.\n";
enum controlHistoryLimit = 32;

bool supersededControlState(const ref ChatMessage message)
{
    return message.internal && message.images.length == 0 &&
        (message.content.startsWith(durableTaskCheckpointPrefix) ||
         message.content.startsWith(taskContinuationMarker) ||
         message.content.startsWith("Progress guidance:"));
}

/// Compact only at a new human turn, and only after a bounded batch of control
/// messages. Live tool rounds retain an identical prefix for provider caching.
bool controlHistoryCompactionNeeded(const ref ChatSession session)
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
    if (!humanAfterBoundary || count < controlHistoryLimit) return false;
    // A boundary belongs immediately after a real request, before any of that
    // request's tools/control state. Never change projection mid-turn.
    const path = activeMessagePath(session);
    return path.length && session.messages[path[$ - 1]].role == "user" &&
        !session.messages[path[$ - 1]].internal;
}
