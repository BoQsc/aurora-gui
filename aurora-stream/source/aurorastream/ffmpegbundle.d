module aurorastream.ffmpegbundle;

import std.conv : to;
import std.file : exists, mkdirRecurse, read, tempDir, write;
import std.path : buildPath;
import std.process : environment;

version (BundledFfmpeg)
{
    private immutable ubyte[] _ffmpegBytes = cast(ubyte[]) import("ffmpeg.exe");
    private immutable ubyte[] _ffprobeBytes = cast(ubyte[]) import("ffprobe.exe");
}

private string bundleDirectory()
{
    version (BundledFfmpeg)
    {
        // Content-address the pair so a new release never reuses or overwrites
        // an older executable that happens to have the same byte length. This
        // also permits upgrades while a previous FFmpeg process still holds
        // its extracted image open.
        return buildPath(tempDir(), "Aurora-Stream-ffmpeg-" ~
            bundleHash(_ffmpegBytes).to!string ~ "-" ~
            bundleHash(_ffprobeBytes).to!string);
    }
    else
    {
        return buildPath(tempDir(), "Aurora-Stream-ffmpeg");
    }
}

private ulong bundleHash(const(ubyte)[] bytes)
{
    ulong hash = 1_469_598_103_934_665_603UL;
    foreach (value; bytes)
    {
        hash ^= value;
        hash *= 1_099_511_628_211UL;
    }
    return hash;
}

private bool writeAndVerify(string path, const(ubyte)[] bytes)
{
    try
    {
        if (exists(path))
        {
            const existing = cast(ubyte[]) read(path);
            if (existing == bytes) return true;
        }
        write(path, bytes);
        const written = cast(ubyte[]) read(path);
        return written == bytes;
    }
    catch (Exception) { return false; }
}

/**
 * Extracts the embedded ffmpeg.exe/ffprobe.exe into a per-user cache directory
 * (idempotent and content-addressed) and returns that directory.
 * Returns "" when this executable was built without an embedded copy, or when
 * extraction failed.
 */
string extractBundledFfmpeg()
{
    version (BundledFfmpeg)
    {
        const dir = bundleDirectory();
        try
        {
            if (!exists(dir)) mkdirRecurse(dir);
            const ffmpegOk = writeAndVerify(
                buildPath(dir, "ffmpeg.exe"), _ffmpegBytes);
            const ffprobeOk = writeAndVerify(
                buildPath(dir, "ffprobe.exe"), _ffprobeBytes);
            return ffmpegOk && ffprobeOk ? dir : "";
        }
        catch (Exception)
        {
            return "";
        }
    }
    else
    {
        return "";
    }
}

/**
 * Puts the bundled ffmpeg/ffprobe folder first on the process PATH so the bare
 * "ffmpeg"/"ffprobe" invocations used everywhere in this app resolve to the
 * embedded copies. Returns true when a bundled copy is now active.
 */
bool enableBundledFfmpeg()
{
    const dir = extractBundledFfmpeg();
    if (dir.length == 0) return false;
    auto path = environment.get("PATH");
    environment["PATH"] = path.length == 0 ? dir : dir ~ ";" ~ path;
    return true;
}
