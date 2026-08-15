module gamecap_live_probe;

/// Background-only diagnostic for attaching the production D3D11 game-capture
/// session to an already-running window. It never moves, activates, minimizes,
/// or otherwise changes the target window.

import aurorastream.gamecapture : GameCaptureFrame, GameCaptureSession;
import core.sys.windows.windows : GetTickCount;
import core.thread : Thread;
import core.time : msecs;
import std.conv : to;
import std.file : write;
import std.stdio : writeln;

private struct PixelStats
{
    size_t sampled;
    size_t black;
    size_t white;
    size_t colored;
    ulong fingerprint;
}

private PixelStats inspectPixels(const ubyte[] pixels)
{
    PixelStats result;
    enum size_t stridePixels = 31;
    foreach (offset; 0 .. (pixels.length / 4 + stridePixels - 1) /
        stridePixels)
    {
        const index = offset * stridePixels * 4;
        if (index + 3 >= pixels.length) break;
        const b = pixels[index];
        const g = pixels[index + 1];
        const r = pixels[index + 2];
        ++result.sampled;
        if (r <= 8 && g <= 8 && b <= 8) ++result.black;
        if (r >= 247 && g >= 247 && b >= 247) ++result.white;
        if ((r > g + 12 || g > r + 12 || b > r + 12 || b > g + 12))
            ++result.colored;
        result.fingerprint = (result.fingerprint ^ r) * 1_099_511_628_211UL;
        result.fingerprint = (result.fingerprint ^ g) * 1_099_511_628_211UL;
        result.fingerprint = (result.fingerprint ^ b) * 1_099_511_628_211UL;
    }
    return result;
}

private void writePpm(string path, uint width, uint height,
    const ubyte[] bgra)
{
    auto header = cast(ubyte[]) ("P6\n" ~ width.to!string ~ " " ~
        height.to!string ~ "\n255\n").dup;
    auto output = new ubyte[header.length +
        cast(size_t) width * height * 3];
    output[0 .. header.length] = header;
    size_t destination = header.length;
    for (size_t source = 0; source + 3 < bgra.length; source += 4)
    {
        output[destination++] = bgra[source + 2];
        output[destination++] = bgra[source + 1];
        output[destination++] = bgra[source];
    }
    write(path, output);
}

void main(string[] args)
{
    if (args.length < 4)
        throw new Exception(
            "usage: gamecap_live_probe <hwnd> <gamecaphook.dll> <output.ppm> [duration-ms]");

    const durationMs = args.length >= 5 ? args[4].to!uint : 3_000;
    auto session = new GameCaptureSession(args[2]);
    scope(exit) session.shutdown();

    string error;
    if (!session.start(args[1], error))
        throw new Exception(error);

    const started = GetTickCount();
    ulong frames;
    ulong changing;
    ulong previousFingerprint;
    uint lastWidth;
    uint lastHeight;
    ubyte[] latestPixels;
    PixelStats latestStats;
    while (GetTickCount() - started < durationMs)
    {
        GameCaptureFrame frame;
        if (!session.readLatestFrame(frame))
        {
            Thread.sleep(2.msecs);
            continue;
        }
        scope(exit) session.releaseFrame(frame);
        ++frames;
        const stats = inspectPixels(frame.pixels);
        if (previousFingerprint != 0 && stats.fingerprint != previousFingerprint)
            ++changing;
        previousFingerprint = stats.fingerprint;
        lastWidth = frame.width;
        lastHeight = frame.height;
        latestPixels = frame.pixels.dup;
        latestStats = stats;
    }

    if (latestPixels.length > 0)
        writePpm(args[3], lastWidth, lastHeight, latestPixels);
    const metrics = session.metrics();
    writeln("hwnd=", args[1],
        " frames=", frames,
        " changing=", changing,
        " received=", metrics.framesReceived,
        " superseded=", metrics.framesSuperseded,
        " gaps=", metrics.sequenceGaps,
        " hook_dropped=", metrics.hookDroppedFrames,
        " size=", lastWidth, "x", lastHeight,
        " sampled=", latestStats.sampled,
        " black=", latestStats.black,
        " white=", latestStats.white,
        " colored=", latestStats.colored,
        " output=", args[3]);
    if (frames == 0)
        throw new Exception(session.failure().length > 0 ? session.failure() :
            "No frames arrived from the selected swapchain.");
}
