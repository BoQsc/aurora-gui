module experiment.aurorahost.scene;

import experiment.aurorahost.canvas : CanvasCommand, CanvasSpec, CanvasWidget,
    parseCanvasColor;
import experiment.aurorahost.events : HostEvent;
import experiment.aurorahost.host_editor : HostTextArea, HostTextEditor;
import experiment.aurorahost.host_ui : ChromeButton, ChromeStyle, ContextTextArea,
    ContextHostTextArea, ContextTextField, HostMenuButton, TabItem, TabStrip,
    iconForName, parseChromeStyle;
import experiment.aurorahost.image_widget : ImageWidget;
import experiment.aurorahost.surface : SurfaceInfo, SurfaceSpec, SurfaceWidget;
import experiment.aurorahost.protocol : MaxSceneDepth, MaxSceneNodes, NodeTypes,
    MaxCanvasCommands, MaxInputEvents, MaxSurfacePixels, SchemaVersion;
import std.algorithm : canFind, max;
import std.exception : enforce;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, buildPath, dirName, isAbsolute;
import std.utf : toUTF8;

import aurora;

struct SceneWindow
{
    string title = "Aurora Host Experiment";
    int width = 760;
    int height = 520;
    string theme = "light";
}

struct SceneNode
{
    string id;
    string type;
    string text;
    string tooltip;
    string action;
    int scale = 2;
    int spacing = 8;
    string src;
    int width;
    int height;
    int flex;
    int padding;
    bool hasPadding;
    bool hasBackground;
    Color background;
    bool hasBorder;
    Color border;
    int radius;
    string style;
    string icon;
    string orientation = "horizontal";
    bool active;
    bool lineNumbers;
    bool highlightCurrentLine;
    int fontSize;
    string textAlign;
    bool hasTextColor;
    Color textColor;
    RgbaImage image;
    string[] events;
    int tickHz;
    CanvasSpec canvas;
    SurfaceSpec surface;
    MenuItemSpec[] menuItems;
    TabItem[] tabItems;
    SceneNode[] children;
}

struct MenuItemSpec
{
    string label;
    string shortcut;
    string action;
    string icon;
    bool separator;
    bool enabled = true;
    bool checked;
    MenuItemSpec[] children;
}

struct SceneThemeOverrides
{
    Color[string] colors;
    int cornerRadius = -1;
    int borderWidth = -1;
    int controlHeight = -1;
    int fontScale = -1;
    int spacing = -1;
}

struct NodeInfo
{
    string id;
    string type;
    string text;
}

class NodeRegistry
{
    private Widget[string] _widgets;
    private string[string] _types;
    private string[string] _texts;
    private string[string] _tooltips;
    private string[] _order;
    private SurfaceWidget[] _surfaces;

    string assetBase;

    void delegate(string) onActivate;
    void delegate(string node, string action) onAction;
    void delegate(HostEvent) onEvent;

    void registerNode(string id, string type, Widget widget, string text)
    {
        enforce(id.length > 0, "node id must not be empty");
        enforce((id in _widgets) is null, "duplicate node id: " ~ id);
        _widgets[id] = widget;
        _types[id] = type;
        _texts[id] = text;
        _order ~= id;
        if (auto surface = cast(SurfaceWidget) widget)
            _surfaces ~= surface;
    }

