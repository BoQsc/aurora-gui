module auroradesktop.desktopfiles;

/**
 * Enumerates the real Windows Desktop folders so the Aurora desktop shows the
 * same files/shortcuts/folders the user has on their actual desktop, instead of
 * a hard-coded icon set.
 */

import std.algorithm : sort;
import std.file : dirEntries, SpanMode, exists;
import std.path : buildPath, baseName;
import std.process : environment;
import std.utf : toUTF16z;

/// One item on the real desktop.
struct DesktopEntry
{
    /// File or folder name (no path).
    string name;
    /// Absolute path used to open the item.
    string path;
    /// True for directories.
    bool directory;
}

version (Windows)
{
    import core.sys.windows.windef : DWORD;
    import core.sys.windows.winbase : GetFileAttributesW;
    import core.sys.windows.winnt : INVALID_FILE_ATTRIBUTES;
    private enum DWORD FILE_ATTRIBUTE_HIDDEN = 0x2;
    private enum DWORD FILE_ATTRIBUTE_SYSTEM = 0x4;
}

/// Items in %USERPROFILE%\Desktop and %PUBLIC%\Desktop, excluding hidden and
/// system entries, sorted by name. Empty on non-Windows.
DesktopEntry[] enumerateDesktopEntries()
{
    DesktopEntry[] result;
    version (Windows)
    {
        string[] roots;
        const userProfile = environment.get("USERPROFILE", "");
        const publicDir = environment.get("PUBLIC", "");
        if (userProfile.length > 0) roots ~= buildPath(userProfile, "Desktop");
        if (publicDir.length > 0) roots ~= buildPath(publicDir, "Desktop");

        foreach (root; roots)
        {
            if (!exists(root)) continue;
            try
            {
                foreach (entry; dirEntries(root, SpanMode.shallow))
                {
                    const name = baseName(entry.name);
                    if (name.length == 0 || name == "desktop.ini") continue;
                    const attributes = GetFileAttributesW(entry.name.toUTF16z);
                    if (attributes != INVALID_FILE_ATTRIBUTES &&
                        (attributes & (FILE_ATTRIBUTE_HIDDEN |
                            FILE_ATTRIBUTE_SYSTEM)) != 0)
                        continue;
                    DesktopEntry item;
                    item.name = name;
                    item.path = entry.name;
                    item.directory = entry.isDir;
                    result ~= item;
                }
            }
            catch (Exception)
            {
            }
        }
        result.sort!((a, b) => a.name < b.name);
    }
    return result;
}
