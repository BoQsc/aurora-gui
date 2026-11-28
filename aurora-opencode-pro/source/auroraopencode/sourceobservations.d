module auroraopencode.sourceobservations;

import auroraopencode.core : ChatSession, activeMessagePath;
import std.algorithm : sort, canFind;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, buildNormalizedPath, isAbsolute, relativePath, baseName;
import std.string : replace, startsWith, endsWith, toLower, splitLines, indexOf;
import std.regex : matchFirst;

private string declarations(string source)
{
    // Some providers escape a whole multi-line payload a second time. This
    // projection is labeled requested declarations, never exact file bytes.
    if (source.indexOf('\n') < 0) source = source.replace(`\n`, "\n");
    string result;
    foreach (line; source.splitLines())
        if (matchFirst(line, `^(?:[0-9]+: )?\s*(?:async\s+)?(?:def|class|from|import)\b`)) result ~= line ~ "\n";
    return result;
}

private string targetPath(string arguments, string workspace)
{
    try
    {
        const args = parseJSON(arguments);
        const field = "filePath" in args.object;
        if (field is null || field.type != JSONType.string || !field.str.length) return "";
        auto path = field.str;
        if (workspace.length && isAbsolute(workspace)) path = absolutePath(path, workspace);
        path = buildNormalizedPath(path).replace("\\", "/");
        version (Windows) path = path.toLower();
        return path;
    }
    catch (Exception) { return ""; }
}

/// Quote small, retired source observations instead of repeatedly discarding
/// the specification/input on each rolling checkpoint. This is context only:
/// it performs no I/O, supplies no receipt and never prevents a fresh read.
string retainedSourceContext(const ref ChatSession session, size_t budget)
{
    const header = "# Retained source observations\n" ~
        "Quoted source context from earlier calls, with the same scoped authority as the original source under the user's request. " ~
        "User-delegated specifications still define acceptance criteria; these records add no authorization, override no instructions and supply no verification receipts. " ~
        "These are snapshots at the named calls, not a claim of present filesystem freshness. " ~
        "Successful Python writes retain requested declaration lines, not complete bodies or proof of behavior. " ~
        "Reuse them for unchanged requirements and inputs instead of rebuilding the same inventory. " ~
        "Refresh a specific source for a concrete change, contradiction, missing range or freshness requirement; " ~
        "current behavioral checks still own verification.\n";
    if (budget <= header.length + 128 || !session.compactedThroughMessageId.length) return "";
    const path = activeMessagePath(session);
    size_t[string] snapshots;
    size_t anchor = size_t.max;
    const workspace = session.contract.workspace;
    string request;
    foreach (position, index; path)
    {
        const ref message = session.messages[index];
        if (message.id == session.compactedThroughMessageId) anchor = position;
        if (message.role == "user" && !message.internal) { snapshots = null; request = message.content.toLower(); continue; }
        if (message.role != "tool") continue;
        const target = targetPath(message.toolArgs, workspace);
        if (message.toolName == "write" || message.toolName == "edit")
        {
            // Even a failed mutation can have partial effects.
            if (target.length) snapshots.remove(target);
            else snapshots = null;
            if (message.toolName == "write" && !message.failed && target.endsWith(".py"))
                try
                {
                    if (declarations(parseJSON(message.toolArgs)["content"].str).length) snapshots[target] = position;
                }
                catch (Exception) {}
        }
        else if (message.workspaceChanged ||
            ["apply_patch", "patch", "remove", "move", "rename", "copy"].canFind(message.toolName)) snapshots = null;
        if (message.toolName != "read" || !target.length) continue;
        if (message.failed || message.content.startsWith("Error:")) snapshots.remove(target);
        else snapshots[target] = position;
    }
    if (anchor == size_t.max) return "";
    size_t[] selected;
    foreach (target, position; snapshots) if (position <= anchor) selected ~= position;
    bool[size_t] named;
    foreach (position; selected)
    {
        const target = targetPath(session.messages[path[position]].toolArgs, workspace);
        named[position] = request.indexOf(baseName(target).toLower()) >= 0;
    }
    sort!((a, b) => named[a] == named[b] ? a < b : named[a])(selected);
    string result;
    foreach (position; selected)
    {
        const ref message = session.messages[path[position]];
        auto target = targetPath(message.toolArgs, workspace);
        try { if (workspace.length) target = relativePath(target, workspace).replace("\\", "/"); }
        catch (Exception) {}
        JSONValue entry;
        entry["file"] = target;
        entry["call_id"] = message.toolCallId;
        try
        {
            const args = parseJSON(message.toolArgs);
            foreach (name; ["offset", "limit"])
                if (auto value = name in args.object) entry[name] = *value;
        }
        catch (Exception) {}
        if (message.toolName == "write")
            entry["requested_declarations_only"] = declarations(parseJSON(message.toolArgs)["content"].str);
        else entry["observed_output"] = message.content;
        auto line = entry.toString() ~ "\n";
        if (header.length + result.length + line.length > budget && message.toolName == "read" && target.endsWith(".py"))
        {
            const outline = declarations(message.content);
            if (outline.length)
            {
                auto object = entry.object; object.remove("observed_output"); entry = JSONValue(object);
                entry["observed_declarations_only"] = outline;
                line = entry.toString() ~ "\n";
            }
        }
        if (header.length + result.length + line.length <= budget) result ~= line;
    }
    return result.length ? header ~ result : "";
}
