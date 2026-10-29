module export_reveal_ui_smoke;

// Headless smoke for Export living under Checkpoint as a hover-revealed
// sub-button. Export must not take toolbar width, must appear flush under
// Checkpoint the moment the pointer reaches it, must dismiss immediately when
// the pointer leaves, and must return to the toolbar when the Checkpoints switch
// is turned off so the action can never be stranded.

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme, setOpencodeStateDirectoryForTesting;
import std.conv : to;
import std.file : mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.utf : toUTF8;

private Widget findById(Widget widget, string requestedId)
{
    if (widget is null) return null;
    if (widget.id() == requestedId) return widget;
    foreach (child; widget.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

private T requireWidget(T)(Widget root, string requestedId)
{
    auto widget = findById(root, requestedId);
    assert(widget !is null, "Missing widget for id: " ~ requestedId);
    auto typed = cast(T) widget;
    assert(typed !is null, "Wrong widget type for id: " ~ requestedId);
    return typed;
}

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private void step(OpenCodeRoot root, UiTestDriver driver, string context)
{
    root.tickTree(0.016);
    assert(driver.paint(), context ~ " paint failed");
}

int main()
{
    const state = buildPath(tempDir(), "aurora-export-reveal-ui-smoke");
    mkdirRecurse(state);
    // Own checkout identity: without a `.git` marker the lease identity walks up
    // to the drive root and collides with other Aurora processes on the drive.
    mkdirRecurse(buildPath(state, ".git"));
    setOpencodeStateDirectoryForTesting(state);
    write(buildPath(state, "settings.json"),
        `{"baseUrl":"http://127.0.0.1:1/v1","apiKey":"fixture","model":"fixture","toolsEnabled":false}`);

    WindowOptions options;
    options.width = 1000;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    root.isolateClipboardForTesting(true);
    foreach (_; 0 .. 100)
    {
        root.tickTree(0.02);
        if (!root.startupPendingForTesting()) break;
    }
    root.newChatForTesting();
    auto driver = new UiTestDriver(window);
    assert(driver.paint(), "initial paint failed");
    assert(driver.paint(), "second paint failed");

    auto checkpoint = requireWidget!Widget(root, "oc-checkpoint");
    const checkpointOrigin = checkpoint.localToGlobal(Point(0, 0));
    const checkpointBottom = checkpointOrigin.y + checkpoint.bounds().height;
    assert(checkpoint.visible() && checkpoint.bounds().width > 0,
        "Checkpoint owns the sub-button but has no laid-out bounds");
    assert(findById(root, "oc-export") is null,
        "Export still occupies toolbar space instead of riding under Checkpoint");
    assert(findById(root, "oc-export-reveal") is null,
        "the Export sub-button is visible before Checkpoint is hovered");
    writeln("PASS Export no longer occupies the toolbar row");

    // Hovering Checkpoint reveals Export immediately.
    driver.moveTo(globalCenter(checkpoint));
    step(root, driver, "reveal paint");
    auto reveal = requireWidget!Widget(root, "oc-export-reveal");
    auto exportButton = requireWidget!Widget(root, "oc-export");
    const revealOrigin = reveal.localToGlobal(Point(0, 0));
    assert(exportButton.visible() && exportButton.bounds().width > 0,
        "the revealed Export button has no laid-out bounds");
    assert(reveal.bounds().width < checkpoint.bounds().width * 3 &&
        reveal.bounds().height < checkpoint.bounds().height * 2,
        "the reveal should be a small sub-button card, not a panel: " ~
        to!string(reveal.bounds()));
    assert(revealOrigin.y <= checkpointBottom && revealOrigin.y >= checkpointBottom - 2,
        "the reveal should sit flush under Checkpoint: revealY=" ~
        to!string(revealOrigin.y) ~ " checkpointBottom=" ~
        to!string(checkpointBottom));
    const revealRight = revealOrigin.x + reveal.bounds().width;
    assert(revealRight <= checkpointOrigin.x + checkpoint.bounds().width &&
        revealRight >= checkpointOrigin.x + checkpoint.bounds().width - 2,
        "the reveal should be right-aligned to Checkpoint");
    assert(root.hitTest(globalCenter(exportButton)).id() == "oc-export",
        "the revealed Export button is not the widget under its own centre");
    writeln("PASS hovering Checkpoint reveals Export flush beneath it");

    // Walking down from Checkpoint into the reveal keeps it open.
    driver.moveTo(Point(revealOrigin.x + 2, revealOrigin.y + 2));
    step(root, driver, "reveal-hover paint");
    assert(findById(root, "oc-export-reveal") !is null,
        "stepping from Checkpoint into the reveal hid it");
    writeln("PASS stepping from Checkpoint into the reveal keeps it open");

    // Leaving hides it on the first frame.
    driver.moveTo(Point(4, 690));
    step(root, driver, "dismissed-reveal paint");
    assert(findById(root, "oc-export-reveal") is null,
        "the Export reveal lingered after the pointer left Checkpoint");
    assert(findById(root, "oc-export") is null,
        "Export stayed in the tree after the reveal closed");
    writeln("PASS the reveal hides on the first frame after the pointer leaves");

    // Turning Checkpoints off must bring Export back to the toolbar row.
    root.setCheckpointFeatureForTesting(false);
    step(root, driver, "checkpoints-off paint");
    assert(findById(root, "oc-export-reveal") is null,
        "the reveal stayed after Checkpoints were switched off");
    auto inlineExport = requireWidget!Widget(root, "oc-export");
    assert(inlineExport.visible() && inlineExport.parent() !is null &&
        inlineExport.parent().id() == "oc-export-slot",
        "Export did not return to the toolbar when Checkpoints were switched off");
    assert(toUTF8(requireWidget!Button(root, "oc-export").text()) == "Export",
        "the toolbar Export button lost its label");
    writeln("PASS switching Checkpoints off restores Export to the toolbar");

    root.setCheckpointFeatureForTesting(true);
    step(root, driver, "checkpoints-on paint");
    assert(findById(root, "oc-export") is null &&
        findById(root, "oc-export-reveal") is null,
        "Export did not return under Checkpoint when the feature came back");
    driver.moveTo(globalCenter(checkpoint));
    step(root, driver, "re-reveal paint");
    assert(findById(root, "oc-export") !is null,
        "the reveal did not return after the feature came back");
    writeln("PASS Export returns under Checkpoint when the feature is re-enabled");

    root.shutdownClient();
    window.close();
    writeln("export reveal UI smoke passed");
    return 0;
}
