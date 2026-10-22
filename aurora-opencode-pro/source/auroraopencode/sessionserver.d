module auroraopencode.sessionserver;

/**
 * General headless session host.
 *
 * One process owns one `OpenCodeRoot` and any number of conversations. Callers
 * address conversations by their own id over newline-delimited JSON on stdin
 * and stdout. The protocol is deliberately game-agnostic: a session is a title,
 * an optional model, a system-prompt section, and an optional tools mode. An
 * NPC, a support bot, or a background coding agent is just a caller.
 *
 * Operations (one JSON object per line):
 *   {"type":"create","id":"npc-1","title":"...","model":"...",
 *    "thinking":true,"tools":false,"instructions":"...","workspace":"..."}
 *   {"type":"submit","id":"npc-1","requestId":"r1","text":"..."}
 *   {"type":"cancel","id":"npc-1"}
 *   {"type":"list"}
 *   {"type":"close","id":"npc-1"}
 *   {"type":"ping"}
 *   {"type":"shutdown"}
 *
 * Events:
 *   ready, created, turn.started, turn.completed, turn.failed,
 *   turn.interrupted, cancelled, sessions, closed, pong, bye, error
 *
 * `id` is the caller's session handle. `sessionId` is the internal persisted
 * conversation id, useful for journal/log correlation. `requestId` is echoed on
 * every event for that turn so concurrent callers can match replies.
 */

import aurora;
import auroraopencode.appicon : applicationIconPath;
import auroraopencode.appui : AgentSessionInfo, OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, msecs, seconds;
import std.conv : to;
import std.file : exists, getcwd, mkdirRecurse;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildNormalizedPath, buildPath, isAbsolute;
import std.process : thisProcessID;
import std.stdio : stderr, stdin, stdout;
import std.string : startsWith, strip;

/// One parsed JSONL operation.
public enum SessionServerCommandType
{
    create,
    submit,
    cancel,
    list,
    close,
    ping,
    shutdown,
    unknown
}

public struct SessionServerCommand
{
    SessionServerCommandType type;
    string id;
    string requestId;
    string text;
    string title;
    string model;
    string instructions;
    string workspace;
    int thinkingMode = -1;
    int toolsMode = -1;
}

private bool hasField(const JSONValue value, string name)
{
    return value.type == JSONType.object && (name in value.object) !is null;
}

private string stringField(const JSONValue value, string name)
{
    if (value.type != JSONType.object) return "";
    auto field = name in value.object;
    if (field is null || field.type != JSONType.string) return "";
    return field.str;
}

private bool boolField(const JSONValue value, string name, bool fallback)
{
    if (value.type != JSONType.object) return fallback;
    auto field = name in value.object;
    if (field is null) return fallback;
    if (field.type == JSONType.true_) return true;
    if (field.type == JSONType.false_) return false;
    return fallback;
}

private int intField(const JSONValue value, string name, int fallback)
{
    if (value.type != JSONType.object) return fallback;
    auto field = name in value.object;
    if (field is null || field.type != JSONType.integer) return fallback;
    return cast(int) field.integer;
}

/// Parse one operation. Returns false with a stable reason on malformed input.
public bool parseSessionServerCommand(string line, out SessionServerCommand command,
    out string error)
{
    command = SessionServerCommand.init;
    command.type = SessionServerCommandType.unknown;
    command.thinkingMode = -1;
    command.toolsMode = -1;
    error = "";

    JSONValue value;
    try
        value = parseJSON(line);
    catch (Exception parseError)
    {
        error = "invalid_json: " ~ parseError.msg;
        return false;
    }
    if (value.type != JSONType.object)
    {
        error = "invalid_json: expected an object";
        return false;
    }

    const kind = stringField(value, "type");
    if (kind.length == 0)
    {
        error = "missing_type";
        return false;
    }

    command.id = stringField(value, "id");
    command.requestId = stringField(value, "requestId");

    if (kind == "create")
    {
        command.type = SessionServerCommandType.create;
        command.title = stringField(value, "title");
        command.model = stringField(value, "model");
        command.instructions = stringField(value, "instructions");
        command.workspace = stringField(value, "workspace");
        if (hasField(value, "thinking"))
            command.thinkingMode = boolField(value, "thinking", false) ? 1 : 0;
        if (hasField(value, "toolsMode"))
            command.toolsMode = intField(value, "toolsMode", -1);
        else if (hasField(value, "tools"))
            command.toolsMode = boolField(value, "tools", true) ? 1 : 0;
        return true;
    }
    if (kind == "submit")
    {
        command.type = SessionServerCommandType.submit;
        command.text = stringField(value, "text");
        if (command.id.length == 0) { error = "missing_id"; return false; }
        if (command.text.strip().length == 0)
        { error = "missing_text"; return false; }
        return true;
    }
    if (kind == "cancel")
    {
        command.type = SessionServerCommandType.cancel;
        if (command.id.length == 0) { error = "missing_id"; return false; }
        return true;
    }
    if (kind == "list")
    {
        command.type = SessionServerCommandType.list;
        return true;
    }
    if (kind == "close")
    {
        command.type = SessionServerCommandType.close;
        if (command.id.length == 0) { error = "missing_id"; return false; }
        return true;
    }
    if (kind == "ping")
    {
        command.type = SessionServerCommandType.ping;
        return true;
    }
    if (kind == "shutdown")
    {
        command.type = SessionServerCommandType.shutdown;
        return true;
    }

    error = "unknown_command: " ~ kind;
    return false;
}

