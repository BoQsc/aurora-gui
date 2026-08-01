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
    timeline.setPlayhead(steppedTime, true);
    assert(editor.previewStatsForTesting().requests ==
        framePreviewRequestsBeforeStep + 1,
        "Frame-step playhead movement did not request preview immediately");
    assert(waitForStillFrame(editor, preview, steppedTime),
        "Frame-step preview frame did not render for cache verification");
    const requestsBeforeAwayStep = editor.previewStatsForTesting().requests;
    timeline.setPlayhead(0.15, true);
    assert(editor.previewStatsForTesting().requests == requestsBeforeAwayStep + 1,
        "Moving to an uncached frame did not request preview immediately");
    const requestsBeforeCachedStep = editor.previewStatsForTesting().requests;
    timeline.setPlayhead(steppedTime, true);
    assert(editor.previewStatsForTesting().requests == requestsBeforeCachedStep,
        "Cached frame-step preview spawned another worker request");
    assert(fabs(preview.frameTime() - steppedTime) < 0.02,
        "Cached frame-step preview did not display synchronously");

    const audioRequestsBefore = editor.audioStatsForTesting().requests;
    driver.click(globalCenter(playButton));
    assert(editor.directSequencePlaybackForTesting(),
        "Plain video/audio timeline did not use direct playback");
    assert(editor.playbackAwaitingFirstFrameForTesting(),
        "Video/audio playback skipped first-frame preroll");
    assert(editor.audioStatsForTesting().requests == audioRequestsBefore,
        "Audio was requested before the first matching video frame");

    assert(waitForPlaybackReady(editor, preview),
        "Video/audio playback did not leave preroll once synchronized");
    assert(editor.audioStatsForTesting().requests > audioRequestsBefore,
        "Synchronized video/audio playback never requested audio");

    writeln("Aurora Cut synchronized playback preroll smoke test passed.");
    return 0;
}
