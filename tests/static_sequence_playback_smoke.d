module tests.static_sequence_playback_smoke;

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
    foreach (_; 0 .. 250)
    {
        editor.tickTree(0.02);
        if (editor.staticSequencePlaybackForTesting() &&
            !editor.playbackAwaitingFirstFrameForTesting() && preview.playing())
            return true;
        Thread.sleep(5.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 3,
        "Usage: static-sequence-playback-smoke <still-image.png> <audio.mp3>");

    WindowOptions options;
    options.title = "Aurora Cut static playback smoke test";
    options.width = 960;
    options.height = 640;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial static playback editor paint failed");

    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto playButton = requireWidget!Button(editor, "play-preview");
    auto model = editor.modelForTesting();

    auto still = new MediaAsset(arguments[1]);
    still.duration = 3.0;
    still.hasVideo = true;
    still.hasAudio = false;
    still.width = 1254;
    still.height = 1254;
    still.frameRate = 30.0;
    const stillIndex = model.addAsset(still);

    auto audio = new MediaAsset(arguments[2]);
    audio.duration = 3.0;
    audio.hasVideo = false;
    audio.hasAudio = true;
    audio.audioChannels = 2;
    audio.sampleRate = 48_000;
    const audioIndex = model.addAsset(audio);

    const v1 = TrackAddress(TrackKind.video, 0);
    const a1 = TrackAddress(TrackKind.audio, 0);
    assert(model.insertClip(stillIndex, v1, 0.0) == 0,
        "Static still clip could not be inserted on V1");
    assert(model.insertClip(audioIndex, a1, 0.0) == 0,
        "Timeline audio clip could not be inserted on A1");
    timeline.modelChanged();
    timeline.setPlayhead(0.20, false);
    assert(driver.paint(), "Static playback setup paint failed");

    const videoProcessesBefore = editor.videoStatsForTesting().processesStarted;
    const audioRequestsBefore = editor.audioStatsForTesting().requests;

    driver.click(globalCenter(playButton));
    assert(editor.staticSequencePlaybackForTesting(),
        "Still-image timeline did not enter static visual playback");
    assert(!editor.playbackAwaitingFirstFrameForTesting(),
        "Static visual playback incorrectly waited for a video frame stream");
    assert(waitForPlaybackReady(editor, preview),
        "Static visual timeline playback never locked to the live audio clock");

    assert(editor.videoStatsForTesting().processesStarted == videoProcessesBefore,
        "Static visual timeline started a live video frame decoder");
    assert(editor.audioStatsForTesting().requests > audioRequestsBefore,
        "Static visual timeline did not start live timeline audio");

    writeln("Aurora Cut static visual playback smoke test passed.");
    return 0;
}
