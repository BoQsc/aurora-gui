// SPDX-License-Identifier: 0BSD
/**
 * Headless smoke: build the inspector layout, load an image, render two frames,
 * and write a PPM. Proves the window lays out and paints without a desktop.
 *
 * Usage: win32-inspector-headless <output.ppm> [image]
 */
module headless_smoke;

import aurora;
import aurorainspector.inspector : InspectorRoot;
import std.file : exists, mkdirRecurse;
import std.path : dirName;
import std.stdio : stderr;

int main(string[] args)
{
    const output = args.length > 1 ? args[1] : "build/inspector-smoke.ppm";
    const imagePath = args.length > 2 ? args[2] : "";

    const directory = dirName(output);
    if (directory.length != 0 && directory != "." && !exists(directory))
        mkdirRecurse(directory);

    WindowOptions options;
    options.title = "Aurora Win32 Laboratory";
    options.width = 1280;
    options.height = 820;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new InspectorRoot(window, imagePath);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();
    driver.paint();
    window.saveScreenshot(output);
    window.close();

    if (!exists(output))
    {
        stderr.writeln("inspector smoke did not write its screenshot");
        return 1;
    }
    return 0;
}
