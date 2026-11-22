module app;

import aurora;
import opencodelite.shell : LiteShell;
import std.file : exists, mkdirRecurse;
import std.path : dirName;

private void runScreenshot(string outputPath)
{
    const directory = dirName(outputPath);
    if (directory.length != 0 && directory != "." && !exists(directory))
        mkdirRecurse(directory);

    WindowOptions options;
    options.title = "Aurora OpenCode Lite";
    options.width = 960;
    options.height = 680;
    options.darkTitleBar = true;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    window.setRoot(new LiteShell());
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();
    driver.paint();
    window.saveScreenshot(outputPath);
    window.close();
}

int main(string[] args)
{
    if (args.length >= 3 && args[1] == "--screenshot")
    {
        runScreenshot(args[2]);
        return 0;
    }

    WindowOptions options;
    options.title = "Aurora OpenCode Lite";
    options.width = 960;
    options.height = 680;
    options.resizable = true;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    options.synchronizedDragPointer = false;
    // The Lite surface is a small 2D UI. Software rendering avoids GPU
    // initialization cost and keeps launch deterministic on every machine.
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    window.setRoot(new LiteShell());
    return window.run();
}
