module auroradesigner.model;

import aurora.types : Rect;
import std.algorithm : filter;
import std.array : Appender, appender, array;
import std.conv : to;
import std.format : format;
import std.string : split, splitLines, startsWith, strip;

/**
 * Aurora Designer document model.
 *
 * A `DesignDocument` owns a flat list of `Node` objects, each positioned in a
 * parent coordinate space. Child offsets are stored relative to the parent so
 * moving a parent moves its children with it (a simple hierarchy without a
 * deep layout engine — the artboard is the canvas surface, and the inspector
 * drives absolute coordinates for the selected node).
 */

/** The Aurora-D widgets that the palette can drop onto the artboard. */
enum NodeKind : ubyte
{
    window,
    panel,
    hbox,
    vbox,
    button,
    label,
    textfield,
    checkbox,
    separator,
    scrollview,
    listview,
    image
}

/** A single node in the design. */
struct Node
{
    NodeKind kind;
    string name;
    string id;
    int x;
    int y;
    int width;
    int height;
    int[] children;
    string text;
    string colorHex = "";
    bool transparent;
    bool accent;
    bool checked;
}

/** The artboard dimensions and the node forest rooted at the window. */
struct DesignDocument
{
    int canvasWidth = 900;
    int canvasHeight = 560;
    Node[] nodes;
    int root = -1;

    /** Allocate a node and append it; returns its index. */
    int addNode(NodeKind kind, int x, int y)
    {
        Node node;
        node.kind = kind;
        node.name = defaultName(kind);
        node.id = defaultId(kind, cast(int) nodes.length + 1);
        node.text = defaultText(kind);
        node.x = x;
        node.y = y;
        node.width = defaultWidth(kind);
        node.height = defaultHeight(kind);
        nodes ~= node;
        return cast(int) nodes.length - 1;
    }

    int findNode(int index) const @safe pure nothrow @nogc
    {
        return index >= 0 && index < cast(int) nodes.length ? index : -1;
    }

    /// Total number of descendants (recursively) of `index`, including itself.
    int subtreeSize(int index) const @safe pure nothrow @nogc
    {
        if (findNode(index) < 0) return 0;
        int count = 1;
        foreach (child; nodes[index].children)
            count += subtreeSize(child);
        return count;
    }

    bool nodeAt(int x, int y) const @safe pure nothrow @nogc
    {
        return findNode(root) < 0;
    }

    bool nodeVisible(int index) const @safe pure nothrow @nogc
    {
        return findNode(index) >= 0;
    }

    /// Find the topmost node whose rect contains the point (children win).
    int hitTest(int x, int y) const @safe pure nothrow @nogc
    {
        if (findNode(root) < 0) return -1;
        return hitTestRecursive(root, x, y);
    }

    private int hitTestRecursive(int index, int x, int y) const
        @safe pure nothrow @nogc
    {
        if (!containsPoint(index, x, y)) return -1;
        // Search children in reverse painter order (topmost first).
        for (int i = cast(int) nodes[index].children.length - 1; i >= 0; --i)
        {
            const child = hitTestRecursive(nodes[index].children[i], x, y);
            if (child >= 0) return child;
        }
        return index;
    }

    bool containsPoint(int index, int x, int y) const @safe pure nothrow @nogc
    {
        if (findNode(index) < 0) return false;
        const node = nodes[index];
        const parent = parentOf(index);
        int ox = 0;
        int oy = 0;
        if (parent >= 0)
        {
            const abs = absoluteRect(parent);
            ox = abs.x;
            oy = abs.y;
        }
        const rx = node.x + ox;
        const ry = node.y + oy;
        return x >= rx && y >= ry && x < rx + node.width && y < ry + node.height;
    }

    /// Absolute artboard rect of a node (sum of ancestor offsets).
    Rect absoluteRect(int index) const @safe pure nothrow @nogc
    {
        if (findNode(index) < 0) return Rect(0, 0, 0, 0);
        const node = nodes[index];
        const parent = parentOf(index);
        if (parent < 0) return Rect(node.x, node.y, node.width, node.height);
        const abs = absoluteRect(parent);
        return Rect(abs.x + node.x, abs.y + node.y, node.width, node.height);
    }

