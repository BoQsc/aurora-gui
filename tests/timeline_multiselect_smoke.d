module tests.timeline_multiselect_smoke;

import aurora;
import aurora.layout : Panel;
import aurora.testing : UiTestDriver;
import aurora.types : Point, Rect;
import auroracut.model : EditorModel, MediaAsset, TrackAddress, TrackKind;
import auroracut.timeline : TimelineWidget;
import std.math : fabs;
import std.stdio : writeln;

private MediaAsset videoAsset(string path, double duration)
{
    auto a = new MediaAsset(path);
    a.duration = duration;
    a.hasVideo = true;
    a.hasAudio = true;
    a.width = 1920;
    a.height = 1080;
    a.frameRate = 30.0;
    a.audioChannels = 2;
    a.sampleRate = 48_000;
    return a;
}

private Point clipCenter(TimelineWidget timeline, TrackAddress address, int index)
{
    const rect = timeline.clipRectForTesting(address, index);
    const origin = timeline.localToGlobal(Point(0, 0));
    return Point(origin.x + rect.x + rect.width / 2,
        origin.y + rect.y + rect.height / 2);
}

int main()
{
    auto model = new EditorModel();
    const v1 = TrackAddress(TrackKind.video, 0);
    const a1 = TrackAddress(TrackKind.audio, 0);
    model.addAsset(videoAsset("a.mp4", 5.0));
    model.insertClip(0, v1, 0.0);
    model.insertClip(0, v1, 6.0);
    model.insertClip(0, a1, 0.0);

    WindowOptions options;
    options.title = "timeline multiselect";
    options.width = 1100;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new Panel();
    window.setRoot(root);
    root.setBounds(Rect(0, 0, 1100, 700));
    auto timeline = new TimelineWidget(model);
    root.add(timeline);
    timeline.setBounds(Rect(0, 0, 1100, 680));

    // Ctrl+click toggling (public API, since the test driver cannot inject a
    // mouse modifier): select clip 0, then toggle clip 1 on.
    timeline.selectSingle(v1, 0, false);
    assert(timeline.selectedCountForTesting() == 1);
    timeline.toggleSelection(v1, 1, false);
    assert(timeline.selectedCountForTesting() == 2,
        "toggleSelection did not build a 2-clip selection");

    // Selecting a contiguous range by Shift-click semantics selects 0 and 1.
    timeline.selectSingle(v1, 0, false);
    timeline.selectRange(v1, 1, false);
    assert(timeline.selectedCountForTesting() == 2,
        "selectRange did not build a 2-clip range");

    // A drag on a selected clip fires onSelectionMoveRequested for the group.
    bool moveFired;
    TrackAddress moveTrack;
    int moveIndex;
    double moveTarget = -1.0;
    timeline.onSelectionMoveRequested = delegate(TrackAddress t, int i, double s) {
        moveFired = true;
        moveTrack = t;
        moveIndex = i;
        moveTarget = s;
    };
    auto driver = new UiTestDriver(window);
    const from = clipCenter(timeline, v1, 0);
    const to = Point(from.x + 120, from.y);
    driver.drag(from, to, 12);
    assert(moveFired,
        "Dragging a selected clip did not request a group move");
    assert(moveTrack == v1 && moveIndex == 0,
        "Group move request reported the wrong pressed clip");
    assert(moveTarget > 0.0,
        "Group move target was not a valid sequence time");

    // Apply the group move exactly as the editor does: uniform delta on each
    // selected clip. Both selected clips move together, preserving their gap
    // (clip 0 at 0.0, clip 1 at 6.0 -> the unselected audio at 0 is untouched).
    import auroracut.model : SelectedClipMove;
    import std.algorithm : min;
    const pressedStart = model.trackValue(v1).clips[0].start;
    const delta = moveTarget - pressedStart;
    const v0Id = model.trackValue(v1).clips[0].id;
    const v1Id = model.trackValue(v1).clips[1].id;
    SelectedClipMove[] moves;
    // Both clips are excluded as obstacles so the group keeps its internal gap.
    moves ~= SelectedClipMove(v1, v0Id, delta, [v0Id, v1Id]);
    moves ~= SelectedClipMove(v1, v1Id, delta, [v0Id, v1Id]);
    int movedCount;
    assert(model.moveSelection(moves, movedCount) && movedCount == 2,
        "Group move did not relocate both selected clips");
    const c0 = model.clipIndexForId(v1, v0Id);
    const c1 = model.clipIndexForId(v1, v1Id);
    assert(fabs(model.trackValue(v1).clips[cast(size_t) c0].start -
        (pressedStart + delta)) < 0.02,
        "Primary clip did not land on the drag target");
    assert(fabs((model.trackValue(v1).clips[cast(size_t) c1].start -
        model.trackValue(v1).clips[cast(size_t) c0].start) - 6.0) < 0.02,
        "Group move did not preserve the clips' relative offset");

    writeln("Aurora Cut timeline multi-select smoke test passed (group move target=",
        moveTarget, ").");
    return 0;
}
