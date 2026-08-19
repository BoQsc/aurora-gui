module auroracut.ffmpegbundle;

import std.file : exists, getSize, mkdirRecurse, tempDir, write;
import std.path : buildPath;
import std.process : environment;
import std.conv : to;

version (BundledFfmpeg)
{
    private immutable ubyte[] _ffmpegBytes = cast(ubyte[]) import("ffmpeg.exe");
    private immutable ubyte[] _ffprobeBytes = cast(ubyte[]) import("ffprobe.exe");
}

private string bundleRoot()
{
    return buildPath(tempDir(), "Aurora-Cut-ffmpeg");
}

/** Directory keyed by the embedded payload sizes so a newer release never
 * reuses (or conflicts with) an older build's extracted files: each distinct
 * bundle gets its own subdirectory, and concurrent app instances writing the
 * same release are byte-identical and idempotent. */
private string bundleDirectory()
{
    version (BundledFfmpeg)
    {
        return buildPath(bundleRoot(),
            "ffmpeg-" ~ to!string(_ffmpegBytes.length) ~ "-" ~
            to!string(_ffprobeBytes.length));
    }
    else
    {
        return bundleRoot();
    }
}

/**
 * Extracts the embedded ffmpeg.exe/ffprobe.exe into a per-user cache directory
 * keyed by the embedded payload sizes, and returns that directory.
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
            // Write only when the target is missing or differs in size. A
            // locked file from a concurrent instance must never block this
            // instance: because the directory is content-keyed, the bytes are
            // already correct on disk, so a failed write is simply ignored.
            writeIfDifferent(buildPath(dir, "ffmpeg.exe"), _ffmpegBytes);
            writeIfDifferent(buildPath(dir, "ffprobe.exe"), _ffprobeBytes);
            return dir;
        }
        catch (Exception)
        {
            // Fall back to the root cache only if the keyed directory failed.
            try
            {
                const fallback = bundleRoot();
                if (!exists(fallback)) mkdirRecurse(fallback);
                writeIfDifferent(buildPath(fallback, "ffmpeg.exe"), _ffmpegBytes);
                writeIfDifferent(buildPath(fallback, "ffprobe.exe"), _ffprobeBytes);
                return fallback;
            }
            catch (Exception)
            {
                return "";
            }
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
        // A concurrent instance may hold a lock on the file; the keyed
        // directory means the on-disk bytes are already correct.
    }
}
