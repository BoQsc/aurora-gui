module tests.timeline_zoombar_pan_map;

import aurora;
import aurora.layout : Panel;
import aurora.testing : UiTestDriver;
import aurora.types : Point, Rect;
import auroracut.model : EditorModel, TrackAddress, TrackKind;
import auroracut.timeline : TimelineWidget, TimelineHorizontalScrollbar;
import std.conv : to;
import std.math : fabs;
import std.stdio : writeln;
int main()
{
    WindowOptions options;
    options.title = "Aurora Cut zoom-bar pan map";
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
    timeline.setZoom(60.0);
    auto scrollbar = new TimelineHorizontalScrollbar(timeline);
    scrollbar.setBounds(Rect(0, 0, 800, 11));
    root.add(scrollbar);
    auto driver = new UiTestDriver(window);

    const max = timeline.horizontalScrollMaximum();
    const maxVisible = timeline.horizontalVisibleDuration();

    // Drag the thumb from its far-left position to the far-right edge.
    timeline.setHorizontalScroll(0.0);
    auto thumb = scrollbar.thumbRectForTesting();
    const track = scrollbar.trackRectForTesting();
    const leftG = scrollbar.leftGripRectForTesting();
    const rightG = scrollbar.rightGripRectForTesting();
    const inner = Rect(leftG.right(), track.y,
        rightG.x - leftG.right(), track.height);
    driver.drag(Point(thumb.x + thumb.width / 2, thumb.y + 4),
        Point(inner.right() - thumb.width / 2, thumb.y + 4));
    const scrolled = timeline.horizontalScroll();
    assert(scrolled > max * 0.95,
        "Dragging thumb to the far right did not reach max scroll (got " ~
        scrolled.to!string ~ " vs max " ~ max.to!string ~ ")");

    // Dragging thumb back to the far-left start reaches scroll 0.
    thumb = scrollbar.thumbRectForTesting();
    driver.drag(Point(thumb.x + thumb.width / 2, thumb.y + 4),
        Point(inner.x + thumb.width / 2, thumb.y + 4));
    assert(fabs(timeline.horizontalScroll()) < 0.001,
        "Dragging thumb to the far left did not reach scroll 0");

    writeln("Aurora Cut zoom-bar pan-mapping smoke test passed.");
    return 0;
}
