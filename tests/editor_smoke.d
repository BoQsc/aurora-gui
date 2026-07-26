module tests.editor_smoke;

import aurora;
import auroracut.editor : EditorRoot, InspectorValueField;
import auroracut.model : ClipKind, EditorModel, EffectProperty, TimelineClip,
    TrackAddress, TrackKind;
import auroracut.preview : PreviewWidget;
import auroracut.timeline : TimelineHorizontalScrollbar, TimelineWidget;
import core.thread : Thread;
import core.time : msecs;
import std.algorithm.searching : canFind;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.math : fabs;
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

private size_t countWidgetsOfType(T)(Widget root)
{
    if (root is null) return 0;
    size_t result = cast(T) root !is null ? 1 : 0;
    foreach (child; root.children()) result += countWidgetsOfType!T(child);
    return result;
}

private ContextMenu findOpenContextMenu(Widget root)
{
    if (root is null) return null;
    auto menu = cast(ContextMenu) root;
    if (menu !is null && !menu.dismissed()) return menu;
    foreach (child; root.children())
    {
        menu = findOpenContextMenu(child);
        if (menu !is null) return menu;
    }
    return null;
}

private bool menuHasLabel(ContextMenu menu, dstring label)
{
    if (menu is null) return false;
    foreach (item; menu.items())
        if (!item.separator && item.label == label) return true;
    return false;
}

private bool menuItemChecked(ContextMenu menu, dstring label)
{
    if (menu is null) return false;
    foreach (item; menu.items())
        if (!item.separator && item.label == label) return item.checked;
    return false;
}

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private Point mediaRowPoint(ListView list, int index)
{
    const origin = list.localToGlobal(Point(0, 0));
    return Point(origin.x + 70,
        origin.y + index * list.rowHeight() - list.scrollOffset() + list.rowHeight() / 2);
}

private Point clipCenter(TimelineWidget timeline, TrackAddress address, int index)
{
    const rect = timeline.clipRectForTesting(address, index);
    assert(!rect.empty(), "Requested test clip is not visible");
    const origin = timeline.localToGlobal(Point(0, 0));
    return Point(origin.x + rect.x + rect.width / 2,
        origin.y + rect.y + rect.height / 2);
}

private void doubleClickDrag(UiTestDriver driver, Point from, Point to, int steps = 12)
{
    // The second press remains inside Aurora's double-click interval, then is
    // held and moved. This exercises the exact gesture requested by the editor.
    driver.click(from);
    driver.moveTo(from);
    driver.mouseDown();
    foreach (step; 1 .. steps + 1)
    {
        const x = from.x + (to.x - from.x) * step / steps;
        const y = from.y + (to.y - from.y) * step / steps;
        driver.moveTo(Point(x, y));
    }
    driver.mouseUp();
}

