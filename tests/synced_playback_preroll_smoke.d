module tests.synced_playback_preroll_smoke;

import aurora;
import auroracut.editor : EditorRoot;
import auroracut.model : MediaAsset, TrackAddress, TrackKind;
import auroracut.preview : PreviewWidget;
import auroracut.timeline : TimelineWidget;
import core.thread : Thread;
import core.time : msecs;
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

private Point globalCenter(Widget widget)
{
    const origin = widget.localToGlobal(Point(0, 0));
    return Point(origin.x + widget.bounds().width / 2,
        origin.y + widget.bounds().height / 2);
}

private bool waitForPlaybackReady(EditorRoot editor, PreviewWidget preview)
{
    foreach (_; 0 .. 300)
    {
        editor.tickTree(0.02);
        if (editor.directSequencePlaybackForTesting() &&
            !editor.playbackAwaitingFirstFrameForTesting() && preview.playing())
            return true;
        Thread.sleep(5.msecs);
    }
    return false;
}

private bool waitForStillFrame(EditorRoot editor, PreviewWidget preview,
    double expectedTime)
{
    foreach (_; 0 .. 300)
    {
        editor.tickTree(0.02);
        if (preview.hasFrame() && fabs(preview.frameTime() - expectedTime) < 0.02)
            return true;
        Thread.sleep(5.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 2,
        "Usage: synced-playback-preroll-smoke <video-with-audio.mp4>");

    WindowOptions options;
    options.title = "Aurora Cut synced playback preroll smoke test";
    options.width = 960;
    options.height = 640;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial synced playback editor paint failed");

    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto playButton = requireWidget!Button(editor, "play-preview");
    auto model = editor.modelForTesting();

    auto asset = new MediaAsset(arguments[1]);
    asset.duration = 3.0;
    asset.hasVideo = true;
    asset.hasAudio = true;
    asset.width = 320;
    asset.height = 180;
    asset.frameRate = 30.0;
    asset.audioChannels = 2;
    asset.sampleRate = 48_000;
    const assetIndex = model.addAsset(asset);

    const v1 = TrackAddress(TrackKind.video, 0);
    assert(model.insertClip(assetIndex, v1, 0.0) == 0,
        "Video/audio clip could not be inserted on V1");
    timeline.modelChanged();
    timeline.setPlayhead(0.15, false);
    assert(driver.paint(), "Synced playback setup paint failed");
    assert(fabs(timeline.frameStepSecondsForTesting(0.15) - 1.0 / 30.0) <
        0.000_001, "Timeline keyboard frame step is not one source frame");
    const steppedTime = 0.15 + timeline.frameStepSecondsForTesting(0.15);
    const framePreviewRequestsBeforeStep = editor.previewStatsForTesting().requests;
    // Frame steps are coalesced through the debounced pending-preview path, so
    // the request fires after the short dispatch delay rather than inside
    // setPlayhead itself. The frame must render.
    timeline.setPlayhead(steppedTime, true);
    assert(waitForStillFrame(editor, preview, steppedTime),
        "Frame-step preview frame did not render for cache verification");
    const requestsAfterStep = editor.previewStatsForTesting().requests;
    assert(requestsAfterStep >= framePreviewRequestsBeforeStep,
        "Frame-step playhead movement never requested a preview");
    // Moving to another frame renders it too.
    timeline.setPlayhead(0.15, true);
    assert(waitForStillFrame(editor, preview, 0.15),
        "Moving to another frame did not render it");

    const audioRequestsBefore = editor.audioStatsForTesting().requests;
    driver.click(globalCenter(playButton));
    assert(editor.directSequencePlaybackForTesting(),
        "Plain video/audio timeline did not use direct playback");
    assert(editor.playbackAwaitingFirstFrameForTesting(),
        "Video/audio playback skipped first-frame preroll");
    // Audio is started PAUSED concurrently with the video decoder so the
    // press-Play-to-sound latency overlaps the video spawn. The transport must
    // still gate presentation on the first prerolled frame.
    assert(editor.audioStatsForTesting().requests >= audioRequestsBefore,
        "Direct Composition Preview audio request counters regressed");
    assert(editor.playbackAwaitingFirstFrameForTesting() && !preview.playing(),
        "Video/audio playback presented before the first prerolled frame");

    assert(waitForPlaybackReady(editor, preview),
        "Video/audio playback did not leave preroll once synchronized");
    assert(editor.audioStatsForTesting().requests > audioRequestsBefore,
        "Synchronized video/audio playback never requested audio");

    // Pause, let the background prewarm re-warm the paused position, then step
    // forward inside its buffered window: the warm stream must serve the step
    // with no seek state and no still-frame renderer process.
    driver.click(globalCenter(playButton));
    foreach (_; 0 .. 200)
    {
        editor.tickTree(0.02);
        if (!editor.playbackRunningForTesting()) break;
        Thread.sleep(10.msecs);
    }
    assert(!editor.playbackRunningForTesting(),
        "Playback did not pause for the warm-step check");
    bool warmPrewarmActive;
    foreach (_; 0 .. 800)
    {
        editor.tickTree(0.02);
        if (editor.playbackPrewarmActiveForTesting())
        {
            warmPrewarmActive = true;
            break;
        }
        Thread.sleep(10.msecs);
    }
    assert(warmPrewarmActive,
        "Paused sequence playback did not re-warm for the step check");
    bool warmFramesBuffered;
    foreach (_; 0 .. 800)
    {
        editor.tickTree(0.02);
        if (editor.videoStreamHasReadyFramesForTesting())
        {
            warmFramesBuffered = true;
            break;
        }
        Thread.sleep(10.msecs);
    }
    assert(warmFramesBuffered,
        "Paused prewarm never buffered frames for the step check");
    const warmPosition = editor.playbackPositionForTesting();
    const warmRequestsBefore = editor.previewStatsForTesting().requests;
    timeline.setPlayhead(warmPosition + timeline.frameStepSecondsForTesting(warmPosition),
        true);
    assert(!editor.seekPendingForTesting(),
        "Warm frame step entered the seek path instead of the buffered stream");
    assert(editor.previewStatsForTesting().requests == warmRequestsBefore,
        "Warm frame step spawned a still-frame renderer request");
    assert(fabs(preview.frameTime() - (warmPosition +
        timeline.frameStepSecondsForTesting(warmPosition))) < 0.02,
        "Warm frame step did not display the buffered stream frame");

    writeln("Aurora Cut synchronized playback preroll smoke test passed.");
    return 0;
}
