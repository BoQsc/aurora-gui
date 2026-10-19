module auroraopencode.workevidence;

import auroraopencode.core : ChatSession, ChatMessage;
import std.algorithm : canFind;
import std.array : appender;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.json : JSONValue, JSONType, parseJSON;
import std.string : strip, startsWith, lastIndexOf, toLower, splitLines;

private string excerpt(string text, size_t bytes)
{
    if (text.length <= bytes) return text;
    if (bytes < 4) return "";
    auto cut = bytes - 3;
    while (cut && (cast(ubyte)text[cut] & 0xC0) == 0x80) --cut;
    return text[0 .. cut] ~ "...";
}

private string diagnosticExcerpt(string text)
{
    const receipt = text.lastIndexOf("\nVerification receipt: ");
    if (receipt >= 0) text = text[0 .. receipt];
    if (text.length <= 360) return text;
    string focus;
    foreach_reverse (line; text.splitLines())
    {
        const lower = line.toLower();
        if (lower.canFind("assertionerror") || lower.canFind("error:") || lower.canFind("exception:") ||
            lower.canFind("fatal ") || lower.canFind("expected "))
        {
            focus = excerpt(line, 240) ~ "\n" ~ focus;
            if (focus.length >= 240) break;
        }
    }
    const tail = focus.length ? 72 : 240;
    size_t begin = text.length - tail;
    while (begin < text.length && (cast(ubyte)text[begin] & 0xC0) == 0x80) ++begin;
    return (focus.length ? excerpt(focus, 280) : excerpt(text, 100)) ~ "\n...\n" ~ text[begin .. $];
}

private string resultBody(string text)
{
    const footer = text.lastIndexOf("\nProcess exited with code ");
    if (footer >= 0) text = text[0 .. footer];
    text = text.strip();
    if (text == "Process exited with code 0.") return "";
    return text;
}

/// Different arguments with identical observations are not new findings.
/// A checker receipt can still establish a first successful check without stdout.
string observedResultKey(const ref ChatMessage message)
{
    if (message.role != "tool" || message.failed || ["update_plan", "read_plan", "update_subplan", "process",
            "tool_status", "request_input", "task_blocker", "retire_images", "assign", "finish", "ask_user"].canFind(message.toolName)) return "";
    const body = resultBody(message.content);
    const lower = body.toLower();
    if (lower.startsWith("no matches") || lower.startsWith("no results") || lower.startsWith("no files") || lower.startsWith("0 matches")) return "";
    if (!body.length && !message.toolDiff.length && !message.verificationCheck.length) return "";
    return sha256Of(message.toolName ~ "\n" ~ body ~ "\n" ~ message.toolDiff ~ "\n" ~ message.verificationCheck).toHexString().idup;
}

private string resultTarget(const ref ChatMessage message)
{
    try
    {
        const arguments = parseJSON(message.toolArgs);
        if (arguments.type == JSONType.object)
        {
            foreach (key; ["filePath", "recipe", "path", "url"])
                if (auto value = key in arguments.object)
                    if (value.type == JSONType.string) return value.str;
            return arguments.toString();
        }
    }
    catch (Exception) {}
    return message.toolArgs;
}

/// A bounded projection of actual tool results. Never promotes a tool's text
/// into instructions or interprets a successful exit as behavioral correctness.
string recentWorkBrief(const ref ChatSession session, const(size_t)[] path, size_t budget = 1400)
{
    if (budget < 256) return "";
    size_t[string] unresolved;
    const begin = path.length > 128 ? path.length - 128 : 0;
    foreach (index; path[begin .. $])
    {
        const ref message = session.messages[index];
        if (message.role != "tool" || ["update_plan", "read_plan", "update_subplan"].canFind(message.toolName)) continue;
        const target = message.toolName ~ "\n" ~ resultTarget(message);
        if (message.failed) unresolved[target] = index;
        else unresolved.remove(target);
    }
    auto output = appender!string();
    bool add(string label, size_t index, bool diagnostic)
    {
        const ref message = session.messages[index];
        JSONValue value;
        value["call"] = message.toolCallId.length ? message.toolCallId : message.id;
        value["tool"] = message.toolName;
        value["target"] = excerpt(resultTarget(message), 180);
        if (diagnostic) value["output"] = diagnosticExcerpt(message.content);
        auto row = label ~ value.toString() ~ "\n";
        if (output.data.length + row.length > budget) return false;
        output.put(row);
        return true;
    }
    size_t failures, changes;
    foreach_reverse (index; path[begin .. $])
    {
        const ref message = session.messages[index];
        if (message.role != "tool" || !message.failed) continue;
        const target = message.toolName ~ "\n" ~ resultTarget(message);
        if (auto latest = target in unresolved)
            if (*latest == index && failures < 2 && add("Failed call (no later success for this target): ", index, true)) ++failures;
    }
    foreach_reverse (index; path[begin .. $])
    {
        const ref message = session.messages[index];
        const nativeChange = message.workspaceChanged && ["write", "edit", "apply_patch", "copy", "move", "rename",
            "remove", "create_folder", "download"].canFind(message.toolName);
        if (message.role != "tool" || message.failed ||
            !(nativeChange || message.diffAdditions || message.diffDeletions || message.toolDiff.length)) continue;
        if (changes < 2 && add("Observed change (verification separate): ", index, false)) ++changes;
    }
    return output.data;
}
