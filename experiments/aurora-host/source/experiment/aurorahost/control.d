module experiment.aurorahost.control;

import experiment.aurorahost.events : HostEvent, buttonName, keyName;
import experiment.aurorahost.canvas : parseCanvasColor;
import experiment.aurorahost.host_editor : EditorTextStyle, HostTextEditor;
import experiment.aurorahost.host_ui : HostTooltip, TabItem, TabStrip;
import experiment.aurorahost.protocol : ProtocolVersion;
import experiment.aurorahost.scene : NodeInfo, NodeRegistry,
    parseCanvasCommands, parseTabItems;
import experiment.aurorahost.surface : SurfaceInfo;
import aurora : ContextMenu, FileDialogMode, FileDialogOptions, GuiWindow, Key,
    MouseButton, Point, Rect, TextEditor, Theme, UiTestDriver, Widget,
    runFileDialogWindow;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime, usecs;
import std.algorithm : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : mkdirRecurse;
import std.json : JSONType, JSONValue, parseJSON, toJSON;
import std.path : dirName;
import std.stdio : stdin, stdout;
import std.string : toLower;
import std.utf : toUTF8;

private struct ControlCommand
{
    string line;
}

private enum TooltipDelayMicros = 550_000;

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
    private HostTooltip _tooltip;
    private string _tooltipNode;
    private MonoTime _tooltipShownAt;

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

    /**
     * Advance hover feedback on the UI thread. Hover hints wait for a short
     * dwell so scanning across a toolbar does not flash a trail of overlays.
     */
    void service(double)
    {
        if (_window.root is null ||
            _window.root.topmostPopupSurface() !is null)
        {
            hideTooltip();
            return;
        }

        string node;
        string text;
        Rect anchor;
        if (!_registry.hoveredTooltip(node, text, anchor))
        {
            hideTooltip();
            return;
        }

        if (node != _tooltipNode)
        {
            hideTooltip(false);
            _tooltipNode = node;
            _tooltipShownAt = MonoTime.currTime;
        }
        if (MonoTime.currTime - _tooltipShownAt < TooltipDelayMicros.usecs)
            return;

        if (_tooltip is null)
        {
            _tooltip = new HostTooltip(text);
            _window.root.add(_tooltip);
        }
        else if (_tooltip.text != text)
            _tooltip.setText(text);

        const rootOrigin = _window.root.globalOrigin();
        const rootSize = _window.root.bounds();
        const tipSize = _tooltip.bounds();
        int x = anchor.x + (anchor.width - tipSize.width) / 2;
        int y = anchor.y - tipSize.height - 6;
        if (y < rootOrigin.y)
            y = anchor.y + anchor.height + 6;
        const maxX = rootOrigin.x + rootSize.width - tipSize.width - 4;
        const maxY = rootOrigin.y + rootSize.height - tipSize.height - 4;
        if (x < rootOrigin.x + 4) x = rootOrigin.x + 4;
        if (x > maxX) x = maxX;
        if (y < rootOrigin.y) y = rootOrigin.y;
        if (y > maxY) y = maxY;
        _tooltip.setBounds(Rect(x - rootOrigin.x, y - rootOrigin.y,
            tipSize.width, tipSize.height));
        _window.root.bringChildToFront(_tooltip);
    }

    private void hideTooltip(bool resetTarget = true)
    {
        if (_tooltip !is null)
        {
            if (_tooltip.parent() !is null)
                _tooltip.parent().remove(_tooltip);
            _tooltip = null;
        }
        if (resetTarget)
        {
            _tooltipNode = null;
            _tooltipShownAt = MonoTime.init;
        }
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
        else if (input.name == "editor")
        {
            event["kind"] = JSONValue(input.kind);
            event["cursor"] = JSONValue(cast(long) input.cursor);
            event["anchor"] = JSONValue(cast(long) input.anchor);
            event["length"] = JSONValue(cast(long) input.length);
            event["line"] = JSONValue(cast(long) input.line);
            event["column"] = JSONValue(cast(long) input.column);
        }
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

    private void addInputKey(ref JSONValue[string] keys, Key key)
    {
        keys[keyName(key)] = JSONValue(cast(long) key);
    }

    private void inputMap(long id)
    {
        JSONValue[string] keys;
        foreach (key; [
            Key.backspace, Key.tab, Key.enter, Key.escape, Key.space,
            Key.pageUp, Key.pageDown, Key.end, Key.home, Key.left, Key.up,
            Key.right, Key.down, Key.insert, Key.deleteKey, Key.minus,
            Key.equal, Key.leftBracket, Key.rightBracket, Key.backslash,
            Key.semicolon, Key.apostrophe, Key.grave, Key.comma, Key.period,
            Key.slash,
        ])
            addInputKey(keys, key);
        foreach (offset; 0 .. 26)
            addInputKey(keys, cast(Key) (cast(int) Key.a + offset));
        foreach (offset; 0 .. 10)
            addInputKey(keys, cast(Key) (cast(int) Key.digit0 + offset));
        foreach (offset; 0 .. 12)
            addInputKey(keys, cast(Key) (cast(int) Key.f1 + offset));

        JSONValue[string] modifiers;
        modifiers["none"] = JSONValue(0);
        modifiers["shift"] = JSONValue(1);
        modifiers["control"] = JSONValue(2);
        modifiers["alt"] = JSONValue(4);
        modifiers["meta"] = JSONValue(8);
        modifiers["capsLock"] = JSONValue(16);
        modifiers["numLock"] = JSONValue(32);

        JSONValue[string] buttons;
        buttons["none"] = JSONValue(cast(long) MouseButton.none);
        buttons["left"] = JSONValue(cast(long) MouseButton.left);
        buttons["middle"] = JSONValue(cast(long) MouseButton.middle);
        buttons["right"] = JSONValue(cast(long) MouseButton.right);
        buttons["extra1"] = JSONValue(cast(long) MouseButton.extra1);
        buttons["extra2"] = JSONValue(cast(long) MouseButton.extra2);

        JSONValue[string] kinds;
        kinds["pointerDown"] = JSONValue(1);
        kinds["pointerMove"] = JSONValue(2);
        kinds["pointerUp"] = JSONValue(3);
        kinds["wheel"] = JSONValue(4);
        kinds["keyDown"] = JSONValue(5);
        kinds["keyUp"] = JSONValue(6);

        JSONValue[string] extra;
        extra["keys"] = JSONValue(keys);
        extra["modifiers"] = JSONValue(modifiers);
        extra["buttons"] = JSONValue(buttons);
        extra["kinds"] = JSONValue(kinds);
        respond(id, true, null, extra);
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
                case "getEditorState":
                    getEditorState(requestId, document);
                    break;
                case "setSelection":
                    setSelection(requestId, document);
                    break;
                case "setWordWrap":
                    setWordWrap(requestId, document);
                    break;
                case "setEditorView":
                    setEditorView(requestId, document);
                    break;
                case "setEditorStyles":
                    setEditorStyles(requestId, document);
                    break;
                case "setCanvas":
                    setCanvas(requestId, document);
                    break;
                case "setTick":
                    setTick(requestId, document);
                    break;
                case "setTabs":
                    setTabs(requestId, document);
                    break;
                case "setChrome":
                    setChrome(requestId, document);
                    break;
                case "setMenu":
                    setMenu(requestId, document);
                    break;
                case "getBounds":
                    getBounds(requestId, document);
                    break;
                case "getTabs":
                    getTabs(requestId, document);
                    break;
                case "uiClick":
                    uiClick(requestId, document);
                    break;
                case "uiMove":
                    uiMove(requestId, document);
                    break;
                case "tooltipState":
                    tooltipState(requestId);
                    break;
                case "menu":
                    openMenu(requestId, document);
                    break;
                case "menuState":
                    menuState(requestId, document);
                    break;
                case "menuClick":
                    menuClick(requestId, document);
                    break;
                case "pointer":
                    pointer(requestId, document);
                    break;
                case "key":
                    key(requestId, document);
                    break;
                case "inputmap":
                    inputMap(requestId);
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
        const framebuffer = _window.framebufferSize();
        const scale = _window.displayScale();
        window["width"] = JSONValue(cast(long) size.width);
        window["height"] = JSONValue(cast(long) size.height);
        window["framebufferWidth"] = JSONValue(cast(long) framebuffer.width);
        window["framebufferHeight"] = JSONValue(cast(long) framebuffer.height);
        window["displayScaleX"] = JSONValue(cast(double) scale.x());
        window["displayScaleY"] = JSONValue(cast(double) scale.y());
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
        bool notify = true;
        if (auto value = "notify" in document.object)
        {
            enforce((*value).type == JSONType.true_ ||
                (*value).type == JSONType.false_, "notify must be a boolean");
            notify = (*value).boolean;
        }
        if (!_registry.setText(node, text, notify))
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
        if (auto editor = cast(HostTextEditor) widget)
        {
            JSONValue[string] extra;
            extra["node"] = JSONValue(node);
            extra["text"] = JSONValue(editor.textUtf8());
            respond(id, true, null, extra);
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

    private void getEditorState(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto widget = _registry.widget(node);
        if (widget is null)
        {
            respond(id, false, "unknown node: " ~ node);
            return;
        }
        if (auto editor = cast(HostTextEditor) widget)
        {
            JSONValue[string] extra;
            extra["node"] = JSONValue(node);
            extra["length"] = JSONValue(cast(long) editor.textView.length);
            extra["cursor"] = JSONValue(cast(long) editor.cursorIndex());
            extra["anchor"] = JSONValue(cast(long) editor.selectionAnchor());
            extra["line"] = JSONValue(cast(long) editor.cursorLine());
            extra["column"] = JSONValue(cast(long) editor.cursorColumn());
            extra["hasSelection"] = JSONValue(editor.hasSelection());
            respond(id, true, null, extra);
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
        extra["length"] = JSONValue(cast(long) editor.textView.length);
        extra["cursor"] = JSONValue(cast(long) editor.cursorIndex());
        extra["anchor"] = JSONValue(cast(long) editor.selectionAnchor());
        extra["line"] = JSONValue(cast(long) editor.cursorLine());
        extra["column"] = JSONValue(cast(long) editor.cursorColumn());
        extra["hasSelection"] = JSONValue(editor.hasSelection());
        respond(id, true, null, extra);
    }

    private void setSelection(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto widget = _registry.widget(node);
        if (widget is null)
        {
            respond(id, false, "unknown node: " ~ node);
            return;
        }
        if (auto editor = cast(HostTextEditor) widget)
        {
            const start = optionalInt(document, "start", -1);
            const end = optionalInt(document, "end", -1);
            enforce(start >= 0 && end >= 0,
                "start and end are required and must be non-negative");
            enforce(start <= editor.textView.length &&
                end <= editor.textView.length,
                "selection range is outside the document");
            editor.setSelection(cast(size_t) start, cast(size_t) end);
            editor.requestFocus();
            JSONValue[string] extra;
            extra["node"] = JSONValue(node);
            extra["start"] = JSONValue(start);
            extra["end"] = JSONValue(end);
            respond(id, true, null, extra);
            return;
        }
        auto editor = cast(TextEditor) widget;
        if (editor is null)
        {
            respond(id, false, "node is not a text editor: " ~ node);
            return;
        }
        const start = optionalInt(document, "start", -1);
        const end = optionalInt(document, "end", -1);
        enforce(start >= 0 && end >= 0,
            "start and end are required and must be non-negative");
        enforce(start <= editor.textView.length &&
            end <= editor.textView.length,
            "selection range is outside the document");
        editor.setSelection(cast(size_t) start, cast(size_t) end);
        editor.requestFocus();
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["start"] = JSONValue(start);
        extra["end"] = JSONValue(end);
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
        if (auto editor = cast(HostTextEditor) widget)
        {
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

    private void setEditorView(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto widget = _registry.widget(node);
        auto editor = cast(HostTextEditor) widget;
        if (editor is null)
        {
            respond(id, false, "node is not a host text editor: " ~ node);
            return;
        }
        auto lineNumbers = "lineNumbers" in document.object;
        auto currentLine = "highlightCurrentLine" in document.object;
        auto fontValue = "fontSize" in document.object;
        enforce(lineNumbers !is null || currentLine !is null ||
            fontValue !is null,
            "lineNumbers, highlightCurrentLine, or fontSize is required");
        foreach (value; [lineNumbers, currentLine])
        {
            if (value is null) continue;
            enforce((*value).type == JSONType.true_ ||
                (*value).type == JSONType.false_,
                "editor view flags must be booleans");
        }
        const fontSize = optionalInt(document, "fontSize", -1);
        enforce(fontSize == -1 || (fontSize >= 0 && fontSize <= 48),
            "fontSize must be -1 or between 0 and 48");
        if (lineNumbers !is null)
            editor.setLineNumbers((*lineNumbers).boolean);
        if (currentLine !is null)
            editor.setCurrentLineHighlight((*currentLine).boolean);
        if (fontSize >= 0)
            editor.setFontPixelSize(cast(int) fontSize);
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["lineNumbers"] = JSONValue(editor.lineNumbers());
        extra["highlightCurrentLine"] =
            JSONValue(editor.currentLineHighlight());
        extra["fontSize"] = JSONValue(editor.fontPixelSizeOverride());
        respond(id, true, null, extra);
    }

    private void setEditorStyles(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto editor = cast(HostTextEditor) _registry.widget(node);
        if (editor is null)
        {
            respond(id, false, "node is not a host text editor: " ~ node);
            return;
        }
        auto value = "styles" in document.object;
        enforce(value !is null, "styles is required");
        enforce((*value).type == JSONType.array,
            "styles must be an array");
        enforce((*value).array.length <= 20000,
            "styles exceeds 20000 ranges");

        const textLength = editor.textView.length;
        EditorTextStyle[] styles;
        styles.reserve((*value).array.length);
        foreach (index, item; (*value).array)
        {
            const label = "styles[" ~ to!string(index) ~ "]";
            enforce(item.type == JSONType.object,
                label ~ " must be an object");
            auto startValue = "start" in item.object;
            auto endValue = "end" in item.object;
            enforce(startValue !is null && endValue !is null,
                label ~ ".start and .end are required");
            enforce((*startValue).type == JSONType.integer &&
                (*endValue).type == JSONType.integer,
                label ~ ".start and .end must be integers");
            const start = (*startValue).integer;
            const end = (*endValue).integer;
            enforce(start >= 0 && end >= start,
                label ~ " range is invalid");
            enforce(end <= textLength,
                label ~ " range exceeds the document length");
            if (start == end) continue;
            const color = optionalString(item, "color", "");
            enforce(color.length > 0, label ~ ".color is required");
            styles ~= EditorTextStyle(cast(size_t) start, cast(size_t) end,
                parseCanvasColor(color, label ~ ".color"));
        }
        styles.sort!((a, b) => a.start < b.start);
        foreach (index, style; styles)
            if (index > 0)
                enforce(styles[index - 1].end <= style.start,
                    "editor style ranges must not overlap");
        editor.setTextStyles(styles);

        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["styles"] = JSONValue(cast(long) editor.styleCount());
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

    private Widget requireWidget(JSONValue document)
    {
        const node = requireString(document, "node");
        auto widget = _registry.widget(node);
        enforce(widget !is null, "unknown node: " ~ node);
        return widget;
    }

    private JSONValue rectValue(Rect rect)
    {
        JSONValue[string] object;
        object["x"] = JSONValue(cast(long) rect.x);
        object["y"] = JSONValue(cast(long) rect.y);
        object["width"] = JSONValue(cast(long) rect.width);
        object["height"] = JSONValue(cast(long) rect.height);
        return JSONValue(object);
    }

    private void setTabs(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto tabs = "items" in document.object;
        enforce(tabs !is null, "items is required");
        auto parsed = parseTabItems(*tabs, "items");
        if (!_registry.setTabs(node, parsed))
        {
            respond(id, false, "node is not a tab strip: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["count"] = JSONValue(cast(long) parsed.length);
        respond(id, true, null, extra);
    }

    private void setChrome(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        const style = optionalString(document, "style", "");
        const icon = optionalString(document, "icon", "");
        const textColor = optionalString(document, "textColor", "");
        const fontSize = optionalInt(document, "fontSize", -1);
        enforce(fontSize == -1 || (fontSize >= 8 && fontSize <= 96),
            "fontSize must be -1 or between 8 and 96");
        int active = -1;
        if (auto value = "active" in document.object)
        {
            enforce((*value).type == JSONType.true_ ||
                (*value).type == JSONType.false_,
                "active must be a boolean");
            active = (*value).boolean ? 1 : 0;
        }
        if (!_registry.setChrome(node, style, icon, active, textColor,
            cast(int) fontSize))
        {
            respond(id, false, "node has no updatable chrome: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        respond(id, true, null, extra);
    }

    private void setMenu(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        auto value = "items" in document.object;
        enforce(value !is null, "items is required");
        enforce((*value).type == JSONType.array,
            "items must be an array");
        const count = _registry.setMenuItems(node, *value);
        if (count < 0)
        {
            respond(id, false, "node is not a menu: " ~ node);
            return;
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["items"] = JSONValue(cast(long) count);
        respond(id, true, null, extra);
    }

    private void getBounds(long id, JSONValue document)
    {
        auto widget = requireWidget(document);
        const origin = widget.globalOrigin();
        // globalOrigin already includes this widget's position; only the size
        // comes from bounds(), which is parent-relative.
        const bounds = widget.bounds();
        const rect = Rect(origin.x, origin.y, bounds.width, bounds.height);
        JSONValue[string] extra;
        extra["node"] = JSONValue(requireString(document, "node"));
        extra["rect"] = rectValue(rect);
        respond(id, true, null, extra);
    }

    private void getTabs(long id, JSONValue document)
    {
        auto widget = requireWidget(document);
        auto strip = cast(TabStrip) widget;
        enforce(strip !is null, "node is not a tab strip");
        const origin = strip.globalOrigin();
        JSONValue[] tabs;
        foreach (index, tab; strip.items)
        {
            const rect = strip.itemRect(cast(int) index)
                .translated(origin.x, origin.y);
            JSONValue[string] item;
            item["index"] = JSONValue(cast(long) index);
            item["label"] = JSONValue(toUTF8(tab.label));
            item["action"] = JSONValue(toUTF8(tab.action));
            item["active"] = JSONValue(tab.active);
            item["dirty"] = JSONValue(tab.dirty);
            item["rect"] = rectValue(rect);
            tabs ~= JSONValue(item);
        }
        JSONValue[string] extra;
        extra["node"] = JSONValue(requireString(document, "node"));
        extra["count"] = JSONValue(cast(long) tabs.length);
        extra["tabs"] = JSONValue(tabs);
        respond(id, true, null, extra);
    }

    private void tooltipState(long id)
    {
        JSONValue[string] tooltip;
        tooltip["visible"] = JSONValue(_tooltip !is null);
        if (_tooltipNode.length > 0)
            tooltip["node"] = JSONValue(_tooltipNode);
        if (_tooltip !is null)
        {
            tooltip["text"] = JSONValue(_tooltip.text);
            const origin = _tooltip.globalOrigin();
            const bounds = _tooltip.bounds();
            tooltip["rect"] = rectValue(
                Rect(origin.x, origin.y, bounds.width, bounds.height));
        }
        JSONValue[string] extra;
        extra["tooltip"] = JSONValue(tooltip);
        respond(id, true, null, extra);
    }

    private void uiClick(long id, JSONValue document)
    {
        const x = optionalInt(document, "x", 0);
        const y = optionalInt(document, "y", 0);
        enforce(x >= -100000 && x <= 100000 &&
            y >= -100000 && y <= 100000,
            "click coordinates must be between -100000 and 100000");
        const button = parseButton(optionalString(document, "button", "left"));
        auto driver = new UiTestDriver(_window);
        driver.click(Point(cast(int) x, cast(int) y), button);
        JSONValue[string] extra;
        extra["x"] = JSONValue(x);
        extra["y"] = JSONValue(y);
        respond(id, true, null, extra);
    }

    private void uiMove(long id, JSONValue document)
    {
        const x = optionalInt(document, "x", 0);
        const y = optionalInt(document, "y", 0);
        enforce(x >= -100000 && x <= 100000 &&
            y >= -100000 && y <= 100000,
            "move coordinates must be between -100000 and 100000");
        auto driver = new UiTestDriver(_window);
        driver.moveTo(Point(cast(int) x, cast(int) y));
        JSONValue[string] extra;
        extra["x"] = JSONValue(x);
        extra["y"] = JSONValue(y);
        respond(id, true, null, extra);
    }

    private JSONValue menuPayload(ContextMenu menu)
    {
        const origin = menu.globalOrigin();
        const localRect = menu.menuRect();
        const menuRect = localRect.translated(origin.x, origin.y);
        JSONValue[] items;
        int y = localRect.y + 3;
        foreach (index, item; menu.items)
        {
            const height = item.separator ? 4 : menu.rowHeightForTesting();
            const itemRect = Rect(localRect.x + 3, y,
                localRect.width - 6, height).translated(origin.x, origin.y);
            JSONValue[string] value;
            value["index"] = JSONValue(cast(long) index);
            value["label"] = JSONValue(toUTF8(item.label));
            value["shortcut"] = JSONValue(toUTF8(item.shortcut));
            value["separator"] = JSONValue(item.separator);
            value["enabled"] = JSONValue(item.enabled);
            value["checked"] = JSONValue(item.checked);
            value["rect"] = rectValue(itemRect);
            items ~= JSONValue(value);
            y += height;
        }
        JSONValue[string] object;
        object["rect"] = rectValue(menuRect);
        object["count"] = JSONValue(cast(long) items.length);
        object["items"] = JSONValue(items);
        return JSONValue(object);
    }

    private ContextMenu openContextMenu()
    {
        auto popup = _window.root.topmostPopupSurface();
        auto menu = cast(ContextMenu) popup;
        enforce(menu !is null, "no menu is open");
        return menu;
    }

    private void openMenu(long id, JSONValue document)
    {
        const node = requireString(document, "node");
        if (!_registry.activate(node))
        {
            respond(id, false, "node is not an activatable menu: " ~ node);
            return;
        }
        auto menu = openContextMenu();
        JSONValue[string] extra;
        extra["node"] = JSONValue(node);
        extra["menu"] = menuPayload(menu);
        respond(id, true, null, extra);
    }

    private void menuState(long id, JSONValue document)
    {
        auto menu = openContextMenu();
        JSONValue[string] extra;
        extra["menu"] = menuPayload(menu);
        respond(id, true, null, extra);
    }

    private void menuClick(long id, JSONValue document)
    {
        auto menu = openContextMenu();
        const index = optionalInt(document, "index", -1);
        enforce(index >= 0 && index < cast(long) menu.items.length,
            "menu index is outside the open menu");
        const origin = menu.globalOrigin();
        const localRect = menu.menuRect();
        int y = localRect.y + 3;
        Point point;
        bool found;
        foreach (itemIndex, item; menu.items)
        {
            const height = item.separator ? 4 : menu.rowHeightForTesting();
            if (cast(long) itemIndex == index)
            {
                point = Point(origin.x + localRect.x + 3 +
                    (localRect.width - 6) / 2,
                    origin.y + y + height / 2);
                found = !item.separator;
                break;
            }
            y += height;
        }
        enforce(found, "cannot click a separator");
        auto driver = new UiTestDriver(_window);
        driver.click(point);
        const closed = _window.root.topmostPopupSurface() is null;
        enforce(closed, "menu did not close after item click");
        JSONValue[string] extra;
        extra["index"] = JSONValue(index);
        extra["closed"] = JSONValue(closed);
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
        extra["inputDropped"] = JSONValue(cast(long) info.inputDropped);
        extra["inputCoalesced"] = JSONValue(cast(long) info.inputCoalesced);
        extra["inputDroppedMoves"] = JSONValue(cast(long) info.inputDroppedMoves);
        extra["inputDroppedDiscrete"] = JSONValue(
            cast(long) info.inputDroppedDiscrete);
        extra["frameAgeMs"] = JSONValue(cast(long) (info.frameAge * 1000.0));
        extra["stale"] = JSONValue(info.stale);
        extra["staleAfterMs"] = JSONValue(cast(long) info.staleMs);
        extra["error"] = JSONValue(info.error);
        extra["retryInMs"] = JSONValue(cast(long) info.retryMs);
        extra["pixelWidth"] = JSONValue(cast(long) info.pixelWidth);
        extra["pixelHeight"] = JSONValue(cast(long) info.pixelHeight);
        extra["preferredWidth"] = JSONValue(cast(long) info.preferredWidth);
        extra["preferredHeight"] = JSONValue(cast(long) info.preferredHeight);
        extra["displayScale"] = JSONValue(info.displayScale);
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
