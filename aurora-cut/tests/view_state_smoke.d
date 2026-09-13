module tests.view_state_smoke;

import aurora;
import auroracut.editor : EditorRoot;
import auroracut.model : MediaAsset, TrackAddress, TrackKind;
import auroracut.timeline : TimelineWidget;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, remove;
import std.math : abs;
import std.stdio : writeln;

private Widget findById(Widget root, string requestedId)
{
    if (root is null) return null;
    if (root.id() == requestedId) return root;
    foreach (child; root.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

private T requireWidget(T)(Widget root, string requestedId)
{
    auto widget = cast(T) findById(root, requestedId);
    assert(widget !is null, "Missing or wrong widget type for id: " ~ requestedId);
    return widget;
}

int main(string[] arguments)
{
    assert(arguments.length == 2,
        "Usage: view-state-smoke <base-av.mp4>");

    const projectPath = "build/headless-smoke/view-state.auroracut";
    if (exists(projectPath)) remove(projectPath);

    WindowOptions options;
    options.title = "Aurora Cut view state smoke test";
    options.width = 1440;
    options.height = 960;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial editor paint failed");

    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    const v1 = TrackAddress(TrackKind.video, 0);

    driver.dropFiles(timeline.pointForTrackTime(v1, 0.05), [arguments[1]]);
    bool placed;
    foreach (_; 0 .. 600)
    {
        editor.tickTree(0.02);
        if (editor.modelForTesting().trackValue(v1).clips.length == 1 &&
            !editor.importBusyForTesting())
        {
            placed = true;
            break;
        }
        Thread.sleep(20.msecs);
    }
    assert(placed, "Dropping the fixture on V1 did not create a clip");

    // Give the Project Media bin enough rows to scroll so the saved media
    // offset is meaningful. Synthetic records need only the fields the list
    // renders; the project round-trip persists them like any other asset.
    auto model = editor.modelForTesting();
    foreach (i; 0 .. 24)
    {
        auto asset = new MediaAsset("C:\\media\\synthetic-" ~ cast(char)('a' + i) ~
            ".mp4");
        asset.hasVideo = true;
        asset.duration = 5.0;
        asset.width = 1920;
        asset.height = 1080;
        asset.frameRate = 30.0;
        model.assets ~= asset;
    }
    editor.syncMediaListForTesting();
    assert(driver.paint(), "Paint after adding synthetic media failed");

    auto mediaList = requireWidget!ListView(editor, "project-media-list");

    // Drive the view away from the default: maximum zoom so the sequence is
    // wider than the viewport, a horizontal scroll, and a media-list scroll.
    timeline.setZoom(900.0);
    assert(driver.paint(), "Paint after zoom failed");
    timeline.setHorizontalScroll(2.0);
    assert(driver.paint(), "Paint after horizontal scroll failed");
    mediaList.verticalScrollbar().setValue(120);
    assert(driver.paint(), "Paint after media scroll failed");

    const savedZoom = timeline.pixelsPerSecond();
    const savedScroll = timeline.horizontalScroll();
    const savedMedia = mediaList.scrollOffset();
    assert(savedZoom > 110.0, "Test setup did not zoom in");
    assert(savedScroll > 0.0, "Test setup did not scroll the timeline");
    assert(savedMedia > 0, "Test setup did not scroll the media list");
    assert(!timeline.viewFits(), "Explicit zoom must clear auto-fit");

    editor.saveProjectForTesting(projectPath);

    // Move every view somewhere else; opening the project must undo this.
    timeline.zoomToFit();
    assert(driver.paint(), "Paint after fit failed");
    assert(timeline.viewFits(), "Fit did not re-enable auto-fit");
    mediaList.verticalScrollbar().setValue(0);
    assert(driver.paint(), "Paint after resetting media scroll failed");

    editor.openProjectForTesting(projectPath);
    foreach (_; 0 .. 6)
    {
        editor.tickTree(0.02);
        assert(driver.paint(), "Paint while settling the restored view failed");
    }

    assert(editor.projectPathForTesting().length > 0,
        "Opening the saved project did not set the project path");
    assert(!timeline.viewFits(),
        "Opening a project with a saved view must not keep auto-fit");
    assert(abs(timeline.pixelsPerSecond() - savedZoom) <= 0.01,
        "Timeline zoom was not restored from the project");
    assert(abs(timeline.horizontalScroll() - savedScroll) <= 0.01,
        "Timeline scroll was not restored from the project");
    assert(abs(mediaList.scrollOffset() - savedMedia) <= 1,
        "Project Media scroll was not restored from the project");

    window.saveScreenshot("build/headless-smoke/view-state.ppm");
    writeln("[view-state-smoke] ALL PASSED");
    return 0;
}
