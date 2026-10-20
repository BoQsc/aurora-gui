module text_coverage_capture;

import aurora;
import auroranotepad.appui : NotepadRoot, notepadTheme;
import auroranotepad.menubar : MenuBar;
import aurora.widgets.popup : currentTransientPopup;
import experiment.aurorahost.scene : loadScene, createWindow, NodeRegistry;
import experiment.aurorahost.host_ui : TabItem;
import std.conv : to;
import std.exception : enforce;
import std.stdio : writeln;
import std.utf : toUTF32;

private immutable sample = "Aurora text rendering candidate\n\n" ~
    "office affinity Il1 O0 0123456789 = + - _\n" ~
    "The quick brown fox jumps over the lazy dog.\n" ~
    "Українська: Якість тексту — Київ\n" ~
    "Greek: Ελληνικά  |  Accents: café Ångström\n\n" ~
    "def hello(name):\n    message = 'Hello, Aurora'\n    return message\n\n" ~
    "Selected text uses the same foreground-aware policy.\n";

version (AuroraHeadless) {} else
{
    import aurora.platform.gdi : ScreenCapture;
    import core.sys.windows.windows : SetForegroundWindow, SetWindowPos, HWND,
        HWND_TOPMOST, SWP_NOMOVE, SWP_NOSIZE, SWP_NOACTIVATE;

    private final class NativeProbe : Widget
    {
        GuiWindow window;
        string output;
        int ticks;
        int stage;
        int captures;
        int rejectedFrames;
        ulong mismatches;
        uint maximumError;
        this(GuiWindow window, string output) { this.window = window; this.output = output; }
        protected override void onPaint(ref Canvas cv)
        {
            cv.fillRect(Rect(0, 0, 620, 320), Color.rgb(255, 255, 255));
            cv.fillRect(Rect(310, 0, 310, 320), Color.rgb(24, 24, 24));
            cv.fillRect(Rect(0, 225, 620, 55), Color.rgb(170, 200, 240));
            foreach (i, color; [Color.rgb(0, 0, 0), Color.rgb(35, 41, 48),
                Color.rgb(255, 255, 255), Color.rgb(240, 240, 240),
                Color.rgb(200, 35, 60), Color.rgb(30, 130, 70),
                Color.rgb(40, 80, 210), Color.rgba(60, 80, 160, 100)])
            {
                const y = 12 + cast(int) i * 34;
                cv.drawText(Point(8, y), "office Il1 O0 café Жй"d, color, 1);
                cv.drawText(Point(318, y), "office Il1 O0 café Жй"d, color, 1);
            }
            cv.fillRect(Rect(8, 294, 32, 18), stage == 0 ?
                Color.rgb(220, 20, 50) : Color.rgb(20, 180, 80));
        }
        protected override void onTick(double delta)
        {
            ++ticks;
            if (ticks == 6)
            {
                auto hwnd = cast(HWND) window.nativeWindow().nativeSurfaceInfo().handleB;
                // Keep only this short-lived probe visible during screen capture.
                SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
                SetForegroundWindow(hwnd);
            }
            if (ticks >= 120)
                enforce(captures == 2,
                    "GPU capture stayed stale, obscured or blank (changing marker mismatch)");
            if (ticks >= 20 && ticks % 10 == 0 && captures < 2)
            {
                const size = window.framebufferSize();
                auto capture = new ScreenCapture(size.width, size.height);
                capture.captureWindow(window.nativeWindow().nativeSurfaceInfo().handleB, true, false);
                ubyte[] rgba = new ubyte[cast(size_t) size.width * size.height * 4];
                enforce(capture.capture(rgba), "Native GPU screen capture failed");
                auto surface = new Surface(size.width, size.height);
                foreach (i, ref pixel; surface.pixels())
                    pixel = Color(rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], 255).argb();
                const marker = window.displayScale().logicalToPhysical(Point(20, 302));
                if (surface.pixel(marker.x, marker.y) != (stage == 0 ?
                    Color.rgb(220, 20, 50).argb() : Color.rgb(20, 180, 80).argb()))
                {
                    ++rejectedFrames;
                    invalidate();
                    return; // Reject the frame and retry; never accept a stale image.
                }
                surface.savePpm(output ~ "-" ~ stage.to!string ~ ".ppm");
                auto reference = window.surface();
                reference.savePpm(output ~ "-software-" ~ stage.to!string ~ ".ppm");
                enforce(reference.size() == surface.size());
                foreach (i, pixel; surface.pixels())
                {
                    uint error;
                    foreach (shift; [0, 8, 16])
                    {
                        const a = cast(int) ((pixel >> shift) & 255);
                        const b = cast(int) ((reference.pixels()[i] >> shift) & 255);
                        const difference = cast(uint) (a > b ? a - b : b - a);
                        if (difference > error) error = difference;
                    }
                    if (error > 0) ++mismatches;
                    if (error > maximumError) maximumError = error;
                }
                ++captures;
                stage = 1;
            }
            if (captures == 2) window.close();
            invalidate();
        }
    }
}

