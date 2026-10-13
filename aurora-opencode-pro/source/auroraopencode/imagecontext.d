module auroraopencode.imagecontext;

import auroraopencode.core : ChatSession, activeMessagePath;
import std.conv : to;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : strip;

public string imageReferenceId(const ref ChatSession session, size_t message, size_t image)
{
    const id = session.messages[message].id;
    return (id.length ? id : "legacy-" ~ to!string(message)) ~ ":" ~ to!string(image + 1);
}

public string retireImagesArgumentsError(string args)
{
    try
    {
        const value = parseJSON(args);
        if (value.type != JSONType.object) return "Error: retire_images requires an object.";
        const ids = "imageIds" in value.object;
        const summary = "summary" in value.object;
        if (ids is null || ids.type != JSONType.array || ids.array.length == 0 || ids.array.length > 32)
            return "Error: supply 1 to 32 imageIds from the current request's image labels.";
        foreach (id; ids.array)
            if (id.type != JSONType.string || id.str.length == 0 || id.str.length > 256)
                return "Error: imageIds must be nonempty image reference strings.";
        if (summary is null || summary.type != JSONType.string || summary.str.strip().length == 0 ||
            summary.str.length > 16384)
            return "Error: supply a visual summary (1 to 16384 bytes) before retiring images.";
    }
    catch (Exception) return "Error: invalid retire_images arguments.";
    return "";
}

public string retireImagesSessionError(const ref ChatSession session, string args)
{
    const error = retireImagesArgumentsError(args);
    if (error.length) return error;
    bool[string] known;
    foreach (index; activeMessagePath(session))
        foreach (i, image; session.messages[index].images)
            known[imageReferenceId(session, index, i)] = true;
    foreach (id; parseJSON(args)["imageIds"].array)
        if (id.str !in known)
            return "Error: image reference is not on this conversation branch: " ~ id.str;
    return "";
}

/// Retirement is a successful tool event on the active branch. No transcript
/// payloads are deleted, and regenerating before the event restores the pixels.
public bool[string] retiredImageIds(const ref ChatSession session, const(size_t)[] path)
{
    bool[string] retired;
    foreach (index; path)
    {
        const message = session.messages[index];
        if (message.role == "assistant" && !message.failed && message.content.strip.length > 0 &&
            message.finishReason != "cancelled" && message.finishReason != "length" && message.finishReason != "max_tokens")
            foreach (id; message.retiredImages) retired[id] = true;
        if (message.role != "tool" || message.toolName != "retire_images" || message.failed ||
            retireImagesArgumentsError(message.toolArgs).length) continue;
        foreach (id; parseJSON(message.toolArgs)["imageIds"].array) retired[id.str] = true;
    }
    return retired;
}
