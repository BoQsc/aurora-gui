module aurorastream.gamecapturebundle;

import std.conv : to;
import std.file : exists, mkdirRecurse, read, tempDir, write;
import std.path : buildPath;

version (BundledGameCapture)
private immutable ubyte[] _gameCaptureHookBytes =
    cast(ubyte[]) import("gamecaphook.dll");

private string bundleDirectory()
{
    return buildPath(tempDir(), "Aurora-Stream-gamecapture");
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

/// Extracts the injectable hook from a single-exe build. Development builds
/// deliberately return an empty path and use the staged DLL beside the exe.
string extractBundledGameCaptureHook()
{
    version (BundledGameCapture)
    {
        const dir = bundleDirectory();
        try
        {
            if (!exists(dir)) mkdirRecurse(dir);
            // Content-addressed names avoid reusing a stale same-size DLL and
            // allow an updated single-exe release to extract while an older
            // hook file is still locked by a game process.
            const path = buildPath(dir, "gamecaphook-" ~
                bundleHash(_gameCaptureHookBytes).to!string ~ ".dll");
            return writeAndVerify(path, _gameCaptureHookBytes) ? path : "";
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
