module auroradesigner_headless_smoke;

import aurora;
import aurora.testing : UiTestDriver;
import auroradesigner.appui : DesignerRoot, darkDesignerTheme;
import auroradesigner.model : DesignDocument, Node, NodeKind, generateCode,
    serializeDocument, deserializeDocument;
import auroradesigner.titlebar : DesignerTitleBar;
import std.conv : to;
import std.file : mkdirRecurse;
import std.stdio : writeln;
import std.string : indexOf;

Widget findById(Widget widget, string id)
{
    if (widget !is null && widget.id() == id) return widget;
    foreach (child; widget.children())
    {
        auto found = findById(child, id);
        if (found !is null) return found;
    }
    return null;
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Designer";
    options.width = 1280;
    options.height = 800;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, darkDesignerTheme());
    auto root = new DesignerRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial Designer paint failed");

    // --- The designer starts with a window node on the artboard. ---
    assert(root.document().root >= 0, "No initial window node");
    const initialRoot = root.document().root;
    assert(root.document().nodes.length >= 1, "No nodes after init");
    assert(root.document().nodes[initialRoot].kind == NodeKind.window,
        "Initial node is not a window");

    // --- The title bar is present with the expected chrome. ---
    auto bar = root.titleBar();
    assert(bar !is null, "Designer titlebar missing");
    assert(bar.barHeight() > 0, "Designer titlebar height invalid");
    assert(bar.iconKind() == IconKind.settings, "Designer icon not set");
    assert(bar.darkMode(), "Dark mode should be on by default");

    // --- Toolbar buttons exist. ---

    // --- Select the root and verify the inspector is populated. ---
    root.selectNodeForTesting(initialRoot);
    assert(root.selectedIndex() == initialRoot, "Selection did not stick");
    assert(root.document().nodes[initialRoot].id.length > 0,
        "Root node has no id");

    // --- Drag a palette item to add a widget (simulate the click). ---
    const before = root.document().nodes.length;
    const added = root.addNodeForTesting(NodeKind.button);
    assert(added >= 0, "addNodeForTesting failed");
    assert(root.document().nodes.length == before + 1,
        "Node count did not increase");
    assert(root.selectedIndex() == added, "New node not selected");

    // --- The generated code compiles to a widget tree. ---
    const code = root.codeForTesting();
    assert(code.indexOf("import aurora") >= 0, "Codegen missing import");
    assert(code.indexOf("new Button") >= 0, "Codegen missing Button");
    assert(code.indexOf("setId(") >= 0, "Codegen missing setId");

    // --- Serialization round-trips. ---
    auto docSnapshot = root.document(); const serialized = serializeDocument(docSnapshot);
    auto restored = deserializeDocument(serialized);
    assert(restored.nodes.length == root.document().nodes.length,
        "Round-trip node count mismatch");
    assert(restored.canvasWidth == root.document().canvasWidth,
        "Round-trip width mismatch");
    assert(restored.root == root.document().root, "Round-trip root mismatch");
    for (int i = 0; i < restored.nodes.length; ++i)
    {
        assert(restored.nodes[i].id == root.document().nodes[i].id,
            "Round-trip id mismatch at " ~ to!string(i));
        assert(restored.nodes[i].kind == root.document().nodes[i].kind,
            "Round-trip kind mismatch at " ~ to!string(i));
        assert(restored.nodes[i].x == root.document().nodes[i].x,
            "Round-trip x mismatch at " ~ to!string(i));
        assert(restored.nodes[i].y == root.document().nodes[i].y,
            "Round-trip y mismatch at " ~ to!string(i));
        assert(restored.nodes[i].width == root.document().nodes[i].width,
            "Round-trip width mismatch at " ~ to!string(i));
        assert(restored.nodes[i].height == root.document().nodes[i].height,
            "Round-trip height mismatch at " ~ to!string(i));
    }

    // --- Undo restores the previous state. ---
    root.undoForTesting();
    assert(root.document().nodes.length == before,
        "Undo did not remove the added node");
    root.redoForTesting();
    assert(root.document().nodes.length == before + 1,
        "Redo did not re-add the node");

    // --- Select the re-added node, then delete it. ---
    root.selectNodeForTesting(added);
    assert(root.selectedIndex() == added, "Re-selection did not stick");
    root.deleteSelectedForTesting();
    assert(root.document().nodes.length == before,
        "Delete did not remove the node");

    // --- Paint and capture a screenshot for visual verification. ---
    assert(driver.paint(), "Final Designer paint failed");
    mkdirRecurse("build/headless-smoke");
    window.saveScreenshot("build/headless-smoke/designer-smoke.ppm");

    // --- Basic hit-testing sanity on the model. ---
    assert(root.document().hitTest(10, 10) >= 0,
        "Hit-test failed at artboard origin");

    // --- Pointer-driven selection through the real dispatch path. ---
    // The artboard origin is computed from the canvas bounds; click on the
    // center of the window node (which is centered on the artboard).
    auto canvas = root.canvas();
    assert(canvas !is null, "Canvas missing");
    assert(driver.paint(), "Paint before pointer selection failed");
    const origin = canvas.artboardOrigin();
    const rootNode = root.document().nodes[root.document().root];
    const artCenter = Point(origin.x + rootNode.x + rootNode.width / 2,
        origin.y + rootNode.y + rootNode.height / 2);
    const canvasGlobal = canvas.localToGlobal(artCenter);
    driver.click(canvasGlobal);
    assert(driver.paint(), "Paint after pointer click failed");
    assert(root.selectedIndex() == root.document().root,
        "Clicking the window node did not select it");

    // --- Drag the window node and confirm its position changed. ---
    const dragStartX = root.document().nodes[root.document().root].x;
    const dragStartY = root.document().nodes[root.document().root].y;
    driver.moveTo(Point(canvasGlobal.x, canvasGlobal.y));
    driver.mouseDown(MouseButton.left);
    driver.moveTo(Point(canvasGlobal.x + 30, canvasGlobal.y + 20));
    driver.mouseUp(MouseButton.left);
    assert(driver.paint(), "Paint after drag failed");
    assert(root.document().nodes[root.document().root].x == dragStartX + 30,
        "Drag did not move the node's X");
    assert(root.document().nodes[root.document().root].y == dragStartY + 20,
        "Drag did not move the node's Y");

    // --- Clicking a palette button adds a widget through the event path. ---
    auto paletteButton = findById(root, "palette-label0");
    assert(paletteButton !is null, "Palette Label button missing");
    const beforePalette = root.document().nodes.length;
    const labelCenter = paletteButton.localToGlobal(Point(
        paletteButton.bounds().width / 2, paletteButton.bounds().height / 2));
    driver.click(labelCenter);
    assert(driver.paint(), "Paint after palette click failed");
    assert(root.document().nodes.length == beforePalette + 1,
        "Palette click did not add a Label node");
    assert(root.document().nodes[root.selectedIndex()].kind == NodeKind.label,
        "Palette click added the wrong node kind");

    writeln("Aurora Designer headless smoke passed.");
    return 0;
}
