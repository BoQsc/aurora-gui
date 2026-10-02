module app;

import aurora;
import auroraopencode.appicon : applicationIconPath;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme;
import auroraopencode.crashguard : installCrashHandler, runGuarded,
    runResolveCrashMode;
import auroraopencode.logging : logInfo, logLaunch;
import auroraopencode.updater : runUpdateHelperMode;
import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.array : join;
import std.conv : to;
import std.stdio : stderr, stdin, stdout, writeln;
import std.string : strip;
import std.utf : toUTF32;

/// An offscreen UI: the real widgets and a test driver, with no window shown.
private struct OffscreenUi
{
    GuiWindow window;
    OpenCodeRoot root;
    UiTestDriver driver;
}

private OffscreenUi openOffscreen(string title, RendererPreference renderer)
{
    WindowOptions options;
    options.title = title;
    options.width = 1200;
    options.height = 800;
    options.decorated = false;
    options.darkTitleBar = true;
    options.iconPath = applicationIconPath();
    options.renderer = renderer;
    OffscreenUi ui;
    ui.window = new GuiWindow(options, opencodeTheme());
    ui.root = new OpenCodeRoot(ui.window);
    ui.window.setRoot(ui.root);
    ui.driver = new UiTestDriver(ui.window);
    ui.driver.paint();
    ui.root.tickTree(0.02);
    ui.driver.paint();
    return ui;
}

/// Submit one prompt through the real input widget and wait for the turn to
/// finish. Returns the assistant's final text for the active conversation.
private string submitPrompt(ref OffscreenUi ui, string message, bool verbose)
{
    auto inputWidget = findById(ui.root, "oc-input");
    if (inputWidget !is null)
    {
        auto input = cast(TextArea) inputWidget;
        input.requestFocus();
        ui.root.tickTree(0.02);
        ui.driver.text(toUTF32(message));
        ui.root.tickTree(0.02);
        if (verbose) writeln("typed: ", input.textUtf8());
        ui.driver.pressKey(Key.enter);
    }
    ui.root.tickTree(0.02);
    if (verbose) printDiagnostics(ui.root, "after send");
    const deadline = MonoTime.currTime + seconds(120);
    while (MonoTime.currTime < deadline)
    {
        ui.root.tickTree(0.03);
        Thread.sleep(30.msecs);
        ui.driver.paint();
        auto sendWidget = findById(ui.root, "oc-send");
        if (sendWidget !is null)
        {
            auto button = cast(Button) sendWidget;
            if (button.text() == "Send") break;
        }
    }
    if (verbose) printDiagnostics(ui.root, "after done");
    return ui.root.lastAssistantContentForTesting();
}

/// Optionally save a screenshot, then tear the offscreen UI down. Returns the
/// final assistant text so one-shot callers can print it.
private string finishOffscreen(ref OffscreenUi ui, string screenshotPath)
{
    ui.driver.paint();
    if (screenshotPath.length > 0) ui.window.saveScreenshot(screenshotPath);
    const reply = ui.root.lastAssistantContentForTesting();
    ui.root.shutdownClient();
    ui.window.close();
    return reply;
}

/// Drive the real widgets without ever showing a window. Shared by the
/// `--screenshot*` and `--headless` entry points so an unattended run
/// exercises the same code as the GUI.
private string driveOffscreen(string message, string screenshotPath,
    bool verbose, RendererPreference renderer)
{
    auto ui = openOffscreen("Aurora OpenCode", renderer);
    if (message.length > 0) submitPrompt(ui, message, verbose);
    return finishOffscreen(ui, screenshotPath);
}

private int runScreenshot(string path, bool withChat, string message)
{
    driveOffscreen(withChat ? message : "", path, true,
        RendererPreference.automatic);
    return 0;
}