    /// The parent of a node, or -1 for the root.
    int parentOf(int index) const @safe pure nothrow @nogc
    {
        if (index == root || findNode(index) < 0) return -1;
        foreach (i, node; nodes)
        {
            foreach (child; node.children)
                if (child == index) return cast(int) i;
        }
        return -1;
    }

    /// True when a node can accept children (a container widget).
    bool canHostChildren(NodeKind kind) const @safe pure nothrow @nogc
    {
        final switch (kind)
        {
            case NodeKind.window:
            case NodeKind.panel:
            case NodeKind.hbox:
            case NodeKind.vbox:
            case NodeKind.scrollview:
                return true;
            case NodeKind.button:
            case NodeKind.label:
            case NodeKind.textfield:
            case NodeKind.checkbox:
            case NodeKind.separator:
            case NodeKind.listview:
            case NodeKind.image:
                return false;
        }
    }

    /// Remove a node and its whole subtree (children arrays are patched).
    void removeNode(int index)
    {
        if (findNode(index) < 0) return;
        if (index == root)
        {
            root = -1;
            nodes = [];
            return;
        }
        const parent = parentOf(index);
        if (parent >= 0)
            nodes[parent].children = nodes[parent].children.filter!(c => c != index).array;

        bool[] removed = new bool[nodes.length];
        markRemoved(index, removed);
        Node[] kept;
        int[] remap = new int[nodes.length];
        remap[] = -1;
        foreach (i, node; nodes)
        {
            if (removed[i]) continue;
            remap[i] = cast(int) kept.length;
            auto copy = node;
            int[] keptChildren;
            foreach (child; node.children)
                if (!removed[child]) keptChildren ~= remap[child];
            copy.children = keptChildren;
            kept ~= copy;
        }
        if (root >= 0) root = remap[root];
        nodes = kept;
    }

    /// Reparent a node as a child of `parentIndex` at the artboard position.
    void reparent(int index, int parentIndex, int artboardX, int artboardY)
    {
        if (findNode(index) < 0 || findNode(parentIndex) < 0 || index == parentIndex)
            return;
        const oldParent = parentOf(index);
        if (oldParent >= 0)
            nodes[oldParent].children = nodes[oldParent].children.filter!(c => c != index).array;
        nodes[index].x = artboardX;
        nodes[index].y = artboardY;
        if (!isDescendant(parentIndex, index))
            nodes[parentIndex].children ~= index;
    }

    /// Move a node by a relative delta.
    void moveBy(int index, int dx, int dy)
    {
        if (findNode(index) < 0) return;
        nodes[index].x += dx;
        nodes[index].y += dy;
    }

    /// True when `candidate` is inside the subtree rooted at `ancestor`.
    bool isDescendant(int ancestor, int candidate) const @safe pure nothrow @nogc
    {
        int current = candidate;
        while (current >= 0 && current != root)
        {
            if (current == ancestor) return true;
            current = parentOf(current);
        }
        return false;
    }

    private void markRemoved(int index, ref bool[] removed) const
        @safe pure nothrow @nogc
    {
        removed[index] = true;
        foreach (child; nodes[index].children)
            markRemoved(child, removed);
    }
}

// (Rect is imported from aurora.types; the model layer reuses it directly.)

private immutable string[] KindNames = [
    "Window", "Panel", "HBox", "VBox", "Button", "Label", "Text Field",
    "Check Box", "Separator", "Scroll View", "List View", "Image"
];

string nodeKindName(NodeKind kind) @safe pure nothrow @nogc
{
    return KindNames[cast(size_t) kind];
}

int defaultWidth(NodeKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case NodeKind.window: return 320;
        case NodeKind.panel: return 220;
        case NodeKind.hbox:
        case NodeKind.vbox: return 200;
        case NodeKind.button: return 96;
        case NodeKind.label: return 120;
        case NodeKind.textfield: return 180;
        case NodeKind.checkbox: return 140;
        case NodeKind.separator: return 140;
        case NodeKind.scrollview: return 200;
        case NodeKind.listview: return 180;
        case NodeKind.image: return 128;
    }
}

