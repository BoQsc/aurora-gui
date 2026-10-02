module auroradimmer_headless_smoke;

import aurora;
import auroradimmer.dimmer : ControlPanelRoot, ScreenTintController,
    combinedTintScale;
import std.stdio : writeln;

/**
 * Drives the control panel through Aurora's test driver and checks the dim and
 * brighten math for the overlay engine plus the full-screen filter math. Levels
 * stay at 0 whenever an engine is active so the process never tints the real
 * desktop while the smoke test runs.
 */
int main()
{
    WindowOptions options;
    options.title = "Aurora Dimmer";
    options.width = 430;
    options.height = 600;
    options.decorated = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());

    // Overlay engine at 0% so both overlays exist but never tint the desktop.
    auto controller = new ScreenTintController(window, 0, true, 0, true,
        false, true);
    auto root = new ControlPanelRoot(controller);
    window.setRoot(root);
    root.refresh();

    auto driver = new UiTestDriver(window);
    driver.resize(Size(430, 600));
    assert(driver.paint(), "Initial dimmer paint failed");
    assert(root.children().length > 0, "Control panel produced no widgets");
    assert(controller.useOverlay() && !controller.useFilter(),
        "engine selection mismatch");

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

    // Full-screen filter math (pure, so it never touches the real screen).
    assert(combinedTintScale(50, true, 0, false) == 0.5f,
        "50% dim should halve every channel");
    assert(combinedTintScale(0, false, 50, true) == 1.5f,
        "50% brighten should lift every channel by half");
    assert(combinedTintScale(0, true, 0, true) == 1.0f,
        "zero levels must be identity");
    assert(combinedTintScale(45, true, 45, true) == (1.0f - 0.45f) * (1.0f + 0.45f),
        "dim and brighten should compose multiplicatively");

    // Enable the filter at 0% so it applies identity over the desktop, and
    // confirm the two engines can be combined.
    controller.setUseFilter(true);
    assert(controller.useFilter() && controller.useOverlay(),
        "engines should be able to run together");
    assert(controller.screenFilterScale() == 1.0f, "0% filter must be identity");

    driver.paint();
    assert(driver.paint(), "Dimmer repaint failed");

    writeln("aurora_dimmer_headless_smoke: ALL PASSED");
    controller.shutdown();
    window.close();
    return 0;
}
