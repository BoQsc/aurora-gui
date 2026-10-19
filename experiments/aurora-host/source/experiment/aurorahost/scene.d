module experiment.aurorahost.scene;

import experiment.aurorahost.protocol : MaxSceneDepth, MaxSceneNodes, NodeTypes,
    SchemaVersion;
import std.algorithm : canFind;
import std.exception : enforce;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
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

    void delegate(string) onActivate;
    void delegate(string node, string action) onAction;

    void registerNode(string id, string type, Widget widget, string text)
    {
        enforce(id.length > 0, "node id must not be empty");
        enforce((id in _widgets) is null, "duplicate node id: " ~ id);
        _widgets[id] = widget;
        _types[id] = type;
        _texts[id] = text;
        _order ~= id;
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

private SceneNode[] parseChildren(JSONValue object, ref int count, int depth,
    string label, string parentId)
{
    auto found = "children" in object.object;
    if (found is null) return [];
    enforce((*found).type == JSONType.array,
        label ~ ".children must be an array");
    SceneNode[] children;
    foreach (index, child; (*found).array)
        children ~= parseNode(child, count, depth + 1,
            format("%s.children[%d]", label, index),
            format("%s.%d", parentId, index));
    return children;
}

private SceneNode parseNode(JSONValue value, ref int count, int depth,
    string label, string fallbackId)
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
            node.children = parseChildren(value, count, depth, label, node.id);
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
    scene.root = parseNode(*rootValue, count, 0, "scene.root", "root");
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
    WindowOptions options;
    options.title = scene.window.title;
    options.width = scene.window.width;
    options.height = scene.window.height;
    auto window = new GuiWindow(options, themeFor(scene.window.theme));
    window.setRoot(buildWidget(scene.root, registry));
    return window;
}