int defaultHeight(NodeKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case NodeKind.window: return 200;
        case NodeKind.panel: return 140;
        case NodeKind.hbox:
        case NodeKind.vbox: return 120;
        case NodeKind.button: return 38;
        case NodeKind.label: return 24;
        case NodeKind.textfield: return 40;
        case NodeKind.checkbox: return 32;
        case NodeKind.separator: return 9;
        case NodeKind.scrollview: return 160;
        case NodeKind.listview: return 160;
        case NodeKind.image: return 96;
    }
}

string defaultName(NodeKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case NodeKind.window: return "window";
        case NodeKind.panel: return "panel";
        case NodeKind.hbox: return "hbox";
        case NodeKind.vbox: return "vbox";
        case NodeKind.button: return "button";
        case NodeKind.label: return "label";
        case NodeKind.textfield: return "field";
        case NodeKind.checkbox: return "checkbox";
        case NodeKind.separator: return "separator";
        case NodeKind.scrollview: return "scroll";
        case NodeKind.listview: return "list";
        case NodeKind.image: return "image";
    }
}

string defaultId(NodeKind kind, int n)
{
    return format("%s%d", defaultName(kind), n);
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

/** Serialize the document to a compact text format (one line per node). */
string serializeDocument(const ref DesignDocument document)
{
    auto output = appender!string;
    output.put(format("canvas %d %d\n", document.canvasWidth,
        document.canvasHeight));
    output.put(format("root %d\n", document.root));
    foreach (index, node; document.nodes)
    {
        output.put(format("node %d %d %s %d %d %d %d",
            index, cast(int) node.kind, node.id, node.x, node.y,
            node.width, node.height));
        if (node.text != defaultText(node.kind))
            output.put(format(" text=%s", node.text));
        if (node.colorHex.length != 0)
            output.put(format(" color=%s", node.colorHex));
        if (node.transparent)
            output.put(format(" transparent=1"));
        if (node.accent)
            output.put(format(" accent=1"));
        if (node.checked)
            output.put(format(" checked=1"));
        output.put("\n");
        if (node.children.length != 0)
        {
            output.put(format("children %d", index));
            foreach (child; node.children)
                output.put(format(" %d", child));
            output.put("\n");
        }
    }
    return output.data;
}

string defaultText(NodeKind kind) @safe pure nothrow @nogc
{
    switch (kind)
    {
        case NodeKind.button: return "Button";
        case NodeKind.label: return "Label";
        case NodeKind.checkbox: return "Check Box";
        default: return "";
    }
}

/** Parse the serialized text format back into a document. */
DesignDocument deserializeDocument(string text)
{
    DesignDocument document;
    document.root = -1;
    bool haveRoot;
    foreach (rawLine; text.splitLines())
    {
        const line = rawLine.strip();
        if (line.length == 0) continue;
        const parts = line.split();
        if (parts.length == 0) continue;
        if (parts[0] == "canvas" && parts.length >= 3)
        {
            document.canvasWidth = parts[1].to!int;
            document.canvasHeight = parts[2].to!int;
        }
        else if (parts[0] == "root" && parts.length >= 2)
        {
            document.root = parts[1].to!int;
            haveRoot = true;
        }
        else if (parts[0] == "node" && parts.length >= 8)
        {
            Node node;
            node.kind = cast(NodeKind) parts[2].to!int;
            node.id = parts[3];
            node.x = parts[4].to!int;
            node.y = parts[5].to!int;
            node.width = parts[6].to!int;
            node.height = parts[7].to!int;
            node.name = node.id;
            node.text = defaultText(node.kind);
            for (int i = 8; i < parts.length; ++i)
            {
                const token = parts[i];
                if (token.startsWith("text=") && token.length > 5)
                    node.text = token[5 .. $];
                else if (token.startsWith("color=") && token.length > 6)
                    node.colorHex = token[6 .. $];
                else if (token == "transparent=1")
                    node.transparent = true;
                else if (token == "accent=1")
                    node.accent = true;
                else if (token == "checked=1")
                    node.checked = true;
            }
            document.nodes ~= node;
        }
        else if (parts[0] == "children" && parts.length >= 2)
        {
            const index = parts[1].to!int;
            if (index >= 0 && index < cast(int) document.nodes.length)
            {
                int[] children;
                for (int i = 2; i < parts.length; ++i)
                    children ~= parts[i].to!int;
                document.nodes[index].children = children;
            }
        }
    }
    if (haveRoot && document.findNode(document.root) < 0)
        document.root = -1;
    return document;
}

// ---------------------------------------------------------------------------
// D code generation
// ---------------------------------------------------------------------------

/** Format a D color literal from an RRGGBB hex string. */
string colorLiteral(string hex)
{
    if (hex.length == 6 && hex.allIsHex())
        return format("Color.fromHex(0x%s)", hex);
    return "";
}

private bool allIsHex(string value) @safe pure nothrow @nogc
{
    if (value.length == 0) return false;
    foreach (char ch; value)
    {
        const ok = (ch >= '0' && ch <= '9') ||
            (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
        if (!ok) return false;
    }
    return true;
}

/**
 * Generate idiomatic Aurora-D source for the current document.
 *
 * The generated tree is a Widget-hierarchy (a `Panel` for containers). Widgets
 * that support a text value or a check state are configured. Every widget gets
 * a `setId` so tests and automation can target it.
 */
string generateCode(const ref DesignDocument document)
{
    auto output = appender!string;
    output.put("import aurora;\n\n");
    output.put("// Generated by Aurora Designer.\n");
    output.put(format("// Artboard %d x %d.\n\n", document.canvasWidth,
        document.canvasHeight));
    output.put("Widget buildDesignedUi()\n{\n");
    if (document.findNode(document.root) < 0)
    {
        output.put("    auto root = new Panel();\n");
        output.put("    return root;\n}\n");
        return output.data;
    }
    const root = document.nodes[document.root];
    const rootVar = root.name.length != 0 ? sanitizeVar(root.name) : "root";
    const indent = "    ";
    output.put(format("%sauto %s = new %s();\n", indent, rootVar,
        className(root.kind)));
    output.put(format("%s%s.setId(\"%s\");\n", indent, rootVar, root.id));
    if (root.text.length != 0 && textWidget(root.kind))
        output.put(format("%s%s.setText(\"%s\");\n", indent, rootVar, root.text));
    if (root.kind == NodeKind.checkbox && root.checked)
        output.put(format("%s%s.setChecked(true);\n", indent, rootVar));
    if (root.kind == NodeKind.button && root.accent)
        output.put(format("%s%s.setAccent(true);\n", indent, rootVar));
    if (root.colorHex.length != 0 && backgroundWidget(root.kind))
    {
        output.put(format("%s%s.setBackground(%s);\n", indent, rootVar,
            colorLiteral(root.colorHex)));
    }
    output.put(format("%s%s.setBounds(Rect(0, 0, %d, %d));\n", indent,
        rootVar, document.canvasWidth, document.canvasHeight));
    output.put("\n");
    emitChildren(document, document.root, rootVar, output, 2);
    output.put(format("    return %s;\n}\n", rootVar));
    return output.data;
}

private void emitChildren(const ref DesignDocument document, int parentIndex,
    string parentVar, ref Appender!string output, int depth)
{
    const indent = repeatIndent(depth);
    foreach (child; document.nodes[parentIndex].children)
    {
        const node = document.nodes[child];
        const varName = sanitizeVar(node.name);
        output.put(format("%sauto %s = new %s();\n", indent, varName,
            className(node.kind)));
        output.put(format("%s%s.setId(\"%s\");\n", indent, varName, node.id));
        if (node.text.length != 0 && textWidget(node.kind))
            output.put(format("%s%s.setText(\"%s\");\n", indent, varName,
                node.text));
        if (node.kind == NodeKind.checkbox && node.checked)
            output.put(format("%s%s.setChecked(true);\n", indent, varName));
        if (node.kind == NodeKind.button && node.accent)
            output.put(format("%s%s.setAccent(true);\n", indent, varName));
        if (node.colorHex.length != 0 && backgroundWidget(node.kind))
        {
            output.put(format("%s%s.setBackground(%s);\n", indent, varName,
                colorLiteral(node.colorHex)));
        }
        if (node.kind == NodeKind.scrollview)
        {
            output.put(format("%s%s.setContent(%s_content());\n", indent,
                varName, varName));
            emitScrollContent(document, node, varName, output, depth + 1);
        }
        else
        {
            output.put(format("%s%s.setBounds(Rect(%d, %d, %d, %d));\n",
                indent, varName, node.x, node.y, node.width, node.height));
            output.put(format("%s%s.add(%s);\n", indent, parentVar, varName));
            emitChildren(document, child, varName, output, depth + 1);
        }
    }
}

private void emitScrollContent(const ref DesignDocument document,
    const ref Node node, string varName, ref Appender!string output, int depth)
{
    if (node.children.length == 0) return;
    const indent = repeatIndent(depth);
    // A ScrollView hosts a single content child; emit that child and return it.
    const first = document.nodes[node.children[0]];
    const innerName = sanitizeVar(first.name);
    output.put(format("%sWidget %s_content()\n", indent, varName));
    output.put(format("%s{\n", indent));
    output.put(format("%s    auto %s = new %s();\n", indent, innerName,
        className(first.kind)));
    output.put(format("%s    %s.setId(\"%s\");\n", indent, innerName, first.id));
    if (first.text.length != 0 && textWidget(first.kind))
        output.put(format("%s    %s.setText(\"%s\");\n", indent, innerName,
            first.text));
    if (first.kind == NodeKind.checkbox && first.checked)
        output.put(format("%s    %s.setChecked(true);\n", indent, innerName));
    if (first.colorHex.length != 0 && backgroundWidget(first.kind))
    {
        output.put(format("%s    %s.setBackground(%s);\n", indent, innerName,
            colorLiteral(first.colorHex)));
    }
    output.put(format("%s    return %s;\n%s}\n", indent, innerName, indent));
}

private string className(NodeKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case NodeKind.window: return "Panel";
        case NodeKind.panel: return "Panel";
        case NodeKind.hbox: return "HBox";
        case NodeKind.vbox: return "VBox";
        case NodeKind.button: return "Button";
        case NodeKind.label: return "Label";
        case NodeKind.textfield: return "TextField";
        case NodeKind.checkbox: return "CheckBox";
        case NodeKind.separator: return "Separator";
        case NodeKind.scrollview: return "ScrollView";
        case NodeKind.listview: return "ListView";
        case NodeKind.image: return "Panel";
    }
    assert(false);
}

bool textWidget(NodeKind kind) @safe pure nothrow @nogc
{
    switch (kind)
    {
        case NodeKind.button:
        case NodeKind.label:
        case NodeKind.textfield:
        case NodeKind.checkbox:
            return true;
        default:
            return false;
    }
}

bool backgroundWidget(NodeKind kind) @safe pure nothrow @nogc
{
    switch (kind)
    {
        case NodeKind.window:
        case NodeKind.panel:
            return true;
        default:
            return false;
    }
}

private string repeatIndent(int depth)
{
    string result;
    for (int i = 0; i < depth; ++i)
        result ~= "    ";
    return result;
}

private string sanitizeVar(string name)
{
    if (name.length == 0) return "widget";
    string result;
    foreach (index, char ch; name)
    {
        const isDigit = ch >= '0' && ch <= '9';
        const isLetter = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
        if (index == 0)
            result ~= isLetter ? ch : 'w';
        else
            result ~= (isLetter || isDigit || ch == '_') ? ch : '_';
    }
    return result;
}
