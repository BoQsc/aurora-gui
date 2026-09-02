module tests.timeline_zoombar_smoke;

import aurora;
import aurora.layout : Panel;
import aurora.testing : UiTestDriver;
import aurora.types : Point, Rect;
import auroracut.model : EditorModel, TrackAddress, TrackKind;
import auroracut.timeline : TimelineWidget, TimelineHorizontalScrollbar;
import std.math : fabs;
import std.stdio : writeln;

int main()
{
    WindowOptions options;
    options.title = "Aurora Cut zoom-bar smoke";
    options.width = 900;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new Panel();
    window.setRoot(root);
    root.setBounds(Rect(0, 0, 900, 700));

    auto model = new EditorModel();
    model.insertTextClip(TrackAddress(TrackKind.video, 0), 0.0, 60.0, "Zoom probe");
    auto timeline = new TimelineWidget(model);
    timeline.setBounds(Rect(0, 0, 800, 180));
    timeline.setZoom(100.0);
    timeline.setHorizontalScroll(0.0);

    auto scrollbar = new TimelineHorizontalScrollbar(timeline);
    scrollbar.setBounds(Rect(0, 0, 800, 11));
    root.add(scrollbar);

    auto driver = new UiTestDriver(window);

    const zoomBefore = timeline.pixelsPerSecond();
    const track = scrollbar.trackRectForTesting();
    const leftGrip = scrollbar.leftGripRectForTesting();
    const rightGrip = scrollbar.rightGripRectForTesting();

    // RIGHT grip: drag inward (left) -> window narrows -> zoom IN.
    const rightIn = rightGrip.x + rightGrip.width / 2;
    driver.drag(Point(rightIn, rightGrip.y + 4),
        Point(rightIn - 100, rightGrip.y + 4));
    const zoomIn = timeline.pixelsPerSecond();
    assert(zoomIn > zoomBefore,
        "Dragging the right grip inward did not zoom in");

    // RIGHT grip: drag outward (right) -> window widens -> zoom OUT.
    driver.drag(Point(rightIn, rightGrip.y + 4),
        Point(rightIn + 150, rightGrip.y + 4));
    const zoomOut = timeline.pixelsPerSecond();
    assert(zoomOut < zoomIn,
        "Dragging the right grip outward did not zoom out");

    // RIGHT edge anchoring: dragging the RIGHT grip inward must keep the window
    // START (left edge) anchoring the content it was at.
    const startBefore = timeline.horizontalScroll();
    driver.drag(Point(rightIn, rightGrip.y + 4),
        Point(rightIn - 60, rightGrip.y + 4));
    const startAfter = timeline.horizontalScroll();
    assert(fabs(startAfter - startBefore) < 0.6,
        "Dragging the right grip moved the left (anchored) edge");

    // LEFT grip: drag inward (right) -> window narrows -> zoom IN.
    const leftIn = leftGrip.x + leftGrip.width / 2;
    const zoomBeforeLeft = timeline.pixelsPerSecond();
    driver.drag(Point(leftIn, leftGrip.y + 4),
        Point(leftIn + 100, leftGrip.y + 4));
    assert(timeline.pixelsPerSecond() > zoomBeforeLeft,
        "Dragging the left grip inward did not zoom in");

    // LEFT edge anchoring: dragging the LEFT grip must keep the window END fixed.
    const endBefore = timeline.horizontalScroll() +
        timeline.horizontalVisibleDuration();
    driver.drag(Point(leftIn, leftGrip.y + 4),
        Point(leftIn + 60, leftGrip.y + 4));
    const endAfter = timeline.horizontalScroll() +
        timeline.horizontalVisibleDuration();
    assert(fabs(endAfter - endBefore) < 0.6,
        "Dragging the left grip moved the right (anchored) edge");

    writeln("Aurora Cut timeline zoom-bar smoke test passed.");
    return 0;
}