private bool waitForMediaCount(EditorRoot editor, ListView mediaList,
    size_t expected, int iterations = 600)
{
    foreach (_; 0 .. iterations)
    {
        editor.tickTree(0.02);
        if (mediaList.items().length == expected && !editor.importBusyForTesting())
            return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

private bool waitForFrame(EditorRoot editor, PreviewWidget preview,
    double minimumTime, int iterations = 600)
{
    foreach (_; 0 .. iterations)
    {
        editor.tickTree(0.02);
        if (preview.hasFrame() && preview.frameTime() >= minimumTime) return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

private bool waitForSequencePlayback(EditorRoot editor, PreviewWidget preview)
{
    foreach (_; 0 .. 2_400)
    {
        editor.tickTree(0.02);
        if (editor.sequencePlaybackForTesting() && preview.hasFrame() &&
            preview.frameTitleForTesting().canFind("Sequence")) return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 4,
        "Usage: editor-smoke <base-av.mp4> <overlay.mp4> <audio.mp3>");

    WindowOptions options;
    options.title = "Aurora Cut headless smoke test";
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
    writeln("[editor-smoke] initial paint");

    auto mediaPanel = requireWidget!Widget(editor, "project-media-panel");
    auto mediaList = requireWidget!ListView(editor, "project-media-list");
    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto timelineScrollbar = requireWidget!TimelineHorizontalScrollbar(editor,
        "sequence-horizontal-scrollbar");
    auto sequenceSplit = requireWidget!SplitPane(editor, "workspace-sequence-split");
    auto inspectorScroll = requireWidget!ScrollView(editor, "clip-inspector-scroll");
    auto inspectorSourceSection = requireWidget!Widget(editor,
        "inspector-source-section");
    auto scale = requireWidget!InspectorValueField(editor, "clip-scale");
    auto mute = requireWidget!CheckBox(editor, "clip-mute");
    auto gainLabel = requireWidget!Label(editor, "inspector-label-Gain");
    auto gainKey = requireWidget!Button(editor, "inspector-key-Gain");
    auto inlineFont = requireWidget!Button(editor, "preview-inline-font");
    auto inlineSize = requireWidget!TextField(editor, "preview-inline-text-size");
    auto inlineColor = requireWidget!TextField(editor, "preview-inline-color");
    auto inlineBold = requireWidget!Button(editor, "preview-inline-bold");
    auto inlineDone = requireWidget!Button(editor, "preview-inline-done");
    auto inspectorTextField = requireWidget!TextField(editor, "clip-text");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto playSource = requireWidget!Button(editor, "play-preview");
    auto qualityButton = requireWidget!Button(editor, "preview-quality");
    auto revealExport = requireWidget!Button(editor, "reveal-export-output");
    assert(playSource.text() == "▶"d,
        "Preview transport button must show the play symbol while idle");
    assert(!revealExport.enabled() && !editor.revealExportEnabledForTesting(),
        "Export output button must stay disabled until an export completes");
    assert(findById(editor, "stop-playback") is null,
        "A separate Stop button returned to the transport");
    assert(findById(editor, "import-media") is null,
        "Project Media still contains a redundant visible Import button");
    assert(findById(editor, "add-selected-media") is null,
        "Project Media still contains a redundant Add selected button");
    assert(!inspectorSourceSection.visible(),
        "Source / Timing controls still pollute Effects / Properties");
    assert(countWidgetsOfType!Slider(inspectorScroll) == 0,
        "Effects / Properties still contains long slider controls");
    assert(timelineScrollbar.bounds().height > 0 &&
        timelineScrollbar.bounds().height <= 12,
        "Timeline horizontal scrollbar is not compact");

    // Out-first export marking must create a complete visible zone rather than
    // leaving a lone Out marker and relying on export-time fallback behavior.
    editor.setWorkOutForTesting(4.25);
    assert(editor.hasWorkInForTesting() && editor.hasWorkOutForTesting(),
        "Setting export Out first did not create the implicit In marker");
    assert(fabs(editor.workInForTesting()) < 0.0001 &&
        fabs(editor.workOutForTesting() - 4.25) < 0.0001,
        "Out-first export range did not begin at timeline start");
    editor.clearWorkRangeForTesting();

    // Geometry regression independent of fixture duration: a 60-second title
    // must yield a movable, proportionally sized thumb, and panning must not
    // alter the timeline's pixels-per-second value.
    {
        auto scrollModel = new EditorModel();
        assert(scrollModel.insertTextClip(TrackAddress(TrackKind.video, 0),
            0.0, 60.0, "Scrollbar probe") >= 0);
        auto scrollTimeline = new TimelineWidget(scrollModel);
        scrollTimeline.setBounds(Rect(0, 0, 800, 180));
        scrollTimeline.setZoom(100.0);
        auto scrollProbe = new TimelineHorizontalScrollbar(scrollTimeline);
        scrollProbe.setBounds(Rect(0, 0, 800, 11));
        const zoomBeforePan = scrollTimeline.pixelsPerSecond();
        assert(scrollTimeline.horizontalScrollMaximum() > 0.0);
        scrollTimeline.setHorizontalScroll(
            scrollTimeline.horizontalScrollMaximum() * 0.5);
        const scrollTrack = scrollProbe.trackRectForTesting();
        const scrollThumb = scrollProbe.thumbRectForTesting();
        assert(scrollThumb.width < scrollTrack.width,
            "Horizontal scrollbar thumb does not represent visible duration");
        assert(scrollThumb.x > scrollTrack.x,
            "Horizontal scrollbar thumb did not follow timeline panning");
        assert(fabs(scrollTimeline.pixelsPerSecond() - zoomBeforePan) < 0.0001,
            "Horizontal panning unexpectedly changed timeline zoom");
    }

    // Regression: V1/A1 row paint must never erase the Cut and Text buttons
    // in the permanent tool rail. This reproduces the exact Windows screenshot
    // where only the selected S button remained visible.
    {
        auto snapshot = window.surface();
        const origin = timeline.localToGlobal(Point(0, 0));
        const pitch = snapshot.width();
        const expected = Color.fromHex(0x2a3038).argb();
        const cutPixel = snapshot.pixels()[cast(size_t) (origin.y + 30) * pitch + origin.x + 6];
        const textPixel = snapshot.pixels()[cast(size_t) (origin.y + 52) * pitch + origin.x + 6];
        assert(cutPixel == expected, "V1 row erased the Cut tool button");
        assert(textPixel == expected, "A1 row erased the Text tool button");
    }
    const timelineToolOrigin = timeline.localToGlobal(Point(0, 0));
    driver.moveTo(Point(timelineToolOrigin.x + 12, timelineToolOrigin.y + 34));
    assert(driver.paint());
    assert(timeline.hoveredToolForTesting() == 1,
        "Cut tool hover did not expose its tooltip");
    driver.moveTo(Point(timelineToolOrigin.x + 140, timelineToolOrigin.y + 120));

    writeln("[editor-smoke] sequence tool rail visible");

    // Exercise the same hit-test/bubbling path used by native WM_DROPFILES.
    auto importWatch = StopWatch(AutoStart.yes);
    driver.dropFiles(globalCenter(mediaPanel),
        [arguments[1], arguments[2], arguments[3], arguments[1], arguments[1] ~ ".txt"]);
    importWatch.stop();
    assert(importWatch.peek.total!"msecs" < 500,
        "Explorer-style drop synchronously waited for FFprobe");
    assert(waitForMediaCount(editor, mediaList, 3),
        "Explorer-style background import did not produce three unique files");
    writeln("[editor-smoke] file drop");

    // The context menu's top-left corner must be immediately beside the pointer.
    const mediaContextPoint = mediaRowPoint(mediaList, 0);
    driver.rightClick(mediaContextPoint);
    auto mediaMenu = findOpenContextMenu(editor);
    assert(mediaMenu !is null, "Project Media right-click did not open a context menu");
    const mediaMenuRect = mediaMenu.menuRect();
    assert(mediaMenuRect.x == mediaContextPoint.x + 2 &&
        mediaMenuRect.y == mediaContextPoint.y + 2,
        "Context menu top-left was not anchored beside the mouse cursor");
    assert(mediaMenu.rowHeightForTesting() == 22 && mediaMenuRect.width <= 280,
        "Context menu did not use the compact editor dimensions");
    assert(menuHasLabel(mediaMenu, "Add to V1"d));
    assert(menuHasLabel(mediaMenu, "Place on new video track at playhead"d));
    assert(!menuHasLabel(mediaMenu, "Play source in Preview"d),
        "Composition Preview exposed a competing source-player command");
    assert(menuHasLabel(mediaMenu, "Show in File Explorer"d));
    driver.pressKey(Key.escape);
    assert(mediaMenu.dismissed());

    const v1 = TrackAddress(TrackKind.video, 0);
    const a1 = TrackAddress(TrackKind.audio, 0);

    // Drag Project Media directly to the existing V1/A1 tracks.
    driver.drag(mediaRowPoint(mediaList, 0), timeline.pointForTrackTime(v1, 0.05), 16);
    assert(editor.modelForTesting().trackValue(v1).clips.length == 1,
        "Project Media drag did not create a V1 clip");
    assert(fabs(editor.modelForTesting().trackValue(v1).clips[0].start) < 0.0001,
        "The first sequence clip did not snap to 00:00:00");
    // Regression: the first clip must keep the timeline viewport anchored at
    // sequence zero. Previously transport auto-follow silently scrolled the
    // ruler to ~00:00:16, making the clipped V1 body look as though it began
    // there even though its real start remained 00:00:00.
    assert(timeline.fitViewForTesting(),
        "The first sequence clip did not enable the default fit view");
    const fitPlayhead = editor.modelForTesting().sequenceDuration() * 0.65;
    timeline.setPlayhead(fitPlayhead, false);
    assert(fabs(timeline.scrollSecondsForTesting()) < 0.0001,
        "Fit view auto-scrolled away from sequence zero");
    assert(fabs(timeline.timeAtXForTesting(timeline.timeOriginXForTesting())) < 0.0001,
        "Timeline zero origin no longer maps to 00:00:00");

    const selectionPlayheadBefore = timeline.playhead();
    driver.click(clipCenter(timeline, v1, 0));
    assert(fabs(timeline.playhead() - selectionPlayheadBefore) < 0.0001,
        "Selecting a timeline item moved the playhead");

    // Every tool must leave the ruler usable as the single timeline transport
    // surface. This guards the former inconsistency where Cut/Text could trap
    // the playhead or redirect Composition Preview away from sequence time.
    {
        const origin = timeline.localToGlobal(Point(0, 0));
        const cutTool = Point(origin.x + 12, origin.y + 34);
        const textTool = Point(origin.x + 12, origin.y + 56);
        const selectTool = Point(origin.x + 12, origin.y + 12);
        const rulerX1 = timeline.timeOriginXForTesting() +
            cast(int) (0.55 * timeline.pixelsPerSecond());
        const rulerX2 = timeline.timeOriginXForTesting() +
            cast(int) (0.85 * timeline.pixelsPerSecond());
        driver.click(cutTool);
        driver.click(Point(origin.x + rulerX1, origin.y + 8));
        assert(fabs(timeline.playhead() - timeline.timeAtXForTesting(rulerX1)) < 0.02,
            "Cut tool prevented ruler playhead movement");
        driver.click(textTool);
        driver.click(Point(origin.x + rulerX2, origin.y + 8));
        assert(fabs(timeline.playhead() - timeline.timeAtXForTesting(rulerX2)) < 0.02,
            "Text tool prevented ruler playhead movement");
        driver.click(selectTool);
    }

    // The normal one-video sequence must play from the original source
    // immediately. It must not start a full composition render merely because
    // the clip was copied from Project Media to V1.
    timeline.setSelection(v1, 0);
    assert(driver.paint());
    assert(gainLabel.visible() && gainLabel.bounds().height >= 20,
        "Inspector property names collapsed to zero height");
    assert(gainKey.visible() && gainKey.text() == "◇ Key"d,
        "Per-item keyframe control is not visibly labeled");
    const playbackLaunchPosition = timeline.playhead();
    assert(playbackLaunchPosition > 0.1,
        "The scrubber-origin regression test requires a non-zero launch position");
    driver.click(globalCenter(playSource));
    assert(editor.directSequencePlaybackForTesting(),
        "Plain V1 playback did not use direct source passthrough");
    // Regression for the Windows screenshot: Play was pressed at a non-zero
    // sequence position, but the Preview scrubber treated that position as its
    // own zero and stayed visually at the far-left edge. Sequence playback and
    // the red timeline playhead must share one absolute 00:00:00-based range.
    assert(fabs(editor.playbackStartForTesting()) < 0.0001,
        "Sequence playback redefined its origin at the launch playhead");
    assert(fabs(editor.scrubMinimumForTesting()) < 0.0001,
        "Preview scrubber is not anchored at sequence 00:00:00");
    assert(fabs(editor.scrubValueForTesting() - playbackLaunchPosition) < 0.02,
        "Preview scrubber does not match the red timeline playhead");
    assert(fabs(editor.scrubMaximumForTesting() -
        editor.modelForTesting().sequenceDuration()) < 0.02,
        "Preview scrubber does not cover the complete sequence duration");
    assert(!editor.renderRunningForTesting(),
        "Plain V1 playback unexpectedly started a composition render");
    assert(waitForFrame(editor, preview, 0.0, 600),
        "Direct V1 playback did not produce an embedded frame");
    driver.pressKey(Key.escape);

    driver.rightClick(globalCenter(preview));
    auto previewMenu = findOpenContextMenu(editor);
    assert(previewMenu !is null && menuHasLabel(previewMenu, "Add text"d),
        "Composition Preview context menu is missing Add text");
    driver.pressKey(Key.escape);

    driver.dropFiles(timeline.pointForTrackTime(a1, 0.10), [arguments[3]]);
    foreach (_; 0 .. 30) editor.tickTree(0.02);
    assert(editor.modelForTesting().trackValue(a1).clips.length == 1,
        "Windows Explorer-style drop directly on A1 did not create an audio clip");

    // Dropping on the top edge creates V2 without adding permanent UI clutter.
    driver.drag(mediaRowPoint(mediaList, 1),
        timeline.newTrackDropPointForTesting(TrackKind.video, 0.20), 18);
    const v2 = TrackAddress(TrackKind.video, 1);
    assert(editor.modelForTesting().trackCount(TrackKind.video) == 2);
    assert(editor.modelForTesting().trackValue(v2).clips.length == 1,
        "Edge drop did not create V2 and place the overlay");

    writeln("[editor-smoke] project media drops");

    // A held second click can move the clip both horizontally and into a new V3.
    const v2Start = clipCenter(timeline, v2, 0);
    const v3Drop = timeline.newTrackDropPointForTesting(TrackKind.video, 1.0);
    doubleClickDrag(driver, v2Start, v3Drop);
    const v3 = TrackAddress(TrackKind.video, 2);
    assert(editor.modelForTesting().trackCount(TrackKind.video) == 3);
    assert(editor.modelForTesting().trackValue(v2).clips.length == 0);
    assert(editor.modelForTesting().trackValue(v3).clips.length == 1,
        "Double-click-drag did not move the item from V2 to newly created V3");
    const overlayStart = editor.modelForTesting().trackValue(v3).clips[0].start;
    assert(overlayStart > 0.25 && overlayStart < 0.65,
        "The horizontal part of the V2-to-V3 drag was not applied");

    writeln("[editor-smoke] video cross-track drag");

    // Timeline clipboard shortcuts must bubble past the tool shortcuts.
    timeline.setSelection(v3, 0);
    const beforeClipboard = editor.modelForTesting().trackValue(v3).clips.length;
    driver.pressKey(Key.c, cast(uint) KeyModifier.control);
    timeline.setPlayhead(2.4, false);
    driver.pressKey(Key.v, cast(uint) KeyModifier.control);
    assert(editor.modelForTesting().trackValue(v3).clips.length == beforeClipboard + 1,
        "Ctrl+C / Ctrl+V did not copy and paste a timeline item");
    driver.pressKey(Key.d, cast(uint) KeyModifier.control);
    assert(editor.modelForTesting().trackValue(v3).clips.length == beforeClipboard + 2,
        "Ctrl+D did not duplicate the selected timeline item");

    // The equivalent bottom-edge gesture creates A2.
    const audioStart = clipCenter(timeline, a1, 0);
    const a2Drop = timeline.newTrackDropPointForTesting(TrackKind.audio, 0.9);
    doubleClickDrag(driver, audioStart, a2Drop);
    const a2 = TrackAddress(TrackKind.audio, 1);
    assert(editor.modelForTesting().trackCount(TrackKind.audio) == 2);
    assert(editor.modelForTesting().trackValue(a1).clips.length == 0);
    assert(editor.modelForTesting().trackValue(a2).clips.length == 1);

    writeln("[editor-smoke] audio cross-track drag");

    // Keep the compact sequence geometry at one third of the old clip height.
    assert(timeline.clipBodyHeightForTesting() == 20);
    assert(timeline.clipRectForTesting(v3, 0).height == 20,
        "Sequence clip bodies do not leave enough height for normal text");
    // Clip edges resize timeline duration without a modal operation.
    const beforeDuration = editor.modelForTesting().trackValue(v3).clips[0].duration();
    auto edgeRect = timeline.clipRectForTesting(v3, 0);
    auto timelineGlobal = timeline.localToGlobal(Point(0, 0));
    const edgeStart = Point(timelineGlobal.x + edgeRect.right() - 1,
        timelineGlobal.y + edgeRect.y + edgeRect.height / 2);
    driver.drag(edgeStart, Point(edgeStart.x + 24, edgeStart.y), 8);
    assert(editor.modelForTesting().trackValue(v3).clips[0].duration() >= beforeDuration,
        "Dragging a clip edge did not resize its timeline duration");

    // Dynamic track and composition operations are exposed through context menus.
    const overlayPoint = clipCenter(timeline, v3, 0);
    driver.rightClick(overlayPoint);
    auto timelineMenu = findOpenContextMenu(editor);
    assert(timelineMenu !is null);
    assert(timelineMenu.menuRect().x == overlayPoint.x + 2 &&
        timelineMenu.menuRect().bottom() == overlayPoint.y - 2,
        "Timeline context menu is not anchored from its bottom-left beside the mouse");
    assert(menuHasLabel(timelineMenu, "Move to V1"d));
    assert(menuHasLabel(timelineMenu, "Move to V2"d));
    assert(menuHasLabel(timelineMenu, "Move to new video track"d));
    assert(menuHasLabel(timelineMenu, "Add video track"d));
    assert(menuHasLabel(timelineMenu, "Add audio track"d));
    assert(menuHasLabel(timelineMenu, "Mute V3"d));
    assert(menuHasLabel(timelineMenu, "Reset transform"d));
    // A long menu must remain scrollable rather than losing lower commands.
    driver.wheel(Point(timelineMenu.menuRect().x + 20,
        timelineMenu.menuRect().y + timelineMenu.menuRect().height / 2), -4);
    driver.pressKey(Key.escape);

    // Animated properties are marked directly on clips. Right-clicking the
    // marker exposes removal and interpolation choices.
    const keyClipStart = editor.modelForTesting().trackValue(v3).clips[0].start;
    assert(editor.modelForTesting().setKeyframe(v3, 0,
        EffectProperty.scale, 0.10, 0.55));
    timeline.visualChanged();
    assert(driver.paint());
    const keyframePoint = timeline.pointForTrackTime(v3, keyClipStart + 0.10);
    driver.rightClick(keyframePoint);
    auto keyframeMenu = findOpenContextMenu(editor);
    assert(keyframeMenu !is null);
    assert(menuHasLabel(keyframeMenu, "Remove keyframe"d));
    assert(menuHasLabel(keyframeMenu, "Linear interpolation"d));
    assert(menuHasLabel(keyframeMenu, "Bezier interpolation"d));
    assert(menuHasLabel(keyframeMenu, "Hold interpolation"d));
    driver.pressKey(Key.escape);

    driver.click(globalCenter(qualityButton));
    auto qualityMenu = findOpenContextMenu(editor);
    assert(qualityMenu !is null);
    assert(menuHasLabel(qualityMenu, "1080p preview and MP4"d));
    assert(menuHasLabel(qualityMenu, "1440p preview and MP4"d));
    assert(menuHasLabel(qualityMenu, "2160p preview and MP4"d));
    driver.pressKey(Key.escape);

    writeln("[editor-smoke] context menus and quality");

    // Resize the Sequence with its actual SplitPane divider.
    const oldSequenceHeight = sequenceSplit.second().bounds().height;
    const splitOrigin = sequenceSplit.localToGlobal(Point(0, 0));
    const dividerY = splitOrigin.y + sequenceSplit.first().bounds().height + 3;
    const dividerX = splitOrigin.x + sequenceSplit.bounds().width / 2;
    driver.drag(Point(dividerX, dividerY), Point(dividerX, dividerY - 80));
    assert(sequenceSplit.second().bounds().height > oldSequenceHeight + 35);

    assert(inspectorScroll.maxScroll() > 0);
    driver.wheel(globalCenter(inspectorScroll), -5);
    assert(inspectorScroll.scrollY() > 0,
        "Clip Inspector did not scroll to lower transform/audio controls");

    writeln("[editor-smoke] resize and inspector scroll");

    // Select the overlay and make it a picture-in-picture composition. The
    // single Preview transport always plays the timeline, even when Project
    // Media currently has focus.
    driver.click(clipCenter(timeline, v3, 0));
    const scaleBeforeScrub = scale.value();
    const scaleCenter = globalCenter(scale);
    driver.drag(scaleCenter, Point(scaleCenter.x + 18, scaleCenter.y), 6);
    assert(fabs(scale.value() - scaleBeforeScrub) > 0.001,
        "Click-dragging a property value did not scrub it");
    timeline.setPlayhead(keyClipStart + 0.25, true);
    scale.setValue(0.5);
    const keyedScaleClip = editor.modelForTesting().trackValue(v3).clips[0];
    assert(keyedScaleClip.hasKeyframe(EffectProperty.scale, 0.25, 0.02),
        "Editing an animated property did not create a marked keyframe");
    assert(fabs(keyedScaleClip.evaluatedValue(EffectProperty.scale, 0.25) - 0.5) < 0.001);
    driver.click(mediaRowPoint(mediaList, 2));
    editor.setPreviewQualityForTesting(720);
    timeline.setPlayhead(0.60, false);
    driver.click(globalCenter(playSource));
    assert(editor.playbackRunningForTesting() &&
        editor.sequencePlaybackForTesting() && preview.playing(),
        "The Preview transport did not start timeline playback");
    assert(waitForSequencePlayback(editor, preview),
        "The live timeline composition never began embedded playback");
    assert(waitForFrame(editor, preview, 0.62, 600));
    writeln("[editor-smoke] sequence frame title=", preview.frameTitleForTesting(),
        " time=", preview.frameTime());
    assert(preview.frameTitleForTesting().canFind("Sequence"),
        "Preview is not showing the timeline composition");
    const center = preview.pixelForTesting(preview.frameWidth() / 2,
        preview.frameHeight() / 2);
    const corner = preview.pixelForTesting(8, 8);
    assert(center[0] > center[2] + 70,
        "The scaled red V3 overlay is missing from the live Preview");
    assert(corner[2] > corner[0] + 70,
        "The blue V1 base is missing outside the live overlay");

    writeln("[editor-smoke] live sequence preview");

    // Hammer the same coalesced path used by the playback selector. Pointer
    // movement must remain immediate, repaint only retained transport layers,
    // and commit at most one useful decoder restart when the gesture ends.
    const statsBeforeScrub = editor.videoStatsForTesting();
    // Headless ticks do not implicitly present. Flush the playback-start
    // layout and the one follow-up frame caused by changed button widths before
    // measuring only the selector gesture itself.
    foreach (_; 0 .. 3) assert(driver.paint());
    window.resetRendererStats();
    window.resetCompositorStats();
    editor.beginSeekGestureForTesting();
    auto scrubWatch = StopWatch(AutoStart.yes);
    foreach (index; 0 .. 240)
    {
        const target = 0.10 + cast(double) (index % 110) / 100.0;
        editor.seekForTesting(target);
        if (index % 12 == 0) assert(driver.paint());
    }
    scrubWatch.stop();
    assert(editor.seekPendingForTesting());
    assert(scrubWatch.peek.total!"msecs" < 1_500,
        "Rapid playback-selector movement blocked the UI thread");
    const scrubRenderer = window.rendererStats();
    const scrubCompositor = window.compositorStats();
    writeln("[editor-smoke] scrub renderer full=", scrubRenderer.fullSceneRedraws,
        " partial=", scrubRenderer.partialSceneRedraws,
        " dirty=", scrubRenderer.dirtyPixels,
        " cached=", scrubRenderer.cachedSurfaceBuilds,
        " baseBuilds=", scrubCompositor.baseBuilds,
        " layerBuilds=", scrubCompositor.layerBuilds,
        " orderBuilds=", scrubCompositor.layerOrderBuilds);
    assert(scrubRenderer.fullSceneRedraws == 0,
        "Playback-selector movement repainted the full editor window");
    assert(scrubRenderer.partialSceneRedraws > 0);
    assert(scrubCompositor.baseBuilds == 0,
        "Playback-selector movement rebuilt static workspace geometry");
    editor.endSeekGestureForTesting();
    assert(waitForFrame(editor, preview, 0.0, 600),
        "Playback did not recover after a rapid selector gesture");
    const statsAfterScrub = editor.videoStatsForTesting();
    assert(statsAfterScrub.processesStarted - statsBeforeScrub.processesStarted < 12,
        "Rapid selector movement spawned excessive decoder processes");
    assert(editor.sequencePlaybackForTesting() && preview.playing(),
        "Rapid selector movement stopped sequence playback");

    writeln("[editor-smoke] coalesced playback selector");

    // Editing mute while the composed sequence is playing must never stop the
    // video decoder or playhead. The change applies to the next render.
    // Select the V1 source clip, which contains embedded audio. The currently
    // selected overlay clip is intentionally video-only, so its audio controls
    // are disabled by the Inspector.
    driver.rightClick(clipCenter(timeline, v1, 0));
    auto avMenu = findOpenContextMenu(editor);
    assert(avMenu !is null &&
        menuHasLabel(avMenu, "Detach audio to separate A track"d),
        "Video-item context menu does not expose audio detachment");
    driver.pressKey(Key.escape);
    timeline.setSelection(v1, 0);
    editor.tickTree(0.02);
    driver.paint();

    foreach (_; 0 .. 120)
    {
        const mutePoint = globalCenter(mute);
        if (editor.hitTest(mutePoint) is mute) break;
        const scrollOrigin = inspectorScroll.localToGlobal(Point(0, 0));
        const scrollBottom = scrollOrigin.y + inspectorScroll.bounds().height;
        if (mutePoint.y < scrollOrigin.y)
            driver.wheel(globalCenter(inspectorScroll), 3);
        else if (mutePoint.y >= scrollBottom)
            driver.wheel(globalCenter(inspectorScroll), -3);
        else
            break;
    }
    assert(editor.hitTest(globalCenter(mute)) is mute,
        "Mute control could not be reached through the scrollable inspector");
    const runningBeforeMute = editor.sequencePlaybackForTesting();
    driver.click(globalCenter(mute));
    assert(runningBeforeMute && editor.sequencePlaybackForTesting() && preview.playing(),
        "Muting a clip stopped active playback");

    // Transform edits likewise invalidate only the next composition render;
    // the already playing proxy and decoder continue without interruption.
    timeline.setSelection(v3, 0);
    editor.tickTree(0.02);
    scale.setValue(0.62);
    const liveChangedClip = editor.modelForTesting().trackValue(v3).clips[0];
    double liveLocal = timeline.playhead() - liveChangedClip.start;
    if (liveLocal < 0.0) liveLocal = 0.0;
    if (liveLocal > liveChangedClip.duration()) liveLocal = liveChangedClip.duration();
    assert(fabs(liveChangedClip.evaluatedValue(EffectProperty.scale, liveLocal) - 0.62) < 0.001);
    assert(editor.sequencePlaybackForTesting() && preview.playing(),
        "Changing a composition transform stopped active playback");

    // Moving a clip while playback is active must not stop or restart the
    // current FFmpeg video/audio snapshot. The edited revision is adopted only
    // after pause/resume or a new Play command.
    const processesBeforeLiveMove = editor.videoStatsForTesting().processesStarted;
    const originalMoveStart = editor.modelForTesting().trackValue(v3).clips[0].start;
    editor.moveClipForTesting(v3, 0, v3, originalMoveStart + 0.10);
    foreach (_; 0 .. 20) editor.tickTree(0.02);
    assert(editor.sequencePlaybackForTesting() && preview.playing(),
        "Moving a timeline item interrupted active playback");
    assert(editor.videoStatsForTesting().processesStarted == processesBeforeLiveMove,
        "Moving a timeline item restarted the active video decoder");
    assert(editor.deferredSequenceRefreshForTesting() &&
        editor.modelRevisionForTesting() != editor.playbackRevisionForTesting(),
        "The active playback snapshot was not preserved after a timeline edit");

    driver.pressKey(Key.escape);

    writeln("[editor-smoke] non-blocking edits");

    // Text placement is one-shot, existing clips remain selectable while the
    // Text tool is armed, and both timeline/Preview double-clicks open editing.
    auto model = editor.modelForTesting();
    const textLane = model.addTrack(TrackKind.video);
    const textTrack = TrackAddress(TrackKind.video, textLane);
    timeline.modelChanged();
    assert(driver.paint());
    const timelineOrigin = timeline.localToGlobal(Point(0, 0));
    const textToolPoint = Point(timelineOrigin.x + 12, timelineOrigin.y + 56);
    const textTrackRect = timeline.trackRectForTesting(textTrack);
    const textTimeX = timeline.timeOriginXForTesting() +
        cast(int) (0.60 * timeline.pixelsPerSecond());
    const textEndX = timeline.timeOriginXForTesting() +
        cast(int) (2.60 * timeline.pixelsPerSecond());
    const textPlacePoint = Point(timelineOrigin.x + textTimeX,
        timelineOrigin.y + textTrackRect.y + textTrackRect.height / 2);
    const textEndPoint = Point(timelineOrigin.x + textEndX, textPlacePoint.y);
    driver.click(textToolPoint);
    driver.click(textPlacePoint);
    assert(model.trackValue(textTrack).clips.length == 0,
        "Text tool created an item without a duration drag");
    driver.drag(textPlacePoint, textEndPoint, 12);
    assert(model.trackValue(textTrack).clips.length == 1);
    assert(model.trackValue(textTrack).clips[0].kind == ClipKind.text);
    assert(fabs(model.trackValue(textTrack).clips[0].duration() - 2.0) < 0.08,
        "Text duration did not match the drag span");
    const firstTitleId = model.trackValue(textTrack).clips[0].id;
    auto textField = preview.titleEditorForTesting(firstTitleId);
    assert(textField !is null,
        "The text item did not create its persistent live preview layer");
    foreach (_; 0 .. 200)
    {
        editor.tickTree(0.02);
        if (textField.focused() && textField.visible() &&
            preview.inlineTextEditing()) break;
        Thread.sleep(10.msecs);
    }
    assert(textField.focused() && textField.visible() &&
        preview.inlineTextEditing(),
        "New text did not focus its persistent live title layer");
    assert(!inspectorTextField.visible(),
        "A duplicate text-content input remained visible in Effects / Properties");
    // Exercise real text-input dispatch rather than directly mutating the
    // field. Typing must update the one selected title and must never leave the
    // Text tool armed to create another sequence item.
    driver.text("Aurora"d);
    driver.pressKey(Key.space);
    assert(!editor.playbackRunningForTesting(),
        "Space started playback while the inline title editor was focused");
    // Native backends deliver the printable character in the following text
    // input event after key-down. The root shortcut handler must leave it alone.
    driver.text(" "d);
    driver.text("timeline"d);
    assert(model.trackValue(textTrack).clips[0].text == "Aurora timeline");
    assert(model.trackValue(textTrack).clips.length == 1,
        "Typing title text created duplicate timeline items");

    driver.click(globalCenter(inlineFont));
    auto fontMenu = findOpenContextMenu(editor);
    assert(fontMenu !is null && menuHasLabel(fontMenu, "Arial"d) &&
        menuHasLabel(fontMenu, "Tahoma"d) && menuHasLabel(fontMenu, "Verdana"d),
        "Composition Preview is missing the complete font dropdown");
    const fontMenuRect = fontMenu.menuRect();
    // Arial is the second row after Segoe UI.
    driver.click(Point(fontMenuRect.x + 70,
        fontMenuRect.y + 3 + fontMenu.rowHeightForTesting() +
        fontMenu.rowHeightForTesting() / 2));
    assert(inlineFont.text() == "Arial ▾"d,
        "Composition Preview font dropdown did not retain its selection");
    assert(model.trackValue(textTrack).clips[0].fontName == "Arial",
        "Arial menu command resolved to a different captured font");

    // Reopen the menu after the model/inspector synchronization pass. The
    // selected row must remain checked instead of resetting to the final Sans
    // callback captured by the foreach loop.
    driver.click(globalCenter(inlineFont));
    fontMenu = findOpenContextMenu(editor);
    assert(fontMenu !is null && menuItemChecked(fontMenu, "Arial"d),
        "Composition Preview lost the selected font after synchronization");
    const secondFontMenuRect = fontMenu.menuRect();
    // Impact is row 7 (zero-based index 6).
    driver.click(Point(secondFontMenuRect.x + 70,
        secondFontMenuRect.y + 3 + 6 * fontMenu.rowHeightForTesting() +
        fontMenu.rowHeightForTesting() / 2));
    assert(inlineFont.text() == "Impact ▾"d &&
        model.trackValue(textTrack).clips[0].fontName == "Impact",
        "Distinct font menu rows still shared one captured callback value");

    inlineSize.setText("72", true);
    inlineColor.setText("#FFCC00", true);
    driver.click(globalCenter(inlineBold));
    const styledText = model.trackValue(textTrack).clips[0];
    assert(styledText.fontName == "Impact" && styledText.textBold,
        "Inline font or bold formatting did not update the selected text item");
    assert(fabs(styledText.textSize - 72.0) < 0.01 &&
        styledText.textColor == 0xffffcc00,
        "Inline size or color formatting did not update the selected text item");

    // Re-arm Text and click the existing title. It must select, not duplicate.
    driver.click(textToolPoint);
    driver.click(clipCenter(timeline, textTrack, 0));
    assert(model.trackValue(textTrack).clips.length == 1,
        "Text tool created another item when clicking an existing text clip");
    driver.doubleClick(clipCenter(timeline, textTrack, 0));
    foreach (_; 0 .. 200)
    {
        editor.tickTree(0.02);
        if (textField.focused() && preview.inlineTextEditing()) break;
        Thread.sleep(10.msecs);
    }
    assert(textField.focused() && preview.inlineTextEditing(),
        "Timeline double-click did not activate the live title layer");

    // Double-click empty sequence space, hold the second press, and drag a
    // marquee over both titles. Selection must include every intersected item.
    assert(model.insertTextClip(textTrack, 3.20, 0.80, "Second title") >= 0);
    timeline.modelChanged();
    assert(driver.paint());
    const marqueeStartX = timeline.timeOriginXForTesting() +
        cast(int) (0.20 * timeline.pixelsPerSecond());
    const marqueeEndX = timeline.timeOriginXForTesting() +
        cast(int) (4.20 * timeline.pixelsPerSecond());
    const marqueeStart = Point(timelineOrigin.x + marqueeStartX, textPlacePoint.y);
    const marqueeEnd = Point(timelineOrigin.x + marqueeEndX, textPlacePoint.y);
    doubleClickDrag(driver, marqueeStart, marqueeEnd, 16);
    assert(timeline.selectedCountForTesting() == 2,
        "Double-click-drag marquee did not select both timeline items");

    timeline.setPlayhead(0.80, true);
    foreach (_; 0 .. 120)
    {
        editor.tickTree(0.02);
        if (preview.hasCompositionFrame()) break;
        Thread.sleep(20.msecs);
    }
    driver.doubleClick(globalCenter(preview));
    assert(timeline.selectedTrack() == textTrack && timeline.selectedIndex() == 0,
        "Preview double-click did not select the top text item");
    foreach (_; 0 .. 200)
    {
        editor.tickTree(0.02);
        if (textField.focused() && preview.inlineTextEditing()) break;
        Thread.sleep(10.msecs);
    }
    assert(textField.focused() && preview.inlineTextEditing(),
        "Preview double-click did not activate the live title layer");
    driver.click(globalCenter(inlineDone));
    assert(!preview.inlineTextEditing(),
        "Done did not close the inline text editor before canvas transforms");
    assert(preview.titleEditorForTesting(firstTitleId) is textField,
        "Done replaced the title instead of keeping the same live layer");
    assert(textField.visible() && textField.readOnly(),
        "The live title layer did not remain visible after editing");

    // Move the selected text directly on the composition canvas. Begin a few
    // pixels away from the prior double-click point so click counting cannot
    // reinterpret the drag as a third click.
    const previewCenter = globalCenter(preview);
    const dragStart = Point(previewCenter.x + 18, previewCenter.y);
    const beforeX = model.trackValue(textTrack).clips[0].positionX;
    const beforeY = model.trackValue(textTrack).clips[0].positionY;
    driver.drag(dragStart, Point(dragStart.x + 64, dragStart.y + 28), 12);
    const movedText = model.trackValue(textTrack).clips[0];
    assert(fabs(movedText.positionX - beforeX) > 0.01 ||
        fabs(movedText.positionY - beforeY) > 0.01,
        "Dragging text in Composition Preview did not update its transform");
    assert(model.trackValue(textTrack).clips.length == 2,
        "Canvas dragging created an extra text item");

    // A split item moved after a silent gap must schedule its future audio
    // boundary. The old player stopped checking after the left item ended and
    // required another seek or Play click before sound returned.
    const gapTrack = TrackAddress(TrackKind.video,
        model.addTrack(TrackKind.video));
    const gapIndex = model.insertClip(0, gapTrack, 100.0);
    assert(gapIndex >= 0);
    const gapRight = model.splitAt(gapTrack, 101.0);
    assert(gapRight >= 0);
    int movedGapRight;
    assert(model.moveClipToTime(gapTrack, gapRight, gapTrack, 103.0,
        movedGapRight));
    assert(fabs(editor.nextTimelineAudioStartForTesting(101.10) - 103.0) < 0.001,
        "Live audio did not schedule the next item after a split/move gap");

    // Project Media focus must not replace the timeline monitor with a source
    // frame. Composition Preview remains the timeline at all times.
    const timelineFrameTitle = preview.frameTitleForTesting();
    driver.click(mediaRowPoint(mediaList, 0));
    foreach (_; 0 .. 20) editor.tickTree(0.02);
    assert(preview.frameTitleForTesting() == timelineFrameTitle,
        "Selecting Project Media replaced the timeline composition preview");

    writeln("[editor-smoke] text selection, canvas transform, and timeline-only preview");

    // Virtualized painting must not scale with the full clip count.
    auto largeVideo = model.cloneTracks(TrackKind.video);
    largeVideo[0].clips = new TimelineClip[20_000];
    foreach (index, ref clip; largeVideo[0].clips)
    {
        clip.id = 1_000_000 + index;
        clip.assetIndex = 0;
        clip.start = cast(double) index * 0.05;
        clip.inPoint = 0.0;
        clip.outPoint = 0.04;
        clip.scale = 1.0;
        clip.opacity = 1.0;
    }
    model.restoreTimeline(largeVideo, model.cloneTracks(TrackKind.audio));
    timeline.modelChanged();
    timeline.setPlayhead(0.0, false);
    assert(driver.paint());
    assert(timeline.lastPaintedClipCountForTesting() < 400,
        "Timeline paint traversed the full 20,000-clip track instead of the viewport");

    writeln("Aurora Cut multi-track editor smoke test passed.");
    return 0;
}
