module tests.ytdlp_progress_smoke;

import auroracut.ytdlp : YtDlpDownloadKind, YtDlpDownloadProgress,
    YtDlpDownloadResult, YtDlpDownloadService;
import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.file : remove;
import std.stdio : writeln;

int main(string[] arguments)
{
    const url = arguments.length >= 2
        ? arguments[1]
        : "https://www.youtube.com/watch?v=jNQXAC9IVRw";

    auto service = new YtDlpDownloadService();
    scope (exit) service.shutdown();

    assert(service.enqueue("yt-dlp", url, YtDlpDownloadKind.video, 480),
        "Download could not be queued");

    size_t progressSamples;
    double lastFraction = -1.0;
    bool monotonic = true;
    string lastPercent;
    YtDlpDownloadProgress progress;
    YtDlpDownloadResult result;
    bool finished;
    bool success;

    const deadline = MonoTime.currTime + seconds(180);
    while (MonoTime.currTime < deadline)
    {
        while (service.takeProgress(progress))
        {
            ++progressSamples;
            lastPercent = progress.percentText;
            if (lastFraction >= 0.0 && progress.fraction < lastFraction - 0.01)
                monotonic = false;
            lastFraction = progress.fraction;
        }
        if (service.takeReady(result))
        {
            finished = true;
            success = result.success();
            break;
        }
        Thread.sleep(20.msecs);
    }

    writeln("progress samples: ", progressSamples);
    writeln("last percent: ", lastPercent);
    writeln("last fraction: ", lastFraction);
    writeln("monotonic: ", monotonic);
    writeln("finished: ", finished);
    writeln("success: ", success);
    if (result.path.length > 0)
        writeln("output: ", result.path);

    assert(progressSamples >= 3,
        "Download produced no streaming progress updates");
    assert(monotonic, "Download progress was not monotonically increasing");
    assert(lastFraction >= 0.98,
        "Download never reached ~100% (last=" ~ lastPercent ~ ")");
    assert(finished && success, "Download did not complete: " ~ result.error);

    writeln("Aurora Cut yt-dlp progress smoke test passed.");
    return 0;
}