/// A single-consumer queue fed by the stdin reader thread.
private final class LineQueue
{
    private Mutex _mutex;
    private string[] _lines;
    private bool _closed;

    this()
    {
        _mutex = new Mutex();
    }

    void push(string line)
    {
        synchronized (_mutex) _lines ~= line;
    }

    bool pop(out string line)
    {
        synchronized (_mutex)
        {
            if (_lines.length == 0) return false;
            line = _lines[0];
            _lines = _lines[1 .. $];
            return true;
        }
    }

    void close()
    {
        synchronized (_mutex) _closed = true;
    }

    bool closed()
    {
        synchronized (_mutex) return _closed;
    }
}

private struct SessionRecord
{
    string externalId;
    string sessionId;
}

private struct PendingTurn
{
    string requestId;
    string sessionId;
    MonoTime startedAt;
    bool sawRunning;
}

/// Hosts sessions and dispatches JSONL operations on the UI thread.
public final class SessionServer
{
    private OpenCodeRoot _root;
    private GuiWindow _window;
    private UiTestDriver _driver;
    private string _defaultWorkspace;
    private SessionRecord[string] _sessions;
    private PendingTurn[string] _pending;
    private LineQueue _queue;
    private Thread _reader;
    private Mutex _outputMutex;
    private bool _stopping;

    this(OpenCodeRoot root, GuiWindow window, UiTestDriver driver,
        string defaultWorkspace)
    {
        _root = root;
        _window = window;
        _driver = driver;
        _defaultWorkspace = defaultWorkspace;
        _outputMutex = new Mutex();
        _queue = new LineQueue();
    }

    int run()
    {
        scope (exit) cleanup();
        startReader();
        emitReady();

        // The root restores settings/history asynchronously. Do not accept a
        // create until it is ready, or the new conversation would be lost.
        const startupDeadline = MonoTime.currTime + seconds(60);
        while (_root.startupPendingForTesting() &&
            MonoTime.currTime < startupDeadline && !_queue.closed())
            tick();
        if (_root.startupPendingForTesting())
        {
            emitError("", "", "startup_timeout");
            return 1;
        }

        while (!_stopping)
        {
            tick();
            string line;
            bool handled = false;
            while (_queue.pop(line))
            {
                handled = true;
                processLine(line);
                if (_stopping) break;
            }
            pollPending();
            if (_stopping) break;
            if (_queue.closed() && _pending.length == 0) break;
            if (!handled) Thread.sleep(10.msecs);
        }

        shutdownPending();
        emitBye();
        return 0;
    }

    private void startReader()
    {
        _reader = new Thread(&readLoop);
        _reader.isDaemon = true;
        _reader.start();
    }

    private void readLoop()
    {
        try
        {
            foreach (line; stdin.byLine())
                _queue.push(line.idup);
        }
        catch (Exception) {}
        finally
            _queue.close();
    }

    private void tick()
    {
        try
        {
            _root.tickTree(0.02);
            _driver.paint();
        }
        catch (Exception error)
        {
            emitError("", "", "ui_tick_failed: " ~ error.msg);
            _stopping = true;
        }
    }

    private void cleanup()
    {
        try _root.shutdownClient();
        catch (Exception) {}
        try _window.close();
        catch (Exception) {}
    }

