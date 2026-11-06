module auroraopencode.contextpolicy;

import auroraopencode.core : ChatSession, ChatRequestMessage, OpenCodeToolDef, activeMessagePath;
import auroraopencode.contextcheckpoint : requestMessageBytes, compactionBoundary;
import auroraopencode.projectioncache : projectContext, RequestProjectionCache, ProjectionRevision;
import auroraopencode.taskcontext : taskContext;
import auroraopencode.taskpolicy : requiredEvidence;
import auroraopencode.taskflow : taskInvestigation;
import auroraopencode.requestintent : RequestIntent, answerOnlyRequest, requestIntent;
import auroraopencode.goalmode : goalPromptBlock;
import std.array : appender, join, split;
import std.algorithm : canFind, min, max;
import std.string : strip, startsWith, toLower, replace;
import std.conv : to;
import std.json : JSONValue, JSONType, parseJSON;

/// Internal checkpoints cannot supersede the human's latest request.
public string latestActualUserRequest(const ref ChatSession session)
{
    if (session.queuedGuidance.length > 0) return session.queuedGuidance[$ - 1];
    foreach_reverse (index; activeMessagePath(session))
        if (session.messages[index].role == "user" && !session.messages[index].internal)
            return session.messages[index].content;
    return "";
}

/// Machine-readable task state supplied on every request. Compaction and
/// restarts retain the objective without overriding the latest user intent.
public string durableTaskPrompt(const ref ChatSession session,
    bool nestedEnabled, bool includeRecentEvidence = true)
{
    if (session.objective.length == 0 && session.taskSteps.length == 0 &&
        session.verificationStatus.length == 0 && session.goal.length == 0)
        return "";
    auto prompt = appender!string();
    const currentRequest = latestActualUserRequest(session);
    prompt.put(goalPromptBlock(session));
    prompt.put("\n\n# Durable Task State\n" ~ taskContext(session, currentRequest,
        nestedEnabled, 12_000, includeRecentEvidence));
    const evidence = requiredEvidence(session);
    if (evidence.length)
    {
        prompt.put("Required evidence (current source inputs):");
        foreach (kind; evidence) prompt.put(" " ~ kind);
        prompt.put(". Use a saved verify recipe; a compiler check alone does not satisfy these outcomes.\n");
    }
    if (answerOnlyRequest(currentRequest) || taskInvestigation(session))
        prompt.put("The latest request asks for an explanation. Answer it from the " ~
            "evidence; do not resume desktop actions or reconcile the older checklist. " ~
            "Preserve the parent objective, current step and return point. The unfinished work remains recorded for resume.\n");
    else if (requestIntent(currentRequest) == RequestIntent.diagnosis)
        prompt.put("The latest request asks why. Diagnose the cause from evidence and resolve it with the correct change; " ~
            "do not stop at an explanation. Preserve the current objective and unfinished checklist, and do not " ~
            "resume desktop input that the user stopped. State the cause and the fix you applied, or the concrete blocker.\n");
    else
        prompt.put("The latest user request defines the current deliverable. Background tasks and paused goals " ~
            "are context, not additional work. Resolve references using saved history; use read_plan task_id " ~
            "for exact earlier requirements. For an active goal, preserve unaffected requirements across amendments. " ~
            "Use a short outcome plan for complex work; execute simple requests directly. " ~
            "Verify the requested behavior in its real execution path: helper or headless checks alone do not prove GUI behavior. " ~
            "Complete authorized execution and relevant verification before replying. State the result, useful evidence " ~
            "and any concrete unresolved limitation briefly. Do not substitute repeated status summaries, permission " ~
            "questions or offers to continue for available useful work.\n");
    return prompt.data;
}

/// Start the streaming request for the current session history. When
/// tools are enabled, the structured history (including tool calls and
/// results) is sent together with the tool definitions and a steering
/// prompt that directs the model toward the native D tools.
/// Build the outgoing history from the active branch, defensively. A stored
/// assistant message may carry `tool_calls` whose results never arrived
/// (the app was closed mid-tool, a tool run was abandoned, or a save
/// predates the tool-reply guarantee). The provider rejects an assistant
/// `tool_calls` message that is not immediately followed by a `tool`
/// message for every call id ("insufficient tool messages following
/// tool_calls message", HTTP 400), so keep the calls only when the full
/// contiguous set of replies is present; otherwise downgrade the assistant
/// to a plain message and drop the orphan tool replies.
/// Conservative local fallback for providers that omit streamed usage.
/// Count the exact compacted messages plus advertised tool schemas, then
/// use four bytes per token for the meter's approximate display.
public int estimateRequestTokens(
    const(ChatRequestMessage)[] messages,
    const(OpenCodeToolDef)[] tools)
{
    const size_t bytes = requestMessageBytes(messages) +
        requestToolDefinitionBytes(tools);
    const size_t tokens = (bytes + 3) / 4;
    return tokens > cast(size_t) int.max ? int.max : cast(int) tokens;
}

