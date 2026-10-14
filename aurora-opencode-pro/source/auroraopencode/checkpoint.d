module auroraopencode.checkpoint;

/+
Optional file/folder checkpoints.

A checkpoint records an append boundary in Aurora's change journal (the same
journal the Changes dialog reads and restores; see tools.d). "Return to
checkpoint" reverts every tool-made file or folder change recorded after that
boundary, which is exactly "put my workspace back the way it was at this point".
Paths edited by other programs since are left untouched, using the same conflict
rule the Changes dialog already applies, so a checkpoint never clobbers newer
work.

This feature is deliberately self-contained so it is easy to remove:

    * delete this file;
    * delete the "experimental: checkpoint" blocks in
      source/auroraopencode/appui.d (the import, the toolbar button, the menu /
      save / return methods, the Settings checkbox, and the newChat() hook);
    * delete `changeJournalPath` in source/auroraopencode/tools.d.

The feature keeps its own small store (checkpoints/checkpoints.json under the
app state directory); it adds no field to the shared Settings struct, so
removing it needs no migration.
+/

import auroraopencode.core : ensureStateDirectory, opencodeStateDirectory;
import auroraopencode.tools : ChangeContext, changeJournalPath,
    revertChangeRecords;

import std.algorithm : sort;
import std.conv : to;
import std.datetime : Clock;
import std.file : exists, getSize, mkdirRecurse, read, rename, write;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath;
import std.string : splitLines, strip, toLower;

/// One saved point the workspace can be returned to.
struct Checkpoint
{
    string id;
    string label;
    string workspace;
    string conversationId;
    long createdAt;     // Unix seconds
    ulong markerBytes;  // change-journal byte length when the checkpoint was taken
}

private struct CheckpointStore
{
    bool enabled = true; // optional feature: available by default
    Checkpoint[] checkpoints;
}

private __gshared ulong _checkpointSequence;

/// Whether checkpoints are offered (the Settings switch). On by default.
bool checkpointFeatureEnabled()
{
    return loadStore().enabled;
}

void setCheckpointFeatureEnabled(bool enabled)
{
    auto store = loadStore();
    if (store.enabled == enabled) return;
    store.enabled = enabled;
    saveStore(store);
}

/// Checkpoints saved for `workspace`, newest first.
Checkpoint[] listCheckpoints(string workspace)
{
    const key = workspaceKey(workspace);
    Checkpoint[] result;
    foreach (cp; loadStore().checkpoints)
        if (workspaceKey(cp.workspace) == key) result ~= cp;
    sort!((a, b) => a.createdAt > b.createdAt)(result);
    return result;
}

/// Record the workspace's current position in the change journal. Cheap: it
/// only stats the journal, so it is safe to call at the start of every
/// conversation.
Checkpoint createCheckpoint(string workspace, string conversationId,
    string label)
{
    Checkpoint cp;
    cp.workspace = buildNormalizedPath(workspace);
    cp.conversationId = conversationId;
    cp.label = label.length > 0 ? label : "Checkpoint";
    cp.createdAt = Clock.currTime.toUnixTime();
    cp.markerBytes = journalBytes(cp.workspace);
    cp.id = to!string(Clock.currTime.stdTime) ~ "-" ~
        to!string(++_checkpointSequence);
    auto store = loadStore();
    store.checkpoints ~= cp;
    saveStore(store);
    return cp;
}

/// Return the workspace to a checkpoint: revert every tool-made change recorded
/// after it. Returns a short human-readable outcome for the status line.
string restoreCheckpoint(string workspace, string checkpointId)
{
    const normalized = buildNormalizedPath(workspace);
    const key = workspaceKey(normalized);
    auto store = loadStore();
    bool found;
    Checkpoint target;
    foreach (cp; store.checkpoints)
        if (cp.id == checkpointId && workspaceKey(cp.workspace) == key)
        {
            target = cp;
            found = true;
            break;
        }
    if (!found) return "That checkpoint no longer exists.";

    auto ids = journalRecordIds(normalized, target.markerBytes);
    if (ids.length == 0)
        return "Already at this checkpoint — no file changes to undo.";

    ChangeContext context;
    context.turnId = "checkpoint-restore";
    const outcome = revertChangeRecords(normalized, ids, context, true);
    if (!outcome.succeeded) return outcome.message;

    // Checkpoints saved after this one in the same workspace no longer describe
    // a reachable state, so drop them rather than let them restore a mixture of
    // old and new changes. Prune by insertion order, not timestamp: two
    // checkpoints can share the same whole second.
    bool reachedTarget;
    Checkpoint[] kept;
    foreach (cp; store.checkpoints)
    {
        if (workspaceKey(cp.workspace) != key)
        {
            kept ~= cp;
            continue;
        }
        if (!reachedTarget)
        {
            kept ~= cp;
            if (cp.id == target.id) reachedTarget = true;
        }
    }
    store.checkpoints = kept;
    saveStore(store);

    return outcome.message ~ " Returned to \"" ~ target.label ~ "\".";
}

