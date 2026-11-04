module auroraopencode.requestbuilder;

import auroraopencode.core : ChatSession, ChatRequestMessage, activeMessagePath;
import auroraopencode.imagehistory : requestHistoryImageIndices, isScreenshot;
import auroraopencode.imagecontext : retiredImageIds, imageReferenceId;
import std.algorithm : canFind;
import std.conv : to;
import auroraopencode.outputguard : outputFailurePrefix;
import std.string : startsWith;
import auroraopencode.grepformat : compactGrepHistory;
import auroraopencode.controlhistory : controlHistoryBoundary, supersededControlState, turnControlState,
    controlStateKind, ControlStateKind, controlHistoryLimit;
import auroraopencode.completionhandoff : completionHandoffMarker;

// Wire projection is independent of widgets, settings, and provider I/O.
public ChatRequestMessage[] projectRequestMessages(
        const ref ChatSession session, string afterMessageId = "",
        bool orchestratorSummaryView = false, size_t imageLimit = 2,
        size_t[]* sourcePositions = null)
    {
        ChatRequestMessage[] messages;
        if (sourcePositions !is null) *sourcePositions = null;
        const path = activeMessagePath(session);
        size_t controlBoundary;
        size_t instructionBoundary;
        foreach (i, index; path)
        {
            const ref message = session.messages[index];
            if (message.role == "user" && (!message.internal ||
                (session.parentSessionId.length && session.subagentId.length && message.authorId == session.subagentId)))
                instructionBoundary = i;
            if (session.messages[index].internal &&
                session.messages[index].content.startsWith(controlHistoryBoundary))
                controlBoundary = i;
        }
        size_t slot = 0;
        if (afterMessageId.length > 0)
            foreach (i, index; path)
                if (session.messages[index].id == afterMessageId)
                {
                    slot = i + 1;
                    break;
                }
        // Checkpoints, continuation notes and progress notes each replace the
        // previous one of the same kind, but only once a single instruction
        // window has stacked a pathological streak (observed: 62 checkpoints /
        // 189 KB in one turn). Collapsing earlier copies shifts every following
        // message, so a live tool round would rewrite the prefix it already sent
        // and lose the provider's prompt cache. Ordinary rounds stay append-only;
        // bounded windows retire superseded state with controlHistoryBoundary
        // instead (see controlHistoryCompactionNeeded).
        // A retire index of 0 means "keep every record of this kind": the drop
        // test is `slot < retireIndex`, which stays false for an ordinary slot.
        size_t retireCheckpoint, retireContinuation, retireProgress;
        {
            size_t checkpoints, continuations, progressNotes;
            size_t lastCheckpoint, lastContinuation, lastProgress;
            foreach (i, index; path)
            {
                if (i < instructionBoundary) continue;
                final switch (controlStateKind(session.messages[index]))
                {
                    case ControlStateKind.checkpoint: ++checkpoints; lastCheckpoint = i; break;
                    case ControlStateKind.continuation: ++continuations; lastContinuation = i; break;
                    case ControlStateKind.progress: ++progressNotes; lastProgress = i; break;
                    case ControlStateKind.none: break;
                }
            }
            if (checkpoints > controlHistoryLimit) retireCheckpoint = lastCheckpoint;
            if (continuations > controlHistoryLimit) retireContinuation = lastContinuation;
            if (progressNotes > controlHistoryLimit) retireProgress = lastProgress;
        }
        auto historyImages = requestHistoryImageIndices(session, path, slot,
            imageLimit);
        const retired = retiredImageIds(session, path);
        while (slot < path.length)
        {
            const message = session.messages[path[slot]];
            const controlKind = controlStateKind(message);
            if ((controlKind == ControlStateKind.checkpoint && slot < retireCheckpoint) ||
                (controlKind == ControlStateKind.continuation && slot < retireContinuation) ||
                (controlKind == ControlStateKind.progress && slot < retireProgress))
            {
                ++slot;
                continue;
            }
            // A summary-only repair belongs to its original instruction. Keep
            // it saved, without disabling tools on a later human/agent task.
            if (slot < instructionBoundary && message.internal &&
                message.content.startsWith(completionHandoffMarker))
            {
                ++slot;
                continue;
            }
            // Earlier-turn controls cannot govern a new request. Preserve the
            // live turn's prefix for provider caching; constrained windows use
            // the explicit control boundary to retire its superseded states.
            if ((slot < controlBoundary && supersededControlState(message)) ||
                (slot < instructionBoundary && turnControlState(message)) ||
                (message.internal && message.content.startsWith(controlHistoryBoundary)))
            {
                ++slot;
                continue;
            }
            // Keep failed output in the transcript, but do not teach recovery
            // requests to imitate leaked XML or looping prose.
            if (message.role == "assistant" && message.failed &&
                message.error.startsWith(outputFailurePrefix))
            {
                ++slot;
                continue;
            }
            // experimental: orchestrator - the orchestrator does not read the
            // sub-agents' shared context (their tool rounds are a separate
            // "subchat"); it sees only each sub-agent's prose result. This keeps
            // the orchestrator's request small instead of re-sending everything.
            if (orchestratorSummaryView && message.authorId.length > 0 &&
                !isRouterAgent(session, message.authorId) &&
                !(message.role == "assistant" &&
                    message.toolCalls.length == 0))
            {
                ++slot;
                continue;
            }
            if (message.role == "assistant" && message.toolCalls.length > 0)
            {
                bool[string] outstanding;
                foreach (call; message.toolCalls)
                    outstanding[call.id] = true;
                size_t replyEnd = slot + 1;
                while (replyEnd < path.length &&
                    session.messages[path[replyEnd]].role == "tool")
                {
                    const replyId = session.messages[path[replyEnd]].toolCallId;
                    if (replyId in outstanding) outstanding.remove(replyId);
                    ++replyEnd;
                }
                if (outstanding.length == 0)
                {
                    ChatRequestMessage request;
                    request.role = message.role;
                    request.content = message.content;
                    request.reasoningContent = message.reasoning;
                    request.toolCalls = message.toolCalls.dup;
                    messages ~= request;
                    if (sourcePositions !is null) *sourcePositions ~= slot;
                    foreach (k; slot + 1 .. replyEnd)
                    {
                        const reply = session.messages[path[k]];
                        ChatRequestMessage tool;
                        tool.role = reply.role;
                        tool.content = reply.toolName == "grep" ? compactGrepHistory(reply.content) : reply.content;
                        tool.toolCallId = reply.toolCallId;
                        messages ~= tool;
                        if (sourcePositions !is null) *sourcePositions ~= k;
                    }
                }
                else if (message.content.length > 0 ||
                    message.reasoning.length > 0)
                {
                    ChatRequestMessage request;
                    request.role = message.role;
                    request.content = message.content;
                    request.reasoningContent = message.reasoning;
                    messages ~= request;
                    if (sourcePositions !is null) *sourcePositions ~= slot;
                }
                slot = replyEnd;
                continue;
            }
            if (message.role == "tool")
            {
                // Orphan reply that does not follow a kept tool_calls message.
                ++slot;
                continue;
            }
            ChatRequestMessage request;
            // Recovery/finalization guidance is application control state, not
            // something the user said. Keep it in the durable graph for replay,
            // but send it under the system role so it cannot overwrite or
            // impersonate the user's intent in later model turns.
            // A view_image payload is hidden from the transcript as internal,
            // but must stay a user-role multimodal message on the wire. System
            // messages are folded together by the client and most vision chat
            // templates accept image parts only on user messages.
            const internalImage = message.internal && message.images.length > 0;
            request.role = message.internal && !internalImage
                ? "system" : message.role;
            request.content = message.internal && !internalImage
                ? "Internal agent-control instruction:\n" ~ message.content
                : message.content;
            if (message.role == "assistant")
                request.reasoningContent = message.reasoning;
            request.toolCallId = message.toolCallId;
            foreach (i; historyImages[slot]) request.images ~= message.images[i];
            foreach (i, image; message.images)
            {
                if (isScreenshot(message, image) && image.base64Data.length == 0) continue;
                const id = imageReferenceId(session, path[slot], i);
                const status = id in retired ? "retired; use recorded findings and reload the original for visual details absent from the answer or summary" :
                    canFind(historyImages[slot], i) ? "pixels attached" : "pixels omitted by image window or request budget";
                request.content ~= "\n[Image " ~ id ~ ": " ~ image.name ~ "; " ~ status;
                if (image.originalWidth > 0 && image.originalHeight > 0)
                    request.content ~= "; original dimensions " ~ to!string(image.originalWidth) ~ "x" ~
                        to!string(image.originalHeight) ~ ", transmitted " ~ to!string(image.width) ~ "x" ~ to!string(image.height);
                const original = image.originalBlob.length ? image.originalBlob : image.blob;
                if (original.length) request.content ~= "; original available via view_image attachmentBlob=" ~ original;
                request.content ~= "]";
            }
            messages ~= request;
            if (sourcePositions !is null) *sourcePositions ~= slot;
            ++slot;
        }
        return messages;
    }

private bool isRouterAgent(const ref ChatSession session, string id)
{
    foreach (agent; session.agents) if (agent.id == id) return agent.router;
    return false;
}
