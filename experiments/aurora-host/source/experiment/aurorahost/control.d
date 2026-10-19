module experiment.aurorahost.control;

import experiment.aurorahost.events : HostEvent, buttonName, keyName;
import experiment.aurorahost.protocol : ProtocolVersion;
import experiment.aurorahost.scene : NodeInfo, NodeRegistry, parseCanvasCommands;
import experiment.aurorahost.surface : SurfaceInfo;
import aurora : FileDialogMode, FileDialogOptions, GuiWindow, Key, MouseButton,
    TextEditor, Theme, runFileDialogWindow;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.exception : enforce;
import std.file : mkdirRecurse;
import std.json : JSONType, JSONValue, parseJSON, toJSON;
import std.path : dirName;
import std.stdio : stdin, stdout;
import std.string : toLower;

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

    void eventInput(HostEvent input)
    {
        JSONValue[string] event;
        event["event"] = JSONValue(input.name);
        event["node"] = JSONValue(input.node);
        if (input.name == "pointer")
        {
            event["kind"] = JSONValue(input.kind);
            event["x"] = JSONValue(cast(long) input.x);
            event["y"] = JSONValue(cast(long) input.y);
            event["button"] = JSONValue(buttonName(input.button));
            event["modifiers"] = JSONValue(cast(long) input.modifiers);
            if (input.kind == "wheel")
            {
                event["wheelX"] = JSONValue(cast(long) input.wheelX);
                event["wheelY"] = JSONValue(cast(long) input.wheelY);
            }
        }
        else if (input.name == "key")
        {
            event["kind"] = JSONValue(input.kind);
            event["key"] = JSONValue(keyName(input.key));
            event["modifiers"] = JSONValue(cast(long) input.modifiers);
        }
        else if (input.name == "tick")
            event["delta"] = JSONValue(input.delta);
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

    private long optionalInt(JSONValue document, string field, long fallback)
    {
        auto value = field in document.object;
        if (value is null) return fallback;
        enforce((*value).type == JSONType.integer,
            field ~ " must be an integer");
        return (*value).integer;
    }

    private uint readModifiers(JSONValue document)
    {
        const value = optionalInt(document, "modifiers", 0);
        enforce(value >= 0 && value <= uint.max,
            "modifiers must be between 0 and 4294967295");
        return cast(uint) value;
    }

    private MouseButton parseButton(string name)
    {
        switch (name.toLower)
        {
            case "left": return MouseButton.left;
            case "middle": return MouseButton.middle;
            case "right": return MouseButton.right;
            case "extra1": return MouseButton.extra1;
            case "extra2": return MouseButton.extra2;
            case "none": return MouseButton.none;
            default: throw new Exception("unknown mouse button: " ~ name);
        }
    }

    private Key parseKey(string name)
    {
        const lower = name.toLower;
        if (lower.length == 1)
        {
            const character = lower[0];
            if (character >= 'a' && character <= 'z')
                return cast(Key) (Key.a + (character - 'a'));
            if (character >= '0' && character <= '9')
                return cast(Key) (Key.digit0 + (character - '0'));
        }
        switch (lower)
        {
            case "backspace": return Key.backspace;
            case "tab": return Key.tab;
            case "enter": return Key.enter;
            case "escape": return Key.escape;
            case "space": return Key.space;
            case "pageup": return Key.pageUp;
            case "pagedown": return Key.pageDown;
            case "end": return Key.end;
            case "home": return Key.home;
            case "left": return Key.left;
            case "up": return Key.up;
            case "right": return Key.right;
            case "down": return Key.down;
            case "insert": return Key.insert;
            case "delete": return Key.deleteKey;
            case "minus": return Key.minus;
            case "equal": return Key.equal;
            case "leftbracket": return Key.leftBracket;
            case "rightbracket": return Key.rightBracket;
            case "backslash": return Key.backslash;
            case "semicolon": return Key.semicolon;
            case "apostrophe": return Key.apostrophe;
            case "grave": return Key.grave;
            case "comma": return Key.comma;
            case "period": return Key.period;
            case "slash": return Key.slash;
            default: break;
        }
        if (lower.length >= 2 && lower[0] == 'f')
        {
            const number = to!int(lower[1 .. $]);
            if (number >= 1 && number <= 12)
                return cast(Key) (Key.f1 + (number - 1));
        }
        throw new Exception("unknown key: " ~ name);
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
                case "setTick":
                    setTick(requestId, document);
                    break;
                case "pointer":
                    pointer(requestId, document);
                    break;
                case "key":
                    key(requestId, document);
                    break;
                case "surface":
                    surface(requestId, document);
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
        auto parsed = parseCanvasCommands(*commands, "commands",
            _registry.assetBase);
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

    private void setTick(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        const hz = optionalInt(document, "hz", -1);
        enforce(hz >= 0 && hz <= 240,
            "hz must be between 0 and 240");
        if (!_registry.setTick(node, cast(int) hz))
        {
            respond(id, false, "node is not a canvas: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["hz"] = JSONValue(hz);
        respond(id, true, null, extra);
    }

    private void pointer(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        const kind = optionalString(document, "kind", "move");
        enforce(kind == "down" || kind == "move" || kind == "up" ||
            kind == "wheel", "kind must be down, move, up, or wheel");
        const x = optionalInt(document, "x", 0);
        const y = optionalInt(document, "y", 0);
        enforce(x >= -100000 && x <= 100000 && y >= -100000 && y <= 100000,
            "pointer coordinates must be between -100000 and 100000");
        const button = parseButton(optionalString(document, "button", "left"));
        const modifiers = readModifiers(document);
        const wheelX = optionalInt(document, "wheelX", 0);
        const wheelY = optionalInt(document, "wheelY", 0);
        if (!_registry.injectPointer(node, kind, cast(int) x, cast(int) y,
            button, modifiers, cast(int) wheelX, cast(int) wheelY))
        {
            respond(id, false, "node is not an input surface: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["kind"] = JSONValue(kind);
        respond(id, true, null, extra);
    }

    private void key(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        const kind = optionalString(document, "kind", "down");
        enforce(kind == "down" || kind == "up",
            "kind must be down or up");
        const key = parseKey(requireString(document, "key"));
        const modifiers = readModifiers(document);
        if (!_registry.injectKey(node, kind, key, modifiers))
        {
            respond(id, false, "node is not an input surface: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["kind"] = JSONValue(kind);
        extra["key"] = JSONValue(keyName(key));
        respond(id, true, null, extra);
    }

    private void surface(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        SurfaceInfo info;
        if (!_registry.surfaceInfo(node, info))
        {
            respond(id, false, "node is not a surface: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["mapped"] = JSONValue(info.mapped);
        extra["width"] = JSONValue(cast(long) info.width);
        extra["height"] = JSONValue(cast(long) info.height);
        extra["sequence"] = JSONValue(cast(long) info.sequence);
        extra["inputHead"] = JSONValue(cast(long) info.inputHead);
        extra["inputTail"] = JSONValue(cast(long) info.inputTail);
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
