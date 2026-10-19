module experiment.aurorahost.control;

import experiment.aurorahost.protocol : ProtocolVersion;
import experiment.aurorahost.scene : NodeInfo, NodeRegistry, parseCanvasCommands;
import aurora : FileDialogMode, FileDialogOptions, GuiWindow, TextEditor, Theme,
    runFileDialogWindow;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.exception : enforce;
import std.file : mkdirRecurse;
import std.json : JSONType, JSONValue, parseJSON, toJSON;
import std.path : dirName;
import std.stdio : stdin, stdout;

private struct ControlCommand
{
    string line;
}

/**
 * A stdin/stdout JSON-lines control channel.
 *
 * The reader thread only queues commands. All widget access and all protocol
 * writes happen on the UI thread through GuiWindow.applicationService.
 */
class ControlServer
{
    private GuiWindow _window;
    private NodeRegistry _registry;
    private Mutex _mutex;
    private ControlCommand[] _queue;
    private Thread _reader;
    private bool _running = true;

    this(GuiWindow window, NodeRegistry registry)
    {
        _window = window;
        _registry = registry;
        _mutex = new Mutex();
    }

    void start()
    {
        _reader = new Thread(delegate() { readLoop(); });
        _reader.isDaemon = true;
        _reader.start();
    }

    void stop()
    {
        _running = false;
    }

    void drain()
    {
        ControlCommand[] commands;
        synchronized (_mutex)
        {
            commands = _queue;
            _queue = [];
        }
        foreach (command; commands)
            handle(command.line);
    }

    void eventActivated(string id)
    {
        JSONValue[string] event;
        event["event"] = JSONValue("activated");
        event["node"] = JSONValue(id);
        emit("EVENT", event);
    }

    void eventAction(string node, string action)
    {
        JSONValue[string] event;
        event["event"] = JSONValue("action");
        event["node"] = JSONValue(node);
        event["action"] = JSONValue(action);
        emit("EVENT", event);
    }

    private void readLoop()
    {
        try
        {
            foreach (line; stdin.byLine())
            {
                if (!_running) break;
                enqueue(line.idup);
            }
        }
        catch (Exception)
        {
            // A closed stdin simply ends the control channel.
        }
    }

    private void enqueue(string line)
    {
        synchronized (_mutex)
            _queue ~= ControlCommand(line);
        auto wake = _window.serviceWake();
        if (wake !is null)
            wake();
    }

    private void emit(string prefix, JSONValue[string] payload)
    {
        JSONValue encoded = JSONValue(payload);
        stdout.writeln(prefix ~ " " ~ toJSON(encoded));
        stdout.flush();
    }

    private void respond(long id, bool ok, string error = null,
        JSONValue[string] extra = null)
    {
        JSONValue[string] payload;
        payload["ok"] = JSONValue(ok);
        if (id != 0)
            payload["id"] = JSONValue(id);
        if (error.length > 0)
            payload["error"] = JSONValue(error);
        if (extra !is null)
            foreach (key, value; extra)
                payload[key] = value;
        emit("RESPONSE", payload);
    }

    private string requireString(JSONValue document, string field)
    {
        auto value = field in document.object;
        enforce(value !is null, field ~ " is required");
        enforce((*value).type == JSONType.string,
            field ~ " must be a string");
        return (*value).str;
    }

    private string optionalString(JSONValue document, string field,
        string fallback)
    {
        auto value = field in document.object;
        if (value is null) return fallback;
        enforce((*value).type == JSONType.string,
            field ~ " must be a string");
        return (*value).str;
    }

    private void handle(string line)
    {
        long requestId = 0;
        try
        {
            const document = parseJSON(line);
            enforce(document.type == JSONType.object,
                "command must be a JSON object");
            if (auto idValue = "id" in document.object)
                if ((*idValue).type == JSONType.integer)
                    requestId = (*idValue).integer;

            auto commandValue = "command" in document.object;
            enforce(commandValue !is null, "command is required");
            enforce((*commandValue).type == JSONType.string,
                "command must be a string");
            const command = (*commandValue).str;

            switch (command)
            {
                case "ping":
                    respond(requestId, true);
                    break;
                case "status":
                    status(requestId);
                    break;
                case "tree":
                    tree(requestId);
                    break;
                case "setText":
                    setText(requestId, document);
                    break;
                case "getText":
                    getText(requestId, document);
                    break;
                case "setWordWrap":
                    setWordWrap(requestId, document);
                    break;
                case "setCanvas":
                    setCanvas(requestId, document);
                    break;
                case "fileDialog":
                    fileDialog(requestId, document);
                    break;
                case "click":
                    click(requestId, document);
                    break;
                case "screenshot":
                    screenshot(requestId, document);
                    break;
                case "close":
                    respond(requestId, true);
                    _window.close();
                    break;
                default:
                    respond(requestId, false, "unknown command: " ~ command);
            }
        }
        catch (Exception error)
        {
            respond(requestId, false, error.msg);
        }
    }

