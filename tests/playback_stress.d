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

    writeln("Aurora Cut playback stress test passed. Video requests/processes: ",
        videoStats.requests, "/", videoStats.processesStarted,
        "; still requests/processes: ", previewStats.requests, "/",
        previewStats.processesStarted, ".");
    return 0;
}