    bool setText(string id, string text, bool notify = true)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        if (auto editor = cast(HostTextEditor) *widget)
            editor.setText(text, notify);
        else if (auto editor = cast(TextEditor) *widget)
            editor.setText(text, notify);
        else if (auto label = cast(Label) *widget)
            label.setText(text);
        else if (auto button = cast(Button) *widget)
            button.setText(text);
        else
            return false;
        _texts[id] = text;
        return true;
    }

    Widget widget(string id)
    {
        auto found = id in _widgets;
        return found is null ? null : *found;
    }

    /** Attach an explanatory hover hint without changing widget layout. */
    void setTooltip(string id, string tooltip)
    {
        if (id in _widgets)
            _tooltips[id] = tooltip;
    }

    /**
     * Find the deepest enabled, hovered node carrying a tooltip.
     *
     * Registration order is parent-before-child, so walking in reverse keeps
     * nested controls from being shadowed by a container hint.
     */
    bool hoveredTooltip(out string id, out string text, out Rect rect)
    {
        foreach_reverse (candidate; _order)
        {
            auto tooltip = candidate in _tooltips;
            if (tooltip is null || (*tooltip).length == 0) continue;
            auto widget = candidate in _widgets;
            if (widget is null || *widget is null) continue;
            if (!(*widget).visible() || !(*widget).enabled() ||
                !(*widget).hovered()) continue;
            const origin = (*widget).globalOrigin();
            const bounds = (*widget).bounds();
            id = candidate;
            text = *tooltip;
            rect = Rect(origin.x, origin.y, bounds.width, bounds.height);
            return true;
        }
        return false;
    }

    bool activate(string id)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        auto button = cast(Button) *widget;
        if (button is null) return false;
        button.activate();
        return true;
    }

    void notifyActivated(string id)
    {
        if (onActivate !is null)
            onActivate(id);
    }

    void dispatchAction(string node, string action)
    {
        if (onAction !is null)
            onAction(node, action);
    }

    bool setCanvasCommands(string id, CanvasCommand[] commands)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        auto canvas = cast(CanvasWidget) *widget;
        if (canvas is null) return false;
        canvas.setCommands(commands);
        return true;
    }

    bool setTick(string id, int hz)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        auto canvas = cast(CanvasWidget) *widget;
        if (canvas is null) return false;
        canvas.setTick(hz);
        return true;
    }

    bool setTabs(string id, TabItem[] tabs)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        auto strip = cast(TabStrip) *widget;
        if (strip is null) return false;
        strip.setItems(tabs);
        return true;
    }

    /**
     * Update portable chrome state without exposing Aurora widget classes to
     * the control protocol. Empty strings and -1 mean "leave unchanged".
     */
    bool setChrome(string id, string styleName = "", string iconName = "",
        int active = -1, string textColor = "", int fontSize = -1)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        bool changed;
        auto chrome = cast(ChromeButton) *widget;
        auto button = cast(Button) *widget;
        if (chrome !is null && styleName.length > 0)
        {
            chrome.setChromeStyle(parseChromeStyle(styleName,
                ChromeStyle.standard));
            changed = true;
        }
        if (button !is null && iconName.length > 0)
        {
            const icon = iconForName(iconName);
            if (chrome !is null)
                chrome.setChromeIcon(icon);
            else
                button.setIcon(icon);
            changed = true;
        }
        if (chrome !is null && active >= 0)
        {
            chrome.setActive(active != 0);
            changed = true;
        }
        if (textColor.length > 0)
        {
            const color = parseCanvasColor(textColor, "textColor");
            if (auto label = cast(Label) *widget)
            {
                label.setColor(color);
                changed = true;
            }
            else if (chrome !is null)
            {
                chrome.setTextColor(color);
                changed = true;
            }
        }
        if (fontSize > 0)
        {
            if (auto label = cast(Label) *widget)
            {
                label.setPixelSize(fontSize);
                changed = true;
            }
            else if (chrome !is null)
            {
                chrome.setPixelSize(fontSize);
                changed = true;
            }
        }
        return changed;
    }

    bool injectPointer(string id, string kind, int x, int y,
        MouseButton button, uint modifiers, int wheelX = 0, int wheelY = 0)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        if (auto canvas = cast(CanvasWidget) *widget)
        {
            canvas.injectPointer(kind, x, y, button, modifiers, wheelX, wheelY);
            return true;
        }
        if (auto surface = cast(SurfaceWidget) *widget)
        {
            surface.injectPointer(kind, x, y, button, modifiers, wheelX, wheelY);
            return true;
        }
        return false;
    }

    /**
     * Replace a menu node's portable popup items. Applications use this to
     * reflect live checked state without recreating the scene.
     */
    int setMenuItems(string id, JSONValue items)
    {
        auto widget = id in _widgets;
        if (widget is null) return -1;
        auto menu = cast(HostMenuButton) *widget;
        if (menu is null) return -1;
        auto specs = parseMenuItems(items, id ~ ".items");
        menu.setItems(buildMenuItems(specs, this, id));
        return cast(int) menu.itemCount();
    }

    bool injectKey(string id, string kind, Key key, uint modifiers)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        if (auto canvas = cast(CanvasWidget) *widget)
        {
            canvas.injectKey(kind, key, modifiers);
            return true;
        }
        if (auto surface = cast(SurfaceWidget) *widget)
        {
            surface.injectKey(kind, key, modifiers);
            return true;
        }
        return false;
    }

    bool surfaceInfo(string id, out SurfaceInfo info)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        auto surface = cast(SurfaceWidget) *widget;
        if (surface is null) return false;
        info = surface.info();
        return true;
    }

    void refreshSurfaces()
    {
        foreach (surface; _surfaces)
            surface.refresh(0.0);
    }

    NodeInfo[] tree()
    {
        NodeInfo[] result;
        foreach (id; _order)
        {
            string text = _texts[id];
            if (auto editor = cast(HostTextEditor) _widgets[id])
                text = editor.textUtf8();
            else if (auto editor = cast(TextEditor) _widgets[id])
                text = editor.textUtf8();
            else if (auto label = cast(Label) _widgets[id])
                text = toUTF8(label.text());
            else if (auto button = cast(Button) _widgets[id])
                text = toUTF8(button.text());
            result ~= NodeInfo(id, _types[id], text);
        }
        return result;
    }

    size_t length() const
    {
        return _order.length;
    }
}

struct Scene
{
    int schemaVersion;
    string assetBase;
    SceneWindow window;
    SceneThemeOverrides themeOverrides;
    SceneNode root;
}

private bool hasField(JSONValue object, string key)
{
    return (key in object.object) !is null;
}

private bool isCommonNodeField(string name)
{
    switch (name)
    {
        case "id":
        case "type":
        case "tooltip":
        case "width":
        case "height":
        case "flex":
        case "padding":
        case "background":
        case "border":
        case "radius":
        case "style":
        case "icon":
        case "active":
        case "fontSize":
        case "textColor":
        case "align":
            return true;
        default:
            return false;
    }
}

private bool isNodeSpecificField(string type, string name)
{
    switch (type)
    {
        case "column":
        case "row":
            return name == "children" || name == "spacing";
        case "label":
            return name == "text" || name == "scale";
        case "button":
            return name == "text" || name == "action";
        case "menu":
            return name == "text" || name == "items";
        case "tabs":
            return name == "items";
        case "separator":
            return name == "orientation";
        case "textArea":
            return name == "text" || name == "events" || name == "menu" ||
                name == "lineNumbers" || name == "highlightCurrentLine";
        case "textField":
            return name == "text" || name == "events" || name == "menu";
        case "canvas":
            return name == "events" || name == "tickHz" ||
                name == "commands";
        case "image":
            return name == "src";
        case "surface":
            return name == "path" || name == "events" ||
                name == "staleMs";
        case "spacer":
            return false;
        default:
            return false;
    }
}

private bool isSceneField(string name)
{
    switch (name)
    {
        case "schemaVersion":
        case "window":
        case "themeOverrides":
        case "root":
            return true;
        default:
            return false;
    }
}

private bool isWindowField(string name)
{
    switch (name)
    {
        case "title":
        case "width":
        case "height":
        case "theme":
            return true;
        default:
            return false;
    }
}