public size_t requestToolDefinitionBytes(
    const(OpenCodeToolDef)[] tools)
{
    size_t bytes;
    foreach (tool; tools)
        bytes += tool.name.length + tool.description.length +
            tool.parametersJson.length + 64;
    return bytes;
}

/// A short, UTF-8-safe excerpt for deterministic checkpoints. Keep text
/// across line breaks so a multi-line task does not lose its requirements.
/// Compaction must never copy a multi-megabyte message into its summary.
public string checkpointSnippet(string text, size_t limit = 480)
{
    size_t cut = text.length < limit ? text.length : limit;
    while (cut > 0 &&
        cut < text.length &&
        (cast(ubyte) text[cut] & cast(ubyte) 0xC0) == cast(ubyte) 0x80)
        --cut;
    const excerpt = text[0 .. cut].replace("\r", " ").replace("\n", " ").strip();
    return cut < text.length ? excerpt ~ "..." : excerpt;
}

/// Long instructions and outcomes often place the decisive constraint at
/// the end. Keep both edges when carrying them into a rolling checkpoint.
public string checkpointEdges(string value, size_t limit)
{
    if (value.length <= limit) return checkpointSnippet(value, limit);
    const size_t edge = limit > 64 ? (limit - 32) / 2 : limit / 2;
    size_t head = edge;
    while (head > 0 &&
        (cast(ubyte) value[head] & cast(ubyte) 0xC0) ==
            cast(ubyte) 0x80) --head;
    size_t tail = value.length - edge;
    while (tail < value.length &&
        (cast(ubyte) value[tail] & cast(ubyte) 0xC0) ==
            cast(ubyte) 0x80) ++tail;
    return value[0 .. head].replace("\r", " ").replace("\n", " ") ~
        " ... [middle omitted] ... " ~
        value[tail .. $].replace("\r", " ").replace("\n", " ");
}

/// Keep both the opening and the outcome of an old tool result. A bare
/// "output shortened" marker erased the only record of what a read,
/// build, or test returned when a local model first hit its context cap.
public string shortenToolOutput(string content,
    size_t edgeBytes = 512)
{
    if (content.length <= edgeBytes * 2 + 64) return content;
    size_t head = edgeBytes;
    while (head > 0 &&
        (cast(ubyte) content[head] & cast(ubyte) 0xC0) ==
            cast(ubyte) 0x80) --head;
    size_t tail = content.length - edgeBytes;
    while (tail < content.length &&
        (cast(ubyte) content[tail] & cast(ubyte) 0xC0) ==
            cast(ubyte) 0x80) ++tail;
    return content[0 .. head] ~
        "\n... middle of older tool output omitted ...\n" ~
        content[tail .. $];
}

/// A completed group can be removed only if it is outside the active tool
/// round. Preserve that round's envelope and replies for the provider.
public size_t collapsibleToolGroupCount(
    const(ChatRequestMessage)[] messages)
{
    size_t groupCount;
    size_t lastUser;
    bool haveUser;
    foreach (i, m; messages)
    {
        // Internal Continue and recovery controls are system messages;
        // they do not end the tool round being continued.
        if (m.role == "user")
        {
            lastUser = i;
            haveUser = true;
        }
        if (m.role == "assistant" && m.toolCalls.length > 0)
            ++groupCount;
    }
    // Only an actively continuing tool round needs its exact envelope. A
    // later real user instruction starts a new round, so every earlier
    // completed envelope can be checkpointed. Keeping eight old groups was
    // both expensive and fragile: one legacy group with missing reasoning
    // could make the provider reject an otherwise unrelated follow-up.
    size_t groupsAfterInstruction;
    foreach (i, m; messages)
        if (m.role == "assistant" && m.toolCalls.length > 0 &&
            (!haveUser || i > lastUser))
            ++groupsAfterInstruction;
    const size_t keepRecentToolGroups = groupsAfterInstruction > 0 ? 1 : 0;
    return groupCount > keepRecentToolGroups
        ? groupCount - keepRecentToolGroups : 0;
}

