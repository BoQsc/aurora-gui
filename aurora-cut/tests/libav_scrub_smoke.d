module tests.libav_scrub_smoke;

import aurora;
import auroracut.editor : EditorRoot;
import auroracut.libavdecode : libavDecodeAvailable,
    libavDecodeUnavailableReason, shutdownLibavDecoders;
import auroracut.model : MediaAsset, TrackAddress, TrackKind;
import auroracut.preview : PreviewWidget;
import auroracut.timeline : TimelineWidget;
import core.thread : Thread;
import core.time : MonoTime, msecs;
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
    assert(widget !is null, "Missing widget: " ~ requestedId);
    return widget;
}

private bool waitForFrame(EditorRoot editor, PreviewWidget preview, double target,
    out long micros)
{
    auto clock = MonoTime.currTime;
    foreach (_; 0 .. 4000)
    {
        editor.tickTree(0.01);
        if (preview.hasFrame() && fabs(preview.frameTime() - target) < 0.03)
        {
            micros = (MonoTime.currTime - clock).total!"usecs";
            return true;
        }
        Thread.sleep(1.msecs);
    }
    micros = (MonoTime.currTime - clock).total!"usecs";
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 2, "Usage: libav-scrub-smoke <video.mp4>");
    if (!libavDecodeAvailable())
    {
        writeln("libav scrub unavailable, skipping: ",
            libavDecodeUnavailableReason());
        return 0;
    }

    WindowOptions options;
    options.title = "Aurora Cut libav scrub smoke test";
    options.width = 960;
    options.height = 640;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial libav scrub paint failed");

    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto model = editor.modelForTesting();

    auto asset = new MediaAsset(arguments[1]);
    asset.duration = 1.5;
    asset.hasVideo = true;
    asset.hasAudio = false;
    asset.width = 320;
    asset.height = 180;
    asset.frameRate = 30.0;
    const ai = model.addAsset(asset);
    const v1 = TrackAddress(TrackKind.video, 0);
    assert(model.insertClip(ai, v1, 0.0) == 0, "clip insert failed");
    editor.setPreviewQualityForTesting(720);
    timeline.modelChanged();

    // Force every still through PreviewService (not the forward-only prewarm
    // decoder) so this exercises the random-access in-process decoder path.
    editor.setPlaybackPrewarmEnabledForTesting(false);

    // Prime one frame, then clear stats.
    timeline.setPlayhead(0.2, true);
    long ignored;
    assert(waitForFrame(editor, preview, 0.2, ignored),
        "initial frame did not render");
    foreach (_; 0 .. 20) editor.tickTree(0.02);

    const processesBefore = editor.previewStatsForTesting().processesStarted;
    const requestsBefore = editor.previewStatsForTesting().requests;

    const targets = [1.2, 0.4, 0.9, 0.1, 0.7, 1.4, 0.3, 1.0];
    long worst;
    foreach (target; targets)
    {
        timeline.setPlayhead(target, true);
        long micros;
        const ok = waitForFrame(editor, preview, target, micros);
        if (micros > worst) worst = micros;
        assert(ok, "random-access scrub did not show the target frame");
    }
    writeln("worst random-access frame us=", worst,
        " processesBefore=", processesBefore,
        " processesAfter=", editor.previewStatsForTesting().processesStarted,
        " requestsDelta=", editor.previewStatsForTesting().requests - requestsBefore);

    // The in-process decoder must not have spawned an ffmpeg still process.
    assert(editor.previewStatsForTesting().processesStarted == processesBefore,
        "random-access scrub spawned ffmpeg instead of using the in-process decoder");
    // And it must be far under the ~54 ms spawn floor.
    assert(worst < 40_000, "random-access scrub was not instant");

    shutdownLibavDecoders();
    writeln("Aurora Cut libav scrub smoke test passed.");
    return 0;
}