private bool isMenuItemField(string name)
{
    switch (name)
    {
        case "label":
        case "shortcut":
        case "action":
        case "icon":
        case "separator":
        case "enabled":
        case "checked":
        case "children":
            return true;
        default:
            return false;
    }
}

private bool isTabItemField(string name)
{
    switch (name)
    {
        case "label":
        case "action":
        case "active":
        case "dirty":
            return true;
        default:
            return false;
    }
}

private bool isCanvasCommandField(string name)
{
    switch (name)
    {
        case "op":
        case "x":
        case "y":
        case "x2":
        case "y2":
        case "width":
        case "height":
        case "radius":
        case "thickness":
        case "scale":
        case "text":
        case "src":
        case "color":
            return true;
        default:
            return false;
    }
}

private void requireNoChildren(JSONValue object, string label)
{
    enforce(!hasField(object, "children"), label ~ " does not accept children");
}

private string readString(JSONValue object, string key, string fallback,
    string label)
{
    auto found = key in object.object;
    if (found is null) return fallback;
    enforce((*found).type == JSONType.string,
        format("%s.%s must be a string", label, key));
    return (*found).str;
}

private int readInt(JSONValue object, string key, int fallback, string label)
{
    auto found = key in object.object;
    if (found is null) return fallback;
    enforce((*found).type == JSONType.integer,
        format("%s.%s must be an integer", label, key));
    const value = (*found).integer;
    enforce(value >= int.min && value <= int.max,
        format("%s.%s is out of range", label, key));
    return cast(int) value;
}

private int readRange(JSONValue object, string key, int fallback, int minimum,
    int maximum, string label)
{
    const value = readInt(object, key, fallback, label);
    enforce(value >= minimum && value <= maximum,
        format("%s.%s must be between %d and %d", label, key, minimum, maximum));
    return value;
}

private string resolveAssetPath(string assetBase, string path)
{
    return isAbsolute(path) ? path : buildPath(assetBase, path);
}

private string[] parseEvents(JSONValue value, string label)
{
    enforce(value.type == JSONType.array, label ~ " must be an array");
    string[] events;
    foreach (index, event; value.array)
    {
        enforce(event.type == JSONType.string,
            format("%s[%d] must be a string", label, index));
        const name = event.str;
        enforce(name == "pointer" || name == "key" || name == "tick",
            format("%s[%d] has unknown event '%s'", label, index, name));
        if (!events.canFind(name))
            events ~= name;
    }
    return events;
}

private string[] parseEditorEvents(JSONValue value, string label)
{
    enforce(value.type == JSONType.array, label ~ " must be an array");
    string[] events;
    foreach (index, event; value.array)
    {
        enforce(event.type == JSONType.string,
            format("%s[%d] must be a string", label, index));
        const name = event.str;
        enforce(name == "change" || name == "cursor",
            format("%s[%d] has unknown editor event '%s'", label, index, name));
        if (!events.canFind(name))
            events ~= name;
    }
    return events;
}

private bool readBool(JSONValue object, string key, bool fallback, string label)
{
    auto found = key in object.object;
    if (found is null) return fallback;
    enforce((*found).type == JSONType.true_ || (*found).type == JSONType.false_,
        format("%s.%s must be a boolean", label, key));
    return (*found).boolean;
}

private MenuItemSpec[] parseMenuItems(JSONValue value, string label, int depth = 0)
{
    enforce(depth <= 4, label ~ " exceeds max menu depth 4");
    enforce(value.type == JSONType.array, label ~ " must be an array");
    enforce(value.array.length <= 64,
        format("%s exceeds max menu item count 64", label));
    MenuItemSpec[] items;
    foreach (index, item; value.array)
    {
        const itemLabel = format("%s[%d]", label, index);
        enforce(item.type == JSONType.object, itemLabel ~ " must be an object");
        MenuItemSpec spec;
        spec.label = readString(item, "label", "", itemLabel);
        spec.shortcut = readString(item, "shortcut", "", itemLabel);
        spec.action = readString(item, "action", "", itemLabel);
        spec.icon = readString(item, "icon", "", itemLabel);
        spec.separator = readBool(item, "separator", false, itemLabel);
        spec.enabled = readBool(item, "enabled", true, itemLabel);
        spec.checked = readBool(item, "checked", false, itemLabel);
        foreach (name, ignored; item.object)
            enforce(isMenuItemField(name),
                format("%s has unknown field '%s'", itemLabel, name));
        if (spec.separator)
            enforce(spec.label.length == 0 && spec.action.length == 0,
                itemLabel ~ ": a separator cannot have a label or action");
        else
            enforce(spec.label.length > 0, itemLabel ~ ".label is required");
        if (auto children = "children" in item.object)
            spec.children = parseMenuItems(*children, itemLabel ~ ".children",
                depth + 1);
        items ~= spec;
    }
    return items;
}

TabItem[] parseTabItems(JSONValue value, string label)
{
    enforce(value.type == JSONType.array, label ~ " must be an array");
    enforce(value.array.length <= 64,
        format("%s exceeds max tab count 64", label));
    TabItem[] items;
    foreach (index, item; value.array)
    {
        const itemLabel = format("%s[%d]", label, index);
        enforce(item.type == JSONType.object, itemLabel ~ " must be an object");
        TabItem tab;
        tab.label = readString(item, "label", "", itemLabel);
        enforce(tab.label.length > 0, itemLabel ~ ".label is required");
        tab.action = readString(item, "action", "", itemLabel);
        tab.active = readBool(item, "active", false, itemLabel);
        tab.dirty = readBool(item, "dirty", false, itemLabel);
        foreach (name, ignored; item.object)
            enforce(isTabItemField(name),
                format("%s has unknown field '%s'", itemLabel, name));
        items ~= tab;
    }
    return items;
}

