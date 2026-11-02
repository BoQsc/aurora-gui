module auroraopencode.restorestore;

import auroraopencode.core : ChatMessage, ChatSession;
import auroraopencode.atomicfile : preserveBackupOnNextWrite;
import auroraopencode.runtime : AgentRuntime, AgentRuntimeEvent, AgentEventKind,
    projectAgentRuntimeEvents, deletedAgentRuntimeThreadIds;
import auroraopencode.attachmentstore : AttachmentStore;
import auroraopencode.conversationcodec : decodeSessionMetadata, decodeMessages;
import std.json : JSONValue, JSONType, parseJSON;
import std.file : exists, readText, dirEntries, SpanMode;
import std.path : buildPath, baseName;
import std.string : startsWith, indexOf;
import std.conv : to;
import std.algorithm : splitter;

public struct RestoredHistory
{
    ChatMessage[] messages;
    string error;
}

public struct LegacySnapshot
{
    ChatSession[] sessions;
    int current = -1;
    bool hasCurrent;
    string currentId;
}

/// Detached startup input. Only the storage owner performs reads; the UI
/// receives this bundle after every required range has either loaded or failed.
public struct RestoreBundle
{
    JSONValue index, pins, archived;
    ChatSession[] sessions;
    LegacySnapshot[string] legacySnapshots;
    string[] candidates;
    RestoredHistory[string] histories;
    AgentRuntimeEvent[] events;
    ChatSession[] journalSessions;
    JSONValue[string] journalPatches;
    string[] deletedThreads;
    ulong sequence, bytes, foldedSequence, foldedOffset;
    bool folded;
    string journalError;
    string[] errors;
}

public bool readRestoreMarker(string directory, out ulong sequence, out ulong offset)
{
    try
    {
        const path = buildPath(directory, "journal.folded");
        if (!exists(path)) return false;
        auto fields = readText(path).splitter();
        if (fields.empty) return false;
        sequence = to!ulong(fields.front); fields.popFront();
        offset = fields.empty ? 0 : to!ulong(fields.front);
        return true;
    }
    catch (Exception) return false;
}

public string historyFilePath(string directory, string id)
{
    char[] safe;
    foreach (ch; id)
        safe ~= ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
            (ch >= '0' && ch <= '9') || ch == '-' || ch == '_') ? ch : '_';
    return buildPath(directory, "threads", (safe.length ? safe.idup : "unnamed") ~ ".json");
}

private bool usableIndex(ref JSONValue value)
{
    if (value.type != JSONType.object) return false;
    if (auto versionField = "version" in value.object)
        if (versionField.type != JSONType.integer || versionField.integer != 2) return false;
    auto sessions = "sessions" in value.object;
    return sessions !is null && sessions.type == JSONType.array;
}

public RestoredHistory readThreadHistory(string directory, string id)
{
    RestoredHistory result;
    try
    {
        const path = historyFilePath(directory, id);
        if (!exists(path)) throw new Exception("Conversation file is missing");
        auto value = parseJSON(readText(path));
        if (value.type != JSONType.object) throw new Exception("Invalid conversation file");
        auto messages = "messages" in value.object;
        if (messages is null || messages.type != JSONType.array)
            throw new Exception("Conversation messages are missing or invalid");
        auto attachments = AttachmentStore(buildPath(directory, "attachments"));
        attachments.hydrate(*messages);
        ChatSession detached; detached.id = id;
        decodeMessages(*messages, detached);
        result.messages = detached.messages;
    }
    catch (Exception error) { result.error = error.msg; }
    return result;
}

