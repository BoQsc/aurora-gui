module tests.layout_smoke;

import aurora;
import aurora.testing : UiTestDriver;
import auroracut.editor : EditorRoot;
import auroracut.timeline : TimelineHorizontalScrollbar, TimelineWidget;

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

private void assertSequenceTimelineSeparatedFromStatus(SplitPane sequenceSplit,
    TimelineWidget timeline, TimelineHorizontalScrollbar timelineScrollbar,
    Widget statusBar)
{
    auto sequenceArea = sequenceSplit.second();
    const sequenceOrigin = sequenceArea.localToGlobal(Point(0, 0));
    const timelineOrigin = timeline.localToGlobal(Point(0, 0));
    const scrollbarOrigin = timelineScrollbar.localToGlobal(Point(0, 0));
    const statusOrigin = statusBar.localToGlobal(Point(0, 0));
    assert(sequenceOrigin.y + sequenceArea.bounds().height <= statusOrigin.y,
        "Sequence panel overlaps the status bar");
    assert(timelineOrigin.y + timeline.bounds().height <= statusOrigin.y,
        "Sequence timeline overlaps the status bar");
    assert(scrollbarOrigin.y + timelineScrollbar.bounds().height <= statusOrigin.y,
        "Sequence scrollbar overlaps the status bar");
}

private void assertStatusProgressDocked(Widget statusBar, ProgressBar progress)
{
    const statusOrigin = statusBar.localToGlobal(Point(0, 0));
    const progressOrigin = progress.localToGlobal(Point(0, 0));
    const statusRight = statusOrigin.x + statusBar.bounds().width;
    const progressRight = progressOrigin.x + progress.bounds().width;
    // The status bar anchors the loading bar to its right edge inside the
    // 8px inset rather than centering it; the status text owns the left side.
    assert(progressRight <= statusRight && progressRight >= statusRight - 12,
        "Status loading bar is not docked to the right edge of the status area");
    assert(progressOrigin.x >= statusOrigin.x,
        "Status loading bar starts before the status area");
    assert(progressOrigin.y >= statusOrigin.y &&
        progressOrigin.y + progress.bounds().height <=
            statusOrigin.y + statusBar.bounds().height,
        "Status loading bar does not fit inside the status area");
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Cut layout smoke";
    options.width = 1440;
    options.height = 960;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto timelineScrollbar = requireWidget!TimelineHorizontalScrollbar(editor,
        "sequence-horizontal-scrollbar");
    auto sequenceSplit = requireWidget!SplitPane(editor, "workspace-sequence-split");
    auto statusBar = requireWidget!Widget(editor, "status-bar");
    auto statusProgress = requireWidget!ProgressBar(editor, "status-progress");

    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Default editor paint failed");
    assertSequenceTimelineSeparatedFromStatus(sequenceSplit, timeline,
        timelineScrollbar, statusBar);
    assertStatusProgressDocked(statusBar, statusProgress);

    driver.resize(Size(options.width, 520));
    assert(driver.paint(), "Compact editor paint failed");
    assertSequenceTimelineSeparatedFromStatus(sequenceSplit, timeline,
        timelineScrollbar, statusBar);
    assertStatusProgressDocked(statusBar, statusProgress);

    return 0;
}
