module tests.paused_scrub_stream_smoke;

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
    assert(widget !is null, "Missing widget: " ~ requestedId);
    return widget;
}

private void drainStills(EditorRoot editor)
{
    foreach (_; 0 .. 3000)
    {
        editor.tickTree(0.02);
        if (!editor.previewBusyForTesting()) return;
        Thread.sleep(2.msecs);
    }
}

int main(string[] arguments)
{
    assert(arguments.length == 2,
        "Usage: paused-scrub-stream-smoke <video.mp4>");

    WindowOptions options;
    options.title = "Aurora Cut paused scrub stream smoke test";
    options.width = 960;
    options.height = 640;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial paused scrub stream paint failed");

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
    const assetIndex = model.addAsset(asset);
    const v1 = TrackAddress(TrackKind.video, 0);
    assert(model.insertClip(assetIndex, v1, 0.0) == 0,
        "Paused scrub stream clip could not be inserted on V1");
    editor.setPreviewQualityForTesting(720);
    timeline.modelChanged();

    // Settle and start the persistent (prewarm) decoder.
    const start = 0.20;
    timeline.setPlayhead(start, true);
    bool prewarmReady;
    foreach (_; 0 .. 800)
    {
        editor.tickTree(0.02);
        if (editor.pausedScrubStreamServingForTesting())
        {
            prewarmReady = true;
            break;
        }
        Thread.sleep(10.msecs);
    }
    assert(prewarmReady,
        "Paused scrub stream never became ready to serve");
    drainStills(editor);

    const processesBefore = editor.previewStatsForTesting().processesStarted;
    const cancellationsBefore = editor.previewStatsForTesting().cancellations;

    // A forward paused scrub must serve from the persistent decoder: the still
    // renderer must not be spawned per frame.
    editor.beginSeekGestureForTesting();
    bool servedForward;
    foreach (step; 0 .. 12)
    {
        timeline.setPlayhead(start + (step + 1) * 0.02, true);
        editor.tickTree(0.02);
        if (editor.pausedScrubStreamServingForTesting()) servedForward = true;
        Thread.sleep(8.msecs);
    }
    editor.endSeekGestureForTesting();
    assert(servedForward, "Forward paused scrub did not use the warm decoder");
    assert(editor.previewStatsForTesting().processesStarted == processesBefore,
        "Forward paused scrub spawned still renderer processes");
    assert(editor.previewStatsForTesting().cancellations == cancellationsBefore,
        "Forward paused scrub churned renderer cancellations");
    const forwardTarget = start + 12 * 0.02;
    assert(preview.hasFrame() &&
        fabs(preview.frameTime() - forwardTarget) < 0.05,
        "Forward paused scrub did not advance the preview frame");

    // A backward move cannot be served by the forward-only decoder and must
    // fall back to the still renderer (and render the target frame).
    timeline.setPlayhead(start, true);
    bool renderedBack;
    foreach (_; 0 .. 400)
    {
        editor.tickTree(0.02);
        if (preview.hasFrame() && fabs(preview.frameTime() - start) < 0.02)
        {
            renderedBack = true;
            break;
        }
        Thread.sleep(5.msecs);
    }
    assert(renderedBack,
        "Backward paused scrub did not render the target frame via the still path");

    writeln("Aurora Cut paused scrub stream smoke test passed.");
    return 0;
}
