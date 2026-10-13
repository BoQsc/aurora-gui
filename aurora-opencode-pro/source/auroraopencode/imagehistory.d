module auroraopencode.imagehistory;

import auroraopencode.imagecontext : imageReferenceId, retiredImageIds;
import auroraopencode.core : ChatMessage, ChatImageAttachment, ChatSession, activeMessagePath;

public bool isRecoveryScreenshot(const ref ChatMessage message,
    const ref ChatImageAttachment image)
{
    return message.internal && image.mimeType == "image/jpeg" &&
        (image.name == "screen-target.jpg" || image.name == "screen-instructions.jpg");
}

/// Only internally generated screen frames expire independently of user images.
public bool isScreenshot(const ref ChatMessage message,
    const ref ChatImageAttachment image)
{
    return isRecoveryScreenshot(message, image) ||
        message.internal && (image.name == "screen.png" ||
        image.name == "screen.jpg") &&
        (image.mimeType == "image/png" || image.mimeType == "image/jpeg");
}

public enum size_t requestImageByteBudget = 3 * 1024 * 1024;
public enum size_t requestImageCountBudget = 8;

/// One current screen or its focused recovery pair per request. User attachments
/// retain their own window; previous desktop evidence never accumulates.
/// Empty metadata chips never occupy a place in that window.
public size_t[][] requestHistoryImageIndices(const ref ChatSession session,
    const(size_t)[] path, size_t start, size_t userMessageLimit)
{
    size_t[][] result;
    result.length = path.length;
    size_t screens, userMessages, toolMessages;
    size_t screenSlot = size_t.max;
    bool recoveryPair;
    const retired = retiredImageIds(session, path);
    foreach_reverse (slot; start .. path.length)
    {
        const message = session.messages[path[slot]];
        bool keptUser, keptTool;
        foreach_reverse (i, image; message.images)
        {
            if (image.base64Data.length == 0 || imageReferenceId(session, path[slot], i) in retired) continue;
            if (isScreenshot(message, image))
            {
                if (screenSlot == size_t.max)
                {
                    screenSlot = slot;
                    recoveryPair = isRecoveryScreenshot(message, image);
                }
                if (slot != screenSlot ||
                    (recoveryPair && !isRecoveryScreenshot(message, image))) continue;
                if (screens++ >= (recoveryPair ? 2 : 1)) continue;
            }
            else if (message.internal)
            {
                // A tool read must not evict a user's reference attachment.
                if (toolMessages >= 1) continue;
                keptTool = true;
            }
            else
            {
                if (userMessageLimit > 0 && userMessages >= userMessageLimit) continue;
                keptUser = true;
            }
            result[slot] = i ~ result[slot];
        }
        if (keptUser) ++userMessages;
        if (keptTool) ++toolMessages;
    }
    // The message window alone does not bound a batch containing many images.
    // Prefer newest evidence, and label omissions in the request projection.
    size_t bytes, count;
    foreach_reverse (slot; start .. path.length)
    {
        size_t[] bounded;
        foreach_reverse (i; result[slot])
        {
            const image = session.messages[path[slot]].images[i];
            const budget = image.originalDetail && count == 0 ? 6 * 1024 * 1024 : requestImageByteBudget;
            if (count >= requestImageCountBudget || bytes + image.base64Data.length > budget) continue;
            bytes += image.base64Data.length;
            ++count;
            bounded = i ~ bounded;
        }
        result[slot] = bounded;
    }
    return result;
}

public ChatImageAttachment[][] requestHistoryImages(const ref ChatSession session,
    const(size_t)[] path, size_t start, size_t userMessageLimit)
{
    const indices = requestHistoryImageIndices(session, path, start, userMessageLimit);
    ChatImageAttachment[][] result;
    result.length = path.length;
    foreach (slot, images; indices)
        foreach (i; images) result[slot] ~= session.messages[path[slot]].images[i];
    return result;
}

/// Keep two generated frames across the whole graph, preferring the active
/// branch. Branching must not leave hundreds of inactive screenshot payloads.
public bool pruneHistoryImages(ref ChatSession session, const(size_t)[] activePath,
    size_t userMessageLimit)
{
    bool[] visited;
    visited.length = session.messages.length;
    size_t screens, userMessages;
    bool changed;
    const keepUsers = userMessageLimit > 8 ? userMessageLimit : 8;
    void prune(size_t index, bool active)
    {
        visited[index] = true;
        auto message = &session.messages[index];
        bool keptUser;
        foreach_reverse (ref image; message.images)
        {
            if (image.base64Data.length == 0) continue;
            if (isScreenshot(*message, image))
            {
                if (screens++ >= 2) { image.base64Data = ""; changed = true; }
            }
            else if (active && userMessageLimit > 0)
            {
                if (userMessages >= keepUsers) { image.base64Data = ""; changed = true; }
                else keptUser = true;
            }
        }
        if (keptUser) ++userMessages;
    }
    foreach_reverse (index; activePath) prune(index, true);
    foreach_reverse (index; 0 .. session.messages.length)
        if (!visited[index]) prune(index, false);
    return changed;
}

/// The successful answer itself is the durable visual analysis. Automatic
/// retirement archives earlier image references, including those omitted by the
/// request budget, so stale images cannot rotate back into later text requests.
/// Incomplete answers and disposable desktop frames stay active.
public string[] completedReplyImageIds(const ref ChatSession session, string replyId,
    size_t userMessageLimit)
{
    const path = activeMessagePath(session);
    if (!path.length) return null;
    const reply = session.messages[path[$ - 1]];
    import std.string : strip;
    if (reply.id != replyId || reply.role != "assistant" || reply.failed || reply.toolCalls.length ||
        !reply.content.strip.length || reply.finishReason == "cancelled" ||
        reply.finishReason == "length" || reply.finishReason == "max_tokens") return null;
    if (reply.retiredImages.length) return reply.retiredImages.dup;
    const retired = retiredImageIds(session, path);
    string[] ids;
    foreach (index; path)
        foreach (i, image; session.messages[index].images)
        {
            const id = imageReferenceId(session, index, i);
            if (!isScreenshot(session.messages[index], image) && id !in retired &&
                (image.originalBlob.length || image.blob.length)) ids ~= id;
        }
    return ids;
}