/// Collapse only the oldest `collapseCount` completed tool groups. The
/// caller chooses the smallest count needed to fit the request budget.
public ChatRequestMessage[] collapseCompletedToolHistory(
    ChatRequestMessage[] messages, size_t collapseCount)
{
    if (collapseCount == 0) return messages;
    int[string] callCounts;
    string[] callOrder;
    size_t seenGroups;
    foreach (m; messages)
    {
        if (m.role != "assistant" || m.toolCalls.length == 0) continue;
        if (seenGroups++ >= collapseCount) break;
        foreach (call; m.toolCalls)
        {
            if (call.name !in callCounts) callOrder ~= call.name;
            ++callCounts[call.name];
        }
    }

    string objective = "Continue the user's current task.";
    foreach (m; messages)
        if (m.role == "user")
        {
            const excerpt = checkpointSnippet(m.content, 700);
            if (excerpt.length > 0) objective = excerpt;
            break;
        }

    string[] concreteOutcomes;
    string[] failures;
    size_t groupsSeen;
    foreach (m; messages)
    {
        if (m.role == "assistant" && m.toolCalls.length > 0)
        {
            if (groupsSeen++ >= collapseCount) break;
            continue;
        }
        if (groupsSeen > 0 && groupsSeen <= collapseCount &&
            m.role == "tool")
        {
            const excerpt = checkpointSnippet(
                shortenToolOutput(m.content, 300), 700);
            if (excerpt.length == 0) continue;
            const lower = excerpt.toLower();
            const failed = lower.canFind("error") ||
                lower.canFind("failed") ||
                lower.canFind("cannot") ||
                lower.canFind("tool call skipped") ||
                lower.canFind("exited with code");
            if (failed)
            {
                failures ~= excerpt;
                if (failures.length > 6) failures = failures[1 .. $];
            }
            else
            {
                concreteOutcomes ~= excerpt;
                if (concreteOutcomes.length > 12)
                    concreteOutcomes = concreteOutcomes[1 .. $];
            }
        }
    }

    auto noteText = appender!string();
    noteText.put("## Objective\n- " ~ objective ~
        "\n\n## Important Details\n- Earlier completed tool activity " ~
        "was checkpointed after " ~ to!string(collapseCount) ~
        " rounds.\n- Tool activity: ");
    foreach (i, name; callOrder)
    {
        if (i > 0) noteText.put(", ");
        noteText.put(name ~ " x" ~ to!string(callCounts[name]));
    }
    noteText.put(".\n\n## Work State\n### Completed\n");
    if (concreteOutcomes.length == 0)
        noteText.put("- No concrete successful outcome was retained.\n");
    else
        foreach (outcome; concreteOutcomes)
            noteText.put("- " ~ outcome ~ "\n");
    noteText.put("\n### Active\n- Continue from the retained recent " ~
        "messages and tool results.\n\n### Blocked\n");
    if (failures.length == 0)
        noteText.put("- (none recorded in the checkpointed tool rounds)\n");
    else
        foreach (failure; failures)
            noteText.put("- " ~ failure ~ "\n");
    noteText.put("\n## Next Move\n- Use the retained recent context; " ~
        "make a targeted lookup only when an exact fact is missing. Do not " ~
        "repeat old exploration merely because raw output was shortened.");
    ChatRequestMessage note;
    note.role = "system";
    note.content = noteText.data;

    ChatRequestMessage[] result;
    bool inserted;
    size_t collapsed;
    size_t slot;
    while (slot < messages.length)
    {
        auto m = messages[slot];
        if (collapsed < collapseCount && m.role == "assistant" &&
            m.toolCalls.length > 0)
        {
            if (!inserted)
            {
                result ~= note;
                inserted = true;
            }
            ++collapsed;
            ++slot;
            while (slot < messages.length && messages[slot].role == "tool")
                ++slot;
            continue;
        }
        result ~= m;
        ++slot;
    }
    return result;
}

public size_t compactionBudgetBytes(int contextLimit)
{
    if (contextLimit <= 0) return 0;
    const size_t contextTokens = cast(size_t) contextLimit;
    const size_t proportionalReserve = contextTokens / 10;
    size_t reserveTokens = proportionalReserve > 20_000
        ? proportionalReserve : 20_000;
    // A 32K window previously reserved 12.8K tokens for output while native
    // schemas used most of the input remainder. Keep 20% output headroom in
    // small windows, plus the conservative three-byte input-token estimate.
    const size_t maximumReserve = contextTokens * (contextLimit <= 32_768 ? 2 : 4) / 10;
    if (reserveTokens > maximumReserve) reserveTokens = maximumReserve;
    // Code and tool JSON often tokenize at fewer than four UTF-8 bytes per
    // token. Leave room for that difference before the server rejects the
    // request, while the separate output reserve remains in token units.
    return (contextTokens - reserveTokens) * 3;
}

