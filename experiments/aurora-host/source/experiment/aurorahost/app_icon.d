module experiment.aurorahost.app_icon;

import std.file : exists, getSize, mkdirRecurse, tempDir, thisExePath, write;
import std.path : buildPath, dirName;

/**
 * The application icon, embedded in the executable at build time.
 *
 * WindowOptions.iconPath needs a path, so the ICO bytes are carried inside the
 * binary and unpacked to a per-user temp file on demand. A real assets file
 * still wins when one is present, which keeps local icon iteration simple.
 */
private immutable ubyte[] _iconBytes =
    cast(ubyte[]) import("aurora-host.ico");

private enum string iconFileName = "aurora-host.ico";
private string _cachedPath;

/// Resolve a usable `aurora-host.ico` for this run, or "" when unavailable.
string applicationIconPath()
{
    if (_cachedPath.length > 0)
        return _cachedPath;

    const local = buildPath("assets", iconFileName);
    if (exists(local))
        return _cachedPath = local;

    try
    {
        const beside = buildPath(dirName(thisExePath()), iconFileName);
        if (exists(beside))
            return _cachedPath = beside;
    }
    catch (Exception)
    {
    }

    return _cachedPath = extractEmbeddedIcon();
}

/// Write the embedded ICO to a per-user temp file and return its path.
private string extractEmbeddedIcon()
{
    if (_iconBytes.length == 0)
        return "";

    const directory = buildPath(tempDir(), "Aurora-Host-assets");
    const path = buildPath(directory, iconFileName);
    try
    {
        if (!exists(directory))
            mkdirRecurse(directory);
        if (!exists(path) || getSize(path) != _iconBytes.length)
            write(path, _iconBytes);
        return path;
    }
    catch (Exception)
    {
        return "";
    }
}
