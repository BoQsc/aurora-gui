module tests.libav_decode_smoke;

import auroracut.libavdecode : decodeLibavRgbFrame, libavDecodeAvailable,
    libavDecodeUnavailableReason, shutdownLibavDecoders;
import core.time : MonoTime;
import std.conv : to;
import std.stdio : writeln;

int main(string[] arguments)
{
    assert(arguments.length == 2, "Usage: libav-decode-smoke <video.mp4>");

    if (!libavDecodeAvailable())
    {
        // Optional accelerator: absent libraries must simply skip, not fail.
        writeln("libav decode unavailable, skipping: ",
            libavDecodeUnavailableReason());
        return 0;
    }

    const path = arguments[1];
    const width = 1280;
    const height = 720;
    auto rgb = new ubyte[width * height * 3];

    // Random-access decodes in a deliberately non-monotonic order.
    const targets = [0.2, 0.9, 0.4, 1.3, 0.6, 0.1, 1.4, 0.3];
    long totalMicros;
    foreach (target; targets)
    {
        auto clock = MonoTime.currTime;
        const ok = decodeLibavRgbFrame(path, target, width, height, rgb);
        const micros = (MonoTime.currTime - clock).total!"usecs";
        totalMicros += micros;
        assert(ok, "decode failed at " ~ target.to!string);
        writeln("target=", target, " us=", cast(long) micros);
    }
    const averageMicros = totalMicros / targets.length;
    writeln("average us=", averageMicros);

    // The whole point: random access must be far below the ~54 ms process-spawn
    // floor of the ffmpeg path. Allow generous headroom for a loaded host.
    assert(averageMicros < 20_000,
        "libav random-access decode is not instant enough");

    // A warm decode of the same frame must be non-empty (not all black) so we
    // know a real picture was produced.
    long luma;
    foreach (i; 0 .. rgb.length) luma += rgb[i];
    assert(luma > 0, "decoded frame is empty");

    shutdownLibavDecoders();
    writeln("Aurora Cut libav decode smoke test passed.");
    return 0;
}
