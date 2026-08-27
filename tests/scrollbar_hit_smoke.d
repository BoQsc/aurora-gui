module scrollbar_hit_smoke;

import aurora;
import aurora.event : Event, MouseButton;
import aurora.types : Point, Rect, Size;
import auroracut.model : EditorModel, TrackAddress, TrackKind;
import auroracut.timeline : TimelineHorizontalScrollbar, TimelineWidget;
import std.math : fabs;
import std.stdio : writeln;

/// The timeline horizontal scrollbar is painted thin but must have a generous
/// hit area so a ~7 px channel is easy to grab. This verifies clicks in the
/// widget padding (outside the painted track) still pan/zoom and that the
/// painted track stays compact.
int main()
{
    auto model = new EditorModel();
    assert(model.insertTextClip(TrackAddress(TrackKind.video, 0),
        0.0, 60.0, "probe") >= 0);
    auto timeline = new TimelineWidget(model);
    timeline.setBounds(Rect(0, 0, 800, 180));
    timeline.setZoom(100.0);
    auto bar = new TimelineHorizontalScrollbar(timeline);
    bar.setBounds(Rect(0, 0, 800, 11));

    assert(timeline.horizontalScrollMaximum() > 0.0);
    const track = bar.trackRectForTesting();
    const thumb = bar.thumbRectForTesting();

    // The painted channel remains thin/compact.
    writeln("track = ", track, " (y=", track.y, " h=", track.height, ")");
    assert(track.height <= 8, "painted channel should remain compact");

    // A click in the top padding (OUTSIDE the painted track) must be hit-tested
    // and start a thumb pan (regression: it used to be ignored).
    const panX = track.x + track.width / 2;
    Event downTop;
    downTop.button = MouseButton.left;
    downTop.position = Point(panX, 0);
    assert(bar.onMouseDown(downTop),
        "click in the top padding should be hit-testable");
    assert(bar.draggingThumbForTesting(),
        "top-padding click should start a thumb pan");
    Event upTop;
    upTop.button = MouseButton.left;
    upTop.position = Point(panX, 0);
    bar.onMouseUp(upTop);
    assert(!bar.draggingThumbForTesting(), "mouse-up should end the drag");

    // Clicking in the bottom padding also pans.
    Event downBottom;
    downBottom.button = MouseButton.left;
    downBottom.position = Point(panX, bar.bounds().height - 1);
    assert(bar.onMouseDown(downBottom),
        "click in the bottom padding should be hit-testable");
    assert(bar.draggingThumbForTesting(), "bottom-padding click should start a pan");
    Event upBottom;
    upBottom.button = MouseButton.left;
    upBottom.position = Point(panX, bar.bounds().height - 1);
    bar.onMouseUp(upBottom);
    assert(!bar.draggingThumbForTesting(), "mouse-up should end the drag");

    // The left grip is also hit-testable across the full widget height.
    const leftGrip = bar.leftGripRectForTesting();
    Event downGrip;
    downGrip.button = MouseButton.left;
    downGrip.position = Point(leftGrip.x + leftGrip.width / 2, 0);
    assert(bar.onMouseDown(downGrip),
        "left grip should be hit-testable at the top padding");
    assert(bar.onMouseUp(downGrip), "left grip should release cleanly");

    writeln("scrollbar_hit_smoke: ALL PASSED");
    return 0;
}
