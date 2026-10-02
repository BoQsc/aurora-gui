module auroradimmer_headless_smoke;

import aurora;
import auroradimmer.dimmer : ControlPanelRoot, ScreenTintController;
import std.stdio : writeln;

/**
 * Drives the control panel through Aurora's test driver and checks the dim and
 * brighten math. Both levels stay at 0 so the process never tints the real
 * desktop while the smoke test runs.
 */
int main()
{
    WindowOptions options;
    options.title = "Aurora Dimmer";
    options.width = 430;
    options.height = 500;
    options.decorated = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());

    // Enabled at 0% so both overlays exist but never tint the real desktop.
    auto controller = new ScreenTintController(window, 0, true, 0, true);
    auto root = new ControlPanelRoot(controller);
    window.setRoot(root);
    root.refresh();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(430, 500));
    assert(driver.paint(), "Initial dimmer paint failed");
    assert(root.children().length > 0, "Control panel produced no widgets");

    controller.setDimPercent(50);
    assert(controller.dimPercent() == 50, "setDimPercent did not store the value");
    assert(controller.dimAlpha() == (50 * 255) / 100, "dim alpha does not track percent");
    assert(controller.dimOverlayActive(), "dim overlay window was not created");

    controller.setDimPercent(500);
    assert(controller.dimPercent() == 90, "dim percent was not clamped to the maximum");

    controller.setDimPercent(-20);
    assert(controller.dimPercent() == 0, "dim percent was not clamped to the minimum");

    controller.setBrightenPercent(30);
    assert(controller.brightenPercent() == 30,
        "setBrightenPercent did not store the value");
    assert(controller.brightenAlpha() == (30 * 255) / 100,
        "brighten alpha does not track percent");
    assert(controller.brightenOverlayActive(),
        "brighten overlay window was not created");

    controller.setBrightenPercent(500);
    assert(controller.brightenPercent() == 60,
        "brighten percent was not clamped to the maximum");

    controller.setBrightenPercent(-10);
    assert(controller.brightenPercent() == 0,
        "brighten percent was not clamped to the minimum");

    controller.setDimEnabled(false);
    assert(controller.dimAlpha() == 0, "disabled dimmer must use zero alpha");
    controller.setDimEnabled(true);
    assert(controller.dimAlpha() == 0, "0% dim level must stay fully transparent");

    controller.setBrightenEnabled(false);
    assert(controller.brightenAlpha() == 0, "disabled brightener must use zero alpha");

    driver.paint();
    assert(driver.paint(), "Dimmer repaint failed");

    writeln("aurora_dimmer_headless_smoke: ALL PASSED");
    controller.shutdown();
    window.close();
    return 0;
}
