module tests.vulkan_smoke;

/**
 * Native-window smoke test for Vulkan text and retained compositor layers.
 *
 * Run under a real display or Xvfb. The test requires Vulkan rather than
 * accepting automatic software fallback, waits for native resize warm-up,
 * resets all work counters, then moves/hides/restores one retained Aurora
 * window while requiring zero content rebuilds and zero geometry uploads.
 */

import aurora;
import std.exception : enforce;
import std.file : mkdirRecurse;
import std.stdio : writefln, writeln;

private final class VulkanSmokeRoot : Widget
{
    private GuiWindow _window;
    private FloatingWindow _floating;
    private double _elapsed;
    private size_t _phase;
    private size_t _stableWarmupTicks;
    private size_t _rgbWarmupUpdates;
    private ulong _lastBaseBuilds;
    private ulong _lastLayerBuilds;
    private ulong _lastGeometryUploads;
    private ulong _warmupGeometryUploads;
    private bool _baselineCaptured;
    private bool _hidLayer;
    private bool _restoredLayer;
    private RgbaImage _testImage;
    private ubyte[] _testRgb;

    this(GuiWindow window)
    {
        _window = window;
        auto panel = new VBox(6, Insets(8));
        panel.add(new Label("Persistent GPU layer"));
        panel.add(new Label("Geometry stays resident; movement changes only its viewport."));
        _floating = add(new FloatingWindow("Retained compositor", IconKind.computer, panel));
        _floating.setBounds(Rect(30, 112, 430, 105));
        _testImage = new RgbaImage(2, 2, [
            255, 80, 80, 255, 80, 255, 80, 255,
            80, 120, 255, 255, 255, 220, 80, 255]);
        _testRgb = [255, 40, 40, 40, 255, 40,
            40, 80, 255, 255, 220, 40];
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        canvas.fillRect(Rect(0, 0, bounds().width, bounds().height),
            palette.windowBackground);
        canvas.drawText(Point(24, 18), "Aurora Vulkan + retained compositor"d,
            palette.text, 3);
        canvas.drawText(Point(24, 65),
            "office ffi  A\u0301  Ελληνικά  Кириллица  العربية  עברית"d,
            palette.accent, 2);
        canvas.drawImage(Rect(650, 26, 36, 36), _testImage, false);
        canvas.drawRgbImage(Rect(600, 26, 36, 36), 2, 2, _testRgb, false);
    }

    protected override void onTick(double deltaSeconds)
    {
        _elapsed += deltaSeconds;
        if (!_baselineCaptured && _rgbWarmupUpdates < 3)
        {
            _testRgb[0] = cast(ubyte) (160 + _rgbWarmupUpdates * 30);
            ++_rgbWarmupUpdates;
            invalidate();
        }

        // Native map/configure events can legitimately rebuild the initial
        // scene. Wait until those counters are stable, then measure only the
        // interactive transform/hide/restore phase.
        if (!_baselineCaptured)
        {
            const ui = _window.compositorStats();
            const gpu = _window.rendererStats();
            if (ui.baseBuilds >= 1 && ui.layerBuilds >= 1 && gpu.geometryUploads >= 2)
            {
                if (ui.baseBuilds == _lastBaseBuilds &&
                    ui.layerBuilds == _lastLayerBuilds &&
                    gpu.geometryUploads == _lastGeometryUploads)
                    ++_stableWarmupTicks;
                else
                    _stableWarmupTicks = 0;
                _lastBaseBuilds = ui.baseBuilds;
                _lastLayerBuilds = ui.layerBuilds;
                _lastGeometryUploads = gpu.geometryUploads;
                if (_stableWarmupTicks >= 3)
                {
                    _warmupGeometryUploads = gpu.geometryUploads;
                    _window.resetCompositorStats();
                    _window.resetRendererStats();
                    _baselineCaptured = true;
                }
            }
            if (_elapsed >= 5.0) _window.close();
            return;
        }

        ++_phase;
        if (_phase <= 8)
            _floating.setPosition(Point(30 + cast(int) (_phase * 18), 112));
        else if (_phase == 9)
        {
            _floating.setVisible(false);
            _hidLayer = true;
        }
        else if (_phase == 10)
        {
            _floating.setVisible(true);
            _restoredLayer = true;
        }
        if (_phase >= 13 || _elapsed >= 8.0)
            _window.close();
    }

    bool baselineCaptured() const @safe pure nothrow @nogc { return _baselineCaptured; }
    bool hidLayer() const @safe pure nothrow @nogc { return _hidLayer; }
    bool restoredLayer() const @safe pure nothrow @nogc { return _restoredLayer; }
    ulong warmupGeometryUploads() const @safe pure nothrow @nogc
    {
        return _warmupGeometryUploads;
    }
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Vulkan retained-compositor smoke";
    options.width = 720;
    options.height = 250;
    options.renderer = RendererPreference.vulkan;
    options.lowLatency = true;

    auto window = new GuiWindow(options, Theme.dark());
    auto root = new VulkanSmokeRoot(window);
    window.setRoot(root);
    const result = window.run();

    enforce(window.hardwareAccelerated(), window.rendererFallbackReason());
    enforce(window.rendererName() == "Vulkan", "required Vulkan renderer was not active");
    const stats = window.compositorStats();
    const rendererStats = window.rendererStats();
    enforce(root.baselineCaptured(), "Vulkan scene warm-up did not complete");
    enforce(root.hidLayer() && root.restoredLayer(),
        "the retained layer hide/restore phase did not run");
    enforce(root.warmupGeometryUploads() >= 2,
        "base and retained layer geometry were not uploaded during warm-up");
    enforce(stats.baseBuilds == 0,
        "transform interaction unexpectedly rebuilt base content");
    enforce(stats.layerBuilds == 0,
        "transform interaction unexpectedly rebuilt layer content");
    enforce(stats.layerOrderBuilds == 2,
        "only hide and restore should rebuild painter order after warm-up");
    enforce(stats.transformOnlyFrames >= 10,
        "moved/hidden/restored states were not presented as retained frames");
    enforce(rendererStats.geometryUploads == 0,
        "retained interaction unexpectedly uploaded geometry");

    mkdirRecurse("build");
    window.saveScreenshot("build/aurora-vulkan-text-smoke.ppm");
    writefln("Vulkan renderer: %s", window.rendererName());
    writefln("Vulkan live-resize scaling: %s",
        window.rendererSupportsLiveResizeScaling());
    writefln("Warm-up geometry uploads: %s", root.warmupGeometryUploads());
    writefln("Measured interaction: %s transform-only frames, %s content rebuilds, "
        ~ "%s geometry uploads", stats.transformOnlyFrames,
        stats.baseBuilds + stats.layerBuilds, rendererStats.geometryUploads);
    writefln("Nonblocking Vulkan frame deferrals: %s", rendererStats.frameDeferrals);
    writeln("Vulkan retained-compositor smoke completed successfully.");
    return result;
}