private bool isThemeColor(string name)
{
    switch (name)
    {
        case "windowBackground":
        case "panelBackground":
        case "panelElevated":
        case "text":
        case "textMuted":
        case "border":
        case "accent":
        case "accentHover":
        case "accentPressed":
        case "selection":
        case "selectionText":
        case "fieldBackground":
        case "buttonBackground":
        case "buttonHover":
        case "buttonPressed":
        case "disabled":
        case "danger":
        case "taskbar":
        case "taskbarHover":
        case "shadow":
            return true;
        default:
            return false;
    }
}

private void parseThemeOverrides(JSONValue value, string label,
    ref SceneThemeOverrides overrides)
{
    enforce(value.type == JSONType.object, label ~ " must be an object");
    foreach (name, item; value.object)
    {
        const itemLabel = label ~ "." ~ name;
        if (name == "cornerRadius")
        {
            overrides.cornerRadius = readRange(value, name, -1, 0, 64,
                label);
            continue;
        }
        if (name == "borderWidth")
        {
            overrides.borderWidth = readRange(value, name, -1, 0, 8, label);
            continue;
        }
        if (name == "controlHeight")
        {
            overrides.controlHeight = readRange(value, name, -1, 18, 120,
                label);
            continue;
        }
        if (name == "fontScale")
        {
            overrides.fontScale = readRange(value, name, -1, 1, 8, label);
            continue;
        }
        if (name == "spacing")
        {
            overrides.spacing = readRange(value, name, -1, 0, 64, label);
            continue;
        }
        enforce(isThemeColor(name),
            format("%s has unknown theme field '%s'", label, name));
        enforce(item.type == JSONType.string,
            itemLabel ~ " must be a color string");
        overrides.colors[name] = parseCanvasColor(item.str, itemLabel);
    }
}

private CanvasCommand parseCanvasCommand(JSONValue value, int index,
    string label, string assetBase)
{
    enforce(value.type == JSONType.object, label ~ " must be an object");
    CanvasCommand command;
    foreach (name, ignored; value.object)
        enforce(isCanvasCommandField(name),
            format("%s has unknown field '%s'", label, name));
    command.op = readString(value, "op", "", label);
    enforce(command.op == "rect" || command.op == "roundedRect" ||
        command.op == "line" || command.op == "circle" ||
        command.op == "ring" || command.op == "text" ||
        command.op == "image",
        format("%s.op is unknown: '%s'", label, command.op));
    command.x = readRange(value, "x", 0, -100000, 100000, label);
    command.y = readRange(value, "y", 0, -100000, 100000, label);
    command.x2 = readRange(value, "x2", 0, -100000, 100000, label);
    command.y2 = readRange(value, "y2", 0, -100000, 100000, label);
    command.width = readRange(value, "width", 0, 0, 100000, label);
    command.height = readRange(value, "height", 0, 0, 100000, label);
    command.radius = readRange(value, "radius", 0, 0, 100000, label);
    command.thickness = readRange(value, "thickness", 1, 1, 64, label);
    command.scale = readRange(value, "scale", 2, 1, 8, label);
    command.text = readString(value, "text", "", label);
    if (command.op == "image")
    {
        command.src = readString(value, "src", "", label);
        enforce(command.src.length > 0, label ~ ".src is required for image");
        command.image = loadImage(resolveAssetPath(assetBase, command.src));
        enforce(command.image.width() > 0 && command.image.height() > 0,
            label ~ " image has no pixels");
        enforce(cast(ulong) command.image.width() * command.image.height() <=
            MaxSurfacePixels,
            format("%s image exceeds max pixel count %d", label,
                MaxSurfacePixels));
        if (command.width == 0)
            command.width = command.image.width();
        if (command.height == 0)
            command.height = command.image.height();
        command.color = Color(255, 255, 255, 255);
    }
    else
        command.color = parseCanvasColor(
            readString(value, "color", "", label), label ~ ".color");
    return command;
}

CanvasCommand[] parseCanvasCommands(JSONValue value, string label,
    string assetBase = "")
{
    enforce(value.type == JSONType.array,
        label ~ " must be an array");
    enforce(value.array.length <= MaxCanvasCommands,
        format("%s exceeds max canvas command count %d", label,
            MaxCanvasCommands));
    CanvasCommand[] commands;
    foreach (index, command; value.array)
        commands ~= parseCanvasCommand(command, cast(int) index,
            format("%s[%d]", label, index), assetBase);
    return commands;
}

private CanvasSpec parseCanvas(JSONValue value, string label, string assetBase)
{
    CanvasSpec canvas;
    canvas.width = readRange(value, "width", 0, 0, 10000, label);
    canvas.height = readRange(value, "height", 0, 0, 10000, label);
    canvas.flex = readRange(value, "flex", 0, 0, 1000, label);
    if (auto background = "background" in value.object)
    {
        enforce((*background).type == JSONType.string,
            label ~ ".background must be a string");
        canvas.hasBackground = true;
        canvas.background = parseCanvasColor(
            (*background).str, label ~ ".background");
    }
    if (auto events = "events" in value.object)
        canvas.events = parseEvents(*events, label ~ ".events");
    canvas.tickHz = readRange(value, "tickHz", 0, 0, 240, label);
    if (auto commands = "commands" in value.object)
        canvas.commands = parseCanvasCommands(*commands,
            label ~ ".commands", assetBase);
    if (canvas.events.canFind("tick") && canvas.tickHz == 0)
        enforce(false,
            label ~ ".tickHz must be set when events includes 'tick'");
    if (canvas.tickHz > 0 && !canvas.events.canFind("tick"))
        enforce(false,
            label ~ ".events must include 'tick' when tickHz is set");
    return canvas;
}

