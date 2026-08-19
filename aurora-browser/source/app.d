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

int main(string[] args)
{
    if (args.length >= 3 && args[1] == "--screenshot")
        return runScreenshot(args[2]);

    WindowOptions options;
    options.title = "Aurora Browser";
    options.width = 1080;
    options.height = 680;
    options.resizable = true;
    options.darkTitleBar = false;
    auto window = new GuiWindow(options, Theme.light());
    auto root = new BrowserRoot(window);
    window.setRoot(root);
    return window.run();
}