/// Deterministically shrink a request only when it approaches the model's
/// context budget. Keeping the model-visible prefix stable below that limit
/// avoids needless context churn on every tool continuation.
public ChatRequestMessage[] compactRequestMessages(
    ChatRequestMessage[] messages, int contextLimit,
    size_t fixedRequestBytes = 0)
{
    if (messages.length == 0) return messages;
    if (contextLimit <= 0) return messages;
    // Reserve 10% or 20k tokens (whichever is larger), capped at 40% for
    // small windows. This follows the same preflight/headroom shape as
    // Codex and OpenCode rather than compacting on every continuation.
    const size_t budget = compactionBudgetBytes(contextLimit);
    size_t total = fixedRequestBytes + requestMessageBytes(messages);
    if (total <= budget) return messages;

    auto result = messages.dup;
    // Saved reasoning is sent to the provider, but older non-tool
    // reasoning is not needed to preserve the visible conversation.
    // Remove it before shortening tool results or dialogue. Keep the
    // newest assistant's reasoning unless pressure still remains.
    size_t newestAssistant = result.length;
    foreach (i, m; result)
        if (m.role == "assistant" && m.toolCalls.length == 0)
            newestAssistant = i;
    foreach (i, ref m; result)
    {
        if (total <= budget) break;
        if (i == newestAssistant || m.role != "assistant" ||
            m.toolCalls.length > 0 || m.reasoningContent.length == 0)
            continue;
        total -= m.reasoningContent.length;
        m.reasoningContent = "";
    }
    if (total <= budget) return result;
    // Pass 1: shorten only as many old tool results as needed. Previously
    // we collapsed every completed tool round first, even when a single
    // shortened output would have put the request under budget.
    enum size_t keepRecentTools = 1;
    size_t[] toolIndexes;
    foreach (i, m; result)
        if (m.role == "tool") toolIndexes ~= i;
    if (toolIndexes.length > keepRecentTools)
    {
        foreach (idx; toolIndexes[0 .. $ - keepRecentTools])
        {
            if (total <= budget) break;
            const shortened = shortenToolOutput(result[idx].content);
            if (shortened.length >= result[idx].content.length) continue;
            total -= result[idx].content.length - shortened.length;
            result[idx].content = shortened;
        }
    }
    if (total <= budget) return result;

    if (newestAssistant < result.length &&
        result[newestAssistant].reasoningContent.length > 0)
    {
        total -= result[newestAssistant].reasoningContent.length;
        result[newestAssistant].reasoningContent = "";
        if (total <= budget) return result;
    }

    // Pass 2: if output trimming was insufficient, collapse the smallest
    // number of oldest completed envelopes that gets under budget. Keep
    // recent exact tool exchanges so a continuation can use their results.
    const maxCollapse = collapsibleToolGroupCount(result);
    if (maxCollapse > 0)
    {
        size_t low = 1;
        size_t high = maxCollapse;
        while (low < high)
        {
            const mid = low + (high - low) / 2;
            const candidate = collapseCompletedToolHistory(result, mid);
            if (fixedRequestBytes + requestMessageBytes(candidate) <= budget)
                high = mid;
            else
                low = mid + 1;
        }
        result = collapseCompletedToolHistory(result, low);
        total = fixedRequestBytes + requestMessageBytes(result);
        if (total <= budget) return result;
    }

    // Pass 3: replace older dialogue with one structured handoff rather
    // than dozens of content-free "message elided" placeholders. The full
    // transcript remains persisted; only this model request is compacted.
    if (total > budget)
    {
        size_t protectHead;
        foreach (i, m; result)
        {
            protectHead = i + 1;
            if (m.role != "system") break;
        }
        // Keep a recent slice by size, not by message count. Eight large
        // messages could otherwise exceed a local server's entire window.
        size_t tailStart = result.length;
        size_t tailBytes;
        const size_t tailBudget = budget > fixedRequestBytes
            ? (budget - fixedRequestBytes) * 3 / 4 : 0;
        while (tailStart > protectHead)
        {
            const candidate = requestMessageBytes(
                result[tailStart - 1 .. tailStart]);
            if (tailBytes + candidate > tailBudget &&
                tailStart < result.length) break;
            tailBytes += candidate;
            --tailStart;
        }
        // Always preserve the latest user instruction, even when a long
        // tool round leaves it outside the recent byte slice.
        size_t latestUser = result.length;
        foreach (i, m; result)
            if (m.role == "user") latestUser = i;
        bool[] remove = new bool[](result.length);
        string[] userDetails;
        string[] completed;
        string[] blockers;
        foreach (i, m; result)
        {
            if (i < protectHead) continue;
            if (i >= tailStart) continue;
            if (i == latestUser) continue;
            if (m.role == "system" || m.role == "tool") continue;
            if (i == protectHead && m.role == "user") continue;
            if (m.toolCalls.length > 0) continue;
            remove[i] = true;
            const excerpt = checkpointSnippet(m.content);
            if (excerpt.length == 0) continue;
            if (m.role == "user")
            {
                userDetails ~= excerpt;
                if (userDetails.length > 8)
                    userDetails = userDetails[1 .. $];
            }
            else if (m.role == "assistant")
            {
                completed ~= excerpt;
                if (completed.length > 8)
                    completed = completed[1 .. $];
                const lower = excerpt.toLower();
                if (lower.canFind("error") || lower.canFind("cannot") ||
                    lower.canFind("couldn't") || lower.canFind("blocked"))
                {
                    blockers ~= excerpt;
                    if (blockers.length > 4)
                        blockers = blockers[1 .. $];
                }
            }
        }

        auto checkpoint = appender!string();
        string objective = "Continue the user's current task.";
        foreach (m; result)
            if (m.role == "user")
            {
                const excerpt = checkpointSnippet(m.content, 700);
                if (excerpt.length > 0) objective = excerpt;
                break;
            }
        checkpoint.put("## Objective\n- " ~ objective ~
            "\n\n## Important Details\n");
        if (userDetails.length == 0) checkpoint.put("- (none)\n");
        else foreach (detail; userDetails) checkpoint.put("- " ~ detail ~ "\n");
        checkpoint.put("\n## Work State\n### Completed\n");
        if (completed.length == 0) checkpoint.put("- (none)\n");
        else foreach (item; completed) checkpoint.put("- " ~ item ~ "\n");
        checkpoint.put("\n### Active\n- Continue from the retained recent " ~
            "messages and exact tool results.\n\n### Blocked\n");
        if (blockers.length == 0) checkpoint.put("- (none)\n");
        else foreach (item; blockers) checkpoint.put("- " ~ item ~ "\n");
        checkpoint.put("\n## Next Move\n- Complete the current request, " ~
            "then run focused verification and report the result.");

        ChatRequestMessage checkpointMessage;
        checkpointMessage.role = "system";
        checkpointMessage.content = checkpoint.data;
        ChatRequestMessage[] compacted;
        bool inserted;
        foreach (i, m; result)
        {
            if (remove[i])
            {
                if (!inserted)
                {
                    compacted ~= checkpointMessage;
                    inserted = true;
                }
                continue;
            }
            compacted ~= m;
        }
        result = compacted;
    }
    // Keeping the latest human message verbatim is impossible when that one
    // attachment/paste exceeds the entire window. Bound its wire projection
    // rather than silently sending beyond the configured context. The exact
    // message stays saved and is recoverable with read_history. Never modify
    // structured tool arguments or break a tool-call/result envelope.
    total = fixedRequestBytes + requestMessageBytes(result);
    while (total > budget)
    {
        size_t largest = result.length;
        foreach (i, message; result)
            if (!message.toolCalls.length && message.content.length > 2048 &&
                (message.role == "user" || message.role == "tool") &&
                (largest == result.length || message.content.length > result[largest].content.length))
                largest = i;
        if (largest == result.length) break;
        const originalLength = result[largest].content.length;
        const excess = total - budget;
        const target = excess + 1024 < originalLength ? originalLength - excess : cast(size_t)1024;
        enum note = "[Context-sized excerpt; exact omitted text remains saved. Use read_history for missing instructions or facts.]\n";
        result[largest].content = note ~ checkpointEdges(result[largest].content, target - note.length);
        total = fixedRequestBytes + requestMessageBytes(result);
    }
    return result;
}

