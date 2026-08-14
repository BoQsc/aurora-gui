module aurorastream.browser;

import std.conv : to;
import std.file : exists;
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

/// Browser choices for the Twitch/YouTube quick-link context menu.
/// `default` hands the URL to the operating system's default handler.
enum BrowserChoice : ubyte
{
    defaultBrowser,
    chrome,
    edge,
    firefox
}

/** Human-readable label shown in the quick-link context menu. */
string browserChoiceLabel(BrowserChoice choice) @safe pure nothrow
{
    switch (choice)
    {
        case BrowserChoice.chrome: return "Google Chrome";
        case BrowserChoice.edge: return "Microsoft Edge";
        case BrowserChoice.firefox: return "Firefox";
        default: return "Default browser";
    }
}

/** Stable settings-file key for a browser choice. */
string browserChoiceKey(BrowserChoice choice) @safe pure nothrow
{
    switch (choice)
    {
        case BrowserChoice.chrome: return "chrome";
        case BrowserChoice.edge: return "edge";
        case BrowserChoice.firefox: return "firefox";
        default: return "default";
    }
}

BrowserChoice browserChoiceFromKey(string key) @safe pure nothrow
{
    if (key == "chrome") return BrowserChoice.chrome;
    if (key == "edge") return BrowserChoice.edge;
    if (key == "firefox") return BrowserChoice.firefox;
    return BrowserChoice.defaultBrowser;
}

/** Installed executable for a concrete browser, or "" when not found. */
string browserExecutablePath(BrowserChoice choice) @safe
{
    if (choice == BrowserChoice.defaultBrowser) return "";
    version (Windows)
    {
        import std.process : environment;
        static string probe(const string[] candidates)
        {
            foreach (candidate; candidates)
            {
                try if (exists(candidate)) return candidate;
                catch (Exception) {}
            }
            return "";
        }
        const programFiles = environment.get("ProgramFiles", "");
        const programFilesX86 = environment.get("ProgramFiles(x86)", "");
        const localAppData = environment.get("LOCALAPPDATA", "");
        switch (choice)
        {
            case BrowserChoice.chrome:
                return probe([
                    programFiles ~ "\\Google\\Chrome\\Application\\chrome.exe",
                    programFilesX86 ~ "\\Google\\Chrome\\Application\\chrome.exe",
                    localAppData ~ "\\Google\\Chrome\\Application\\chrome.exe"]);
            case BrowserChoice.edge:
                return probe([
                    programFilesX86 ~ "\\Microsoft\\Edge\\Application\\msedge.exe",
                    programFiles ~ "\\Microsoft\\Edge\\Application\\msedge.exe",
                    localAppData ~ "\\Microsoft\\Edge\\Application\\msedge.exe"]);
            case BrowserChoice.firefox:
                return probe([
                    programFiles ~ "\\Mozilla Firefox\\firefox.exe",
                    programFilesX86 ~ "\\Mozilla Firefox\\firefox.exe",
                    localAppData ~ "\\Mozilla Firefox\\firefox.exe"]);
            default: return "";
        }
    }
    else
    {
        return "";
    }
}

/** True when the choice can launch right now (default always can). */
bool isBrowserDetected(BrowserChoice choice) @safe
{
    return choice == BrowserChoice.defaultBrowser ||
        browserExecutablePath(choice).length > 0;
}

/** Installed browsers to offer in the quick-link menu, in display order. */
BrowserChoice[] availableBrowserChoices() @safe
{
    BrowserChoice[] result;
    foreach (choice; [BrowserChoice.defaultBrowser, BrowserChoice.chrome,
        BrowserChoice.edge, BrowserChoice.firefox])
        if (isBrowserDetected(choice)) result ~= choice;
    return result;
}

/** Opens a URL with the chosen browser; default uses the OS handler. */
bool openUrlInBrowser(string url, BrowserChoice choice, out string error)
{
    error = "";
    if (url.length == 0)
    {
        error = "The browser address is empty.";
        return false;
    }
    if (choice != BrowserChoice.defaultBrowser)
    {
        const path = browserExecutablePath(choice);
        if (path.length == 0)
        {
            error = browserChoiceLabel(choice) ~
                " was not found on this computer.";
            return false;
        }
        try
        {
            spawnProcess([path, url], cast(const string[string]) null,
                Config.detached | Config.suppressConsole);
            return true;
        }
        catch (Exception failure)
        {
            error = failure.msg;
            return false;
        }
    }
    return openExternalUrl(url, error);
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
