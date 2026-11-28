module auroraopencode.sourceobservations;

import auroraopencode.core : ChatSession, activeMessagePath;
import std.algorithm : sort, canFind;
import std.json : JSONValue, JSONType, parseJSON;
import std.path : absolutePath, buildNormalizedPath, isAbsolute, relativePath, baseName;
import std.string : replace, startsWith, endsWith, toLower, splitLines, indexOf;
import std.regex : matchFirst;
import auroraopencode.sourcesnapshot;
import core.time : MonoTime, msecs;
import std.conv : to;

private string numberedSource(string content)
{
    string result;
    foreach (i, line; content.splitLines()) result ~= to!string(i + 1) ~ ": " ~ line ~ "\n";
    return result;
}

private string sourceExcerpt(string output, size_t limit, size_t focus)
{
    string result;
    foreach (line; output.splitLines())
    {
        const m = matchFirst(line, `^([0-9]+): `);
        if (!m.length) continue;
        size_t number;
        try { number = to!size_t(m[1]); } catch (Exception) { continue; }
        if (focus && (number + 18 < focus || number > focus + 18)) continue;
        if (result.length + line.length + 1 > limit) break;
        result ~= line ~ "\n";
    }
    return result;
}

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
        "Entries marked byte_identity_matches_at_request were checked by native code against the complete current file bytes during this request's preparation; do not recalculate that identity. " ~
        "Unmarked entries are historical snapshots. Later changes or a concrete contradiction require a focused refresh. " ~
        "A native stamped write may retain its confirmed text; legacy writes retain requested declarations only. Neither proves behavior. " ~
        "Reuse them for unchanged requirements and inputs instead of rebuilding the same inventory. " ~
        "Refresh a specific source for a concrete change, contradiction, missing range or freshness requirement; " ~
        "current behavioral checks still own verification.\n";
    if (budget <= header.length + 128 || !session.compactedThroughMessageId.length) return "";
    const path = activeMessagePath(session);
    size_t[][string] snapshots;
    const workspace = session.contract.workspace;
    const deadline = MonoTime.currTime + 50.msecs;
    bool[string] validated;
    bool current(string target, string hash)
    {
        if (!hash.length) return false;
        const key = target ~ "\n" ~ hash;
        if (auto known = key in validated) return *known;
        return validated[key] = sourceSnapshotCurrent(target, hash, workspace, deadline);
    }
    size_t anchor = size_t.max;
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
            if (message.toolName == "write" && !message.failed && target.length)
                try
                {
                    const content = parseJSON(message.toolArgs)["content"].str;
                    const identity = sourceSnapshotHash(message.content);
                    if ((identity.length && identity == sourceContentHash(content)) ||
                        (target.endsWith(".py") && declarations(content).length)) snapshots[target] = [position];
                }
                catch (Exception) {}
        }
        else if (message.workspaceChanged ||
            ["apply_patch", "patch", "remove", "move", "rename", "copy"].canFind(message.toolName))
        {
            // Preserve only resources whose actual current bytes still match
            // their own native stamp, never infer this from a command exit.
            foreach (resource; snapshots.keys)
            {
                const positions = snapshots[resource];
                const hash = sourceSnapshotHash(session.messages[path[positions[$-1]]].content);
                if (!current(resource, hash)) snapshots.remove(resource);
            }
        }
        else if (message.failed && (message.toolName == "verify" || message.verificationCheck.startsWith("verify:")))
        {
            // A native unchanged-workspace observation covers only this root,
            // never an absolute source reference in another checkout.
            auto observedRoot = isAbsolute(workspace) ? buildNormalizedPath(workspace).replace("\\", "/") : "";
            version (Windows) observedRoot = observedRoot.toLower();
            if (observedRoot.endsWith("/")) observedRoot = observedRoot[0 .. $ - 1];
            foreach (snapshot; snapshots.keys)
                if (!observedRoot.length || !snapshot.startsWith(observedRoot ~ "/")) snapshots.remove(snapshot);
        }
        if (message.toolName != "read" || !target.length) continue;
        if (message.failed || message.content.startsWith("Error:")) snapshots.remove(target);
        else
        {
            const hash = sourceSnapshotHash(message.content);
            // A complete stamped read supersedes earlier windows and confirmed
            // writes of this resource; do not spend context on the same body.
            bool complete = hash.length && message.content.startsWith("1: ") &&
                cast(bool)matchFirst(message.content, `(?m)^\(Showing lines 1-[0-9]+\. End of file\.\)\r?$`) &&
                message.content.indexOf("(line truncated)") < 0;
            if (complete) { snapshots[target]=[position]; continue; }
            auto positions = target in snapshots;
            if (positions !is null && positions.length)
            {
                const previous = sourceSnapshotHash(session.messages[path[(*positions)[$-1]]].content);
                if (hash != previous) snapshots.remove(target);
            }
            bool duplicate;
            if (auto prior = target in snapshots)
                foreach (ref old; *prior)
                    if (session.messages[path[old]].content == message.content)
                    { old = position; duplicate = true; break; }
            if (!duplicate) snapshots[target] ~= position;
        }
    }
    if (anchor == size_t.max) return "";
    size_t[] selected;
    foreach (target, positions; snapshots)
        foreach (position; positions)
            if (position <= anchor)
            {
                const hash = sourceSnapshotHash(session.messages[path[position]].content);
                if (!hash.length || current(target, hash)) selected ~= position;
            }
    // A concrete traceback selects the relevant already-observed source range.
    // It is not a request to reload every file in the project.
    size_t[string] locations;
    foreach_reverse (index; path)
    {
        const ref message = session.messages[index];
        if (message.role == "user" && !message.internal) break;
        if (message.role != "tool" || !message.failed) continue;
        import std.regex : matchAll;
        foreach (m; matchAll(message.content, `File ["']([^"']+)["'], line ([0-9]+)`))
            try { locations[baseName(m[1]).toLower()] = to!size_t(m[2]); } catch (Exception) {}
        if (locations.length) break;
    }
    bool[size_t] named;
    foreach (position; selected)
    {
        const target = targetPath(session.messages[path[position]].toolArgs, workspace);
        named[position] = request.indexOf(baseName(target).toLower()) >= 0 || (baseName(target).toLower() in locations) !is null;
    }
    sort!((a, b) => named[a] == named[b] ? a > b : named[a])(selected);
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
        const identity = sourceSnapshotHash(message.content);
        if (identity.length)
        { entry["source_sha256"]=identity; entry["byte_identity_matches_at_request"]=true; }
        try
        {
            const args = parseJSON(message.toolArgs);
            foreach (name; ["offset", "limit"])
                if (auto value = name in args.object) entry[name] = *value;
        }
        catch (Exception) {}
        string observed;
        if (message.toolName == "write")
        {
            const content = parseJSON(message.toolArgs)["content"].str;
            const hash = sourceSnapshotHash(message.content);
            if (hash.length && hash != sourceContentHash(content)) continue;
            if (hash.length && hash == sourceContentHash(content))
            { observed = numberedSource(content); entry["confirmed_written_source"] = observed; }
            else entry["requested_declarations_only"] = declarations(content);
        }
        else { observed = message.content; entry["observed_output"] = observed; }
        auto line = entry.toString() ~ "\n";
        if (header.length + result.length + line.length > budget && observed.length)
        {
            const spare = budget > header.length + result.length + 256 ? budget - header.length - result.length - 256 : 0;
            const location = baseName(target).toLower() in locations;
            const excerpt = sourceExcerpt(observed, spare * 3 / 4, location is null ? 0 : *location);
            const outline = declarations(observed.length ? observed : message.content);
            if (outline.length || excerpt.length)
            {
                auto object = entry.object; object.remove("observed_output"); object.remove("confirmed_written_source"); entry = JSONValue(object);
                entry["observed_declarations_only"] = outline;
                if (excerpt.length) entry["observed_source_excerpt"] = excerpt;
                entry["omitted_ranges"] = "Exact remaining text is saved at this call; retrieve only a concrete missing range.";
                line = entry.toString() ~ "\n";
            }
        }
        if (header.length + result.length + line.length <= budget) result ~= line;
    }
    return result.length ? header ~ result : "";
}