public bool checkpointOnActivePath(const ref ChatSession session)
{
    if (session.compactedThroughMessageId.length == 0 ||
        session.compactionSummary.length == 0) return false;
    foreach (index; activeMessagePath(session))
        if (session.messages[index].id == session.compactedThroughMessageId)
            return true;
    return false;
}

public size_t compactionSummaryCapacity(int contextLimit, size_t fixedRequestBytes)
{
    if (contextLimit <= 0) return 0;
    const budget = compactionBudgetBytes(contextLimit);
    if (fixedRequestBytes >= budget) return 0;
    const maximum = cast(size_t) contextLimit * 4 / 10;
    size_t capacity = maximum < 24_000 ? maximum : 24_000;
    if (capacity > (budget - fixedRequestBytes) / 4) capacity = (budget - fixedRequestBytes) / 4;
    return capacity;
}

public string compactionSummarySizeInstruction(size_t byteBudget)
{
    if (!byteBudget) return "";
    return " The checkpoint text must be under " ~ to!string(max(cast(size_t)256,byteBudget/3)) ~
        " UTF-8 bytes so the authoritative task state and recent tool results also fit. " ~
        "Prioritize original behavioral rules, units, supplied user decisions and the exact next action. " ~
        "Do not restate identical objective/goal/request fields or recursively quote earlier checkpoints.";
}

