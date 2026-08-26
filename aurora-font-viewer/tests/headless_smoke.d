module aurorafontviewer_headless_smoke;

import aurora;
import aurora.text.fontmanager : SystemFontInventory;
import aurora.testing : UiTestDriver;
import aurorafontviewer.fontviewer : FontViewerRoot;
import std.utf : toUTF32;
import std.stdio : writeln;

int main()
{
    const installed = SystemFontInventory.installed();
    writeln("Installed system font faces: ", installed.length);
    assert(installed.length > 0, "No installed fonts discovered");

    // Render an actual specimen through Aurora's text engine into a Surface.
    const w = 700;
    const h = 360;
    auto surface = new Surface(w, h);
    surface.clear(Color.rgb(0xff, 0xf6, 0xf8));
    auto canvas = Canvas(surface, FontSystem.sharedInstance());
    auto face = FontSystem.sharedInstance().uiFace;
    canvas.drawText(Point(20, 40),
        "Sphinx of black quartz, judge my vow."d,
        Color.rgb(0x20, 0x24, 0x2a), 3, FontRole.ui, face);

    int darkish;
    foreach (pixel; surface.pixels())
    {
        const a = (pixel >> 24) & 0xff;
        const r = (pixel >> 16) & 0xff;
        const g = (pixel >> 8) & 0xff;
        const b = pixel & 0xff;
        if (a == 0xff && r < 120 && g < 120 && b < 120) ++darkish;
    }
    writeln("Specimen darkish glyph pixels: ", darkish);
    assert(darkish > 200, "Specimen rendered no real glyph coverage");

    // Full widget path: build the viewer, check child layout, then paint.
    WindowOptions options;
    options.title = "Aurora Font Viewer";
    options.width = 1080;
    options.height = 720;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.light());
    auto root = new FontViewerRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1080, 720));
    assert(driver.paint(), "Initial Font Viewer paint failed");
    root.layoutTree();

    assert(root.familyCount() > 0, "No font families enumerated");
    root.selectFamilyForTesting(0);
    root.layoutTree();
    assert(driver.paint(), "Specimen paint failed after selection");

    writeln("font_viewer_headless_smoke: ALL PASSED");
    window.close();
    return 0;
}
