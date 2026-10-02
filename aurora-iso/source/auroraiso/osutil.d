/**
 * Small platform helpers: open a file with its default application and find the
 * user's Downloads folder.
 */
module auroraiso.osutil;

import std.file : exists, tempDir;
import std.path : buildPath;
import std.process : environment;
import std.string : replace;
import std.utf : toUTF16z;

version (Windows)
{
    private extern(Windows)
    {
        alias void* HWND;
        alias void* HINSTANCE;
        alias wchar WCHAR;
        alias const(WCHAR)* LPCWSTR;
        HINSTANCE ShellExecuteW(HWND window, LPCWSTR operation, LPCWSTR file,
            LPCWSTR parameters, LPCWSTR directory, int showCommand);
    }

    /// Open a path with the operating system's default handler.
    void openPathWithShell(string path)
    {
        ShellExecuteW(null, "open".toUTF16z, path.toUTF16z, null, null, 1);
    }
}
else
{
    void openPathWithShell(string path)
    {
    }
}

/// Best-effort Downloads folder, falling back to the user profile or temp.
string downloadsDirectory()
{
    version (Windows)
    {
        auto profile = environment.get("USERPROFILE", "");
        if (profile.length > 0)
        {
            auto candidate = buildPath(profile, "Downloads");
            if (exists(candidate))
                return candidate;
        }
    }
    return tempDir();
}

/// A private working directory for extractions.
string workingDirectory()
{
    return buildPath(tempDir(), "aurora-iso");
}