/// A compact "how long ago" label for menus, e.g. "just now", "7m ago".
string checkpointAge(long createdAt)
{
    const seconds = Clock.currTime.toUnixTime() - createdAt;
    if (seconds < 5) return "just now";
    if (seconds < 60) return to!string(seconds) ~ "s ago";
    const minutes = seconds / 60;
    if (minutes < 60) return to!string(minutes) ~ "m ago";
    const hours = minutes / 60;
    if (hours < 48) return to!string(hours) ~ "h ago";
    return to!string(hours / 24) ~ "d ago";
}

// -- internals ---------------------------------------------------------------

private string workspaceKey(string workspace)
{
    return buildNormalizedPath(workspace).toLower();
}

private string checkpointStorePath()
{
    ensureStateDirectory();
    return buildPath(opencodeStateDirectory(), "checkpoints",
        "checkpoints.json");
}

private ulong journalBytes(string workspace)
{
    const path = changeJournalPath(workspace);
    if (!exists(path)) return 0;
    try return getSize(path);
    catch (Exception) return 0;
}

/// Ids of journal records appended after `markerBytes`. Records written by a
/// previous restore ("revert") are skipped so repeated returns stay idempotent
/// instead of re-applying an undo.
private string[] journalRecordIds(string workspace, ulong markerBytes)
{
    const path = changeJournalPath(workspace);
    if (!exists(path)) return [];
    string text;
    try text = cast(string) read(path);
    catch (Exception) return [];
    if (markerBytes >= text.length) return [];
    string[] ids;
    foreach (line; text[cast(size_t) markerBytes .. $].splitLines())
    {
        const trimmed = line.strip();
        if (trimmed.length == 0) continue;
        try
        {
            auto value = parseJSON(trimmed);
            if (value.type != JSONType.object) continue;
            if (auto name = "toolName" in value.object)
                if (name.type == JSONType.string && name.str == "revert")
                    continue;
            if (auto id = "id" in value.object)
                if (id.type == JSONType.string && id.str.length > 0)
                    ids ~= id.str;
        }
        catch (Exception) {}
    }
    return ids;
}

private CheckpointStore loadStore()
{
    CheckpointStore store;
    const path = checkpointStorePath();
    if (!exists(path)) return store;
    string text;
    try text = cast(string) read(path);
    catch (Exception) return store;
    try
    {
        auto root = parseJSON(text);
        if (root.type != JSONType.object) return store;
        if (auto enabled = "enabled" in root.object)
            if (enabled.type == JSONType.true_ ||
                enabled.type == JSONType.false_)
                store.enabled = enabled.type == JSONType.true_;
        if (auto list = "checkpoints" in root.object)
            if (list.type == JSONType.array)
                foreach (item; list.array)
                {
                    if (item.type != JSONType.object) continue;
                    Checkpoint cp;
                    cp.id = jsonString(item, "id");
                    cp.label = jsonString(item, "label");
                    cp.workspace = jsonString(item, "workspace");
                    cp.conversationId = jsonString(item, "conversationId");
                    cp.createdAt = jsonLong(item, "createdAt");
                    cp.markerBytes = cast(ulong) jsonLong(item, "markerBytes");
                    if (cp.id.length > 0) store.checkpoints ~= cp;
                }
    }
    catch (Exception) {}
    return store;
}

private void saveStore(const CheckpointStore store)
{
    try
    {
        const path = checkpointStorePath();
        const directory = buildPath(opencodeStateDirectory(), "checkpoints");
        if (!exists(directory)) mkdirRecurse(directory);
        JSONValue root;
        root["enabled"] = JSONValue(store.enabled);
        JSONValue list = JSONValue(string[].init);
        foreach (cp; store.checkpoints)
        {
            JSONValue item;
            item["id"] = JSONValue(cp.id);
            item["label"] = JSONValue(cp.label);
            item["workspace"] = JSONValue(cp.workspace);
            item["conversationId"] = JSONValue(cp.conversationId);
            item["createdAt"] = JSONValue(cp.createdAt);
            item["markerBytes"] = JSONValue(cast(long) cp.markerBytes);
            list.array ~= item;
        }
        root["checkpoints"] = list;
        const temporary = path ~ ".tmp";
        write(temporary, root.toString());
        rename(temporary, path);
    }
    catch (Exception) {}
}

private string jsonString(JSONValue root, string key)
{
    if (root.type != JSONType.object) return "";
    if (auto field = key in root.object)
        if (field.type == JSONType.string) return field.str;
    return "";
}

private long jsonLong(JSONValue root, string key)
{
    if (root.type != JSONType.object) return 0;
    if (auto field = key in root.object)
        if (field.type == JSONType.integer) return field.integer;
    return 0;
}
