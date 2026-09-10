module tests.composition_prefetch_smoke;

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

private bool waitForCompositionFrame(EditorRoot editor, PreviewWidget preview,
    double expectedTime)
{
    foreach (_; 0 .. 800)
    {
        editor.tickTree(0.02);
        if (preview.hasFrame() && fabs(preview.frameTime() - expectedTime) < 0.02)
            return true;
        Thread.sleep(5.msecs);
    }
    return false;
}

private bool waitForPreviewIdle(EditorRoot editor)
{
    foreach (_; 0 .. 3000)
    {
        editor.tickTree(0.02);
        if (!editor.previewBusyForTesting()) return true;
        Thread.sleep(5.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 2,
        "Usage: composition-prefetch-smoke <video.mp4>");

    WindowOptions options;
    options.title = "Aurora Cut composition prefetch smoke test";
    options.width = 960;
    options.height = 640;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    scope (exit) editor.shutdown();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial composition prefetch paint failed");
    // This smoke exercises the still/composition renderer + its neighbor
    // prefetch. Disable the persistent scrub prewarm so the still path (not the
    // warm decoder) serves the paused frames.
    editor.setPlaybackPrewarmEnabledForTesting(false);

    auto timeline = requireWidget!TimelineWidget(editor, "sequence-timeline");
    auto preview = requireWidget!PreviewWidget(editor, "preview");
    auto model = editor.modelForTesting();

    auto asset = new MediaAsset(arguments[1]);
    asset.duration = 3.0;
    asset.hasVideo = true;
    asset.hasAudio = false;
    asset.width = 320;
    asset.height = 180;
    asset.frameRate = 30.0;
    const assetIndex = model.addAsset(asset);

    const v1 = TrackAddress(TrackKind.video, 0);
    assert(model.insertClip(assetIndex, v1, 0.0) == 0,
        "Composition clip could not be inserted on V1");

    // A transform forces the overlay composition path instead of the plain
    // source-frame path; that is the case the neighbor prefetch targets.
    assert(model.setScale(v1, 0, 0.9),
        "Could not set V1 scale to force the composition path");
    editor.setPreviewQualityForTesting(720);
    timeline.modelChanged();

    // Settle on one composition frame and let the worker finish (including its
    // neighbor prefetch) before measuring.
    const frameStep = 1.0 / 30.0;
    const baseTime = 0.60;
    timeline.setPlayhead(baseTime, true);
    assert(waitForCompositionFrame(editor, preview, baseTime),
        "Settled composition frame never rendered");
    assert(waitForPreviewIdle(editor),
        "Composition preview worker never went idle after the settled frame");

    const processesBefore = editor.previewStatsForTesting().processesStarted;
    const hitsBefore = editor.previewStatsForTesting().cacheHits;

    // The settled frame cached its immediate neighbors, so a one-frame step is
    // a composition-LRU hit with no new FFmpeg process.
    timeline.setPlayhead(baseTime + frameStep, true);
    assert(waitForCompositionFrame(editor, preview, baseTime + frameStep),
        "Forward composition step did not render");
    assert(editor.previewStatsForTesting().cacheHits > hitsBefore,
        "Forward neighbor was not prefetched into the composition cache");
    assert(editor.previewStatsForTesting().processesStarted == processesBefore,
        "Forward neighbor step spawned a new FFmpeg process instead of a cache hit");

    const hitsAfterForward = editor.previewStatsForTesting().cacheHits;
    timeline.setPlayhead(baseTime, true);
    assert(waitForCompositionFrame(editor, preview, baseTime),
        "Backward composition step did not render");
    assert(editor.previewStatsForTesting().cacheHits > hitsAfterForward,
        "Backward neighbor was not prefetched into the composition cache");

    // An active paused scrub must keep the monitor following the cursor instead
    // of freezing until release. The coalescing delay is reset by every pointer
    // move, so the drag path uses an independent cadence and only dispatches
    // when the worker is free (no kill/restart per pixel: cancellations stay
    // flat while several frames render during the gesture).
    assert(waitForPreviewIdle(editor),
        "Composition preview worker never went idle before the scrub test");
    const dragRequestsBefore = editor.previewStatsForTesting().requests;
    const dragProcessesBefore =
        editor.previewStatsForTesting().processesStarted;
    editor.beginSeekGestureForTesting();
    bool scrubProducedFrame;
    foreach (step; 0 .. 60)
    {
        const t = baseTime + frameStep * 2.0 * (step + 1);
        timeline.setPlayhead(t, true);
        editor.tickTree(0.02);
        if (editor.previewStatsForTesting().requests > dragRequestsBefore)
            scrubProducedFrame = true;
        Thread.sleep(5.msecs);
    }
    assert(scrubProducedFrame,
        "An active paused scrub never dispatched a preview frame");
    editor.endSeekGestureForTesting();
    // The still renderer is the fallback path (the prewarm is disabled here), so
    // it must not spawn one FFmpeg per pixel: 60 moves must stay well bounded.
    const dragProcesses = editor.previewStatsForTesting().processesStarted -
        dragProcessesBefore;
    assert(dragProcesses < 12,
        "A paused scrub spawned an FFmpeg process per frame instead of serializing");

    writeln("Aurora Cut composition prefetch smoke test passed.");
    return 0;
}
