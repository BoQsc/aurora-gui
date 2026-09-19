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
import auroraopencode.core : ChatMessage, ChatSession, OpenCodeToolCall,
    TaskStep, ensureMessageGraph;

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

/**
 * Rebuild thread snapshots from the append-only lifecycle stream.
 *
 * The JSON snapshot remains a fast cache, but this projection is the recovery
 * authority when that cache is missing, stale, or was torn during a crash.
 */
public ChatSession[] projectAgentRuntimeEvents(
    const(AgentRuntimeEvent)[] events)
{
    ChatSession[] sessions;
    size_t[string] positions;
    bool[string] deleted;

    foreach (event; events)
    {
        if (event.threadId.length == 0) continue;
        if (event.kind == AgentEventKind.threadDeleted)
        {
            deleted[event.threadId] = true;
            continue;
        }
        if (event.threadId in deleted &&
            event.kind != AgentEventKind.threadStarted) continue;
        if (event.kind == AgentEventKind.threadStarted)
            deleted.remove(event.threadId);
        size_t index;
        if (auto found = event.threadId in positions)
            index = *found;
        else
        {
            ChatSession session;
            session.id = event.threadId;
            sessions ~= session;
            index = sessions.length - 1;
            positions[event.threadId] = index;
        }
        auto session = &sessions[index];
        JSONValue payload;
        try payload = parseJSON(event.payloadJson);
        catch (Exception) payload = JSONValue.init;

        if (event.kind == AgentEventKind.threadStarted ||
            event.kind == AgentEventKind.threadUpdated)
        {
            applyThreadPayload(*session, payload);
            continue;
        }
        if (event.kind == AgentEventKind.turnStarted)
        {
            session.taskStatus = "active";
            continue;
        }
        if (event.kind == AgentEventKind.turnInterrupted ||
            event.kind == AgentEventKind.turnFailed)
        {
            session.taskStatus = "blocked";
            continue;
        }
        if (event.kind != AgentEventKind.itemAdded &&
            event.kind != AgentEventKind.itemUpdated) continue;

        ChatMessage message;
        bool foundMessage;
        size_t messageIndex;
        foreach (i, existing; session.messages)
            if (existing.id == event.itemId)
            {
                message = existing;
                messageIndex = i;
                foundMessage = true;
                break;
            }
        message.id = event.itemId;
        applyMessagePayload(message, payload);
        if (foundMessage) session.messages[messageIndex] = message;
        else session.messages ~= message;
        if (event.kind == AgentEventKind.itemAdded)
            session.activeLeafId = message.id;
    }

    ChatSession[] result;
    foreach (session; sessions)
    {
        if (session.id in deleted) continue;
        ensureMessageGraph(session);
        result ~= session;
    }
    return result;
}

public string[] deletedAgentRuntimeThreadIds(
    const(AgentRuntimeEvent)[] events)
{
    bool[string] deleted;
    foreach (event; events)
    {
        if (event.threadId.length == 0) continue;
        if (event.kind == AgentEventKind.threadDeleted)
            deleted[event.threadId] = true;
        else if (event.kind == AgentEventKind.threadStarted)
            deleted.remove(event.threadId);
    }
    string[] result;
    foreach (id, value; deleted) if (value) result ~= id;
    return result;
}

private void applyThreadPayload(ref ChatSession session, JSONValue payload)
{
    if (payload.type != JSONType.object) return;
    if (auto f = "title" in payload.object)
        if (f.type == JSONType.string) session.title = f.str;
    if (auto f = "model" in payload.object)
        if (f.type == JSONType.string) session.model = f.str;
    if (auto f = "thinking" in payload.object)
        session.thinking = f.type == JSONType.true_;
    if (auto f = "projectId" in payload.object)
        if (f.type == JSONType.string) session.projectId = f.str;
    if (auto f = "activeLeafId" in payload.object)
        if (f.type == JSONType.string) session.activeLeafId = f.str;
    if (auto f = "objective" in payload.object)
        if (f.type == JSONType.string) session.objective = f.str;
    if (auto f = "taskStatus" in payload.object)
        if (f.type == JSONType.string) session.taskStatus = f.str;
    if (auto f = "verificationStatus" in payload.object)
        if (f.type == JSONType.string) session.verificationStatus = f.str;
    if (auto f = "taskSteps" in payload.object)
        if (f.type == JSONType.array)
        {
            TaskStep[] steps;
            foreach (item; f.array)
            {
                if (item.type != JSONType.object) continue;
                TaskStep step;
                if (auto value = "text" in item.object)
                    if (value.type == JSONType.string) step.text = value.str;
                if (auto value = "status" in item.object)
                    if (value.type == JSONType.string) step.status = value.str;
                if (step.text.length > 0) steps ~= step;
            }
            session.taskSteps = steps;
        }
    if (auto f = "queuedGuidance" in payload.object)
        if (f.type == JSONType.array)
        {
            session.queuedGuidance.length = 0;
            foreach (item; f.array)
                if (item.type == JSONType.string)
                    session.queuedGuidance ~= item.str;
        }
}

