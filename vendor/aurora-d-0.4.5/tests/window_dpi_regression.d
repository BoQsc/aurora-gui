module tests.window_dpi_regression;

import aurora;
import std.stdio : writeln;

private final class DpiProbe : Widget
{
    protected override void onPaint(ref Canvas canvas)
    {
        canvas.fillRect(Rect(5, 5, 50, 20), Color.rgb(20, 100, 180));
        canvas.drawText(Point(10, 40), "HIl1 office 0123"d, Color.rgb(0, 0, 0), 1);
    }
}

int main()
{
    WindowOptions options;
    options.width = 320; options.height = 200;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.light());
    window.setRoot(new DpiProbe());
    auto driver = new UiTestDriver(window);
    uint[] original;
    foreach (dpi; [96u, 120u, 144u, 192u, 96u])
    {
        const scale = DisplayScale.fromDpi(dpi);
        const physical = scale.logicalToPhysical(Size(320, 200));
        driver.resize(Size(320, 200), scale);
        assert(driver.paint());
        assert(window.displayScale() == scale, "Native readback discarded the test DPI");
        assert(window.logicalClientSize() == Size(320, 200));
        assert(window.framebufferSize() == physical && window.surface().size() == physical);
        assert(window.nativeWindow().clientSize() == Size(320, 200),
            "Presenting physical pixels changed the logical window size");
        const point = scale.logicalToPhysical(Point(15, 15));
        assert(window.surface().pixel(point.x, point.y) == Color.rgb(20, 100, 180).argb());
        if (original is null) original = window.surface().pixels().dup;
        else if (dpi == 96)
            assert(window.surface().pixels() == original, "Returning to the original DPI changed the frame");
    }
    driver.resize(Size(280, 180), DisplayScale.fromDpi(144));
    assert(driver.paint());
    assert(window.logicalClientSize() == Size(280, 180));
    assert(window.framebufferSize() == Size(420, 270));
    assert(window.nativeWindow().clientSize() == Size(280, 180));
    window.close();
    writeln("Window DPI 96/120/144/192, physical frames, logical sizes and return-frame equality passed.");
    return 0;
}
