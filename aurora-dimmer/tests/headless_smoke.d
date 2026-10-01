module auroradimmer_headless_smoke;

import aurora;
import auroradimmer.dimmer : DimmerController, DimmerRoot;
import std.stdio : writeln;

/**
 * Drives the control panel through Aurora's test driver and checks the dim
 * math. The dim level stays at 0 so the process never darkens the real
 * desktop while the smoke test runs.
 */
int main()
{
    WindowOptions options;
    options.title = "Aurora Dimmer";
    options.width = 430;
    options.height = 372;
    options.decorated = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());

    // Enabled at 0% so the overlay exists but never darkens the real desktop.
    auto controller = new DimmerController(window, 0, true);
    auto root = new DimmerRoot(controller);
    window.setRoot(root);
    root.refresh();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(430, 372));
    assert(driver.paint(), "Initial dimmer paint failed");
    assert(root.children().length > 0, "Control panel produced no widgets");

    controller.setPercent(50);
    assert(controller.percent() == 50, "setPercent did not store the value");
    assert(controller.alpha() == (50 * 255) / 100, "alpha does not track percent");
    assert(controller.overlayActive(), "overlay window was not created");

    controller.setPercent(500);
    assert(controller.percent() == 90, "percent was not clamped to the maximum");

    controller.setPercent(-20);
    assert(controller.percent() == 0, "percent was not clamped to the minimum");

    controller.setEnabled(false);
    assert(controller.alpha() == 0, "disabled dimmer must use zero alpha");
    controller.setEnabled(true);
    assert(controller.alpha() == 0, "0% dim level must stay fully transparent");

    driver.paint();
    assert(driver.paint(), "Dimmer repaint failed");

    writeln("aurora_dimmer_headless_smoke: ALL PASSED");
    controller.shutdown();
    window.close();
    return 0;
}