    private void processLine(string line)
    {
        if (line.strip().length == 0) return;

        SessionServerCommand command;
        string error;
        if (!parseSessionServerCommand(line, command, error))
        {
            emitError("", "", error);
            return;
        }

        try
        {
            final switch (command.type)
            {
            case SessionServerCommandType.create: create(command); break;
            case SessionServerCommandType.submit: submit(command); break;
            case SessionServerCommandType.cancel: cancel(command); break;
            case SessionServerCommandType.list: listSessions(); break;
            case SessionServerCommandType.close: close(command); break;
            case SessionServerCommandType.ping: emitSimple("pong"); break;
            case SessionServerCommandType.shutdown: _stopping = true; break;
            case SessionServerCommandType.unknown: break;
            }
        }
        catch (Exception caught)
        {
            emitError(command.id, command.requestId,
                "internal_error: " ~ caught.msg);
        }
    }

    private void create(const ref SessionServerCommand command)
    {
        if (command.id.length > 0 &&
            ((command.id in _sessions) !is null ||
             (command.id in _pending) !is null))
        {
            emitError(command.id, "", "duplicate_id");
            return;
        }

        string workspace = command.workspace;
        if (workspace.length == 0) workspace = _defaultWorkspace;
        else if (!isAbsolute(workspace)) workspace = buildPath(getcwd(), workspace);
        workspace = buildNormalizedPath(workspace);
        if (!exists(workspace))
        {
            emitError(command.id, "", "workspace_not_found");
            return;
        }

        const sessionId = _root.createAgentSession(command.title,
            command.model, command.thinkingMode, command.toolsMode,
            command.instructions, workspace);
        if (sessionId.length == 0)
        {
            emitError(command.id, "", "session_not_created");
            return;
        }

        const externalId = command.id.length > 0 ? command.id : sessionId;
        SessionRecord record;
        record.externalId = externalId;
        record.sessionId = sessionId;
        _sessions[externalId] = record;
        emitCreated(record);
    }

    private void submit(const ref SessionServerCommand command)
    {
        auto record = command.id in _sessions;
        if (record is null)
        {
            emitError(command.id, command.requestId, "unknown_session");
            return;
        }
        if ((command.id in _pending) !is null)
        {
            emitError(command.id, command.requestId, "session_busy");
            return;
        }

        string error;
        if (!_root.submitAgentTurn(record.sessionId, command.text, error))
        {
            emitError(command.id, command.requestId, error);
            return;
        }

        PendingTurn pending;
        pending.requestId = command.requestId;
        pending.sessionId = record.sessionId;
        pending.startedAt = MonoTime.currTime;
        _pending[command.id] = pending;

        JSONValue event;
        event["type"] = "turn.started";
        event["id"] = command.id;
        if (command.requestId.length > 0) event["requestId"] = command.requestId;
        event["sessionId"] = record.sessionId;
        const turnId = _root.agentSessionTurnId(record.sessionId);
        if (turnId.length > 0) event["turnId"] = turnId;
        writeEvent(event);
    }

    private void cancel(const ref SessionServerCommand command)
    {
        auto record = command.id in _sessions;
        if (record is null)
        {
            emitError(command.id, "", "unknown_session");
            return;
        }
        const accepted = _root.cancelAgentTurn(record.sessionId);

        JSONValue event;
        event["type"] = "cancelled";
        event["id"] = command.id;
        if (auto pending = command.id in _pending)
            if (pending.requestId.length > 0)
                event["requestId"] = pending.requestId;
        event["sessionId"] = record.sessionId;
        event["accepted"] = accepted;
        writeEvent(event);
    }

    private void close(const ref SessionServerCommand command)
    {
        auto record = command.id in _sessions;
        if (record is null)
        {
            emitError(command.id, "", "unknown_session");
            return;
        }
        _root.cancelAgentTurn(record.sessionId);
        if (auto pending = command.id in _pending)
        {
            finishTurn(command.id, *pending, "session_closed", true);
            _pending.remove(command.id);
        }
        _sessions.remove(command.id);

        JSONValue event;
        event["type"] = "closed";
        event["id"] = command.id;
        event["sessionId"] = record.sessionId;
        writeEvent(event);
    }

    private void listSessions()
    {
        JSONValue[] items;
        foreach (externalId, record; _sessions)
        {
            const info = _root.agentSessionInfo(record.sessionId);
            JSONValue item;
            item["id"] = externalId;
            item["sessionId"] = record.sessionId;
            item["title"] = info.title;
            item["model"] = info.model;
            item["thinking"] = info.thinking;
            item["toolsMode"] = info.toolsMode;
            item["busy"] = info.busy;
            item["turnStatus"] = info.turnStatus;
            item["taskStatus"] = info.taskStatus;
            item["verificationStatus"] = info.verificationStatus;
            if (info.turnId.length > 0) item["turnId"] = info.turnId;
            items ~= item;
        }

        JSONValue event;
        event["type"] = "sessions";
        event["sessions"] = JSONValue(items);
        writeEvent(event);
    }

