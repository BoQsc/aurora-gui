module aurorastream.browser;

import std.conv : to;
import std.process : Config, spawnProcess;

version (Windows)
{
    import std.utf : toUTF16z;
    pragma(lib, "shell32");

    private alias HINSTANCE = void*;
    extern (Windows) HINSTANCE ShellExecuteW(void* window,
        const(wchar)* operation, const(wchar)* file,
        const(wchar)* parameters, const(wchar)* directory, int showCommand);
}

/** Opens an HTTP or HTTPS address through the operating system's default browser. */
bool openExternalUrl(string url, out string error)
{
    error = "";
    if (url.length == 0)
    {
        error = "The browser address is empty.";
        return false;
    }

    try
    {
        string[] arguments;
        version (Windows)
            arguments = ["explorer.exe", url];
        else version (OSX)
            arguments = ["open", url];
        else
            arguments = ["xdg-open", url];

        spawnProcess(arguments, cast(const string[string]) null,
            Config.detached | Config.suppressConsole);
        return true;
    }
    catch (Exception failure)
    {
        error = failure.msg;
        return false;
    }
}

/** Opens the manual A/V pacing diagnostic in a visible terminal window. */
bool openPacingDiagnostic(out string error)
{
    error = "";
    version (Windows)
    {
        try
        {
            const result = cast(size_t) ShellExecuteW(null,
                toUTF16z("open"), toUTF16z("CHECK-STREAM-PACING.bat"),
                null, null, 1);
            if (result <= 32)
            {
                error = "Windows could not open CHECK-STREAM-PACING.bat (ShellExecute code " ~
                    result.to!string ~ ").";
                return false;
            }
            return true;
        }
        catch (Exception failure)
        {
            error = failure.msg;
            return false;
        }
    }
    else
    {
        error = "The A/V pacing diagnostic currently requires Windows.";
        return false;
    }
}