int main(string[] args)
{
    enforce(args.length >= 3, "capture <notepad|host|padpp|native> <output-prefix> [theme] [dpi]");
    version (AuroraHeadless) {} else if (args[1] == "native")
    {
        WindowOptions options;
        options.title = "Aurora text candidate GPU capture";
        options.width = 620; options.height = 320;
        options.renderer = RendererPreference.vulkan;
        auto window = new GuiWindow(options, Theme.light());
        auto root = new NativeProbe(window, args[2]);
        window.setRoot(root);
        const result = window.run();
        enforce(window.hardwareAccelerated() && window.rendererName() == "Vulkan",
            "Vulkan was not active: " ~ window.rendererFallbackReason());
        enforce(root.captures == 2, "Both GPU marker states must be captured");
        writeln("Vulkan screen capture: two validated live states; DPI=", window.displayScale().dpiX,
            "; differing pixels=", root.mismatches, "; maximum channel error=", root.maximumError,
            "; rejected frames=", root.rejectedFrames);
        enforce(root.maximumError <= 2, "GPU/software difference exceeds two channel levels");
        return result;
    }
    const dark = args.length > 3 && args[3] == "dark";
    const dpi = args.length > 4 ? args[4].to!uint : 96u;
    GuiWindow window;
    if (args[1] == "notepad")
    {
        WindowOptions options;
        options.width = 1080; options.height = 680;
        options.decorated = false;
        window = new GuiWindow(options, notepadTheme());
        auto root = new NotepadRoot(window);
        root.editor().setText(toUTF32(sample), false);
        root.editor().setSelection(15, 28);
        window.setRoot(root);
        auto driver = new UiTestDriver(window);
        driver.resize(Size(options.width, options.height), DisplayScale.fromDpi(dpi));
        driver.paint();
        if (dark)
        {
            MenuBar menuBar;
            foreach (child; root.children())
                if (auto bar = cast(MenuBar) child) menuBar = bar;
            enforce(menuBar !is null);
            auto view = menuBar.children()[3];
            const point = view.globalOrigin();
            driver.click(Point(point.x + 10, point.y + 8));
            auto popup = cast(ContextMenu) currentTransientPopup(root);
            enforce(popup !is null, "View menu did not open");
            bool changed;
            foreach (item; popup.items())
                if (item.label == "Dark Theme") { item.action(); changed = true; }
            enforce(changed);
            driver.keyDown(Key.escape);
            driver.paint();
        }
    }
    else
    {
        auto scene = loadScene(args[1] == "padpp" ?
            "experiments/aurora-host-notepadpp/padpp.scene.json" :
            "experiments/aurora-host/samples/editor.scene.json");
        if (args[1] != "padpp") scene.window.theme = dark ? "dark" : "light";
        auto registry = new NodeRegistry();
        window = createWindow(scene, registry);
        registry.setText("editor", sample, false);
        if (args[1] == "padpp")
            registry.setTabs("docs", [TabItem("sample.py", "select", true, false)]);
        auto driver = new UiTestDriver(window);
        driver.resize(Size(scene.window.width, scene.window.height), DisplayScale.fromDpi(dpi));
        driver.paint();
    }
    const requestedScale = DisplayScale.fromDpi(dpi);
    enforce(window.displayScale() == requestedScale, "Capture DPI was not applied by the platform");
    enforce(window.framebufferSize() == requestedScale.logicalToPhysical(window.nativeWindow().clientSize()),
        "Capture framebuffer does not match physical DPI");
    window.saveScreenshot(args[2] ~ ".ppm");
    writeln(args[1], " ", dark ? "dark" : "light", " ", dpi, " DPI; atlas=",
        window.fontSystem().atlas.width(), "x", window.fontSystem().atlas.height(),
        "; rasterizations=", window.fontSystem().atlas.rasterizations());
    window.close();
    return 0;
}
