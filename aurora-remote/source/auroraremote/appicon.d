module auroraremote.appicon;

import std.file : exists, getSize, mkdirRecurse, tempDir, write;
import std.path : buildPath;

private immutable ubyte[] iconBytes =
    cast(ubyte[]) import("aurora-remote.ico");
private enum string iconFileName = "aurora-remote.ico";
private string cachedPath;

/// Materialize the bundled icon so WindowOptions.iconPath has a real file.
string applicationIconPath()
{
    if (cachedPath.length != 0 && exists(cachedPath)
        && getSize(cachedPath) == iconBytes.length)
        return cachedPath;
    const directory = buildPath(tempDir(), "Aurora-Remote-assets");
    const path = buildPath(directory, iconFileName);
    try
    {
        if (!exists(directory)) mkdirRecurse(directory);
        if (!exists(path) || getSize(path) != iconBytes.length)
            write(path, iconBytes);
        cachedPath = path;
        return path;
    }
    catch (Exception)
    {
        return "";
    }
}
