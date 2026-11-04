module auroraopencode.toolprogresspolicy;

import auroraopencode.core;
import auroraopencode.tools : partialStringArg;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : extension;
import std.string : startsWith, strip, splitLines, toLower;
import std.array : appender;
import std.conv : to;

public enum cumulativeRepeatLimit = 12;

public bool isCommentOnlyChangedLine(string body)
{
    if (body.length == 0) return true;
    if (body[0] == '*') return true;
    if (body.length >= 2 &&
        (body[0 .. 2] == "//" || body[0 .. 2] == "/*" ||
         body[0 .. 2] == "*/")) return true;
    return false;
}

public bool isPlainDocumentMutation(string name, string args)
{
    if (name != "write" && name != "edit") return false;
    const path = partialStringArg(args, "filePath");
    const suffix = extension(path).toLower();
    return suffix == ".md" || suffix == ".markdown" ||
        suffix == ".rst" || suffix == ".adoc";
}

public bool isSubstantiveMutation(string name, bool failed,
    int additions, int deletions, string diff)
{
    if (failed || !isMutatingTool(name)) return false;
    if (diff.length == 0)
        return name == "copy" || name == "move" || name == "rename" ||
            name == "create_folder" || name == "remove" ||
            additions > 0 || deletions > 0;
    foreach (line; diff.splitLines())
    {
        if (line.length < 2 || (line[0] != '+' && line[0] != '-'))
            continue;
        if (line.length >= 3 &&
            (line[0 .. 3] == "+++" || line[0 .. 3] == "---"))
            continue;
        const body = strip(line[1 .. $]);
        if (!isCommentOnlyChangedLine(body)) return true;
    }
    return false;
}

public bool isMutatingTool(string name)
{
    return name == "write" || name == "edit" || name == "apply_patch" ||
        name == "copy" || name == "move" || name == "rename" ||
        name == "create_folder" || name == "remove" || name == "download";
}

public bool isVerificationTool(string name, string arguments)
{
    import auroraopencode.verification : verificationCheck;
    if (name != "run") return false;
    try
    {
        const value = parseJSON(arguments);
        if (value.type != JSONType.object) return false;
        if (auto background = "background" in value.object)
            if (background.type == JSONType.true_) return false;
        auto program = "program" in value.object;
        if (program is null || program.type != JSONType.string) return false;
        string[] args;
        if (auto field = "args" in value.object)
            if (field.type == JSONType.array)
                foreach (arg; field.array)
                    if (arg.type == JSONType.string) args ~= arg.str;
        return verificationCheck(program.str, args).length > 0;
    }
    catch (Exception) { return false; }
}

private bool isReadOnlyOrControlCall(const OpenCodeToolCall call)
{
    switch (call.name)
    {
        case "read":
        case "grep":
        case "glob":
        case "read_plan":
        case "read_history":
        case "tool_status":
        case "calculate":
        case "view_image":
        case "webfetch":
        case "checksum":
        case "update_plan":
        case "update_subplan":
            return true;
        case "dshell":
            try
            {
                const value = parseJSON(call.arguments);
                if (value.type != JSONType.object) return false;
                auto command = "command" in value.object;
                return command !is null && command.type == JSONType.string &&
                    (command.str == "where" || command.str == "list" ||
                     command.str == "info");
            }
            catch (Exception) { return false; }
        default:
            return false;
    }
}

public bool isReadOnlyOrControlBatch(const(OpenCodeToolCall)[] calls)
{
    if (calls.length == 0) return false;
    foreach (call; calls)
        if (!isReadOnlyOrControlCall(call)) return false;
    return true;
}

/// The immediately preceding assistant tool batch must have the same
/// signature and every result must have succeeded. A skipped result is neutral:
/// it means the duplicate was already suppressed, so continue suppressing it.
/// Only the active branch is judged: an edited or regenerated run stays in the
/// message store but is not part of the conversation, so its results must not
/// decide whether this duplicate is safe to collapse.
public bool isConsecutiveSuccessfulRepeat(
    const ref ChatSession session, const(OpenCodeToolCall)[] calls)
{
    const signature = toolCallSignature(calls);
    if (signature.length == 0) return false;

    const path = activeMessagePath(session);
    size_t lastAssistant = size_t.max;
    foreach (position, index; path)
    {
        const message = session.messages[index];
        if (message.role == "assistant" && message.toolCalls.length)
            lastAssistant = position;
    }
    if (lastAssistant == size_t.max) return false;
    if (toolCallSignature(session.messages[path[lastAssistant]].toolCalls) != signature)
        return false;

    bool sawResult;
    foreach (position; lastAssistant + 1 .. path.length)
    {
        const message = session.messages[path[position]];
        if (message.role == "tool")
        {
            sawResult = true;
            if (message.failed && !message.content.startsWith("Tool call skipped:"))
                return false;
        }
        else if (message.role == "user" && !message.internal)
            return false;
        else if (message.role == "assistant")
            break;
    }
    return sawResult;
}

public int toolCallRunCount(const ref ChatSession session,
    const ref OpenCodeToolCall call)
{
    int count;
    const signature = call.name ~ "|" ~ call.arguments;
    foreach (index; activeMessagePath(session))
    {
        const message = session.messages[index];
        if ((message.role == "user" && !message.internal) ||
            (message.role == "tool" && !message.failed &&
                isMutatingTool(message.toolName) &&
                (message.diffAdditions > 0 || message.diffDeletions > 0 ||
                    message.toolDiff.length > 0 || isSubstantiveMutation(
                        message.toolName, false, 0, 0, ""))))
        {
            count = 0;
            continue;
        }
        if (message.role != "tool" || message.toolName.length == 0)
            continue;
        if (message.toolName ~ "|" ~ message.toolArgs == signature)
            ++count;
    }
    return count;
}

public bool hasExhaustedRepeatedCall(
    const ref ChatSession session, const(OpenCodeToolCall)[] calls)
{
    foreach (ref call; calls)
        if (toolCallRunCount(session, call) >= cumulativeRepeatLimit)
            return true;
    return false;
}

public string toolCallSignature(const(OpenCodeToolCall)[] calls)
{
    if (calls.length == 0) return "";
    auto builder = appender!string();
    foreach (call; calls)
        builder.put(call.name ~ "(" ~ call.arguments ~ ");");
    return builder.data;
}
