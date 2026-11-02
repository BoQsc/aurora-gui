module auroraopencode.projectioncache;

import auroraopencode.core : ChatSession, ChatRequestMessage, ChatImageAttachment,
    OpenCodeToolCall, activeMessagePath;
import auroraopencode.requestbuilder : projectRequestMessages;

struct ProjectionRevision { ulong graph, capabilities; }

/// One immutable full projection per execution owner. Suffixes retain complete
/// tool envelopes and share immutable text, while callers receive private arrays.
final class RequestProjectionCache
{
    private ProjectionRevision revision;
    private string thread, leaf;
    private size_t imageLimit, count, messagesAddress, budget, retained;
    private bool summaryView, valid;
    private immutable(ChatRequestMessage)[] messages;
    private immutable(size_t)[] positions;
    private size_t[string] pathPositions;
    ulong builds, hits;

    this(size_t byteBudget = 4 * 1024 * 1024) { budget = byteBudget; }
    size_t retainedBytes() const { return retained; }
    void clear()
    {
        valid = false; retained = 0;
        messages = null; positions = null; pathPositions = null;
    }

    ChatRequestMessage[] project(const ref ChatSession session, ProjectionRevision stamp,
        string after = "", bool summary = false, size_t images = 2, size_t[]* sourcePositions = null)
    {
        const matches = valid && revision == stamp && thread == session.id && leaf == session.activeLeafId &&
            count == session.messages.length && messagesAddress == cast(size_t) session.messages.ptr &&
            summaryView == summary && imageLimit == images;
        immutable(ChatRequestMessage)[] view;
        immutable(size_t)[] slots;
        size_t[string] indices;
        if (matches)
        {
            ++hits; view = messages; slots = positions; indices = pathPositions;
        }
        else
        {
            clear(); ++builds;
            size_t[] projectedSlots;
            auto projected = projectRequestMessages(session, "", summary, images, &projectedSlots);
            // Projection creates fresh outer, call and image arrays. Their text
            // is already immutable; ownership is transferred here exactly once.
            view = cast(immutable(ChatRequestMessage)[]) projected;
            slots = cast(immutable(size_t)[]) projectedSlots;
            size_t bytes = slots.length * size_t.sizeof;
            foreach (i, index; activeMessagePath(session))
            {
                const id = session.messages[index].id;
                indices[id] = i;
                // Include keys, buckets and node overhead even when control
                // messages are omitted from the provider projection.
                bytes += 128 + id.length;
            }
            foreach (message; view)
            {
                bytes += ChatRequestMessage.sizeof + message.content.length + message.reasoningContent.length;
                foreach (call; message.toolCalls) bytes += OpenCodeToolCall.sizeof + call.arguments.length + call.name.length;
                foreach (image; message.images) bytes += ChatImageAttachment.sizeof + image.base64Data.length;
            }
            if (bytes <= budget)
            {
                revision = stamp; thread = session.id; leaf = session.activeLeafId;
                count = session.messages.length; messagesAddress = cast(size_t) session.messages.ptr;
                summaryView = summary; imageLimit = images;
                messages = view; positions = slots; pathPositions = indices;
                retained = bytes; valid = true;
            }
        }
        size_t begin;
        if (after.length) if (auto position = after in indices) begin = *position + 1;
        ChatRequestMessage[] result;
        if (sourcePositions !is null) *sourcePositions = null;
        bool[string] calls;
        foreach (i, message; view)
        {
            if (slots[i] < begin) continue;
            if (message.role == "tool" && (message.toolCallId in calls) is null) continue;
            ChatRequestMessage copy;
            copy.role = message.role; copy.content = message.content;
            copy.reasoningContent = message.reasoningContent; copy.toolCallId = message.toolCallId;
            copy.toolCalls = message.toolCalls.dup;
            copy.images = message.images.dup;
            result ~= copy;
            foreach (call; message.toolCalls) calls[call.id] = true;
            if (sourcePositions !is null) *sourcePositions ~= slots[i];
        }
        return result;
    }
}

ChatRequestMessage[] projectContext(const ref ChatSession session, string after, bool summary,
    size_t images, RequestProjectionCache cache = null, ProjectionRevision revision = ProjectionRevision.init,
    size_t[]* positions = null)
{
    return cache is null ? projectRequestMessages(session, after, summary, images, positions)
        : cache.project(session, revision, after, summary, images, positions);
}