public RestoreBundle readRestoreBundle(string directory, AgentRuntime runtime)
{
    RestoreBundle result;
    JSONValue readJson(string path)
    {
        try { if (exists(path)) return parseJSON(readText(path)); }
        catch (Exception error) { result.errors ~= path ~ ": " ~ error.msg; }
        return JSONValue.init;
    }
    result.pins = readJson(buildPath(directory, "pins.json"));
    result.archived = readJson(buildPath(directory, "archived.json"));
    const primaryIndex = buildPath(directory, "threads.index.json");
    const backupIndex = primaryIndex ~ ".bak";
    const hadIndex = exists(primaryIndex) || exists(backupIndex);
    result.index = readJson(primaryIndex);
    const primaryValid = usableIndex(result.index);
    if (!primaryValid)
    {
        result.index = readJson(buildPath(directory, "threads.index.json.bak"));
        if (usableIndex(result.index)) preserveBackupOnNextWrite(primaryIndex);
    }
    result.folded = readRestoreMarker(directory, result.foldedSequence, result.foldedOffset);
    // A backup can predate the fold marker. Replay the authority in full when
    // the corresponding primary index cannot be trusted.
    if (!primaryValid)
    {
        result.folded = false;
        result.foldedSequence = result.foldedOffset = 0;
    }
    try
    {
        // The ordered read also waits for journal initialization off the UI
        // thread. An empty result is success, never a reason to reread on UI.
        result.events = runtime.eventsFrom(result.folded ? result.foldedOffset : 0);
        result.sequence = runtime.latestSequence();
        result.bytes = runtime.journalSize();
        if (result.foldedSequence > result.sequence || result.foldedOffset > result.bytes)
        {
            result.folded = false;
            result.foldedSequence = result.foldedOffset = 0;
            result.events = runtime.eventsFrom(0);
        }
    }
    catch (Throwable error) { result.journalError = error.msg; }

    if (usableIndex(result.index))
    {
        auto sessions = result.index["sessions"].array;
        int current;
        string currentId;
        if (auto field = "current" in result.index.object)
            if (field.type == JSONType.integer) current = cast(int) field.integer;
        if (auto field = "currentId" in result.index.object)
            if (field.type == JSONType.string) currentId = field.str;
        if (current < 0 || current >= sessions.length) current = 0;
        bool[string] needed, indexed, changed, completeCopies;
        foreach (event; result.events) if (event.threadId.length)
        {
            needed[event.threadId] = true; changed[event.threadId] = true;
            if (event.kind == AgentEventKind.threadStarted && event.parsedPayload.type == JSONType.object)
                if (auto snapshot = "snapshot" in event.parsedPayload.object)
                    if (snapshot.type == JSONType.object)
                        if (auto messages = "messages" in snapshot.object)
                            if (messages.type == JSONType.array) completeCopies[event.threadId] = true;
        }
        bool matchedCurrent;
        foreach (i, session; sessions)
        {
            if (session.type != JSONType.object) throw new Exception("Invalid conversation metadata");
            auto id = "id" in session.object;
            if (id is null || id.type != JSONType.string || !id.str.length)
                throw new Exception("Conversation identity is missing");
            ChatSession metadata;
            decodeSessionMetadata(session, metadata);
            result.sessions ~= metadata;
            indexed[id.str] = true;
            if (id.str == currentId) { needed[id.str] = true; matchedCurrent = true; }
            if (auto field = "turnStatus" in session.object)
                if (field.type == JSONType.string && field.str == "running") needed[id.str] = true;
            if (auto field = "goalStatus" in session.object)
                if (field.type == JSONType.string && field.str == "active") needed[id.str] = true;
        }
        if (!matchedCurrent && sessions.length && sessions[current].type == JSONType.object)
            if (auto id = "id" in sessions[current].object)
                if (id.type == JSONType.string) needed[id.str] = true;
        foreach (id, _; needed)
        {
            auto history = readThreadHistory(directory, id);
            if (history.error.length && id in completeCopies) history = RestoredHistory.init;
            if (history.error.length && id in indexed && id in changed)
                result.journalError = "Conversation " ~ id ~ " needs recovery before its journal can be merged: " ~ history.error;
            result.histories[id] = history;
        }
    }
    else
    {
        result.index = JSONValue.init;
        string[] candidates = [buildPath(directory, "sessions.recovery.json"),
            buildPath(directory, "sessions.json")];
        try
        {
            foreach (entry; dirEntries(directory, SpanMode.shallow))
            {
                const name = baseName(entry.name);
                if (!entry.isFile || !name.startsWith("sessions") || name.indexOf(".json") < 0 ||
                    name.indexOf(".bad") >= 0 || name.indexOf(".preserve") >= 0) continue;
                candidates ~= entry.name;
            }
        }
        catch (Exception error) { result.errors ~= error.msg; }
        bool[string] seen;
        bool hadSnapshot;
        bool canonicalLoaded;
        foreach (path; candidates)
        {
            if (path in seen) continue;
            seen[path] = true;
            const name = baseName(path);
            if (canonicalLoaded && (name.indexOf(".bak") >= 0 || name.indexOf(".tmp") >= 0)) continue;
            hadSnapshot |= exists(path);
            auto value = readJson(path);
            if (value.type != JSONType.object) continue;
            auto sessions = "sessions" in value.object;
            if (sessions is null || sessions.type != JSONType.array) continue;
            auto attachments = AttachmentStore(buildPath(directory, "attachments"));
            attachments.hydrate(value);
            try
            {
                LegacySnapshot snapshot;
                if (auto current = "current" in value.object)
                    if (current.type == JSONType.integer)
                    { snapshot.current = cast(int) current.integer; snapshot.hasCurrent = true; }
                foreach (sessionValue; sessions.array)
                {
                    if (sessionValue.type != JSONType.object) throw new Exception("Invalid conversation metadata");
                    ChatSession session;
                    decodeSessionMetadata(sessionValue, session);
                    if (auto messages = "messages" in sessionValue.object) decodeMessages(*messages, session);
                    snapshot.sessions ~= session;
                }
                if (snapshot.current >= 0 && snapshot.current < snapshot.sessions.length)
                    snapshot.currentId = snapshot.sessions[snapshot.current].id;
                result.candidates ~= path;
                result.legacySnapshots[path] = snapshot;
                if (name == "sessions.json") canonicalLoaded = true;
            }
            catch (Exception error) { result.errors ~= path ~ ": " ~ error.msg; }
        }
        // An existing store is not a fresh installation. Keep it unavailable
        // for repair rather than overwriting it with a partial journal view.
        if ((hadIndex || hadSnapshot) && !result.candidates.length)
            result.journalError = "Saved conversation indexes could not be read. Original files are preserved.";
    }
    if (!result.journalError.length)
    {
        result.journalSessions = projectAgentRuntimeEvents(result.events, true, &result.journalPatches);
        result.deletedThreads = deletedAgentRuntimeThreadIds(result.events);
    }
    return result;
}
