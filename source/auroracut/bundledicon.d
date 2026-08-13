module auroracut.bundledicon;

import std.file : exists, getSize, mkdirRecurse, tempDir, write;
import std.path : buildPath;

version (BundledFfmpeg)
{
    private immutable ubyte[] _iconBytes = cast(ubyte[]) import("aurora-cut.ico");
}

/**
 * Returns the path to the app icon embedded in this executable, extracted to a
 * per-user cache directory on first use (size-cached, idempotent). Returns ""
 * when the executable was built without an embedded icon.
 */
string bundledIconPath()
{
    version (BundledFfmpeg)
    {
        const dir = buildPath(tempDir(), "Aurora-Cut-assets");
        const path = buildPath(dir, "aurora-cut.ico");
        try
        {
            if (!exists(dir)) mkdirRecurse(dir);
            if (!exists(path) || getSize(path) != _iconBytes.length)
                write(path, _iconBytes);
            return path;
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