private void parseBackground(JSONValue value, string label, ref bool hasBackground,
    ref Color background)
{
    if (auto found = "background" in value.object)
    {
        enforce((*found).type == JSONType.string,
            label ~ ".background must be a string");
        hasBackground = true;
        background = parseCanvasColor((*found).str, label ~ ".background");
    }
}

private void parseImageNode(JSONValue value, string label, string assetBase,
    ref SceneNode node)
{
    node.src = readString(value, "src", "", label);
    enforce(node.src.length > 0, label ~ ".src is required for image");
    node.image = loadImage(resolveAssetPath(assetBase, node.src));
    const sourceWidth = node.image.width();
    const sourceHeight = node.image.height();
    enforce(sourceWidth > 0 && sourceHeight > 0,
        label ~ " image has no pixels");
    enforce(cast(ulong) sourceWidth * sourceHeight <= MaxSurfacePixels,
        format("%s image exceeds max pixel count %d", label,
            MaxSurfacePixels));
    node.width = readRange(value, "width", sourceWidth, 1, 10000, label);
    node.height = readRange(value, "height", sourceHeight, 1, 10000, label);
    node.flex = readRange(value, "flex", 0, 0, 1000, label);
    parseBackground(value, label, node.hasBackground, node.background);
}

private SurfaceSpec parseSurface(JSONValue value, string label,
    string assetBase)
{
    SurfaceSpec surface;
    const path = readString(value, "path", "", label);
    enforce(path.length > 0, label ~ ".path is required for surface");
    surface.path = resolveAssetPath(assetBase, path);
    surface.width = readRange(value, "width", 320, 1, 10000, label);
    surface.height = readRange(value, "height", 240, 1, 10000, label);
    enforce(cast(ulong) surface.width * surface.height <= MaxSurfacePixels,
        format("%s surface exceeds max pixel count %d", label,
            MaxSurfacePixels));
    surface.flex = readRange(value, "flex", 0, 0, 1000, label);
    surface.staleMs = cast(uint) readRange(value, "staleMs", 500, 50,
        3600000, label);
    parseBackground(value, label, surface.hasBackground, surface.background);
    if (auto events = "events" in value.object)
        surface.events = parseEvents(*events, label ~ ".events");
    return surface;
}

private SceneNode[] parseChildren(JSONValue object, ref int count, int depth,
    string label, string parentId, string assetBase)
{
    auto found = "children" in object.object;
    if (found is null) return [];
    enforce((*found).type == JSONType.array,
        label ~ ".children must be an array");
    SceneNode[] children;
    foreach (index, child; (*found).array)
        children ~= parseNode(child, count, depth + 1,
            format("%s.children[%d]", label, index),
            format("%s.%d", parentId, index), assetBase);
    return children;
}

private SceneNode parseNode(JSONValue value, ref int count, int depth,
    string label, string fallbackId, string assetBase)
{
    enforce(depth <= MaxSceneDepth,
        format("%s exceeds max scene depth %d", label, MaxSceneDepth));
    enforce(value.type == JSONType.object, label ~ " must be an object");
    ++count;
    enforce(count <= MaxSceneNodes,
        format("scene exceeds max node count %d", MaxSceneNodes));

    SceneNode node;
    node.id = readString(value, "id", fallbackId, label);
    enforce(node.id.length > 0, label ~ ".id must not be empty");
    node.type = readString(value, "type", "", label);
    enforce(node.type.length > 0, label ~ ".type is required");
    enforce(NodeTypes.canFind(node.type),
        format("%s has unknown node type '%s'", label, node.type));
    foreach (name, ignored; value.object)
        enforce(isCommonNodeField(name) ||
            isNodeSpecificField(node.type, name),
            format("%s has unknown field '%s'", label, name));
    node.tooltip = readString(value, "tooltip", "", label);
    enforce(node.tooltip.length <= 240,
        label ~ ".tooltip must not exceed 240 characters");

    switch (node.type)
    {
        case "column":
        case "row":
            node.spacing = readInt(value, "spacing", 8, label);
            enforce(node.spacing >= 0 && node.spacing <= 64,
                format("%s.spacing must be between 0 and 64", label));
            node.children = parseChildren(value, count, depth, label, node.id,
                assetBase);
            break;
        case "label":
            requireNoChildren(value, label);
            node.text = readString(value, "text", "", label);
            node.scale = readInt(value, "scale", 2, label);
            enforce(node.scale >= 1 && node.scale <= 8,
                format("%s.scale must be between 1 and 8", label));
            break;
        case "button":
            requireNoChildren(value, label);
            node.text = readString(value, "text", "", label);
            node.action = readString(value, "action", "", label);
            break;
        case "textArea":
            requireNoChildren(value, label);
            node.text = readString(value, "text", "", label);
            node.lineNumbers = readBool(value, "lineNumbers", false, label);
            node.highlightCurrentLine = readBool(value,
                "highlightCurrentLine", false, label);
            if (auto events = "events" in value.object)
                node.events = parseEditorEvents(*events, label ~ ".events");
            if (auto menu = "menu" in value.object)
                node.menuItems = parseMenuItems(*menu, label ~ ".menu");
            break;
        case "textField":
            requireNoChildren(value, label);
            node.text = readString(value, "text", "", label);
            if (auto events = "events" in value.object)
                node.events = parseEditorEvents(*events, label ~ ".events");
            if (auto menu = "menu" in value.object)
                node.menuItems = parseMenuItems(*menu, label ~ ".menu");
            break;
        case "menu":
            requireNoChildren(value, label);
            node.text = readString(value, "text", "", label);
            enforce(node.text.length > 0, label ~ ".text is required");
            if (auto items = "items" in value.object)
                node.menuItems = parseMenuItems(*items, label ~ ".items");
            break;
        case "tabs":
            requireNoChildren(value, label);
            if (auto items = "items" in value.object)
                node.tabItems = parseTabItems(*items, label ~ ".items");
            break;
        case "separator":
            requireNoChildren(value, label);
            node.orientation = readString(value, "orientation",
                "horizontal", label);
            enforce(node.orientation == "horizontal" ||
                node.orientation == "vertical",
                label ~ ".orientation must be horizontal or vertical");
            break;
        case "canvas":
            requireNoChildren(value, label);
            node.canvas = parseCanvas(value, label, assetBase);
            break;
        case "image":
            requireNoChildren(value, label);
            parseImageNode(value, label, assetBase, node);
            break;
        case "surface":
            requireNoChildren(value, label);
            node.surface = parseSurface(value, label, assetBase);
            break;
        case "spacer":
            requireNoChildren(value, label);
            break;
        default:
            enforce(false, "unsupported node type: " ~ node.type);
    }

    if (auto width = "width" in value.object)
        node.width = readRange(value, "width", 0, 0, 10000, label);
    if (auto height = "height" in value.object)
        node.height = readRange(value, "height", 0, 0, 10000, label);
    if (auto flex = "flex" in value.object)
        node.flex = readRange(value, "flex", 0, 0, 1000, label);
    if (auto padding = "padding" in value.object)
    {
        node.padding = readRange(value, "padding", 0, 0, 64, label);
        node.hasPadding = true;
    }
    if (auto background = "background" in value.object)
        node.hasBackground = true;
    parseBackground(value, label, node.hasBackground, node.background);
    if (auto border = "border" in value.object)
    {
        enforce((*border).type == JSONType.string,
            label ~ ".border must be a color string");
        node.border = parseCanvasColor((*border).str, label ~ ".border");
        node.hasBorder = true;
    }
    if (auto radius = "radius" in value.object)
        node.radius = readRange(value, "radius", 0, 0, 64, label);
    if (auto style = "style" in value.object)
        node.style = readString(value, "style", "", label);
    if (auto icon = "icon" in value.object)
        node.icon = readString(value, "icon", "", label);
    if (auto active = "active" in value.object)
        node.active = readBool(value, "active", false, label);
    if (auto fontSize = "fontSize" in value.object)
        node.fontSize = readRange(value, "fontSize", 0, 8, 96, label);
    if (auto textColor = "textColor" in value.object)
    {
        enforce((*textColor).type == JSONType.string,
            label ~ ".textColor must be a color string");
        node.textColor = parseCanvasColor((*textColor).str,
            label ~ ".textColor");
        node.hasTextColor = true;
    }
    if (auto alignValue = "align" in value.object)
    {
        node.textAlign = readString(value, "align", "left", label);
        enforce(node.textAlign == "left" || node.textAlign == "center" ||
            node.textAlign == "right",
            label ~ ".align must be left, center, or right");
    }
    if (!node.hasPadding)
        node.padding = node.type == "column" ? 12 : 0;
    return node;
}

