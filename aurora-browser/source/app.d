module app;

/**
 * Aurora Browser — a desktop web browser shell built on Aurora-D.
 *
 * The window chrome and page rendering live in `aurorabrowser.appui`
 * (`BrowserRoot`); this module is the slim entry point.
 */

import aurora;
import aurorabrowser.appui : BrowserRoot;

private int runScreenshot(string path)
{
    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.darkTitleBar = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.light());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
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

/// Open a browser window. When `startUrl` is non-empty it is opened in the
/// first tab instead of the home page.
private int runBrowser(string startUrl)
{
    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.resizable = true;
    options.darkTitleBar = false;
    auto window = new GuiWindow(options, Theme.light());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    if (startUrl.length > 0)
        root.openUrlAtStartup(startUrl);
    return window.run();
}

int main(string[] args)
{
    if (args.length >= 3 && args[1] == "--screenshot")
        return runScreenshot(args[2]);
    return runBrowser(urlArg(args));
}
