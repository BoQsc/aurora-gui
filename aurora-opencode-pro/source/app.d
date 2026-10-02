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
import std.stdio : stdin, stdout, writeln;
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
    return reply.length > 0 ? 0 : 1;
}

/// Interactive automation: keep one offscreen UI alive and run one prompt per
/// line of stdin, printing each reply as it completes. Reusing the session
/// avoids paying the conversation-restore startup cost for every prompt;
/// `exit` or `quit` ends the loop.
private int runHeadlessLoop()
{
    auto ui = openOffscreen("Aurora OpenCode", RendererPreference.software);
    scope (exit)
    {
        ui.root.shutdownClient();
        ui.window.close();
    }
    foreach (line; stdin.byLine())
    {
        const prompt = strip(line).idup;
        if (prompt.length == 0) continue;
        if (prompt == "exit" || prompt == "quit") break;
        const reply = submitPrompt(ui, prompt, false);
        writeln(reply);
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
    if (args.length >= 3 && args[1] == "--screenshot")
        return runScreenshot(args[2], false, "");
    if (args.length >= 4 && args[1] == "--screenshot-chat")
        return runScreenshot(args[2], true, args[3]);
    // `--headless-loop` keeps one offscreen session and runs one prompt per
    // stdin line; `--headless <prompt>` runs a single prompt. Both print the
    // assistant reply, so the exe can be used as an automation tool.
    if (args.length >= 2 && args[1] == "--headless-loop")
        return runHeadlessLoop();
    if (args.length >= 3 && args[1] == "--headless")
        return runHeadless(join(args[2 .. $], " "));

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
