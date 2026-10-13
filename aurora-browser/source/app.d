module app;

/**
 * Aurora Browser — a desktop web browser shell built on Aurora-D.
 *
 * The window chrome and page rendering live in `aurorabrowser.appui`
 * (`BrowserRoot`); this module is the slim entry point. The window is
 * frameless: `BrowserRoot` carries the `BrowserTitleBar` (an Aurora
 * `FramelessWindowTitleBar`) plus a snap-preview overlay and 1 px window
 * border, matching the current Aurora window-shell pattern.
 */

import aurora;
import aurorabrowser.appui : BrowserRoot, browserTheme;

private int runScreenshot(string path, string startUrl)
{
    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.decorated = false;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, browserTheme());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    if (startUrl.length > 0)
        root.openUrlAtStartup(startUrl);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();
    window.saveScreenshot(path);
    window.close();
    return 0;
}

/// Extract `--url <target>` from the command line ("" when absent).
private string urlArg(string[] args)
{
    for (int i = 1; i < args.length - 1; ++i)
    {
        if (args[i] == "--url" && args[i + 1].length > 0)
            return args[i + 1];
    }
    return "";
}

/// Extract `--screenshot <path>` from the command line ("" when absent).
private string screenshotArg(string[] args)
{
    for (int i = 1; i < args.length - 1; ++i)
    {
        if (args[i] == "--screenshot" && args[i + 1].length > 0)
            return args[i + 1];
    }
    return "";
}

/// Open a browser window. When `startUrl` is non-empty it is opened in the
/// first tab instead of the home page.
private int runBrowser(string startUrl)
{
    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = false;
    options.lowLatency = true;
    options.vsync = true;
    // Keep the native pointer during titlebar drags; Aurora's synchronized
    // drawn cursor is meant for dragging retained compositor layers.
    options.synchronizedDragPointer = false;
    auto window = new GuiWindow(options, browserTheme());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    if (startUrl.length > 0)
        root.openUrlAtStartup(startUrl);
    return window.run();
}

int main(string[] args)
{
    const screenshot = screenshotArg(args);
    if (screenshot.length > 0)
        return runScreenshot(screenshot, urlArg(args));
    return runBrowser(urlArg(args));
}
