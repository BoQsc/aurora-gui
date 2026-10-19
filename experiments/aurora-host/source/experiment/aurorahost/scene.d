module experiment.aurorahost.scene;

import experiment.aurorahost.canvas : CanvasCommand, CanvasSpec, CanvasWidget,
    parseCanvasColor;
import experiment.aurorahost.events : HostEvent;
import experiment.aurorahost.image_widget : ImageWidget;
import experiment.aurorahost.surface : SurfaceInfo, SurfaceSpec, SurfaceWidget;
import experiment.aurorahost.protocol : MaxSceneDepth, MaxSceneNodes, NodeTypes,
    MaxCanvasCommands, MaxInputEvents, MaxSurfacePixels, SchemaVersion;
import std.algorithm : canFind;
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
    string action;
    int scale = 2;
    int spacing = 8;
    string src;
    int width;
    int height;
    int flex;
    bool hasBackground;
    Color background;
    RgbaImage image;
    string[] events;
    int tickHz;
    CanvasSpec canvas;
    SurfaceSpec surface;
    SceneNode[] children;
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

    bool setText(string id, string text)
    {
        auto widget = id in _widgets;
        if (widget is null) return false;
        if (auto editor = cast(TextEditor) *widget)
            editor.setText(text);
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
            if (auto editor = cast(TextEditor) _widgets[id])
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
    SceneNode root;
}

private bool hasField(JSONValue object, string key)
{
    return (key in object.object) !is null;
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

private CanvasCommand parseCanvasCommand(JSONValue value, int index,
    string label, string assetBase)
{
    enforce(value.type == JSONType.object, label ~ " must be an object");
    CanvasCommand command;
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
    return node;
}

Scene loadScene(string path)
{
    const JSONValue document = parseJSON(readText(path));
    enforce(document.type == JSONType.object, "scene root must be an object");

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

    auto rootValue = "root" in document.object;
    enforce(rootValue !is null, "scene is missing field 'root'");
    int count;
    scene.root = parseNode(*rootValue, count, 0, "scene.root", "root",
        scene.assetBase);
    return scene;
}

string describeScene(const Scene scene)
{
    return format("%s %dx%d theme=%s root=%s",
        scene.window.title, scene.window.width, scene.window.height,
        scene.window.theme, scene.root.type);
}

Theme themeFor(string name)
{
    return name == "dark" ? Theme.dark() : Theme.light();
}

Widget buildWidget(const SceneNode node, NodeRegistry registry)
{
    switch (node.type)
    {
        case "column":
        {
            auto column = new VBox(node.spacing, Insets(12));
            registry.registerNode(node.id, node.type, column, node.text);
            foreach (child; node.children)
                column.add(buildWidget(child, registry));
            return column;
        }
        case "row":
        {
            auto row = new HBox(node.spacing);
            row.layoutHints().preferredHeight = 44;
            registry.registerNode(node.id, node.type, row, node.text);
            foreach (child; node.children)
                row.add(buildWidget(child, registry));
            return row;
        }
        case "label":
        {
            auto label = new Label(node.text);
            label.setScale(node.scale);
            registry.registerNode(node.id, node.type, label, node.text);
            return label;
        }
        case "button":
        {
            auto button = new Button(node.text);
            button.layoutHints().preferredWidth = 96;
            button.layoutHints().preferredHeight = 36;
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
        case "textArea":
        {
            auto editor = new TextArea(node.text);
            editor.layoutHints().flex = 1.0;
            registry.registerNode(node.id, node.type, editor, node.text);
            return editor;
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
            registry.registerNode(node.id, node.type, canvas, "");
            return canvas;
        }
        case "image":
        {
            auto source = cast(SceneNode) node;
            auto image = new ImageWidget(source.image, source.width,
                source.height, source.flex, source.hasBackground,
                source.background);
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
            registry.registerNode(source.id, source.type, surface,
                source.surface.path);
            return surface;
        }
        case "spacer":
        {
            auto spacer = new Spacer();
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
    auto window = new GuiWindow(options, themeFor(scene.window.theme));
    window.setRoot(buildWidget(scene.root, registry));
    return window;
}
