module auroraopencode.runtime;

/**
 * Backend-neutral agent runtime events.
 *
 * The desktop UI should consume this vocabulary instead of owning provider,
 * process and persistence state directly. The existing Aurora engine is the
 * first producer; Codex App Server and other engines can later be adapters
 * that publish the same thread/turn/item lifecycle.
 */

import std.datetime.systime : Clock;
import std.file : exists, getSize, mkdirRecurse;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : dirName;
import std.stdio : File;
import core.stdc.stdio : SEEK_END;

public enum AgentEventKind
{
    threadStarted,
    threadUpdated,
    threadDeleted,
    turnStarted,
    turnCompleted,
    turnInterrupted,
    turnFailed,
    itemAdded,
    itemUpdated,
}

public string agentEventKindName(AgentEventKind kind)
{
    final switch (kind)
    {
        case AgentEventKind.threadStarted: return "thread.started";
        case AgentEventKind.threadUpdated: return "thread.updated";
        case AgentEventKind.threadDeleted: return "thread.deleted";
        case AgentEventKind.turnStarted: return "turn.started";
        case AgentEventKind.turnCompleted: return "turn.completed";
        case AgentEventKind.turnInterrupted: return "turn.interrupted";
        case AgentEventKind.turnFailed: return "turn.failed";
        case AgentEventKind.itemAdded: return "item.added";
        case AgentEventKind.itemUpdated: return "item.updated";
    }
}

private bool parseAgentEventKind(string name, out AgentEventKind kind)
{
    foreach (candidate; [AgentEventKind.threadStarted,
        AgentEventKind.threadUpdated, AgentEventKind.threadDeleted,
        AgentEventKind.turnStarted, AgentEventKind.turnCompleted,
        AgentEventKind.turnInterrupted, AgentEventKind.turnFailed,
        AgentEventKind.itemAdded, AgentEventKind.itemUpdated])
    {
        if (agentEventKindName(candidate) == name)
        {
            kind = candidate;
            return true;
        }
    }
    return false;
}

public struct AgentRuntimeEvent
{
    int schemaVersion = 1;
    ulong sequence;
    long recordedAt;
    AgentEventKind kind;
    string threadId;
    string turnId;
    string itemId;
    string itemKind;
    string payloadJson = "{}";
}

/// The small boundary the UI and engine share. Publishing is deliberately
/// synchronous and append-only: once an action is visible in the transcript,
/// its recovery record is already on disk.
public interface AgentRuntime
{
    bool publish(AgentRuntimeEvent event);
    AgentRuntimeEvent[] history();
    string lastError() const;
}

public final class DurableAgentRuntime : AgentRuntime
{
    private string _path;
    private ulong _nextSequence = 1;
    private string _lastError;

    public this(string path)
    {
        _path = path;
        foreach (event; readAgentRuntimeEvents(path))
            if (event.sequence >= _nextSequence)
                _nextSequence = event.sequence + 1;
    }

    public bool publish(AgentRuntimeEvent event)
    {
        try
        {
            const parent = dirName(_path);
            if (parent.length > 0 && !exists(parent)) mkdirRecurse(parent);
            // A process death can tear the final JSON object before its line
            // terminator. Separate that fragment from the next valid record so
            // recovery loses at most the in-flight event, never its successor.
            ensureAppendBoundary();
            event.schemaVersion = 1;
            event.sequence = _nextSequence;
            event.recordedAt = Clock.currTime.stdTime;
            auto file = File(_path, "a");
            file.writeln(eventToJson(event).toString());
            file.flush();
            ++_nextSequence;
            _lastError = "";
            return true;
        }
        catch (Exception error)
        {
            _lastError = error.msg;
            return false;
        }
    }

    public AgentRuntimeEvent[] history()
    {
        return readAgentRuntimeEvents(_path);
    }

    public string lastError() const
    {
        return _lastError;
    }

    private void ensureAppendBoundary()
    {
        if (!exists(_path) || getSize(_path) == 0) return;
        auto reader = File(_path, "rb");
        reader.seek(-1, SEEK_END);
        ubyte[1] tail;
        reader.rawRead(tail[]);
        reader.close();
        if (tail[0] == '\n') return;
        auto repair = File(_path, "a");
        repair.write("\n");
        repair.flush();
        repair.close();
    }
}

