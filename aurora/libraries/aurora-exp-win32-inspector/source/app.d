// SPDX-License-Identifier: 0BSD
/**
 * Aurora Win32 Laboratory inspector entry point.
 *
 * Normal start opens the inspector window with an optional image path.
 * `--screenshot <ppm> [image]` renders the same layout off-screen for review.
 */
module app;

import aurora;
import aurorainspector.inspector : InspectorRoot;
import std.file : exists, mkdirRecurse;
import std.path : dirName;
import std.stdio : stderr;

private int captureScreenshot(string outputPath, string imagePath)
{
    const directory = dirName(outputPath);
    if (directory.length != 0 && directory != "." && !exists(directory))
        mkdirRecurse(directory);

    WindowOptions options;
    options.title = "Aurora Win32 Laboratory";
    options.width = 1280;
    options.height = 820;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    window.setRoot(new InspectorRoot(window, imagePath));
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();
    driver.paint();
    window.saveScreenshot(outputPath);
    window.close();
    return 0;
}

int main(string[] args)
{
    if (args.length >= 3 && args[1] == "--screenshot")
        return captureScreenshot(args[2], args.length >= 4 ? args[3] : "");

    WindowOptions options;
    options.title = "Aurora Win32 Laboratory";
    options.width = 1280;
    options.height = 820;
    options.resizable = true;
    options.decorated = true;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;

    try
    {
        auto window = new GuiWindow(options, Theme.dark());
        window.setRoot(new InspectorRoot(window,
            args.length >= 2 ? args[1] : ""));
        return window.run();
    }
    catch (Exception error)
    {
        stderr.writeln("inspector failed: ", error.msg);
        return 1;
    }
}