private void applyMessagePayload(ref ChatMessage message, JSONValue payload)
{
    if (payload.type != JSONType.object) return;
    if (auto f = "role" in payload.object)
        if (f.type == JSONType.string) message.role = f.str;
    if (auto f = "content" in payload.object)
        if (f.type == JSONType.string) message.content = f.str;
    if (auto f = "reasoning" in payload.object)
        if (f.type == JSONType.string) message.reasoning = f.str;
    if (auto f = "parentId" in payload.object)
        if (f.type == JSONType.string) message.parentId = f.str;
    if (auto f = "time" in payload.object)
        if (f.type == JSONType.string) message.time = f.str;
    if (auto f = "failed" in payload.object)
        message.failed = f.type == JSONType.true_;
    if (auto f = "internal" in payload.object)
        message.internal = f.type == JSONType.true_;
    if (auto f = "toolCallId" in payload.object)
        if (f.type == JSONType.string) message.toolCallId = f.str;
    if (auto f = "toolName" in payload.object)
        if (f.type == JSONType.string) message.toolName = f.str;
    if (auto f = "toolArgs" in payload.object)
        if (f.type == JSONType.string) message.toolArgs = f.str;
    foreach (target, name; ["promptTokens", "completionTokens", "totalTokens"])
        if (auto f = name in payload.object)
            if (f.type == JSONType.integer)
            {
                if (target == 0) message.promptTokens = cast(int) f.integer;
                else if (target == 1) message.completionTokens = cast(int) f.integer;
                else message.totalTokens = cast(int) f.integer;
            }
    if (auto f = "tokensPerSecondTenths" in payload.object)
        if (f.type == JSONType.integer)
            message.tokensPerSecondTenths = cast(int) f.integer;
    if (auto f = "diffAdditions" in payload.object)
        if (f.type == JSONType.integer)
            message.diffAdditions = cast(int) f.integer;
    if (auto f = "diffDeletions" in payload.object)
        if (f.type == JSONType.integer)
            message.diffDeletions = cast(int) f.integer;
    if (auto f = "toolDiff" in payload.object)
        if (f.type == JSONType.string) message.toolDiff = f.str;
    if (auto f = "toolElapsedMs" in payload.object)
        if (f.type == JSONType.integer) message.toolElapsedMs = f.integer;
    if (auto f = "workedSeconds" in payload.object)
    {
        if (f.type == JSONType.integer)
            message.workedSeconds = cast(double) f.integer;
        else if (f.type == JSONType.float_)
            message.workedSeconds = f.floating;
    }
    if (auto f = "toolCalls" in payload.object)
        if (f.type == JSONType.array)
        {
            message.toolCalls.length = 0;
            foreach (item; f.array)
            {
                if (item.type != JSONType.object) continue;
                OpenCodeToolCall call;
                if (auto v = "id" in item.object)
                    if (v.type == JSONType.string) call.id = v.str;
                if (auto v = "name" in item.object)
                    if (v.type == JSONType.string) call.name = v.str;
                if (auto v = "arguments" in item.object)
                    if (v.type == JSONType.string) call.arguments = v.str;
                message.toolCalls ~= call;
            }
        }
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

unittest
{
    AgentRuntimeEvent[] events;
    AgentRuntimeEvent started;
    started.kind = AgentEventKind.threadStarted;
    started.threadId = "thread-durable";
    started.payloadJson = `{"title":"Long task","objective":"Ship it","taskStatus":"active","verificationStatus":"required","taskSteps":[{"text":"Implement","status":"completed"},{"text":"Test","status":"in_progress"}],"queuedGuidance":["Keep the GUI simple"]}`;
    events ~= started;
    AgentRuntimeEvent item;
    item.kind = AgentEventKind.itemAdded;
    item.threadId = started.threadId;
    item.turnId = "user-1";
    item.itemId = "user-1";
    item.payloadJson = `{"role":"user","content":"Build it"}`;
    events ~= item;
    item.kind = AgentEventKind.itemUpdated;
    item.payloadJson = `{"role":"user","content":"Build it well"}`;
    events ~= item;

    auto projected = projectAgentRuntimeEvents(events);
    assert(projected.length == 1);
    assert(projected[0].id == "thread-durable");
    assert(projected[0].objective == "Ship it");
    assert(projected[0].taskSteps.length == 2);
    assert(projected[0].queuedGuidance == ["Keep the GUI simple"]);
    assert(projected[0].messages.length == 1);
    assert(projected[0].messages[0].content == "Build it well");

    AgentRuntimeEvent removed;
    removed.kind = AgentEventKind.threadDeleted;
    removed.threadId = started.threadId;
    events ~= removed;
    assert(projectAgentRuntimeEvents(events).length == 0);
    assert(deletedAgentRuntimeThreadIds(events) == ["thread-durable"]);
}
