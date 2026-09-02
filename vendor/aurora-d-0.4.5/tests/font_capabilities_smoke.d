module font_capabilities_smoke;

/// Headless smoke for the font-capabilities demo: builds the specimen tree on
/// a software renderer and writes a PPM so we can verify the glyph paths.

import aurora;
import legacy_demos.font_capabilities : CapabilitiesRoot;
import std.stdio : writeln;

int main(string[] args)
{
    string outputPath = "build/font-capabilities-smoke.ppm";
    if (args.length > 1) outputPath = args[1];

    WindowOptions options;
    options.title = "smoke";
    options.width = 1080;
    options.height = 680;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.light());
    auto root = new CapabilitiesRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    driver.paint();

    window.saveScreenshot(outputPath);
    writeln("WROTE: ", outputPath);
    window.close();
    return 0;
}
