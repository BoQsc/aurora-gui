module tests.recompress_smoke;

import auroracut.exporter : ExportJob;
import auroracut.util : absoluteNormalized;
import core.thread : Thread;
import core.time : msecs;
import std.file : exists, remove;
import std.path : buildPath;
import std.stdio : writeln;

int main(string[] arguments)
{
    assert(arguments.length == 3,
        "Usage: recompress-smoke <source.mp4> <output-directory>");

    const outputPath = absoluteNormalized(buildPath(arguments[2], "compressed-crf30.mp4"));
    if (exists(outputPath)) remove(outputPath);

    auto job = new ExportJob();
    scope (exit) job.shutdown();
    assert(job.startRecompress(arguments[1], outputPath, 30),
        "Could not start MP4 recompression");

    foreach (_; 0 .. 600)
    {
        const state = job.state();
        if (state.done && !state.running)
        {
            assert(state.success, "MP4 recompression failed: " ~ state.error);
            assert(state.outputPath == outputPath && exists(outputPath),
                "MP4 recompression did not create the requested output path");
            writeln("Aurora Cut MP4 recompression smoke test passed.");
            return 0;
        }
        Thread.sleep(50.msecs);
    }

    assert(false, "Timed out waiting for MP4 recompression");
}