Scene loadScene(string path)
{
    const JSONValue document = parseJSON(readText(path));
    enforce(document.type == JSONType.object, "scene root must be an object");
    foreach (name, ignored; document.object)
        enforce(isSceneField(name),
            format("scene has unknown field '%s'", name));

    Scene scene;
    scene.schemaVersion = readInt(document, "schemaVersion", -1, "scene");
    enforce(scene.schemaVersion == SchemaVersion,
        format("unsupported schemaVersion %d (expected %d)",
            scene.schemaVersion, SchemaVersion));
    scene.assetBase = dirName(absolutePath(path));

    auto windowValue = "window" in document.object;
    if (windowValue !is null)
    {
        enforce((*windowValue).type == JSONType.object,
            "scene.window must be an object");
        auto window = *windowValue;
        foreach (name, ignored; window.object)
            enforce(isWindowField(name),
                format("scene.window has unknown field '%s'", name));
        scene.window.title = readString(window, "title",
            "Aurora Host Experiment", "scene.window");
        scene.window.width = readInt(window, "width", 760, "scene.window");
        scene.window.height = readInt(window, "height", 520, "scene.window");
        scene.window.theme = readString(window, "theme", "light", "scene.window");
        enforce(scene.window.width >= 200 && scene.window.width <= 10000,
            "scene.window.width must be between 200 and 10000");
        enforce(scene.window.height >= 200 && scene.window.height <= 10000,
            "scene.window.height must be between 200 and 10000");
        enforce(scene.window.theme == "light" || scene.window.theme == "dark",
            "scene.window.theme must be 'light' or 'dark'");
    }
    if (auto themeOverrides = "themeOverrides" in document.object)
        parseThemeOverrides(*themeOverrides, "scene.themeOverrides",
            scene.themeOverrides);

    auto rootValue = "root" in document.object;
    enforce(rootValue !is null, "scene is missing field 'root'");
    int count;
    scene.root = parseNode(*rootValue, count, 0, "scene.root", "root",
        scene.assetBase);
    bool[string] ids;
    validateUniqueIds(scene.root, ids);
    return scene;
}

private void validateUniqueIds(const SceneNode node, ref bool[string] seen)
{
    enforce((node.id in seen) is null, "duplicate node id: " ~ node.id);
    seen[node.id] = true;
    foreach (child; node.children)
        validateUniqueIds(child, seen);
}

string describeScene(const Scene scene)
{
    return format("%s %dx%d theme=%s root=%s",
        scene.window.title, scene.window.width, scene.window.height,
        scene.window.theme, scene.root.type);
}

private void emitEditorEvent(T)(T editor, string node, string kind,
    NodeRegistry registry)
{
    if (registry.onEvent is null)
        return;
    HostEvent event;
    event.node = node;
    event.name = "editor";
    event.kind = kind;
    event.cursor = editor.cursorIndex();
    event.anchor = editor.selectionAnchor();
    event.length = editor.textView.length;
    event.line = editor.cursorLine();
    event.column = editor.cursorColumn();
    registry.onEvent(event);
}

