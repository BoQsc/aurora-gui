module auroraopencode.toolprotocol;

import auroraopencode.core : ChatMessage, OpenCodeToolCall;
import std.conv : to;

/// Normalize before recording or dispatching a batch. Both the provider history
/// and the result ledger then use the same unambiguous identifiers, including
/// when a provider reuses an identifier from an earlier round.
public OpenCodeToolCall[] normalizeToolCalls(const(OpenCodeToolCall)[] incoming,
    const(ChatMessage)[] history, string assistantId, ulong requestId)
{
    bool[string] reserved, used;
    foreach (message; history)
    {
        if (message.id == assistantId && assistantId.length) continue;
        foreach (call; message.toolCalls)
            if (call.id.length) used[call.id] = true;
        if (message.toolCallId.length) used[message.toolCallId] = true;
    }
    // Reserve later incoming identifiers too: a generated identifier must not
    // steal a legitimate identifier from a later call in this same batch.
    foreach (call; incoming)
        if (call.id.length) reserved[call.id] = true;
    auto calls = incoming.dup;
    foreach (index, ref call; calls)
    {
        if (!call.id.length || call.id in used)
        {
            const prefix = "call_aurora_" ~ to!string(requestId) ~ "_" ~ to!string(index);
            call.id = prefix;
            size_t suffix;
            while (call.id in reserved || call.id in used)
                call.id = prefix ~ "_" ~ to!string(++suffix);
        }
        used[call.id] = true;
    }
    return calls;
}
