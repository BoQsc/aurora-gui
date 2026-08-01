module tests.playback_seek_resilience_smoke;

import aurora;
import auroracut.editor : EditorRoot;
import auroracut.model : MediaAsset, TrackAddress, TrackKind;
import auroracut.preview : PreviewWidget;
import auroracut.timeline : TimelineWidget;
import core.thread : Thread;
import core.time : msecs;
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
    assert(widget !is null, "Missing widget: " ~ requestedId);
    return widget;
}

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private bool waitForPlayback(EditorRoot editor, PreviewWidget preview,
    int attempts = 500)
{
    foreach (_; 0 .. attempts)
    {
        editor.tickTree(0.02);
        if (editor.sequencePlaybackForTesting() &&
            !editor.playbackAwaitingFirstFrameForTesting() &&
            preview.playing() && preview.hasFrame())
            return true;
        Thread.sleep(5.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 4,
        "Usage: playback-seek-resilience-smoke <video.mp4> <overlay.mp4> <audio.mp3>");

    WindowOptions options;
    options.title = "Aurora Cut playback seek resilience smoke test";
    options.width = 960;
    options.height = 640;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial seek resilience editor paint failed");

    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto playButton = requireWidget!Button(editor, "play-preview");
    auto model = editor.modelForTesting();

    auto video = new MediaAsset(arguments[1]);
    video.duration = 3.0;
    video.hasVideo = true;
    video.hasAudio = true;
    video.width = 320;
    video.height = 180;
    video.frameRate = 30.0;
    video.audioChannels = 2;
    video.sampleRate = 48_000;
    const videoIndex = model.addAsset(video);

    auto overlay = new MediaAsset(arguments[2]);
    overlay.duration = 1.0;
    overlay.hasVideo = true;
    overlay.width = 160;
    overlay.height = 90;
    overlay.frameRate = 30.0;
    const overlayIndex = model.addAsset(overlay);

    auto audio = new MediaAsset(arguments[3]);
    audio.duration = 1.0;
    audio.hasAudio = true;
    audio.audioChannels = 2;
    audio.sampleRate = 48_000;
    const audioIndex = model.addAsset(audio);

    const v1 = TrackAddress(TrackKind.video, 0);
    const v2 = TrackAddress(TrackKind.video, 1);
    const a1 = TrackAddress(TrackKind.audio, 0);
    assert(model.insertClip(videoIndex, v1, 0.0) == 0);
    assert(model.insertClip(overlayIndex, v2, 0.0) == 0);
    assert(model.insertClip(audioIndex, a1, 0.0) == 0);
    timeline.modelChanged();
    timeline.setPlayhead(0.10, false);
    assert(driver.paint(), "Seek resilience setup paint failed");

    driver.click(globalCenter(playButton));
    assert(waitForPlayback(editor, preview),
        "Live composition did not become ready before seek test");
    const previewRequestsBeforeSeek = editor.previewStatsForTesting().requests;

    editor.beginSeekGestureForTesting();
    foreach (index; 0 .. 7)
    {
        editor.seekForTesting(0.20 + cast(double) index * 0.18);
        // This models real pointer settling without blocking the UI thread.
        editor.tickTree(0.20);
    }
    assert(editor.seekPendingForTesting(),
        "Playhead drag did not leave one coalesced seek pending");
    assert(editor.previewStatsForTesting().requests == previewRequestsBeforeSeek,
        "Active playback seek spawned competing still-frame compositor work");

    editor.endSeekGestureForTesting();
    assert(waitForPlayback(editor, preview),
        "Playback did not resume after releasing the playhead");
    const resumedPosition = editor.playbackPositionForTesting();
    Thread.sleep(120.msecs);
    editor.tickTree(0.12);
    assert(editor.playbackPositionForTesting() > resumedPosition + 0.02,
        "Playhead did not continue advancing after a seek");

    writeln("Aurora Cut playback seek resilience smoke test passed.");
    return 0;
}