private string recentUserDecisions(const ref ChatSession session, size_t budget)
{
    if (budget < 160) return "";
    const latest = latestActualUserRequest(session);
    string[] decisions;
    foreach_reverse (index; activeMessagePath(session))
    {
        const ref message = session.messages[index];
        if (message.role != "user" || message.internal || message.content == latest ||
            message.content == session.objective || message.content == session.goal) continue;
        decisions ~= message.content;
        if (decisions.length == 2) break;
    }
    if (!decisions.length) return "";
    auto text = appender!string();
    text.put("Recent user decisions (quoted; newer instructions supersede older ones):\n");
    const perDecision = (budget - text.data.length) / decisions.length;
    foreach_reverse (entry; decisions) text.put("- " ~ checkpointEdges(entry, perDecision - 3) ~ "\n");
    return text.data;
}

/// Install one reusable checkpoint, leaving a generous recent tail for
/// subsequent tool rounds. The boundary is a complete message/group; a
/// provider-native tool envelope never crosses it. Earlier messages stay
/// untouched in the saved graph and are available when switching branches.
public bool rollCompactionCheckpoint(ref ChatSession session,
    int contextLimit, size_t fixedRequestBytes, size_t imageLimit = 2,
    RequestProjectionCache cache = null, ProjectionRevision revision = ProjectionRevision.init)
{
    if (contextLimit <= 0) return false;
    const path = activeMessagePath(session);
    if (path.length < 2) return false;
    // Schemas and the system prompt consume real capacity. At 32K the native
    // tools leave roughly 11 KB for history; a 12.8 KB checkpoint alone used
    // to exceed that, forcing the current reads out on every continuation.
    const requestBudget = compactionBudgetBytes(contextLimit);
    if (fixedRequestBytes >= requestBudget) return false;
    const available = requestBudget - fixedRequestBytes;
    const summaryBudget = compactionSummaryCapacity(contextLimit, fixedRequestBytes);
    if (summaryBudget < 900 || available <= summaryBudget + 128) return false;
    const size_t tailBudget = (available - summaryBudget - 128) * 3 / 4;
    size_t start;
    if (checkpointOnActivePath(session))
        foreach (i, index; path)
            if (session.messages[index].id ==
                session.compactedThroughMessageId)
            {
                start = i + 1;
                break;
            }
    auto boundary = compactionBoundary(session, path, start, tailBudget,
        imageLimit, cache, revision);
    // The current batch is a working set, not old history. A byte selector
    // may otherwise retire every result from a multi-read batch when that
    // batch exceeds the target tail size, leaving the model nothing to act on.
    foreach_reverse (i; 0 .. path.length)
    {
        const ref current = session.messages[path[i]];
        if (current.role == "user" && !current.internal) break;
        if (current.role == "assistant" && !current.toolCalls.length && current.content.length)
            break; // A later answer has already consumed the older tool batch.
        if (current.role == "assistant" && current.toolCalls.length)
        {
            if (boundary >= i)
            {
                const before = i ? session.messages[path[i - 1]].id : "";
                const currentBatch = projectContext(session, before, false, imageLimit, cache, revision);
                // Truly oversized output must still be pageable/compacted.
                // Pin the complete batch only when it fits the remaining
                // history capacity, rather than merely the smaller tail target.
                if (requestMessageBytes(currentBatch) <= available - summaryBudget - 128)
                {
                    if (i <= start) return false;
                    boundary = i - 1;
                }
            }
            break;
        }
    }
    if (boundary == path.length || boundary < start) return false;

    auto header = appender!string();
    header.put("Earlier conversation checkpoint. Full task records and transcript remain saved. " ~
        "Use read_history to recover omitted facts, exact instructions or tool results; read_plan for task details.\n");
    header.put(taskContext(session, latestActualUserRequest(session), true, summaryBudget / 2));
    header.put(recentUserDecisions(session, summaryBudget / 4));
    header.put("## Earlier context\n");
    if (header.data.length + 128 >= summaryBudget) return false;
    string previous;
    if (start > 0)
        previous = checkpointSnippet(session.compactionSummary,
            (summaryBudget - header.data.length) / 3);
    string[] entries;
    size_t entryBytes;
    foreach (i; start .. boundary + 1)
    {
        const message = session.messages[path[i]];
        if (message.internal) continue;
        string entry = "- " ~ message.role ~ " message_id=" ~ message.id ~ ": ";
        if (message.role == "tool")
            entry ~= message.toolName ~ " tool_call_id=" ~ message.toolCallId ~ "; accepted_check=" ~ message.verificationCheck ~ " result: " ~
                checkpointSnippet(shortenToolOutput(message.content, 350), 900);
        else
            entry ~= checkpointEdges(message.content,
                message.role == "user" ? 1800 : 900);
        if (message.toolCalls.length > 0)
            foreach (call; message.toolCalls)
                entry ~= " [called " ~ call.name ~ " id=" ~ call.id ~ ": " ~
                    checkpointSnippet(call.arguments, 240) ~ "]";
        entry ~= "\n";
        entries ~= entry;
        entryBytes += entry.length;
    }
    const size_t entryBudget = summaryBudget - header.data.length -
        previous.length - 100;
    while (entries.length > 1 && entryBytes > entryBudget)
    {
        entryBytes -= entries[0].length;
        entries = entries[1 .. $];
    }
    auto checkpoint = appender!string();
    checkpoint.put(header.data);
    if (previous.length > 0)
        checkpoint.put("Previous checkpoint excerpt:\n" ~ previous ~ "\n");
    foreach (entry; entries) checkpoint.put(checkpointSnippet(entry, entryBudget));
    session.compactionSummary = checkpoint.data;
    session.compactedThroughMessageId = session.messages[path[boundary]].id;
    return true;
}

