module auroraopencode.imagehistory;

import auroraopencode.core : ChatMessage, ChatImageAttachment, ChatSession;

/// Only internally generated screen frames expire independently of user images.
public bool isScreenshot(const ref ChatMessage message,
    const ref ChatImageAttachment image)
{
    return message.internal && (image.name == "screen.png" ||
        image.name == "screen.jpg") &&
        (image.mimeType == "image/png" || image.mimeType == "image/jpeg");
}

/// One current screen per request; user attachments retain their own window.
/// Empty metadata chips never occupy a place in that window.
public ChatImageAttachment[][] requestHistoryImages(const ref ChatSession session,
    const(size_t)[] path, size_t start, size_t userMessageLimit)
{
    ChatImageAttachment[][] result;
    result.length = path.length;
    size_t screens, userMessages;
    foreach_reverse (slot; start .. path.length)
    {
        const message = session.messages[path[slot]];
        bool keptUser;
        foreach_reverse (image; message.images)
        {
            if (image.base64Data.length == 0) continue;
            if (isScreenshot(message, image))
            {
                if (screens++ >= 1) continue;
            }
            else
            {
                if (userMessageLimit > 0 && userMessages >= userMessageLimit) continue;
                keptUser = true;
            }
            result[slot] = image ~ result[slot];
        }
        if (keptUser) ++userMessages;
    }
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