/// The exe links as a GUI-subsystem binary, so Windows attaches no console and
/// any CLI output (`--headless`, usage, errors) would go nowhere. Before the
/// first write, join the console the exe was launched from so the text lands in
/// that cmd window (a fresh `AllocConsole` window pops up and vanishes with the
/// process). When there is no parent console - launched from Explorer - create
/// one. When standard output is already a pipe or a redirected file, leave the
/// streams alone so callers can capture the text.
private void attachCliConsole()
{
    version (Windows)
    {
        import core.stdc.stdio : freopen, stderr, stdin, stdout;
        import core.sys.windows.wincon : AllocConsole, AttachConsole,
            ATTACH_PARENT_PROCESS, GetConsoleWindow, SetConsoleOutputCP;
        import core.sys.windows.windows : FILE_TYPE_DISK, FILE_TYPE_PIPE,
            GetFileType, GetStdHandle, INVALID_HANDLE_VALUE, STD_OUTPUT_HANDLE;
        // Already attached to a console: its standard streams work as they are.
        if (GetConsoleWindow() !is null) return;
        // stdout is captured through a pipe or a file: do not replace it.
        const output = GetStdHandle(STD_OUTPUT_HANDLE);
        if (output !is null && output != INVALID_HANDLE_VALUE)
        {
            const kind = GetFileType(cast(void*) output);
            if (kind == FILE_TYPE_PIPE || kind == FILE_TYPE_DISK) return;
        }
        if (!AttachConsole(ATTACH_PARENT_PROCESS) && !AllocConsole()) return;
        freopen("CONOUT$", "w", stdout);
        freopen("CONOUT$", "w", stderr);
        freopen("CONIN$", "r", stdin);
        // Replies and prompts are UTF-8; match the console so they do not mojibake.
        SetConsoleOutputCP(65001);
    }
}

/// Whether the process was started from a console (a shell). The GUI subsystem
/// hides that console, so it is probed once at startup and released again; the
/// answer decides between an interactive console and the desktop window.
private __gshared bool startedFromShell;

/// Interactive sessions need a console this process alone reads from. cmd does
/// not wait for a GUI-subsystem exe, so the shell keeps its own console and
/// typed lines go to the shell, not here (the session looks dead). Take a fresh
/// console instead - its window is the session. Piped or redirected stdin is a
/// script feed, so it is left untouched.
private void ensureInteractiveConsole()
{
    version (Windows)
    {
        import core.stdc.stdio : freopen, stderr, stdin, stdout;
        import core.sys.windows.wincon : AllocConsole, GetConsoleWindow,
            SetConsoleOutputCP;
        import core.sys.windows.windows : FILE_TYPE_DISK, FILE_TYPE_PIPE,
            GetFileType, GetStdHandle, INVALID_HANDLE_VALUE, STD_INPUT_HANDLE;
        const input = GetStdHandle(STD_INPUT_HANDLE);
        if (input !is null && input != INVALID_HANDLE_VALUE)
        {
            const kind = GetFileType(cast(void*) input);
            if (kind == FILE_TYPE_PIPE || kind == FILE_TYPE_DISK) return;
        }
        if (GetConsoleWindow() is null && !AllocConsole()) return;
        freopen("CONOUT$", "w", stdout);
        freopen("CONOUT$", "w", stderr);
        freopen("CONIN$", "r", stdin);
        SetConsoleOutputCP(65001);
    }
}

/// Describe the command-line modes. Printed for `--help` (and for an option
/// that is not one of them), instead of silently opening the window.
private int printUsage()
{
    writeln("Aurora OpenCode Pro");
    writeln("Usage:");
    writeln("  aurora-opencode-pro                      open the desktop window");
    writeln(`  aurora-opencode-pro "prompt"             send a prompt; keeps chatting`);
    writeln("                                           in a console, one-shot on a pipe");
    writeln("  aurora-opencode-pro -i | --interactive   chat in the console");
    writeln("  aurora-opencode-pro --headless [prompt]  one prompt; with no prompt");
    writeln("                                           reads stdin (interactive in a");
    writeln("                                           console, one batch on a pipe)");
    writeln("  aurora-opencode-pro --headless-loop      one prompt per stdin line");
    writeln("  aurora-opencode-pro --screenshot <path>");
    writeln(`  aurora-opencode-pro --screenshot-chat <path> "prompt"`);
    return 0;
}

