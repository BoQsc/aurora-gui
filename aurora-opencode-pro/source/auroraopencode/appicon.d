module auroraopencode.appicon;

import std.file : exists, getSize, mkdirRecurse, tempDir, thisExePath, write;
import std.path : buildPath, dirName;

/**
 * The application icon, embedded in the executable at build time.
 *
 * `WindowOptions.iconPath` takes a path to an `.ico` file, so the bytes are
 * carried inside the binary (via D's string import) and unpacked beside the
 * user's temp directory on demand. That keeps a single-file build's
 * window/taskbar/alt-tab icon working without an `assets` folder next to the
 * `.exe`; a real file on disk still wins when one is present.
 */
private immutable ubyte[] _iconBytes =
    cast(ubyte[]) import("aurora-opencode-pro.ico");

/// Cached extraction path, so the temp file is resolved once per process.
private string _cachedPath;

/// File name used both for the shipped asset and the extracted temp copy.
private enum string iconFileName = "aurora-opencode-pro.ico";

/**
 * Resolve a usable `aurora-opencode-pro.ico` for this run, or "" when none can
 * be produced (in which case the window falls back to the OS default icon).
 *
 * Search order: the working-directory `assets` folder, the `assets` folder
 * beside the executable, then the icon embedded in this binary.
 */
string applicationIconPath()
{
    if (_cachedPath.length > 0) return _cachedPath;

    const local = buildPath("assets", iconFileName);
    if (exists(local)) return _cachedPath = local;

    try
    {
        const beside = buildPath(dirName(thisExePath()), iconFileName);
        if (exists(beside)) return _cachedPath = beside;
    }
    catch (Exception)
    {
    }

    return _cachedPath = extractEmbeddedIcon();
}

/// Write the embedded bytes to a per-user temp file (idempotent, size-cached)
/// and return its path; "" on failure.
private string extractEmbeddedIcon()
{
    if (_iconBytes.length == 0) return "";
    const dir = buildPath(tempDir(), "Aurora-OpenCode-assets");
    const path = buildPath(dir, iconFileName);
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