public ChatRequestMessage[] checkpointRequestMessages(
    const ref ChatSession session, size_t imageLimit = 2,
    RequestProjectionCache cache = null, ProjectionRevision revision = ProjectionRevision.init)
{
    if (!checkpointOnActivePath(session))
        return projectContext(session, "", false, imageLimit, cache, revision);
    ChatRequestMessage note;
    note.role = "system";
    note.content = session.compactionSummary;
    auto result = [note];
    result ~= projectContext(session, session.compactedThroughMessageId, false, imageLimit, cache, revision);
    return result;
}

public ChatRequestMessage[] prepareCompactedRequest(
    ref ChatSession session, int contextLimit, size_t fixedRequestBytes,
    out bool checkpointCreated, out bool fallbackCompacted, size_t imageLimit = 2,
    RequestProjectionCache cache = null, ProjectionRevision revision = ProjectionRevision.init)
{
    checkpointCreated = false;
    fallbackCompacted = false;
    auto request = checkpointRequestMessages(session, imageLimit, cache, revision);
    if (contextLimit <= 0 || fixedRequestBytes +
        requestMessageBytes(request) <= compactionBudgetBytes(contextLimit))
        return request;
    checkpointCreated = rollCompactionCheckpoint(session, contextLimit, fixedRequestBytes, imageLimit, cache, revision);
    if (checkpointCreated) request = checkpointRequestMessages(session, imageLimit, cache, revision);
    auto bounded = compactRequestMessages(request, contextLimit,
        fixedRequestBytes);
    fallbackCompacted = requestMessageBytes(bounded) <
        requestMessageBytes(request);
    return bounded;
}