/// Read the whole of standard input as one prompt.
private string readAllStdin()
{
    string text;
    foreach (line; stdin.byLine())
    {
        text ~= line;
        text ~= '\n';
    }
    return text;
}

/// One-shot automation: run one prompt with no visible window and print the
/// assistant's final reply to stdout. `-` reads the prompt from stdin, so the
/// exe can be driven by a pipe. Exit code 0 means a reply was produced.
private int runHeadless(string message)
{
    if (message == "-") message = readAllStdin();
    const reply = driveOffscreen(message, "", false, RendererPreference.software);
    writeln(reply);
    stdout.flush();
    if (reply.length == 0)
    {
        stderr.writeln("aurora-opencode-pro: no reply was produced " ~
            "(check the API key/settings; see logs/errors.log)");
        return 1;
    }
    return 0;
}

/// Interactive automation: keep one offscreen UI alive and run one prompt per
/// line of stdin, printing each reply as it completes. Reusing the session
/// avoids paying the conversation-restore startup cost for every prompt;
/// `exit` or `quit` ends the loop. A prompt given on the command line
/// (`firstPrompt`) is answered first, then the session stays open.
private int runHeadlessLoop(string firstPrompt = "")
{
    auto ui = openOffscreen("Aurora OpenCode", RendererPreference.software);
    scope (exit)
    {
        ui.root.shutdownClient();
        ui.window.close();
    }
    // Plain output: only the assistant replies reach the console - no banner
    // or prompt chrome.
    if (firstPrompt.length > 0)
    {
        writeln(submitPrompt(ui, firstPrompt, false));
        stdout.flush();
    }
    foreach (line; stdin.byLine())
    {
        const prompt = strip(line).idup;
        if (prompt == "exit" || prompt == "quit") break;
        if (prompt.length == 0) continue;
        writeln(submitPrompt(ui, prompt, false));
        stdout.flush();
    }
    return 0;
}

private void printDiagnostics(OpenCodeRoot root, string stage)
{
    import std.stdio : writeln;
    auto statusLabel = cast(Label) findById(root, "oc-status");
    auto messagesVBox = cast(VBox) findById(root, "oc-messages");
    writeln("[", stage, "] status: ",
        statusLabel is null ? "?" : statusLabel.text());
    writeln("[", stage, "] bubbles: ",
        messagesVBox is null ? "?" : to!string(messagesVBox.children().length));
    if (messagesVBox !is null)
    {
        foreach (child; messagesVBox.children())
            writeln("[", stage, "] bubble bounds: ", child.bounds());
    }
    writeln("[", stage, "] last assistant content: ",
        root.lastAssistantContentForTesting());
}

private Widget findById(Widget widget, string requestedId)
{
    if (widget is null) return null;
    if (widget.id() == requestedId) return widget;
    foreach (child; widget.children())
    {
        auto found = findById(child, requestedId);
        if (found !is null) return found;
    }
    return null;
}

int main(string[] args)
{
    // The rebuild agent is a detached copy of this binary (see shared/rebuild.d)
    // and is selected before anything else runs, so it never builds a window.
    import rebuild : rebuildHelperFlag, runRebuildHelperMode;
    if (args.length >= 2 && args[1] == rebuildHelperFlag)
        return runRebuildHelperMode(args);
    const updateCode = runUpdateHelperMode(args);
    if (updateCode >= 0) return updateCode;
    // Install before anything else so a crash during window/UI construction is
    // still recorded in <stateDir>/logs/errors.log.
    installCrashHandler();
    // `--resolve-crash` is how the crash handler asks a fresh copy of this
    // build to name a faulting address while its symbols still match.
    if (runResolveCrashMode(args)) return 0;
    return runGuarded(() => runApp(args));
}

