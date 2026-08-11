module tests.playback_stress;

import auroracut.model : MediaAsset;
import auroracut.playback : PlaybackWorkerStats, VideoFrameStream;
import auroracut.preview : PreviewFrame, PreviewService, PreviewServiceStats;
import core.thread : Thread;
import core.time : msecs;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.stdio : writeln;

private bool waitForVideoFrame(VideoFrameStream stream, out PreviewFrame frame,
    int attempts = 750)
{
    foreach (_; 0 .. attempts)
    {
        if (stream.takeReady(frame) && frame.valid()) return true;
        Thread.sleep(10.msecs);
    }
    return false;
}

private bool waitForStaticFrame(PreviewService service, out PreviewFrame frame,
    int attempts = 1_000)
{
    foreach (_; 0 .. attempts)
    {
        if (service.takeReady(frame) && frame.valid()) return true;
        Thread.sleep(10.msecs);
    }
    return false;
}

private bool waitForPreviewIdle(PreviewService service, int attempts = 1_000)
{
    foreach (_; 0 .. attempts)
    {
        if (!service.busy()) return true;
        Thread.sleep(10.msecs);
    }
    return false;
}

int main(string[] arguments)
{
    assert(arguments.length == 2, "Usage: playback-stress <video.mp4>");
    const path = arguments[1];

    auto stream = new VideoFrameStream();
    scope (exit) stream.shutdown();

    // Give one generation enough time to own a child process, then hammer the
    // selector. start()/stop() must remain event-thread-safe and requests must
    // collapse instead of creating one FFmpeg process per pointer position.
    assert(stream.start(path, 0.0, 1.8, 320, 180, 30, "stress"));
    Thread.sleep(80.msecs);

    auto requestWatch = StopWatch(AutoStart.yes);
    foreach (index; 0 .. 240)
    {
        const seek = cast(double) (index % 150) / 100.0;
        assert(stream.start(path, seek, 0.25, 320, 180, 30, "stress"));
    }
    requestWatch.stop();
    assert(requestWatch.peek.total!"msecs" < 1_000,
        "Rapid video seek requests blocked the caller");

    auto stopWatch = StopWatch(AutoStart.yes);
    stream.stop();
    stopWatch.stop();
    assert(stopWatch.peek.total!"msecs" < 250,
        "Video stop waited for decoder shutdown");

    assert(stream.start(path, 0.55, 0.7, 320, 180, 30, "final"));
    PreviewFrame videoFrame;
    assert(waitForVideoFrame(stream, videoFrame),
        "The final coalesced video request never produced a frame");
    assert(videoFrame.width == 320 && videoFrame.height == 180);

    const videoStats = stream.stats();
    assert(videoStats.requests >= 242);
    assert(videoStats.processesStarted < videoStats.requests / 3,
        "Rapid seeks spawned almost one decoder process per request");
    assert(videoStats.cancellations > 0);

    auto asset = new MediaAsset(path);
    asset.duration = 2.0;
    asset.hasVideo = true;
    asset.width = 640;
    asset.height = 360;
    asset.frameRate = 30.0;

    auto preview = new PreviewService();
    scope (exit) preview.shutdown();
    preview.requestAsset(asset, 0.0, 320, 180);
    Thread.sleep(60.msecs);

    auto stillWatch = StopWatch(AutoStart.yes);
    foreach (index; 0 .. 180)
        preview.requestAsset(asset, cast(double) (index % 170) / 100.0, 320, 180);
    stillWatch.stop();
    assert(stillWatch.peek.total!"msecs" < 1_000,
        "Rapid still-preview requests blocked the caller");

    preview.requestAsset(asset, 0.75, 320, 180);
    PreviewFrame staticFrame;
    assert(waitForStaticFrame(preview, staticFrame),
        "The final coalesced static preview never produced a frame");
    assert(staticFrame.width == 320 && staticFrame.height == 180);

    const previewStats = preview.stats();
    assert(previewStats.requests >= 182);
    assert(previewStats.processesStarted < previewStats.requests / 2,
        "Static scrub requests were not coalesced");
    // A tight request burst may coalesce before the worker starts at all; the
    // process-count bound above is the deterministic regression guard.

    auto centeredPreview = new PreviewService();
    scope (exit) centeredPreview.shutdown();
    const centeredTime = 0.65;
    centeredPreview.requestAsset(asset, centeredTime, 320, 180);
    PreviewFrame centeredFrame;
    assert(waitForStaticFrame(centeredPreview, centeredFrame) &&
        waitForPreviewIdle(centeredPreview),
        "Settled paused frame did not prefetch its adjacent neighborhood");
    const centeredStats = centeredPreview.stats();
    centeredPreview.requestAsset(asset,
        centeredTime + 1.0 / asset.frameRate, 320, 180, null, 1);
    assert(waitForStaticFrame(centeredPreview, centeredFrame),
        "First forward arrow frame was not prefetched");
    centeredPreview.requestAsset(asset,
        centeredTime - 1.0 / asset.frameRate, 320, 180, null, -1);
    assert(waitForStaticFrame(centeredPreview, centeredFrame),
        "First reverse arrow frame was not prefetched");
    const centeredStepStats = centeredPreview.stats();
    assert(centeredStepStats.processesStarted == centeredStats.processesStarted &&
        centeredStepStats.cacheHits >= centeredStats.cacheHits + 2,
        "First arrow step did not use the settled-frame neighborhood cache");

    // Arrow-key stepping supplies a direction hint. One seek must fill a small
    // adjacent-frame neighborhood so the following steps are cache hits rather
    // than one new FFmpeg process per frame.
    auto stepPreview = new PreviewService();
    scope (exit) stepPreview.shutdown();
    const stepStart = 0.40;
    stepPreview.requestAsset(asset, stepStart, 320, 180, null, 1);
    PreviewFrame steppedFrame;
    assert(waitForStaticFrame(stepPreview, steppedFrame),
        "Directional frame-step batch did not produce its requested frame");
    assert(waitForPreviewIdle(stepPreview),
        "Forward adjacent-frame prefetch did not settle");
    const batchStats = stepPreview.stats();
    foreach (offset; 1 .. 6)
    {
        const time = stepStart + cast(double) offset / asset.frameRate;
        stepPreview.requestAsset(asset, time, 320, 180, null, 1);
        assert(waitForStaticFrame(stepPreview, steppedFrame),
            "A prefetched forward frame was not published");
    }
    const forwardStats = stepPreview.stats();
    assert(forwardStats.processesStarted == batchStats.processesStarted,
        "Forward arrow steps launched FFmpeg despite adjacent-frame prefetch");
    assert(forwardStats.cacheHits >= batchStats.cacheHits + 5,
        "Forward arrow steps did not use the adjacent-frame cache");

    auto reversePreview = new PreviewService();
    scope (exit) reversePreview.shutdown();
    const reverseStart = 0.90;
    reversePreview.requestAsset(asset, reverseStart, 320, 180, null, -1);
    assert(waitForStaticFrame(reversePreview, steppedFrame),
        "Reverse frame-step batch did not produce its requested frame");
    assert(waitForPreviewIdle(reversePreview),
        "Reverse adjacent-frame prefetch did not settle");
    const reverseBatchStats = reversePreview.stats();
    foreach (offset; 1 .. 6)
    {
        const time = reverseStart - cast(double) offset / asset.frameRate;
        reversePreview.requestAsset(asset, time, 320, 180, null, -1);
        assert(waitForStaticFrame(reversePreview, steppedFrame),
            "A prefetched reverse frame was not published");
    }
    const reverseStats = reversePreview.stats();
    assert(reverseStats.processesStarted == reverseBatchStats.processesStarted,
        "Reverse arrow steps launched FFmpeg despite adjacent-frame prefetch");
    assert(reverseStats.cacheHits >= reverseBatchStats.cacheHits + 5,
        "Reverse arrow steps did not use the adjacent-frame cache");

    writeln("Aurora Cut playback stress test passed. Video requests/processes: ",
        videoStats.requests, "/", videoStats.processesStarted,
        "; still requests/processes: ", previewStats.requests, "/",
        previewStats.processesStarted, ".");
    return 0;
}
