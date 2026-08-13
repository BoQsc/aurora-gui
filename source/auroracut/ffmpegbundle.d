module auroracut.ffmpegbundle;

import std.file : exists, getSize, mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;

version (BundledFfmpeg)
{
    private immutable ubyte[] _ffmpegBytes = cast(ubyte[]) import("ffmpeg.exe");
    private immutable ubyte[] _ffprobeBytes = cast(ubyte[]) import("ffprobe.exe");
}

private string bundleDirectory()
{
    return buildPath(tempDir(), "Aurora-Cut-ffmpeg");
}

private void writeIfDifferent(string path, const(ubyte)[] bytes)
{
    try
    {
        if (exists(path) && getSize(path) == bytes.length)
            return;
        write(path, bytes);
    }
    catch (Exception)
    {
    }
}

/**
 * Extracts the embedded ffmpeg.exe/ffprobe.exe into a per-user cache directory
 * (idempotent; size-cached so it runs only once) and returns that directory.
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
            writeIfDifferent(buildPath(dir, "ffmpeg.exe"), _ffmpegBytes);
            writeIfDifferent(buildPath(dir, "ffprobe.exe"), _ffprobeBytes);
            return dir;
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