    private void pollPending()
    {
        if (_pending.length == 0) return;

        string[] keys;
        foreach (externalId, _; _pending) keys ~= externalId;
        string[] finished;
        string[] missing;

        foreach (externalId; keys)
        {
            auto pending = externalId in _pending;
            if (pending is null) continue;

            const busy = _root.agentSessionBusy(pending.sessionId);
            const status = _root.agentSessionTurnStatus(pending.sessionId);
            if (busy || status == "running")
            {
                pending.sawRunning = true;
                continue;
            }
            if (status == "completed" || status == "failed" ||
                status == "interrupted")
            {
                finished ~= externalId;
                continue;
            }
            const elapsed = (MonoTime.currTime - pending.startedAt).total!"msecs";
            if (!pending.sawRunning && elapsed < 1000) continue;
            missing ~= externalId;
        }

        foreach (externalId; finished)
        {
            auto pending = externalId in _pending;
            if (pending is null) continue;
            finishTurn(externalId, *pending);
            _pending.remove(externalId);
        }
        foreach (externalId; missing)
        {
            auto pending = externalId in _pending;
            if (pending is null) continue;
            finishTurn(externalId, *pending, "turn_not_started", false);
            _pending.remove(externalId);
        }
    }

    private void shutdownPending()
    {
        if (_pending.length == 0) return;

        string[] keys;
        foreach (externalId, _; _pending) keys ~= externalId;
        foreach (externalId; keys)
            if (auto pending = externalId in _pending)
                _root.cancelAgentTurn(pending.sessionId);

        const deadline = MonoTime.currTime + seconds(2);
        while (_pending.length > 0 && MonoTime.currTime < deadline)
        {
            tick();
            pollPending();
            if (_pending.length == 0) break;
            Thread.sleep(10.msecs);
        }

        keys.length = 0;
        foreach (externalId, _; _pending) keys ~= externalId;
        foreach (externalId; keys)
        {
            auto pending = externalId in _pending;
            if (pending is null) continue;
            finishTurn(externalId, *pending, "server_shutdown", true);
            _pending.remove(externalId);
        }
    }

    private void finishTurn(string externalId, const ref PendingTurn pending,
        string forcedError = "", bool forcedInterrupted = false)
    {
        const status = _root.agentSessionTurnStatus(pending.sessionId);
        const info = _root.agentSessionInfo(pending.sessionId);
        const interrupted = forcedInterrupted || status == "interrupted";
        const failed = !interrupted && (status == "failed" || forcedError.length > 0);

        JSONValue event;
        event["type"] = interrupted ? "turn.interrupted"
            : failed ? "turn.failed" : "turn.completed";
        event["id"] = externalId;
        if (pending.requestId.length > 0) event["requestId"] = pending.requestId;
        event["sessionId"] = pending.sessionId;
        if (info.turnId.length > 0) event["turnId"] = info.turnId;
        event["turnStatus"] = status;
        event["taskStatus"] = info.taskStatus;
        event["verificationStatus"] = info.verificationStatus;
        event["reply"] = _root.agentSessionReply(pending.sessionId);
        const error = forcedError.length > 0 ? forcedError
            : _root.agentSessionError(pending.sessionId);
        if (error.length > 0) event["error"] = error;
        writeEvent(event);
    }

    private void emitReady()
    {
        JSONValue event;
        event["type"] = "ready";
        event["protocol"] = 1;
        event["pid"] = cast(long) thisProcessID();
        event["workspace"] = _defaultWorkspace;
        writeEvent(event);
    }

    private void emitCreated(const ref SessionRecord record)
    {
        const info = _root.agentSessionInfo(record.sessionId);
        JSONValue event;
        event["type"] = "created";
        event["id"] = record.externalId;
        event["sessionId"] = record.sessionId;
        event["title"] = info.title;
        event["model"] = info.model;
        event["thinking"] = info.thinking;
        event["toolsMode"] = info.toolsMode;
        writeEvent(event);
    }

    private void emitError(string id, string requestId, string message)
    {
        JSONValue event;
        event["type"] = "error";
        if (id.length > 0) event["id"] = id;
        if (requestId.length > 0) event["requestId"] = requestId;
        event["error"] = message;
        writeEvent(event);
    }

    private void emitSimple(string kind)
    {
        JSONValue event;
        event["type"] = kind;
        writeEvent(event);
    }

    private void emitBye()
    {
        emitSimple("bye");
    }