    private void status(long id)
    {
        JSONValue[string] extra;
        extra["protocol"] = JSONValue(cast(long) ProtocolVersion);
        extra["renderer"] = JSONValue(_window.rendererName());
        extra["nodes"] = JSONValue(cast(long) _registry.length());

        JSONValue[string] window;
        const size = _window.logicalClientSize();
        window["width"] = JSONValue(cast(long) size.width);
        window["height"] = JSONValue(cast(long) size.height);
        extra["window"] = JSONValue(window);
        respond(id, true, null, extra);
    }

    private void tree(long id)
    {
        JSONValue[] nodes;
        foreach (info; _registry.tree())
        {
            JSONValue[string] item;
            item["id"] = JSONValue(info.id);
            item["type"] = JSONValue(info.type);
            item["text"] = JSONValue(info.text);
            nodes ~= JSONValue(item);
        }
        JSONValue[string] extra;
        extra["nodes"] = JSONValue(nodes);
        respond(id, true, null, extra);
    }

    private void setText(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        const text = requireString(document, "text");
        if (!_registry.setText(node, text))
        {
            respond(id, false, "node does not support text: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["text"] = JSONValue(text);
        respond(id, true, null, extra);
    }

    private void getText(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto widget = _registry.widget(node);
        if (widget is null)
        {
            respond(id, false, "unknown node: " ~ node);
            return;
        }
        auto editor = cast(TextEditor) widget;
        if (editor is null)
        {
            respond(id, false, "node is not a text editor: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["text"] = JSONValue(editor.textUtf8());
        respond(id, true, null, extra);
    }

    private void setWordWrap(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto widget = _registry.widget(node);
        if (widget is null)
        {
            respond(id, false, "unknown node: " ~ node);
            return;
        }
        auto editor = cast(TextEditor) widget;
        if (editor is null)
        {
            respond(id, false, "node is not a text editor: " ~ node);
            return;
        }
        auto wrap = "wrap" in document.object;
        enforce(wrap !is null, "wrap is required");
        enforce((*wrap).type == JSONType.true_ ||
            (*wrap).type == JSONType.false_,
            "wrap must be a boolean");
        editor.setWordWrap((*wrap).boolean);
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["wrap"] = JSONValue((*wrap).boolean);
        respond(id, true, null, extra);
    }

    private void setCanvas(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto commands = "commands" in document.object;
        enforce(commands !is null, "commands is required");
        auto parsed = parseCanvasCommands(*commands, "commands");
        if (!_registry.setCanvasCommands(node, parsed))
        {
            respond(id, false, "node is not a canvas: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["commands"] = JSONValue(cast(long) parsed.length);
        respond(id, true, null, extra);
    }

    private void fileDialog(long id, JSONValue document)
    {
        const mode = optionalString(document, "mode", "open");
        enforce(mode == "open" || mode == "save",
            "mode must be 'open' or 'save'");
        FileDialogOptions options;
        options.mode = mode == "save" ? FileDialogMode.save : FileDialogMode.open;
        options.title = optionalString(document, "title",
            mode == "save" ? "Save File" : "Open File");
        options.initialPath = optionalString(document, "initialPath", "");
        options.defaultFileName = optionalString(document, "defaultFileName", "");
        options.acceptLabel = optionalString(document, "acceptLabel",
            mode == "save" ? "Save" : "Open");
        string path;
        const accepted = runFileDialogWindow(_window, options, path,
            Theme.light());
        JSONValue[string] extra;
        extra["accepted"] = JSONValue(accepted);
        if (accepted)
            extra["path"] = JSONValue(path);
        respond(id, true, null, extra);
    }

    private void click(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        if (!_registry.activate(node))
        {
            respond(id, false, "node is not an activatable button: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        respond(id, true, null, extra);
    }

    private void screenshot(long id, JSONValue document)
    {
        const path = requireString(document, "path");
        const parent = dirName(path);
        if (parent.length > 0 && parent != ".")
            mkdirRecurse(parent);
        _window.saveScreenshot(path);
        JSONValue[string] extra;
        extra["path"] = JSONValue(path);
        respond(id, true, null, extra);
    }
}