/// The summary model sees the prefix being retired, plus the preceding
/// checkpoint. Textual roles avoid replaying old provider-specific tool or
/// reasoning blocks in a new summarization request.
public string compactionSource(const ref ChatSession session,
    string oldAnchor, string oldSummary, int contextLimit)
{
    const path = activeMessagePath(session);
    size_t start;
    if (oldAnchor.length > 0)
        foreach (i, index; path)
            if (session.messages[index].id == oldAnchor)
            {
                start = i + 1;
                break;
            }
    size_t end = path.length;
    foreach (i, index; path)
        if (session.messages[index].id ==
            session.compactedThroughMessageId)
        {
            end = i + 1;
            break;
        }
    if (end <= start || end > path.length) return "";
    const size_t proportional = cast(size_t) contextLimit * 2;
    const size_t sourceBudget = proportional < 180_000
        ? proportional : 180_000;
    if (sourceBudget < 4_000) return "";
    auto prefix = appender!string();
    prefix.put("Current durable task objective: " ~
        checkpointEdges(session.objective, 1800) ~ "\n");
    prefix.put(durableTaskPrompt(session, true));
    if (oldAnchor.length > 0 && oldSummary.length > 0)
        prefix.put("Prior checkpoint:\n" ~
            checkpointSnippet(oldSummary,
                sourceBudget / 4) ~ "\n");
    prefix.put("Extractive draft (verify and improve it):\n" ~
        session.compactionSummary ~ "\n\nEarlier messages:\n");
    if (prefix.data.length >= sourceBudget) return "";
    string[] entries;
    size_t entryBytes;
    foreach (i; start .. end)
    {
        const message = session.messages[path[i]];
        if (message.internal) continue;
        string entry = "[" ~ message.role ~ " message_id=" ~ message.id ~ "] ";
        if (message.role == "tool")
            entry ~= message.toolName ~ " tool_call_id=" ~ message.toolCallId ~ "; accepted_check=" ~ message.verificationCheck ~ ": " ~
                checkpointEdges(message.content, 1600);
        else
            entry ~= checkpointEdges(message.content,
                message.role == "user" ? sourceBudget / 2 : 2200);
        if (message.toolCalls.length > 0)
            foreach (call; message.toolCalls)
                entry ~= "\n[tool call] " ~ call.name ~ " id=" ~ call.id ~ " " ~
                    checkpointEdges(call.arguments, 800);
        entry ~= "\n\n";
        entries ~= entry;
        entryBytes += entry.length;
    }
    const size_t available = sourceBudget - prefix.data.length;
    while (entries.length > 1 && entryBytes > available)
    {
        entryBytes -= entries[0].length;
        entries = entries[1 .. $];
    }
    foreach (entry; entries)
    {
        const remaining = sourceBudget - prefix.data.length;
        if (remaining < 64) break;
        prefix.put(checkpointEdges(entry, remaining));
    }
    return prefix.data;
}

public bool applyModelCompactionSummary(ref ChatSession session,
    string anchor, string leaf, string output, int contextLimit, bool allowDescendant = false,
    size_t byteBudget = 0)
{
    if (anchor != session.compactedThroughMessageId) return false;
    if (leaf != session.activeLeafId)
    {
        bool ancestor;
        if (allowDescendant && leaf.length)
            foreach (index; activeMessagePath(session)) if (session.messages[index].id == leaf) ancestor = true;
        if (!ancestor) return false;
    }
    const summary = output.strip();
    const size_t proportional = cast(size_t) contextLimit * 4 / 10;
    size_t maximum = proportional < 24_000
        ? proportional : 24_000;
    // Refinement must fit the capacity reserved for the installed draft.
    // Otherwise a successful optional summary can immediately retire the
    // useful tail again and start another compaction before any real work.
    if (byteBudget && maximum > byteBudget) maximum = byteBudget;
    string objective = session.objective;
    string latestUser;
    foreach (index; activeMessagePath(session))
        if (session.messages[index].role == "user" &&
            !session.messages[index].internal)
        {
            if (objective.length == 0)
                objective = session.messages[index].content;
            latestUser = session.messages[index].content;
        }
    string durable = taskContext(session, latestUser, true, maximum / 3);
    durable ~= "Objective: " ~ checkpointEdges(objective, maximum / 8);
    if (latestUser.length > 0 && latestUser != objective)
        durable ~= "\nLatest user instruction: " ~
            checkpointEdges(latestUser, maximum / 8);
    durable ~= "\n" ~ recentUserDecisions(session, maximum / 8);
    if (summary.length < 100 || summary.canFind("<think>") ||
        summary.length + durable.length + 240 > maximum) return false;
    session.compactionSummary = "Earlier conversation checkpoint. Use read_history for exact omitted messages and read_plan for task details.\n" ~
        "Durable objective and constraints:\n" ~ durable ~
        "\nModel summary of earlier work:\n" ~ summary;
    return true;
}

/// Optional per-session system-prompt section. Kept outside the cached
/// prompt so one session's instructions never leak into another.
public string sessionInstructionsBlock(const ref ChatSession session)
{
    if (session.instructions.length == 0) return "";
    return "\n# Session instructions\n" ~ session.instructions ~ "\n";
}
