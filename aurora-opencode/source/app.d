module app;

import aurora;
import auroraopencode.appui : OpenCodeRoot, opencodeTheme;
import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.utf : toUTF32;

private int runScreenshot(string path, bool withChat, string message)
{
    WindowOptions options;
    options.title = "Aurora OpenCode";
    options.width = 1200;
    options.height = 800;
    options.darkTitleBar = true;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, opencodeTheme());
    auto root = new OpenCodeRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.paint();
    root.tickTree(0.02);
    driver.paint();

    if (withChat && message.length > 0)
    {
        Widget inputWidget;
        foreach (child; root.children())
            inputWidget = findById(child, "oc-input");
        if (inputWidget !is null)
        {
            auto input = cast(TextArea) inputWidget;
            input.requestFocus();
            root.tickTree(0.02);
            driver.text(toUTF32(message));
            root.tickTree(0.02);
            driver.pressKey(Key.enter);
        }
        const deadline = MonoTime.currTime + seconds(120);
        while (MonoTime.currTime < deadline)
        {
            root.tickTree(0.03);
            Thread.sleep(30.msecs);
            driver.paint();
            bool send = true;
            foreach (child; root.children())
            {
                if (child.id() == "oc-send")
                {
                    auto button = cast(Button) child;
                    send = button.text() == "Send";
                }
            }
            if (send) break;
        }
    }

    driver.paint();
    window.saveScreenshot(path);
    window.close();
    return 0;
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
    window.setRoot(new OpenCodeRoot(window));
    return window.run();
}
