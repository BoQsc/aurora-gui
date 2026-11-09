module auroraopencode.toolprogresspolicy;

import auroraopencode.core;
import auroraopencode.tools : partialStringArg;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : extension;
import std.string : startsWith, strip, splitLines, toLower;
import std.array : appender;
import std.conv : to;


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
        name == "create_folder" || name == "remove" || name == "download" || name == "archive" || name == "data";
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

public string toolCallSignature(const(OpenCodeToolCall)[] calls)
{
    if (calls.length == 0) return "";
    auto builder = appender!string();
    foreach (call; calls)
        builder.put(call.name ~ "(" ~ call.arguments ~ ");");
    return builder.data;
}
