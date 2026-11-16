module auroradesigner_headless_smoke;

import aurora;
import aurora.testing : UiTestDriver;
import auroradesigner.appui : DesignerRoot, darkDesignerTheme;
import auroradesigner.model : DesignDocument, Node, NodeKind, generateCode,
    serializeDocument, deserializeDocument;
import auroradesigner.titlebar : DesignerTitleBar;
import std.conv : to;
import std.file : mkdirRecurse;
import std.math : abs;
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
    assert(bar.bounds().height >= 28, "Designer titlebar has no layout height");
    assert(bar.bounds().y == 0, "Designer titlebar is not at the top");
    assert(bar.iconKind() == IconKind.settings, "Designer icon not set");
    assert(bar.darkMode(), "Dark mode should be on by default");
    assert(findById(root, "outline-" ~ root.document().nodes[initialRoot].id)
        !is null, "Layers tree does not show the root node");
    auto undoButton = findById(root, "designer-undo");
    auto redoButton = findById(root, "designer-redo");
    assert(undoButton !is null && redoButton !is null,
        "History buttons are missing");
    assert(!undoButton.enabled(), "Undo is enabled on an untouched document");
    assert(!redoButton.enabled(), "Redo is enabled with no redo history");

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
    assert(undoButton.enabled(), "Undo is disabled after a mutation");

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

    // --- Names and whitespace survive a save/load round-trip. ---
    DesignDocument special;
    special.root = special.addNode(NodeKind.window, 0, 0);
    special.nodes[special.root].name = "Main Window";
    special.nodes[special.root].id = "root id";
    const specialChild = special.addChild(NodeKind.button, special.root, 4, 6);
    special.nodes[specialChild].name = "Button One";
    special.nodes[specialChild].id = "button id";
    special.nodes[specialChild].text = "Say \"hi\" \\ now\nnext";
    special.nodes[specialChild].colorHex = "12abEF";
    const specialText = serializeDocument(special);
    auto specialRestored = deserializeDocument(specialText);
    assert(specialRestored.nodes[specialRestored.root].name == "Main Window",
        "Save/load lost the root name");
    assert(specialRestored.nodes[specialRestored.root].id == "root id",
        "Save/load lost the root id");
    const specialChildIndex = specialRestored.nodes[specialRestored.root].children[0];
    assert(specialRestored.nodes[specialChildIndex].name == "Button One",
        "Save/load lost the child name");
    assert(specialRestored.nodes[specialChildIndex].id == "button id",
        "Save/load lost the child id");
    assert(specialRestored.nodes[specialChildIndex].text ==
        "Say \"hi\" \\ now\nnext", "Save/load lost text escaping");
    assert(specialRestored.nodes[specialChildIndex].colorHex == "12abEF",
        "Save/load lost the color");

    // --- Malformed hierarchy entries are repaired. ---
    auto malformed = deserializeDocument(
        "canvas 900 560\nroot 0\n" ~
        "node 0 0 self 0 0 10 10 name=self\n" ~
        "children 0 0 1 1 99\n" ~
        "node 1 0 child 0 0 10 10 name=child\n");
    assert(malformed.root == 0, "Malformed root was lost");
    assert(malformed.nodes[0].children.length == 1 &&
        malformed.nodes[0].children[0] == 1,
        "Malformed child indices were not repaired");
    auto duplicateIds = deserializeDocument(
        "root 0\n" ~
        "node 0 0 same 0 0 10 10 name=a\n" ~
        "node 1 0 same 0 0 10 10 name=b\n" ~
        "children 0 1\n");
    assert(duplicateIds.nodes[0].id != duplicateIds.nodes[1].id,
        "Duplicate node ids were not made unique");
    auto cyclic = deserializeDocument(
        "root 0\n" ~
        "node 0 0 a 0 0 10 10\n" ~
        "node 1 0 b 0 0 10 10\n" ~
        "children 0 1\nchildren 1 0\n");
    assert(cyclic.root == -1, "A cyclic hierarchy was accepted");

    // --- Unique ids after deleting and re-adding a sibling. ---
    DesignDocument idDocument;
    idDocument.root = idDocument.addNode(NodeKind.window, 0, 0);
    const firstButton = idDocument.addChild(NodeKind.button, idDocument.root, 0, 0);
    const secondButton = idDocument.addChild(NodeKind.button, idDocument.root, 0, 0);
    const firstId = idDocument.nodes[firstButton].id;
    const secondId = idDocument.nodes[secondButton].id;
    assert(firstId != secondId, "New sibling ids collide");
    idDocument.removeNode(firstButton);
    const thirdButton = idDocument.addChild(NodeKind.button, idDocument.root, 0, 0);
    assert(idDocument.nodes[thirdButton].id != secondId,
        "A re-added node reused an existing id");

    // --- Hierarchy-ordered marquee hit testing. ---
    DesignDocument marqueeDocument;
    marqueeDocument.root = marqueeDocument.addNode(NodeKind.window, 0, 0);
    const firstPanel = marqueeDocument.addChild(NodeKind.panel,
        marqueeDocument.root, 10, 10);
    const topPanel = marqueeDocument.addChild(NodeKind.panel,
        marqueeDocument.root, 10, 10);
    marqueeDocument.addChild(NodeKind.button, firstPanel, 10, 10);
    assert(marqueeDocument.hitTestRect(0, 0, 300, 300) == topPanel,
        "Marquee hit testing used flat creation order");

    // --- Generated code is unique, escaped, and keeps ScrollView children. ---
    DesignDocument generated;
    generated.root = generated.addNode(NodeKind.window, 0, 0);
    generated.nodes[generated.root].name = "root";
    const firstGenerated = generated.addChild(NodeKind.button,
        generated.root, 0, 0);
    generated.nodes[firstGenerated].name = "same";
    generated.nodes[firstGenerated].id = "id\"one";
    generated.nodes[firstGenerated].text = "Say \"hi\" \\ now\nnext";
    generated.nodes[firstGenerated].colorHex = "nothex";
    const secondGenerated = generated.addChild(NodeKind.button,
        generated.root, 0, 0);
    generated.nodes[secondGenerated].name = "same";
    const keywordGenerated = generated.addChild(NodeKind.button,
        generated.root, 0, 0);
    generated.nodes[keywordGenerated].name = "class";
    const generatedCode = generateCode(generated);
    assert(generatedCode.indexOf("auto same =") >= 0,
        "Generated code lost the first variable");
    assert(generatedCode.indexOf("auto same2 =") >= 0,
        "Generated code reused a variable name");
    assert(generatedCode.indexOf("auto _class =") >= 0,
        "Generated code used a D keyword as a variable");
    assert(generatedCode.indexOf("id\\\"one") >= 0,
        "Generated code did not escape an id");
    assert(generatedCode.indexOf("Say \\\"hi\\\"") >= 0,
        "Generated code did not escape text");
    assert(generatedCode.indexOf("setBackground(") < 0,
        "Generated code emitted an invalid color");
    const scroll = generated.addChild(NodeKind.scrollview,
        generated.root, 0, 0);
    const scrollA = generated.addChild(NodeKind.button, scroll, 0, 0);
    generated.nodes[scrollA].id = "scroll-a";
    const scrollB = generated.addChild(NodeKind.label, scroll, 0, 0);
    generated.nodes[scrollB].id = "scroll-b";
    const scrollCode = generateCode(generated);
    assert(scrollCode.indexOf("scroll-a") >= 0 &&
        scrollCode.indexOf("scroll-b") >= 0,
        "Generated ScrollView content dropped children");
    assert(scrollCode.indexOf("setContent(") >= 0,
        "Generated ScrollView did not set content");

    // --- Undo restores the previous state. ---
    root.undoForTesting();
    assert(root.document().nodes.length == before,
        "Undo did not remove the added node");
    assert(!undoButton.enabled(), "Undo stayed enabled at the start of history");
    assert(redoButton.enabled(), "Redo is disabled after an undo");
    root.redoForTesting();
    assert(root.document().nodes.length == before + 1,
        "Redo did not re-add the node");
    assert(undoButton.enabled(), "Undo is disabled after a redo");
    assert(!redoButton.enabled(), "Redo stayed enabled after redo");

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
    root.undoForTesting();
    assert(root.document().nodes[root.document().root].x == dragStartX &&
        root.document().nodes[root.document().root].y == dragStartY,
        "Undo did not restore the dragged position");
    root.redoForTesting();
    assert(root.document().nodes[root.document().root].x == dragStartX + 30 &&
        root.document().nodes[root.document().root].y == dragStartY + 20,
        "Redo did not restore the dragged position");

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

    // --- Dragging a palette entry places a widget at the drop point. ---
    auto dragPalette = findById(root, "palette-button0");
    assert(dragPalette !is null, "Palette Button entry missing");
    const beforeDrag = root.document().nodes.length;
    const from = dragPalette.localToGlobal(Point(
        dragPalette.bounds().width / 2, dragPalette.bounds().height / 2));
    const artOrigin = canvas.artboardOrigin();
    const targetArt = Point(250, 160);
    const target = canvas.localToGlobal(Point(
        artOrigin.x + targetArt.x, artOrigin.y + targetArt.y));
    driver.moveTo(from);
    driver.mouseDown(MouseButton.left);
    driver.moveTo(Point(from.x + 6, from.y + 6));
    driver.moveTo(target);
    driver.mouseUp(MouseButton.left);
    assert(driver.paint(), "Paint after palette drag failed");
    assert(root.document().nodes.length == beforeDrag + 1,
        "Palette drag did not add a widget");
    const dropped = root.document().nodes[root.selectedIndex()];
    const droppedParent = root.document().parentOf(root.selectedIndex());
    assert(droppedParent == root.document().root,
        "Palette drag did not parent the node inside the target container");
    assert(dropped.kind == NodeKind.button,
        "Palette drag added the wrong node kind");
    const droppedParentOrigin = root.document().absoluteRect(droppedParent);
    assert(abs(dropped.x - (targetArt.x - droppedParentOrigin.x -
        dropped.width / 2)) <= 2,
        "Palette drop X is not centered on the pointer");
    assert(abs(dropped.y - (targetArt.y - droppedParentOrigin.y -
        dropped.height / 2)) <= 2,
        "Palette drop Y is not centered on the pointer");

    // --- Adding from the palette targets the selected container. ---
    const panel = root.addNodeForTesting(NodeKind.panel);
    assert(root.document().parentOf(panel) == root.document().root,
        "New panel is not under the root");
    assert(root.selectedIndex() == panel, "New panel is not selected");
    const beforeChild = root.document().nodes.length;
    driver.click(labelCenter);
    assert(driver.paint(), "Paint after child palette click failed");
    assert(root.document().nodes.length == beforeChild + 1,
        "Palette click did not add a child");
    const child = root.selectedIndex();
    assert(root.document().parentOf(child) == panel,
        "Palette click did not add into the selected panel");
    assert(root.document().depth(child) == root.document().depth(panel) + 1,
        "Child depth is not one below its panel");
    assert(findById(root, "outline-" ~ root.document().nodes[child].id) !is null,
        "Layers tree does not show the added child");

    // --- A palette drop on the window background honors the selected panel. ---
    root.selectNodeForTesting(panel);
    const beforePanelDrop = root.document().nodes.length;
    const panelDropFrom = dragPalette.localToGlobal(Point(
        dragPalette.bounds().width / 2, dragPalette.bounds().height / 2));
    const panelDropRoot = root.document().absoluteRect(root.document().root);
    const panelDropOrigin = canvas.artboardOrigin();
    const panelDropTarget = canvas.localToGlobal(Point(
        panelDropOrigin.x + panelDropRoot.x + 4,
        panelDropOrigin.y + panelDropRoot.y + 4));
    driver.moveTo(panelDropFrom);
    driver.mouseDown(MouseButton.left);
    driver.moveTo(Point(panelDropFrom.x + 6, panelDropFrom.y + 6));
    driver.moveTo(panelDropTarget);
    driver.mouseUp(MouseButton.left);
    assert(driver.paint(), "Paint after selected-panel drop failed");
    assert(root.document().nodes.length == beforePanelDrop + 1,
        "Selected-panel palette drop added no node");
    assert(root.document().parentOf(root.selectedIndex()) == panel,
        "Palette drop ignored the selected panel and used the window");

    // --- A selected panel can be moved by its grip, even over its children. ---
    root.selectNodeForTesting(panel);
    assert(driver.paint(), "Paint before panel grip drag failed");
    const panelBeforeX = root.document().nodes[panel].x;
    const childBeforeX = root.document().absoluteRect(child).x;
    const panelGrip = canvas.moveGripRect();
    assert(panelGrip.width > 0, "Selected panel has no move grip");
    const gripGlobal = canvas.localToGlobal(Point(
        panelGrip.x + panelGrip.width / 2,
        panelGrip.y + panelGrip.height / 2));
    driver.moveTo(gripGlobal);
    driver.mouseDown(MouseButton.left);
    driver.moveTo(Point(gripGlobal.x + 40, gripGlobal.y + 20));
    driver.mouseUp(MouseButton.left);
    assert(driver.paint(), "Paint after panel grip drag failed");
    assert(root.document().nodes[panel].x == panelBeforeX + 40,
        "The selected panel did not move from its grip");
    assert(root.document().absoluteRect(child).x == childBeforeX + 40,
        "The panel's child did not move with the panel");

    const oldChildId = root.document().nodes[child].id;
    assert(root.setNodeId(child, "fresh-child-id"),
        "A unique node id was rejected");
    assert(findById(root, "outline-fresh-child-id") !is null,
        "Layers tree did not refresh after an id edit");
    assert(findById(root, "outline-" ~ oldChildId) is null,
        "Layers tree kept the old id row");
    assert(!root.setNodeId(child, root.document().nodes[initialRoot].id),
        "A duplicate node id was accepted");
    assert(root.document().nodes[child].id == "fresh-child-id",
        "Rejected id edit changed the node");

    // --- A second click on the selected child still starts a drag. ---
    const childRect = root.document().absoluteRect(child);
    const childOrigin = canvas.artboardOrigin();
    const childCenter = canvas.localToGlobal(Point(
        childOrigin.x + childRect.x + childRect.width / 2,
        childOrigin.y + childRect.y + childRect.height / 2));
    driver.click(childCenter);
    driver.click(childCenter);
    assert(root.selectedIndex() == child,
        "Second click changed selection to the parent");
    const childX = root.document().nodes[child].x;
    driver.moveTo(childCenter);
    driver.mouseDown(MouseButton.left);
    driver.moveTo(Point(childCenter.x + 24, childCenter.y + 12));
    driver.mouseUp(MouseButton.left);
    assert(driver.paint(), "Paint after second-click drag failed");
    assert(root.selectedIndex() == child,
        "Dragging after a second click lost the child selection");
    assert(root.document().nodes[child].x == childX + 24,
        "Dragging after a second click did not move the child");

    root.toggleCollapsed(root.document().root);
    assert(findById(root, "outline-" ~ root.document().nodes[child].id) is null,
        "Collapsing the root did not hide its children");
    root.toggleCollapsed(root.document().root);
    assert(findById(root, "outline-" ~ root.document().nodes[child].id) !is null,
        "Expanding the root did not restore its children");

    // --- Dragging a selected node's corner handle resizes it. ---
    root.selectNodeForTesting(initialRoot);
    assert(driver.paint(), "Paint before resize failed");
    const resizeFrom = root.document().nodes[initialRoot];
    const resizeOrigin = canvas.artboardOrigin();
    const bottomRight = canvas.localToGlobal(Point(
        resizeOrigin.x + resizeFrom.x + resizeFrom.width,
        resizeOrigin.y + resizeFrom.y + resizeFrom.height));
    driver.moveTo(bottomRight);
    driver.mouseDown(MouseButton.left);
    driver.moveTo(Point(bottomRight.x + 40, bottomRight.y + 30));
    driver.mouseUp(MouseButton.left);
    assert(driver.paint(), "Paint after resize failed");
    const resized = root.document().nodes[initialRoot];
    assert(resized.width == resizeFrom.width + 40 &&
        resized.height == resizeFrom.height + 30,
        "Corner-handle drag did not resize the node");

    // --- Hierarchy-aware paint and hit order, then sibling z-order. ---
    ref DesignDocument hierarchy = root.designDocument();
    const panelA = hierarchy.addChild(NodeKind.panel, hierarchy.root, 10, 10);
    hierarchy.nodes[panelA].width = 140;
    hierarchy.nodes[panelA].height = 80;
    const panelB = hierarchy.addChild(NodeKind.panel, hierarchy.root, 180, 10);
    hierarchy.nodes[panelB].width = 140;
    hierarchy.nodes[panelB].height = 80;
    const zBack = hierarchy.addChild(NodeKind.button, panelA, 5, 45);
    const zFront = hierarchy.addChild(NodeKind.button, panelA, 5, 45);
    const zPoint = hierarchy.absoluteRect(zFront);
    assert(hierarchy.hitTest(zPoint.x + 2, zPoint.y + 2) == zFront,
        "Topmost sibling did not win hit testing");
    auto zPath = hierarchy.hitPath(zPoint.x + 2, zPoint.y + 2);
    assert(zPath.length >= 3 && zPath[$ - 1] == zFront,
        "Hit path did not include the nested child");
    auto paintOrder = hierarchy.paintOrder();
    int panelPos = -1, frontPos = -1;
    foreach (i, index; paintOrder)
    {
        if (index == panelA) panelPos = cast(int) i;
        if (index == zFront) frontPos = cast(int) i;
    }
    assert(panelPos >= 0 && frontPos > panelPos,
        "Paint order did not place the child after its parent");
    assert(hierarchy.sendToBack(zFront), "sendToBack failed");
    assert(hierarchy.hitTest(zPoint.x + 2, zPoint.y + 2) == zBack,
        "sendToBack did not expose the lower sibling");
    assert(hierarchy.bringToFront(zFront), "bringToFront failed");
    assert(hierarchy.hitTest(zPoint.x + 2, zPoint.y + 2) == zFront,
        "bringToFront did not restore the top sibling");

    // --- Dragging a child onto another container reparents it. ---
    const leaf = hierarchy.addChild(NodeKind.button, panelA, 20, 5);
    const leafAbs = hierarchy.absoluteRect(leaf);
    root.selectNodeForTesting(leaf);
    assert(driver.paint(), "Paint before reparent drag failed");
    const reparentOrigin = canvas.artboardOrigin();
    const leafCenter = canvas.localToGlobal(Point(
        reparentOrigin.x + leafAbs.x + leafAbs.width / 2,
        reparentOrigin.y + leafAbs.y + leafAbs.height / 2));
    const targetRect = hierarchy.absoluteRect(panelB);
    const targetCenter = canvas.localToGlobal(Point(
        reparentOrigin.x + targetRect.x + targetRect.width / 2,
        reparentOrigin.y + targetRect.y + targetRect.height / 2));
    driver.moveTo(leafCenter);
    driver.mouseDown(MouseButton.left);
    driver.moveTo(targetCenter);
    driver.mouseUp(MouseButton.left);
    assert(driver.paint(), "Paint after reparent drag failed");
    assert(hierarchy.parentOf(leaf) == panelB,
        "Canvas drag did not reparent into the target container");
    const movedAbs = hierarchy.absoluteRect(leaf);
    const deltaX = targetCenter.x - leafCenter.x;
    const deltaY = targetCenter.y - leafCenter.y;
    assert(abs(movedAbs.x - (leafAbs.x + deltaX)) <= 2 &&
        abs(movedAbs.y - (leafAbs.y + deltaY)) <= 2,
        "Reparent did not preserve the dragged artboard position");
    const newParentAbs = hierarchy.absoluteRect(panelB);
    assert(hierarchy.nodes[leaf].x == movedAbs.x - newParentAbs.x &&
        hierarchy.nodes[leaf].y == movedAbs.y - newParentAbs.y,
        "Reparented coordinates are not parent-relative");

    // --- Palette drag still works from a new, empty artboard. ---
    root.designDocument() = DesignDocument.init;
    root.designDocument().canvasWidth = 900;
    root.designDocument().canvasHeight = 560;
    root.selectNodeForTesting(-1);
    assert(driver.paint(), "Paint of empty artboard failed");
    const emptyTarget = canvas.localToGlobal(Point(
        canvas.artboardOrigin().x + 400, canvas.artboardOrigin().y + 220));
    driver.moveTo(from);
    driver.mouseDown(MouseButton.left);
    driver.moveTo(Point(from.x + 6, from.y + 6));
    driver.moveTo(emptyTarget);
    driver.mouseUp(MouseButton.left);
    assert(driver.paint(), "Paint after empty-artboard drop failed");
    assert(root.document().root >= 0,
        "Palette drop did not create a root window");
    assert(root.document().nodes.length == 2,
        "Palette drop did not add the widget under the new root");
    assert(root.document().parentOf(root.selectedIndex()) == root.document().root,
        "Empty-artboard drop is not a child of the new root");

    writeln("Aurora Designer headless smoke passed.");
    return 0;
}
