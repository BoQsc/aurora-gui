module tests.ytdlp_progress_smoke;

import auroracut.ytdlp : YtDlpDownloadKind, YtDlpDownloadProgress,
    YtDlpDownloadResult, YtDlpDownloadService;
import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.stdio : writeln;
import std.string : startsWith;

int main(string[] arguments)
{
    const url = arguments.length >= 2
        ? arguments[1]
        : "https://www.youtube.com/watch?v=jNQXAC9IVRw";

    auto service = new YtDlpDownloadService();
    scope (exit) service.shutdown();

    assert(service.enqueue("yt-dlp", url, YtDlpDownloadKind.video, 480),
        "Download could not be queued");

    size_t samples;
    size_t downloadSamples;
    size_t normalizeSamples;
    bool sawProcessing;
    bool downloadReached100;
    bool normalizeReached100;
    bool downloadMonotonic = true;
    bool normalizeMonotonic = true;
    double lastDownload = -1.0;
    double lastNormalize = -1.0;
    string lastLabel;
    YtDlpDownloadProgress progress;
    YtDlpDownloadResult result;
    bool finished;
    bool success;

    const deadline = MonoTime.currTime + seconds(180);
    while (MonoTime.currTime < deadline)
    {
        while (service.takeProgress(progress))
        {
            ++samples;
            lastLabel = progress.label;
            if (startsWith(progress.label, "Download"))
            {
                ++downloadSamples;
                if (lastDownload >= 0.0 &&
                    progress.fraction < lastDownload - 0.01)
                    downloadMonotonic = false;
                lastDownload = progress.fraction;
                if (progress.fraction >= 0.98) downloadReached100 = true;
            }
            else if (startsWith(progress.label, "Normalizing"))
            {
                ++normalizeSamples;
                if (lastNormalize >= 0.0 &&
                    progress.fraction < lastNormalize - 0.01)
                    normalizeMonotonic = false;
                lastNormalize = progress.fraction;
                if (progress.fraction >= 0.98) normalizeReached100 = true;
            }
            else if (startsWith(progress.label, "Processing"))
                sawProcessing = true;
        }
        if (service.takeReady(result))
        {
            finished = true;
            success = result.success();
            break;
        }
        Thread.sleep(20.msecs);
    }

    writeln("progress samples: ", samples);
    writeln("download samples: ", downloadSamples);
    writeln("normalize samples: ", normalizeSamples);
    writeln("saw Processing: ", sawProcessing);
    writeln("last label: ", lastLabel);
    writeln("download monotonic: ", downloadMonotonic);
    writeln("normalize monotonic: ", normalizeMonotonic);
    writeln("finished: ", finished, " success: ", success);
    if (result.path.length > 0)
        writeln("output: ", result.path);

    assert(samples >= 3, "Download produced no streaming progress updates");
    assert(downloadSamples >= 2 && downloadReached100,
        "Download phase never showed live progress reaching 100%");
    assert(normalizeSamples >= 2 && normalizeReached100,
        "Normalization phase never showed live progress reaching 100%");
    assert(downloadMonotonic && normalizeMonotonic,
        "A progress phase was not monotonically increasing");
    assert(sawProcessing, "Post-download processing state was not reported");
    assert(finished && success, "Download did not complete: " ~ result.error);

    writeln("Aurora Cut yt-dlp progress smoke test passed.");
    return 0;
}