/// The real entry point; wrapped by `main` so any uncaught Throwable is logged.
private int runApp(string[] args)
{
    // The GUI subsystem hides the console the exe was started from, so probe
    // for it once and release it again: the flag decides between an interactive
    // console (shell launch) and the desktop window (Explorer/double-click).
    version (Windows)
    {
        import core.sys.windows.wincon : AttachConsole, ATTACH_PARENT_PROCESS,
            FreeConsole;
        startedFromShell = AttachConsole(ATTACH_PARENT_PROCESS) != 0;
        if (startedFromShell) FreeConsole();
    }

    const bool hasArg = args.length >= 2;
    const string arg1 = hasArg ? args[1] : "";

    if (arg1 == "--help" || arg1 == "-h")
    {
        attachCliConsole();
        return printUsage();
    }
    // One interactive session, one prompt per line, until `exit`/`quit`.
    if (arg1 == "--interactive" || arg1 == "-i" || arg1 == "--headless-loop")
    {
        ensureInteractiveConsole();
        return runHeadlessLoop();
    }
    if (arg1 == "--screenshot" && args.length >= 3)
    {
        attachCliConsole();
        return runScreenshot(args[2], false, "");
    }
    if (arg1 == "--screenshot-chat" && args.length >= 4)
    {
        attachCliConsole();
        return runScreenshot(args[2], true, args[3]);
    }
    if (arg1 == "--headless")
    {
        // With a prompt it is a one-shot; without one, a shell gets the
        // interactive session and a pipe is read as one batch prompt.
        if (args.length >= 3)
        {
            attachCliConsole();
            return runHeadless(join(args[2 .. $], " "));
        }
        if (startedFromShell)
        {
            ensureInteractiveConsole();
            return runHeadlessLoop();
        }
        attachCliConsole();
        return runHeadless("-");
    }
    // A bare prompt: in a shell it answers and keeps the session open, so
    // launching the exe behaves like a chat; on a pipe it is a one-shot.
    if (hasArg && arg1.length > 0 && arg1[0] != '-')
    {
        const prompt = join(args[1 .. $], " ");
        if (startedFromShell)
        {
            ensureInteractiveConsole();
            return runHeadlessLoop(prompt);
        }
        attachCliConsole();
        return runHeadless(prompt);
    }
    if (hasArg)
    {
        // An option that is not a known mode: say so rather than opening the
        // window, which looked like the command did nothing.
        attachCliConsole();
        stderr.writeln("aurora-opencode-pro: unknown option: ", arg1);
        printUsage();
        return 2;
    }
    // No arguments: launched from a shell, start the interactive console;
    // launched from Explorer (no console), open the desktop window.
    if (startedFromShell)
    {
        ensureInteractiveConsole();
        return runHeadlessLoop();
    }

    WindowOptions options;
    options.title = "Aurora OpenCode";
    options.width = 1200;
    options.height = 800;
    options.decorated = false;
    options.darkTitleBar = true;
    options.iconPath = applicationIconPath();
    // The custom titlebar owns window moves; keep the native pointer during
    // those drags (Aurora's synchronized drawn cursor is for compositor drags).
    options.synchronizedDragPointer = false;
    // Record how long startup actually takes, so the number is visible in
    // logs/errors.log next to the launch banner instead of being guessed at.
    // Restoring the conversation is the expensive part and happens entirely in
    // the OpenCodeRoot constructor.
    const startupBegan = MonoTime.currTime;
    auto window = new GuiWindow(options, opencodeTheme());
    // `GuiWindow.run()` is the only place that shows the window, and it is not
    // reached until the OpenCodeRoot constructor has finished restoring the
    // conversation - which parses a multi-megabyte sessions.json and can take
    // several seconds on a large history. Present the themed first frame here so
    // the window appears immediately instead of leaving the desktop blank until
    // the restore completes; run() re-presents the same frame when the UI is
    // ready.
    if (auto native = window.nativeWindow())
    {
        native.prepareFirstFrame(opencodeTheme().windowBackground);
        native.show();
    }
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    logInfo("startup: ui built in " ~ to!string((MonoTime.currTime -
        startupBegan).total!"msecs") ~ " ms");
    logLaunch("Aurora OpenCode Pro");
    // Shut down on every exit path, not just a clean window close. An
    // uncaught `Error` unwinds straight past the code after `run()` and lands
    // in `runGuarded`, so the state was never written whenever the app died
    // mid-conversation - the reason the last message was missing after a
    // restart. `scope (exit)` runs on the error path too.
    scope (exit) root.shutdownClient();
    return window.run();
}