private void wireEditorEvents(T)(T editor, const SceneNode node,
    NodeRegistry registry)
{
    if (node.events.canFind("change"))
        editor.onChanged = delegate()
        {
            emitEditorEvent(editor, node.id, "change", registry);
        };
    if (node.events.canFind("cursor"))
        editor.onCursorMoved = delegate()
        {
            emitEditorEvent(editor, node.id, "cursor", registry);
        };
}

Theme themeFor(string name)
{
    return name == "dark" ? Theme.dark() : Theme.light();
}

private Theme themeWithOverrides(const Scene scene)
{
    auto palette = themeFor(scene.window.theme);
    const overrides = scene.themeOverrides;
    if (overrides.cornerRadius >= 0)
        palette.cornerRadius = overrides.cornerRadius;
    if (overrides.borderWidth >= 0)
        palette.borderWidth = overrides.borderWidth;
    if (overrides.controlHeight >= 0)
        palette.controlHeight = overrides.controlHeight;
    if (overrides.fontScale >= 0)
        palette.fontScale = overrides.fontScale;
    if (overrides.spacing >= 0)
        palette.spacing = overrides.spacing;
    if (auto value = "windowBackground" in overrides.colors)
        palette.windowBackground = *value;
    if (auto value = "panelBackground" in overrides.colors)
        palette.panelBackground = *value;
    if (auto value = "panelElevated" in overrides.colors)
        palette.panelElevated = *value;
    if (auto value = "text" in overrides.colors)
        palette.text = *value;
    if (auto value = "textMuted" in overrides.colors)
        palette.textMuted = *value;
    if (auto value = "border" in overrides.colors)
        palette.border = *value;
    if (auto value = "accent" in overrides.colors)
        palette.accent = *value;
    if (auto value = "accentHover" in overrides.colors)
        palette.accentHover = *value;
    if (auto value = "accentPressed" in overrides.colors)
        palette.accentPressed = *value;
    if (auto value = "selection" in overrides.colors)
        palette.selection = *value;
    if (auto value = "selectionText" in overrides.colors)
        palette.selectionText = *value;
    if (auto value = "fieldBackground" in overrides.colors)
        palette.fieldBackground = *value;
    if (auto value = "buttonBackground" in overrides.colors)
        palette.buttonBackground = *value;
    if (auto value = "buttonHover" in overrides.colors)
        palette.buttonHover = *value;
    if (auto value = "buttonPressed" in overrides.colors)
        palette.buttonPressed = *value;
    if (auto value = "disabled" in overrides.colors)
        palette.disabled = *value;
    if (auto value = "danger" in overrides.colors)
        palette.danger = *value;
    if (auto value = "taskbar" in overrides.colors)
        palette.taskbar = *value;
    if (auto value = "taskbarHover" in overrides.colors)
        palette.taskbarHover = *value;
    if (auto value = "shadow" in overrides.colors)
        palette.shadow = *value;
    return palette;
}

private void applyHints(Widget widget, const SceneNode node)
{
    if (node.width > 0)
        widget.layoutHints().preferredWidth = node.width;
    if (node.height > 0)
        widget.layoutHints().preferredHeight = node.height;
    if (node.flex > 0)
        widget.layoutHints().flex = cast(double) node.flex;
}

private void applyPanelChrome(Widget widget, const SceneNode node)
{
    auto panel = cast(Panel) widget;
    if (panel is null) return;
    if (node.hasBackground)
        panel.setBackground(node.background);
    if (node.hasBorder)
        panel.setBorder(node.border, node.radius);
}

private void delegate() menuAction(NodeRegistry registry, string nodeId,
    string action)
{
    return delegate()
    {
        registry.dispatchAction(nodeId, action);
    };
}

private ContextMenuItem[] buildMenuItems(const(MenuItemSpec)[] specs,
    NodeRegistry registry, string nodeId)
{
    ContextMenuItem[] items;
    foreach (spec; specs)
    {
        if (spec.separator)
        {
            items ~= ContextMenuItem.separatorItem();
            continue;
        }
        auto icon = iconForName(spec.icon);
        if (spec.children.length > 0)
        {
            auto childItems = buildMenuItems(spec.children, registry, nodeId);
            items ~= ContextMenuItem.submenuItem(toUTF8(spec.label), icon,
                childItems, spec.enabled);
            continue;
        }
        void delegate() action;
        if (spec.action.length > 0)
            action = menuAction(registry, nodeId, toUTF8(spec.action));
        auto item = ContextMenuItem.command(toUTF8(spec.label), icon, action,
            toUTF8(spec.shortcut), spec.enabled);
        item.checked = spec.checked;
        items ~= item;
    }
    return items;
}

