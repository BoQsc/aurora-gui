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
        alias void* HANDLE;
        alias uint DWORD;
        alias wchar WCHAR;
        alias const(WCHAR)* LPCWSTR;
        alias WCHAR* LPWSTR;
        HINSTANCE ShellExecuteW(HWND window, LPCWSTR operation, LPCWSTR file,
            LPCWSTR parameters, LPCWSTR directory, int showCommand);
        DWORD GetModuleFileNameW(HANDLE moduleHandle, LPWSTR filename, DWORD size);
    }

    /// Open a path with the operating system's default handler.
    void openPathWithShell(string path)
    {
        ShellExecuteW(null, "open".toUTF16z, path.toUTF16z, null, null, 1);
    }

    /// Absolute path of the running executable.
    string executablePath()
    {
        WCHAR[1024] buffer;
        const length = GetModuleFileNameW(null, buffer.ptr, 1024);
        dchar[] chars;
        foreach (i; 0 .. length)
            chars ~= cast(dchar) buffer[i];
        import std.utf : toUTF8;
        return toUTF8(chars);
    }

    /**
     * Relaunch this executable elevated with the given command line. Returns the
     * ShellExecute code: > 32 on success, 1223 when the user declines the UAC
     * prompt, other values on failure.
     */
    int shellExecuteRunAs(string parameters)
    {
        return cast(int) ShellExecuteW(null, "runas".toUTF16z,
            executablePath.toUTF16z, parameters.toUTF16z, null, 1);
    }
}
else
{
    void openPathWithShell(string path)
    {
    }

    string executablePath()
    {
        return "";
    }

    int shellExecuteRunAs(string parameters)
    {
        return 0;
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
