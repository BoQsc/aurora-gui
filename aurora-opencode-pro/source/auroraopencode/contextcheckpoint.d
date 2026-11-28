module auroraopencode.contextcheckpoint;

import auroraopencode.core : ChatSession, ChatRequestMessage, activeMessagePath;
import auroraopencode.projectioncache : projectContext, RequestProjectionCache, ProjectionRevision;
import std.json : JSONValue;
import std.algorithm : canFind;

/// Shared request accounting: reasoning, tool envelopes and image token costs
/// must agree between the context meter and the checkpoint selector.
size_t requestMessageBytes(const(ChatRequestMessage)[] messages)
{
    size_t total;
    foreach (m; messages)
    {
        total += m.role.length + m.content.length + m.reasoningContent.length + m.toolCallId.length + 16;
        foreach (call; m.toolCalls) total += call.name.length + call.arguments.length + 16;
        total += m.images.length * 4 * 1400;
    }
    return total;
}

/// Optional retained memory must not crowd the fresh batch out of a context
/// that can otherwise hold it. Include its real envelope and control suffix.
size_t currentToolBatchStart(const ref ChatSession session, const(size_t)[] path)
{
    foreach_reverse (i; 0 .. path.length)
    {
        const ref message = session.messages[path[i]];
        if (message.role == "user" && !message.internal) return size_t.max;
        if (message.role == "assistant" && !message.failed && !message.toolCalls.length && message.content.length) return size_t.max;
        if (message.role == "assistant" && message.toolCalls.length)
        {
            bool data;
            foreach (call; message.toolCalls)
                if (!["update_plan", "update_subplan"].canFind(call.name)) data = true;
            if (data) return i;
        }
    }
    return size_t.max;
}

size_t currentToolBatchBytes(const ref ChatSession session, size_t imageLimit = 2,
    RequestProjectionCache cache = null, ProjectionRevision revision = ProjectionRevision.init)
{
    const path = activeMessagePath(session);
    const start = currentToolBatchStart(session, path);
    if (start == size_t.max) return 0;
    const before = start ? session.messages[path[start - 1]].id : "";
    return requestMessageBytes(projectContext(session, before, false, imageLimit, cache, revision));
}

/// Project once, then walk suffix costs once. Previously every candidate
/// rebuilt the full branch, image retirement index, and provider envelopes.
size_t compactionBoundary(const ref ChatSession session, const(size_t)[] path,
    size_t start, size_t tailBudget, size_t imageLimit = 2,
    RequestProjectionCache cache = null, ProjectionRevision revision = ProjectionRevision.init)
{
    size_t[] positions;
    const projected = projectContext(session, "", false, imageLimit, cache, revision, &positions);
    size_t[] costs = new size_t[](path.length + 1);
    foreach (i, message; projected)
        costs[positions[i]] += requestMessageBytes(projected[i .. i + 1]);
    foreach_reverse (i; 0 .. path.length) costs[i] += costs[i + 1];
    size_t boundary = path.length;
    foreach_reverse (i; start .. path.length)
    {
        const ref message = session.messages[path[i]];
        if (i + 1 == path.length && message.role != "tool") continue;
        if (message.role == "assistant" && message.toolCalls.length) continue;
        if (message.role == "tool" && i + 1 < path.length && session.messages[path[i + 1]].role == "tool") continue;
        if (costs[i + 1] > tailBudget) break;
        boundary = i;
    }
    return boundary;
}

bool completeCompactionResponse(bool cancelled, string finishReason)
{
    // A length-limited summary can end before the constraints or next action.
    // Empty finish reasons remain compatible with providers that only send DONE.
    return !cancelled && (finishReason == "stop" || finishReason.length == 0);
}

enum long compactionTimeoutMs = 45_000;
enum size_t compactionOutputLimit = 24_000;

/// A goal can be edited without appending a chat message. A late summary must
/// not install the former objective over that newer durable task.
string compactionTaskIdentity(const ref ChatSession session)
{
    JSONValue identity;
    identity["goal"] = session.goal;
    identity["goalStatus"] = session.goalStatus;
    identity["objective"] = session.objective;
    identity["task"] = session.contract.id;
    identity["constraints"] = JSONValue(session.contract.constraints);
    return identity.toString();
}