private JSONValue eventToJson(const ref AgentRuntimeEvent event)
{
    JSONValue root;
    root["schema"] = event.schemaVersion;
    root["sequence"] = cast(long) event.sequence;
    root["recordedAt"] = event.recordedAt;
    root["type"] = agentEventKindName(event.kind);
    root["threadId"] = event.threadId;
    if (event.turnId.length > 0) root["turnId"] = event.turnId;
    if (event.itemId.length > 0) root["itemId"] = event.itemId;
    if (event.itemKind.length > 0) root["itemKind"] = event.itemKind;
    try root["payload"] = parseJSON(event.payloadJson);
    catch (Exception) root["payload"] = JSONValue(event.payloadJson);
    return root;
}

private bool eventFromJson(JSONValue root, out AgentRuntimeEvent event)
{
    if (root.type != JSONType.object) return false;
    auto type = "type" in root.object;
    auto thread = "threadId" in root.object;
    if (type is null || type.type != JSONType.string ||
        thread is null || thread.type != JSONType.string ||
        !parseAgentEventKind(type.str, event.kind))
        return false;
    event.threadId = thread.str;
    if (auto field = "schema" in root.object)
        if (field.type == JSONType.integer)
            event.schemaVersion = cast(int) field.integer;
    if (auto field = "sequence" in root.object)
        if (field.type == JSONType.integer)
            event.sequence = cast(ulong) field.integer;
    if (auto field = "recordedAt" in root.object)
        if (field.type == JSONType.integer)
            event.recordedAt = field.integer;
    if (auto field = "turnId" in root.object)
        if (field.type == JSONType.string) event.turnId = field.str;
    if (auto field = "itemId" in root.object)
        if (field.type == JSONType.string) event.itemId = field.str;
    if (auto field = "itemKind" in root.object)
        if (field.type == JSONType.string) event.itemKind = field.str;
    if (auto field = "payload" in root.object)
        event.payloadJson = field.toString();
    return true;
}

/** Read every complete event, ignoring an invalid final line left by a crash. */
public AgentRuntimeEvent[] readAgentRuntimeEvents(string path)
{
    AgentRuntimeEvent[] result;
    if (!exists(path)) return result;
    try
    {
        auto file = File(path, "r");
        foreach (line; file.byLineCopy())
        {
            try
            {
                AgentRuntimeEvent event;
                if (eventFromJson(parseJSON(line), event)) result ~= event;
            }
            catch (Exception)
            {
                // JSONL makes crash recovery local: one torn record cannot make
                // the already-flushed history unreadable.
            }
        }
    }
    catch (Exception)
    {
        // Startup must remain usable even when the optional journal is damaged.
    }
    return result;
}

unittest
{
    import std.conv : to;
    import std.file : remove, tempDir;
    import std.path : buildPath;

    const path = buildPath(tempDir(), "aurora-runtime-" ~
        to!string(Clock.currTime.stdTime) ~ ".jsonl");
    scope (exit) if (exists(path)) remove(path);

    auto runtime = new DurableAgentRuntime(path);
    AgentRuntimeEvent first;
    first.kind = AgentEventKind.threadStarted;
    first.threadId = "thread-1";
    first.payloadJson = `{ "title": "Durable task" }`;
    assert(runtime.publish(first));

    AgentRuntimeEvent second;
    second.kind = AgentEventKind.itemAdded;
    second.threadId = "thread-1";
    second.turnId = "turn-1";
    second.itemId = "message-1";
    second.itemKind = "userMessage";
    second.payloadJson = `{ "content": "Keep going" }`;
    assert(runtime.publish(second));

    // Simulate a crash during the next append. Previously flushed events must
    // still replay and a restarted writer must continue their sequence.
    auto torn = File(path, "a");
    torn.write(`{"sequence":`);
    torn.close();
    auto replayed = readAgentRuntimeEvents(path);
    assert(replayed.length == 2);
    assert(replayed[0].sequence == 1 && replayed[1].sequence == 2);
    assert(replayed[1].payloadJson == `{"content":"Keep going"}`);

    auto restarted = new DurableAgentRuntime(path);
    AgentRuntimeEvent third;
    third.kind = AgentEventKind.turnCompleted;
    third.threadId = "thread-1";
    third.turnId = "turn-1";
    assert(restarted.publish(third));
    replayed = readAgentRuntimeEvents(path);
    assert(replayed.length == 3);
    assert(replayed[$ - 1].sequence == 3);
}
