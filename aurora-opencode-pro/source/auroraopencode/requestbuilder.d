module auroraopencode.requestbuilder;

import auroraopencode.core : ChatSession, ChatRequestMessage, activeMessagePath;
import auroraopencode.imagehistory : requestHistoryImages;

// Wire projection is independent of widgets, settings, and provider I/O.
public ChatRequestMessage[] projectRequestMessages(
        const ref ChatSession session, string afterMessageId = "",
        bool orchestratorSummaryView = false, size_t imageLimit = 2)
    {
        ChatRequestMessage[] messages;
        const path = activeMessagePath(session);
        size_t slot = 0;
        if (afterMessageId.length > 0)
            foreach (i, index; path)
                if (session.messages[index].id == afterMessageId)
                {
                    slot = i + 1;
                    break;
                }
        auto historyImages = requestHistoryImages(session, path, slot,
            imageLimit);
        while (slot < path.length)
        {
            const message = session.messages[path[slot]];
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
                    foreach (k; slot + 1 .. replyEnd)
                    {
                        const reply = session.messages[path[k]];
                        ChatRequestMessage tool;
                        tool.role = reply.role;
                        tool.content = reply.content;
                        tool.toolCallId = reply.toolCallId;
                        messages ~= tool;
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
            request.images = historyImages[slot];
            messages ~= request;
            ++slot;
        }
        return messages;
    }

private bool isRouterAgent(const ref ChatSession session, string id)
{
    foreach (agent; session.agents) if (agent.id == id) return agent.router;
    return false;
}
