module auroraopencode.events;

import auroraopencode.core : ChatImageAttachment, OpenCodeToolCall;

/// Correlated messages shared by provider, execution and presentation owners.
enum ChatStartResult { accepted, busy, closed, failed, capacity }

enum OpenCodeEventKind
{
    chatBegin,   // assistant reply started (text = "")
    delta,       // streaming fragment (text = fragment, reasoning = kind)
    usage,       // live usage update while streaming (token fields populated)
    toolCallDelta, // assistant is generating tool arguments (toolCalls = partial)
    toolCalls,   // assistant finished requesting tools (text = content, toolCalls set)
    toolResult,  // a tool execution finished (text = output, toolName/toolCallId set)
    done,        // assistant reply finished (text = full content)
    error,       // request failed (text = message)
    models,      // model list refreshed (modelIds = ids)
    modelsError, // model discovery failed; must not fail an active chat
}

struct OpenCodeEvent
{
    OpenCodeEventKind kind;
    string text;
    bool reasoning;
    string[] modelIds;
    bool cancelled;
    int promptTokens;
    int completionTokens;
    int totalTokens;
    OpenCodeToolCall[] toolCalls;
    string toolName;
    string toolCallId;
    bool toolFailed;
    string verificationCheck;
    string verificationWorkspace;
    ulong verificationRevision;
    bool verificationPassed;
    int verificationExitCode = int.min;
    // A bounded output snapshot from an executing tool, not a terminal result.
    bool toolRunning;
    int diffAdditions;
    int diffDeletions;
    string diffText;
    long elapsedMs; // tool wall-clock duration in ms, carried to the UI
    // A local image-view tool carries pixels out-of-band from its textual tool
    // result. The UI inserts them only after all tool results in the batch.
    ChatImageAttachment[] images;
    // Opaque UI-supplied identity for routing late events. Zero is reserved for
    // standalone parser tests and callers that do not need request isolation.
    ulong requestId;
    // Provider terminal reason (`stop`, `length`, `max_tokens`, ...). Kept
    // separate from cancellation so the UI can offer a safe continuation.
    string finishReason;
    int[string] modelContextLimits;
    bool llamaCppServer;
    // Provider-reported prompt-cache accounting. DeepSeek reports explicit
    // hit/miss tokens, OpenAI reports cached prompt details, and Anthropic-style
    // gateways report cache reads/creation. Zero means unavailable or none.
    int cachedPromptTokens;
    int uncachedPromptTokens;
    string effectWorkspace;
    ulong effectRevision;
    bool workspaceChanged;
    // A decoder-detected output loop, distinct from a network/provider outage.
    string outputIssue;
}

