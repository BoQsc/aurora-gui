module app;

import aurora;
import auroraopencode.appui : OpenCodeRoot;
import auroraopencode.core : opencodeTheme;
import auroraopencode.logging : logLaunch;
import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.conv : to;
import std.stdio : writeln;
import std.utf : toUTF32;

private int runScreenshot(string path, bool withChat, string message)
{
    WindowOptions options;
    options.title = "Aurora OpenCode";
    options.width = 1200;
    options.height = 800;
    options.darkTitleBar = true;
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
    if (args.length >= 3 && args[1] == "--screenshot")
        return runScreenshot(args[2], false, "");
    if (args.length >= 4 && args[1] == "--screenshot-chat")
        return runScreenshot(args[2], true, args[3]);

    WindowOptions options;
    options.title = "Aurora OpenCode";
    options.width = 1200;
    options.height = 800;
    options.darkTitleBar = true;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    logLaunch("Aurora OpenCode");
    const exitCode = window.run();
    root.shutdownClient();
    return exitCode;
}