    private void writeEvent(const ref JSONValue event)
    {
        const line = event.toString();
        synchronized (_outputMutex)
        {
            stdout.writeln(line);
            stdout.flush();
        }
    }
}

/// CLI entry point. `options` are the arguments after `--session-server`.
public int runSessionServer(string[] options)
{
    string workspace = getcwd();
    string stateDir;

    for (size_t i = 0; i < options.length; ++i)
    {
        const option = options[i];
        if (option == "--help" || option == "-h")
        {
            printSessionServerUsage();
            return 0;
        }
        if (option == "--workspace" && i + 1 < options.length)
        {
            workspace = options[++i];
            continue;
        }
        if (option.startsWith("--workspace="))
        {
            workspace = option["--workspace=".length .. $];
            continue;
        }
        if (option == "--state-dir" && i + 1 < options.length)
        {
            stateDir = options[++i];
            continue;
        }
        if (option.startsWith("--state-dir="))
        {
            stateDir = option["--state-dir=".length .. $];
            continue;
        }
        stderr.writeln("aurora-opencode-pro --session-server: unknown option: ",
            option);
        printSessionServerUsage();
        return 2;
    }

    workspace = buildNormalizedPath(workspace);
    if (stateDir.length > 0)
    {
        stateDir = buildNormalizedPath(stateDir);
        if (!exists(stateDir)) mkdirRecurse(stateDir);
        setOpencodeStateDirectoryForTesting(stateDir);
    }

    WindowOptions windowOptions;
    windowOptions.title = "Aurora OpenCode session server";
    windowOptions.width = 1200;
    windowOptions.height = 800;
    windowOptions.decorated = false;
    windowOptions.darkTitleBar = true;
    windowOptions.iconPath = applicationIconPath();
    windowOptions.renderer = RendererPreference.software;

    auto window = new GuiWindow(windowOptions, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.paint();
    root.tickTree(0.02);
    driver.paint();

    auto server = new SessionServer(root, window, driver, workspace);
    return server.run();
}

private void printSessionServerUsage()
{
    stdout.writeln("Aurora OpenCode Pro - session server");
    stdout.writeln("Usage: aurora-opencode-pro --session-server " ~
        "[--workspace <dir>] [--state-dir <dir>]");
    stdout.writeln("Reads newline-delimited JSON operations on stdin and " ~
        "writes one event per line on stdout.");
    stdout.writeln("Operations: create, submit, cancel, list, close, ping, " ~
        "shutdown.");
}

unittest
{
    SessionServerCommand command;
    string error;

    assert(parseSessionServerCommand(
        `{"type":"create","id":"npc-1","title":"Guide","model":"m",` ~
        `"thinking":true,"tools":false,"instructions":"stay in character",` ~
        `"workspace":"C:/work"}`, command, error));
    assert(command.type == SessionServerCommandType.create);
    assert(command.id == "npc-1");
    assert(command.title == "Guide");
    assert(command.model == "m");
    assert(command.thinkingMode == 1);
    assert(command.toolsMode == 0);
    assert(command.instructions == "stay in character");
    assert(command.workspace == "C:/work");
    assert(error.length == 0);

    assert(parseSessionServerCommand(
        `{"type":"submit","id":"npc-1","requestId":"r1","text":"hello"}`,
        command, error));
    assert(command.type == SessionServerCommandType.submit);
    assert(command.requestId == "r1");
    assert(command.text == "hello");

    assert(parseSessionServerCommand(`{"type":"cancel","id":"npc-1"}`,
        command, error));
    assert(command.type == SessionServerCommandType.cancel);

    assert(parseSessionServerCommand(`{"type":"list"}`, command, error));
    assert(command.type == SessionServerCommandType.list);

    assert(parseSessionServerCommand(`{"type":"close","id":"npc-1"}`,
        command, error));
    assert(command.type == SessionServerCommandType.close);

    assert(parseSessionServerCommand(`{"type":"ping"}`, command, error));
    assert(command.type == SessionServerCommandType.ping);

    assert(parseSessionServerCommand(`{"type":"shutdown"}`, command, error));
    assert(command.type == SessionServerCommandType.shutdown);

    assert(!parseSessionServerCommand(`not json`, command, error));
    assert(error.startsWith("invalid_json"));

    assert(!parseSessionServerCommand(`{"type":"submit","id":"npc-1"}`,
        command, error));
    assert(error == "missing_text");

    assert(!parseSessionServerCommand(`{"type":"submit","text":"hello"}`,
        command, error));
    assert(error == "missing_id");

    assert(!parseSessionServerCommand(`{"type":"bogus"}`, command, error));
    assert(error == "unknown_command: bogus");
}
