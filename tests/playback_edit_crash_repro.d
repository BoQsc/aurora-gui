module tests.playback_edit_crash_repro;

import aurora;
import auroracut.clipboardimage : setClipboardImageProviderForTesting;
import auroracut.editor : EditorRoot;
import auroracut.model : EditorModel, MediaAsset, TrackAddress, TrackKind;
import auroracut.preview : PreviewWidget;
import auroracut.recentprojects : clearRecentProjects, setRecentProjectsFilePathForTesting;
import auroracut.timeline : TimelineWidget;
import auroracut.util : setApplicationExportDirectoryForTesting,
    setProjectAutosaveDirectoryForTesting;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, mkdirRecurse, remove, rmdirRecurse, tempDir;
import std.path : buildPath;
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

private Point globalCenter(Widget widget)
{
    const bounds = widget.bounds();
    return widget.localToGlobal(Point(bounds.width / 2, bounds.height / 2));
}

private bool waitForSequencePlayback(EditorRoot editor, PreviewWidget preview,
    int attempts = 600)
{
    foreach (_; 0 .. attempts)
    {
        editor.tickTree(0.02);
        if (editor.sequencePlaybackForTesting() &&
            !editor.playbackAwaitingFirstFrameForTesting() &&
            preview.playing() && preview.hasFrame())
            return true;
        Thread.sleep(20.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 2,
        "Usage: playback-edit-crash-repro <video.mp4>");

    WindowOptions options;
    options.title = "Aurora Cut playback edit crash repro";
    options.width = 1440;
    options.height = 960;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    const recentPath = buildPath(tempDir(), "aurora-cut-crash-repro-recent.json");
    const autosavePath = buildPath(tempDir(), "aurora-cut-crash-repro-autosaves");
    const exportPath = buildPath(tempDir(), "aurora-cut-crash-repro-exports");
    if (exists(recentPath)) remove(recentPath);
    if (exists(autosavePath)) rmdirRecurse(autosavePath);
    if (exists(exportPath)) rmdirRecurse(exportPath);
    scope (exit)
    {
        setClipboardImageProviderForTesting(null, null, null);
        setRecentProjectsFilePathForTesting("");
        setProjectAutosaveDirectoryForTesting("");
        setApplicationExportDirectoryForTesting("");
        if (exists(recentPath)) remove(recentPath);
        if (exists(autosavePath)) rmdirRecurse(autosavePath);
        if (exists(exportPath)) rmdirRecurse(exportPath);
    }
    setRecentProjectsFilePathForTesting(recentPath);
    setProjectAutosaveDirectoryForTesting(autosavePath);
    setApplicationExportDirectoryForTesting(exportPath);
    mkdirRecurse(autosavePath);
    mkdirRecurse(exportPath);
    clearRecentProjects();
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial crash-repro paint failed");

    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto playButton = requireWidget!Button(editor, "play-preview");
    auto model = editor.modelForTesting();

    auto video = new MediaAsset(arguments[1]);
    video.duration = 0.5;
    video.hasVideo = true;
    video.hasAudio = false;
    video.width = 320;
    video.height = 180;
    video.frameRate = 30.0;
    const videoIndex = model.addAsset(video);

    const v1 = TrackAddress(TrackKind.video, 0);
    const v2 = TrackAddress(TrackKind.video, 1);
    // Clip A on V1 covers [0, 0.5]; clip B on V2 covers [0.6, 1.1].
    assert(model.insertClip(videoIndex, v1, 0.0) == 0);
    assert(model.insertClip(videoIndex, v2, 0.6) == 0);

    // Start live sequence playback from inside clip B.
    timeline.setPlayhead(0.7, false);
    driver.click(globalCenter(playButton));
    assert(editor.playbackRunningForTesting() && editor.sequencePlaybackForTesting(),
        "Sequence playback did not start");
    assert(waitForSequencePlayback(editor, preview),
        "Sequence playback never reached a playing frame");

    // Regression: during playback, move clip B (on V2) back to start 0.0 so it
    // now ends at 0.5 and the sequence shrinks below the playhead (clip A ends
    // at 0.5, playhead is past 0.7). The compositor rebuild therefore rejects
    // an empty render range. This must not crash the transport; it should stop
    // gracefully instead.
    editor.moveClipForTesting(v2, 0, v2, 0.0);
    foreach (_; 0 .. 40) editor.tickTree(0.02);

    assert(!editor.sequencePlaybackForTesting(),
        "Playback kept running with no content at the playhead after an edit");

    // Extend case: move clip B later during playback so the sequence end grows
    // beyond the pre-edit boundary. Playback must continue to the NEW end
    // instead of stopping at the stale pre-edit last-item position.
    // Reset to the original two-clip layout: A [0, 0.5], B [0.6, 1.1].
    model.removeClip(v1, 0);
    model.removeClip(v2, 0);
    assert(model.insertClip(videoIndex, v1, 0.0) == 0);
    assert(model.insertClip(videoIndex, v2, 0.6) == 0);
    timeline.setPlayhead(0.7, false);
    driver.click(globalCenter(playButton));
    assert(waitForSequencePlayback(editor, preview),
        "Sequence playback did not restart for the extend case");
    // Move clip B (on V2) forward so it now ends at ~3.1 (start 2.6 + 0.5).
    const extendPlaybackEnd = editor.playbackEndForTesting();
    editor.moveClipForTesting(v2, 0, v2, 2.6);
    foreach (_; 0 .. 20) editor.tickTree(0.02);
    // The transport end must be re-derived from the edited model.
    const newEnd = editor.playbackEndForTesting();
    assert(newEnd > extendPlaybackEnd + 0.5,
        "Playback end was not extended after moving the last clip during playback");
    assert(editor.sequencePlaybackForTesting(),
        "Playback stopped after an edit that extended the sequence");

    writeln("Aurora Cut playback edit crash repro passed (no crash on empty render range).");
    return 0;
}
