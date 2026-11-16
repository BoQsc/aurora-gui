module auroradesigner.preview;

import aurora;
import auroradesigner.model : DesignDocument, Node, NodeKind;

/**
 * Runtime preview of the design document.
 *
 * This intentionally mirrors the generated tree: containers are Panels, text
 * nodes are Labels/Buttons/TextFields, and every node keeps the document's
 * absolute bounds and id.
 */
Widget buildPreviewWidget(const ref DesignDocument document)
{
    auto canvas = new Panel();
    canvas.setId("preview-canvas");
    canvas.setBounds(Rect(0, 0, document.canvasWidth, document.canvasHeight));
    canvas.setBackground(Color.rgba(18, 20, 26, 255));

    if (document.root >= 0 && document.root < cast(int) document.nodes.length)
    {
        auto root = makeWidget(document.nodes[document.root]);
        root.setBounds(Rect(0, 0, document.canvasWidth, document.canvasHeight));
        canvas.add(root);
        addChildren(document, document.root, root);
    }
    return canvas;
}

private bool isContainer(NodeKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case NodeKind.window:
        case NodeKind.panel:
        case NodeKind.hbox:
        case NodeKind.vbox:
        case NodeKind.scrollview:
        case NodeKind.listview:
            return true;
        case NodeKind.button:
        case NodeKind.label:
        case NodeKind.textfield:
        case NodeKind.checkbox:
        case NodeKind.separator:
        case NodeKind.image:
            return false;
    }
}

private Widget makeWidget(const ref Node node)
{
    Widget widget;
    switch (node.kind)
    {
        case NodeKind.button:
            auto button = new Button(node.text);
            button.setAccent(node.accent);
            widget = button;
            break;
        case NodeKind.label:
            widget = new Label(node.text);
            break;
        case NodeKind.textfield:
            auto field = new TextField();
            if (node.text.length != 0) field.setText(node.text);
            widget = field;
            break;
        case NodeKind.checkbox:
            widget = new CheckBox(node.text, node.checked);
            break;
        default:
            auto panel = new Panel();
            if (node.kind == NodeKind.window)
                panel.setBackground(Color.rgba(30, 34, 44, 255));
            else if (node.kind == NodeKind.panel)
                panel.setBackground(Color.rgba(42, 46, 58, 255));
            widget = panel;
            break;
    }
    if (node.id.length != 0) widget.setId(node.id);
    return widget;
}

private void addChildren(const ref DesignDocument document, int parentIndex,
    Widget parent)
{
    if (!isContainer(document.nodes[parentIndex].kind)) return;
    auto panel = cast(Panel) parent;
    if (panel is null) return;
    foreach (childIndex; document.nodes[parentIndex].children)
    {
        if (childIndex < 0 || childIndex >= cast(int) document.nodes.length)
            continue;
        const node = document.nodes[childIndex];
        auto child = makeWidget(node);
        child.setBounds(Rect(node.x, node.y, node.width, node.height));
        panel.add(child);
        addChildren(document, childIndex, child);
    }
}
