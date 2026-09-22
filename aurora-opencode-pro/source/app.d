module app;

import aurora;
import auroraopencode.appicon : applicationIconPath;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : enableNativeTextRendering, opencodeTheme;
import auroraopencode.crashguard : installCrashHandler, runGuarded,
    runResolveCrashMode;
import auroraopencode.logging : logInfo, logLaunch;
import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.conv : to;
import std.stdio : writeln;
import std.utf : toUTF32;

private int runScreenshot(string path, bool withChat, string message)
{
    enableNativeTextRendering();
    WindowOptions options;
    options.title = "Aurora OpenCode";
    options.width = 1200;
    options.height = 800;
    options.decorated = false;
    options.darkTitleBar = true;
    options.iconPath = applicationIconPath();
    options.renderer = RendererPreference.automatic;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.paint();
    root.tickTree(0.02);
    driver.paint();

    if (withChat && message.length > 0)
    {
        auto inputWidget = findById(root, "oc-input");
        if (inputWidget !is null)
        {
            auto input = cast(TextArea) inputWidget;
            input.requestFocus();
            root.tickTree(0.02);
            driver.text(toUTF32(message));
            root.tickTree(0.02);
            writeln("typed: ", input.textUtf8());
            driver.pressKey(Key.enter);
        }
        root.tickTree(0.02);
        printDiagnostics(root, "after send");
        const deadline = MonoTime.currTime + seconds(120);
        while (MonoTime.currTime < deadline)
        {
            root.tickTree(0.03);
            Thread.sleep(30.msecs);
            driver.paint();
            auto sendWidget = findById(root, "oc-send");
            if (sendWidget !is null)
            {
                auto button = cast(Button) sendWidget;
                if (button.text() == "Send") break;
            }
        }
        printDiagnostics(root, "after done");
    }

    driver.paint();
    window.saveScreenshot(path);
    root.shutdownClient();
    window.close();
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
    enableNativeTextRendering();
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
