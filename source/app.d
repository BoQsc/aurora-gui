module app;

import aurora;
import auroracut.appversion : appDisplayName, appFullVersion, appVersion;
import auroracut.editor : EditorRoot;
import auroracut.util : appLog;
import std.file : append, exists, thisExePath;
import std.path : buildPath, dirName;
import std.stdio : stderr, writeln;

version (Windows)
{
    import core.sys.windows.windows : MB_ICONERROR, MB_OK, MessageBoxW;
    import std.utf : toUTF16z;
}

private void reportStage(string message)
{
    stderr.writeln("[Aurora Cut] ", message);
    stderr.flush();
    appLog(message);
}

private void recordStartupFailure(string details)
{
    try
    {
        append("aurora-cut-startup.log", details ~ "\r\n");
    }
    catch (Exception)
    {
        // Failure to write diagnostics must not replace the real error.
    }

    version (Windows)
    {
        try
        {
            MessageBoxW(null, toUTF16z(details),
                toUTF16z("Aurora Cut startup error"), MB_OK | MB_ICONERROR);
        }
        catch (Throwable)
        {
            // The console and startup log remain available.
        }
    }
}

private string applicationIconPath()
{
    const local = buildPath("assets", "aurora-cut.ico");
    if (exists(local)) return local;
    try
    {
        const besideExecutable = buildPath(dirName(thisExePath()), "assets",
            "aurora-cut.ico");
        if (exists(besideExecutable)) return besideExecutable;
    }
    catch (Exception)
    {
    }
    return local;
}

private int runEditor()
{
    reportStage("Starting " ~ appDisplayName ~ "...");
    reportStage("Creating the application window...");

    WindowOptions options;
    options.title = appDisplayName ~ " — MP4 / MP3 Editor";
    options.iconPath = applicationIconPath();
    options.width = 1440;
    options.height = 900;
    options.resizable = true;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    options.renderer = RendererPreference.automatic;

    auto theme = Theme.dark();
    theme.windowBackground = Color.fromHex(0x14171b);
    theme.panelBackground = Color.fromHex(0x1d2228);
    theme.panelElevated = Color.fromHex(0x272d35);
    theme.fieldBackground = Color.fromHex(0x111419);
    theme.buttonBackground = Color.fromHex(0x303740);
    theme.buttonHover = Color.fromHex(0x3b4551);
    theme.buttonPressed = Color.fromHex(0x242a31);
    theme.border = Color.fromHex(0x444d58);
    theme.accent = Color.fromHex(0x4f8cff);
    theme.selection = Color.fromHex(0x355f9f);
    theme.cornerRadius = 5;
    theme.controlHeight = 36;
    theme.spacing = 7;

    auto window = new GuiWindow(options, theme);
    reportStage("Renderer selected: " ~ window.rendererName());
    if (window.rendererFallbackReason().length > 0)
        reportStage("Renderer fallback: " ~ window.rendererFallbackReason());

    reportStage("Building the editor interface...");
    auto editor = new EditorRoot(window);
    window.setRoot(editor);
    window.onCloseRequested = delegate() {
        editor.shutdown();
        return true;
    };

    reportStage("Showing the editor window.");
    return window.run();
}

int main(string[] arguments)
{
    foreach (argument; arguments[1 .. $])
    {
        if (argument == "--version" || argument == "-v")
        {
            // The app links as the Windows GUI subsystem (no console), so the
            // version command must allocate one for its stdout.
            version (Windows)
            {
                import core.sys.windows.windows : AllocConsole;
                import core.stdc.stdio : fflush, freopen, stderr, stdout, stdin;
                if (AllocConsole())
                {
                    freopen("CONOUT$", "w", stdout);
                    freopen("CONOUT$", "w", stderr);
                    freopen("CONIN$", "r", stdin);
                }
            }
            writeln(appFullVersion);
            return 0;
        }
    }

    try
    {
        return runEditor();
    }
    catch (Throwable error)
    {
        string details;
        try
            details = "Aurora Cut could not start.\r\n\r\n" ~ error.toString();
        catch (Throwable)
            details = "Aurora Cut could not start: " ~ error.msg;

        stderr.writeln(details);
        stderr.flush();
        recordStartupFailure(details);
        return 1;
    }
}