Widget buildWidget(const SceneNode node, NodeRegistry registry)
{
    switch (node.type)
    {
        case "column":
        {
            auto column = new VBox(node.spacing, Insets(node.padding));
            applyPanelChrome(column, node);
            applyHints(column, node);
            registry.registerNode(node.id, node.type, column, node.text);
            foreach (child; node.children)
                column.add(buildWidget(child, registry));
            return column;
        }
        case "row":
        {
            auto row = new HBox(node.spacing, Insets(node.padding));
            if (node.height == 0)
                row.layoutHints().preferredHeight = 44;
            applyPanelChrome(row, node);
            applyHints(row, node);
            registry.registerNode(node.id, node.type, row, node.text);
            foreach (child; node.children)
                row.add(buildWidget(child, registry));
            return row;
        }
        case "label":
        {
            auto label = new Label(node.text);
            if (node.fontSize > 0)
                label.setPixelSize(node.fontSize);
            else
                label.setScale(node.scale);
            if (node.hasTextColor)
                label.setColor(node.textColor);
            if (node.textAlign == "center")
                label.setAlignment(HorizontalAlign.center);
            else if (node.textAlign == "right")
                label.setAlignment(HorizontalAlign.right);
            applyHints(label, node);
            registry.registerNode(node.id, node.type, label, node.text);
            return label;
        }
        case "button":
        {
            auto button = new ChromeButton(node.text, iconForName(node.icon),
                parseChromeStyle(node.style));
            if (node.fontSize > 0)
                button.setPixelSize(node.fontSize);
            if (node.active)
                button.setActive(true);
            if (node.hasTextColor)
                button.setTextColor(node.textColor);
            if (node.width == 0)
                button.layoutHints().preferredWidth = 96;
            if (node.height == 0)
                button.layoutHints().preferredHeight = 36;
            applyHints(button, node);
            registry.registerNode(node.id, node.type, button, node.text);
            if (node.action.length > 0)
                button.onClick = delegate()
                {
                    registry.dispatchAction(node.id, node.action);
                };
            else
                button.onClick = delegate() { registry.notifyActivated(node.id); };
            return button;
        }
        case "menu":
        {
            auto button = new HostMenuButton(node.text);
            if (node.fontSize > 0)
                button.setPixelSize(node.fontSize);
            if (node.hasTextColor)
                button.setTextColor(node.textColor);
            applyHints(button, node);
            registry.registerNode(node.id, node.type, button, node.text);
            auto items = buildMenuItems(node.menuItems, registry, node.id);
            button.setItems(items);
            button.onEmpty = delegate() { registry.notifyActivated(node.id); };
            button.onClick = delegate() { button.open(); };
            return button;
        }
        case "tabs":
        {
            TabItem[] tabs;
            foreach (item; node.tabItems)
                tabs ~= TabItem(toUTF8(item.label), toUTF8(item.action),
                    item.active, item.dirty);
            auto strip = new TabStrip(tabs);
            applyHints(strip, node);
            registry.registerNode(node.id, node.type, strip, "");
            strip.onAction = delegate(string action)
            {
                registry.dispatchAction(node.id, action);
            };
            return strip;
        }
        case "separator":
        {
            auto separator = new Separator(node.orientation == "vertical" ?
                Orientation.vertical : Orientation.horizontal);
            applyHints(separator, node);
            registry.registerNode(node.id, node.type, separator, "");
            return separator;
        }
        case "textArea":
        {
            HostTextEditor editor = node.menuItems.length > 0 ?
                new ContextHostTextArea(node.text,
                    buildMenuItems(node.menuItems, registry, node.id)) :
                new HostTextArea(node.text);
            if (node.hasTextColor)
                editor.setTextColor(node.textColor);
            editor.setLineNumbers(node.lineNumbers);
            editor.setCurrentLineHighlight(node.highlightCurrentLine);
            editor.layoutHints().flex = 1.0;
            applyHints(editor, node);
            registry.registerNode(node.id, node.type, editor, node.text);
            wireEditorEvents(editor, node, registry);
            return editor;
        }
        case "textField":
        {
            TextEditor field = node.menuItems.length > 0 ?
                new ContextTextField(node.text,
                    buildMenuItems(node.menuItems, registry, node.id)) :
                new TextField(node.text);
            if (node.hasTextColor)
                field.setTextColor(node.textColor);
            if (node.width == 0)
                field.layoutHints().preferredWidth = 180;
            applyHints(field, node);
            registry.registerNode(node.id, node.type, field, node.text);
            wireEditorEvents(field, node, registry);
            return field;
        }
        case "canvas":
        {
            auto canvas = new CanvasWidget(node.canvas);
            const eventNode = node.id;
            canvas.onInput = delegate(HostEvent event)
            {
                event.node = eventNode;
                if (registry.onEvent !is null)
                    registry.onEvent(event);
            };
            applyHints(canvas, node);
            registry.registerNode(node.id, node.type, canvas, "");
            return canvas;
        }
        case "image":
        {
            auto source = cast(SceneNode) node;
            auto image = new ImageWidget(source.image, source.width,
                source.height, source.flex, source.hasBackground,
                source.background);
            applyHints(image, node);
            registry.registerNode(source.id, source.type, image, source.src);
            return image;
        }
        case "surface":
        {
            auto source = cast(SceneNode) node;
            auto surface = new SurfaceWidget(source.surface);
            const eventNode = source.id;
            surface.onInput = delegate(HostEvent event)
            {
                event.node = eventNode;
                if (registry.onEvent !is null)
                    registry.onEvent(event);
            };
            applyHints(surface, node);
            registry.registerNode(source.id, source.type, surface,
                source.surface.path);
            return surface;
        }
        case "spacer":
        {
            auto spacer = new Spacer();
            applyHints(spacer, node);
            registry.registerNode(node.id, node.type, spacer, node.text);
            return spacer;
        }
        default:
            throw new Exception("Unsupported node type: " ~ node.type);
    }
}

GuiWindow createWindow(const Scene scene, NodeRegistry registry)
{
    registry.assetBase = scene.assetBase;
    WindowOptions options;
    options.title = scene.window.title;
    options.width = scene.window.width;
    options.height = scene.window.height;
    auto window = new GuiWindow(options, themeWithOverrides(scene));
    auto root = buildWidget(scene.root, registry);
    registerTooltips(scene.root, registry);
    window.setRoot(root);
    return window;
}

private void registerTooltips(const SceneNode node, NodeRegistry registry)
{
    if (node.tooltip.length > 0)
        registry.setTooltip(node.id, node.tooltip);
    foreach (child; node.children)
        registerTooltips(child, registry);
}
