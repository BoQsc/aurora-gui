module tests.timeline_zoomout_smoke;

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
    options.title = "Aurora Cut zoom-out smoke";
    options.width = 900;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new Panel();
    window.setRoot(root);
    root.setBounds(Rect(0, 0, 900, 700));

    // EMPTY model (no clips): the scrollbar/zoom must still be usable.
    auto model = new EditorModel();
    auto timeline = new TimelineWidget(model);
    timeline.setBounds(Rect(0, 0, 800, 180));
    auto scrollbar = new TimelineHorizontalScrollbar(timeline);
    scrollbar.setBounds(Rect(0, 0, 800, 11));
    root.add(scrollbar);

    auto driver = new UiTestDriver(window);

    // 1) Empty timeline must expose a content range so the scrollbar can pan.
    assert(timeline.horizontalContentDuration() > 0.0,
        "Empty timeline reports no content duration");
    assert(timeline.horizontalScrollMaximum() > 0.0,
        "Empty timeline has no scrollable range");

    // 2) Zooming OUT far (well below the old 14 px/s floor) must be allowed.
    const defaultPps = timeline.pixelsPerSecond();
    timeline.zoomOut(); // start
    double wide = timeline.pixelsPerSecond();
    writeln("default pps=", defaultPps, " after zoomOut=", wide);
    assert(wide < defaultPps, "zoomOut did not reduce pixels-per-second");
    // Repeatedly zoom out until we approach the minimum (2 px/s).
    int guard;
    while (timeline.pixelsPerSecond() > 2.001 && guard < 60)
    {
        timeline.zoomOut();
        ++guard;
    }
    assert(timeline.pixelsPerSecond() >= 2.0,
        "zoom-out did not respect the (lower) minimum");
    assert(timeline.pixelsPerSecond() < 14.0,
        "Could not zoom out below the previous 14 px/s floor");
    writeln("final zoomed-out pps=", timeline.pixelsPerSecond(),
        " visibleDuration=", timeline.horizontalVisibleDuration());

    // 3) With a very wide view, the visible duration should be large.
    assert(timeline.horizontalVisibleDuration() > 200.0,
        "Zoomed-out view did not produce a wide visible span");

    // 4) Panning must work on the (empty) timeline across its content range.
    const before = timeline.horizontalScroll();
    timeline.setHorizontalScroll(timeline.horizontalScrollMaximum());
    assert(timeline.horizontalScroll() > before,
        "Could not pan an empty timeline");

    // 5) The scrollbar must align to the timeline content region: it starts
    // after the label column and does not reach into the vertical scrollbar.
    const track = scrollbar.trackRectForTesting();
    assert(track.x >= timeline.horizontalViewportLeft(),
        "Scrollbar track starts before the timeline label column");
    const timelineRight = timeline.bounds().width;
    assert(track.right() <= timelineRight - 12 + 1,
        "Scrollbar track reaches into the vertical scrollbar column");

    writeln("Aurora Cut zoom-out smoke test passed.");
    return 0;
}
