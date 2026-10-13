module auroraopencode.lifecyclediagnostics;

import auroraopencode.logging : logInfo;
import std.json : JSONValue, JSONType;
import std.algorithm : canFind;

/// Correlation metadata only: never persist prompts, arguments, reasoning,
/// result text, credentials or image payloads in the lifecycle record.
public void logAgentLifecycle(string threadId, ulong requestId, string stage,
    JSONValue details = JSONValue.init)
{
    JSONValue row;
    row["thread"] = threadId;
    row["request"] = cast(long) requestId;
    row["stage"] = stage;
    if (details.type == JSONType.object)
        foreach (key, value; details.object)
            if (allowedDetail(key)) row[key] = value;
    logInfo("agent-lifecycle " ~ row.toString());
}

private bool allowedDetail(string key)
{
    foreach (allowed; ["turn", "toolCallId", "tool", "workspace", "scope",
        "path", "phase", "elapsedMs", "queuedMs", "lastActivityMs",
        "files", "folders", "bytes", "matches", "candidateFiles",
        "processedFiles", "totalsKnown", "partial", "pendingTools",
        "outputBytes", "failed", "cancelled", "verificationPassed",
        "taskStatus", "turnStatus", "verificationStatus", "finishReason",
        "promptTokens", "completionTokens", "errorCategory", "outputIssue",
        "contextBudget", "messageBytes", "messageCount", "toolCount",
        "forceCompact", "checkpointCreated", "fallbackCompacted", "applied"])
        if (key == allowed) return true;
    return false;
}

public string lifecycleErrorCategory(string text)
{
    if (text.canFind("available context size") || text.canFind("context_length_exceeded"))
        return "context_overflow";
    if (text.canFind("12029")) return "connection_unavailable";
    if (text.canFind("12002")) return "timeout";
    if (text.canFind("Loading model")) return "model_loading";
    if (text.canFind("image input is not supported")) return "image_unsupported";
    if (text.canFind("output limit")) return "output_limit";
    return "request_error";
}
