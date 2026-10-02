module auroradimmer.dimmer;

/**
 * Aurora Dimmer - a tiny Windows screen tint tool for night and day use.
 *
 * Two tint engines are available, chosen in the UI or with `--overlay`:
 *
 *   - Full-screen filter (default): the Windows Magnification API
 *     (`MagSetFullscreenColorEffect`) applies a color matrix to the whole
 *     primary display *after* compositing. It therefore also tints context
 *     menus, tooltips, the taskbar and other shell surfaces that a floating
 *     window cannot sit above. Limitation: it only covers the primary monitor.
 *
 *   - Overlay: one or two full virtual-screen, always-on-top, click-through
 *     layered Win32 windows are blended over the desktop. It covers every
 *     monitor, but windows and menus placed in a higher z-order band (menus,
 *     the taskbar, secure surfaces) stay at full brightness.
 *
 * Both engines are driven by an independent dim level (black, 0-90%) and
 * brighten level (white, 0-60%). Neither engine changes what is behind it, so
 * games and video keep running and the pointer still reaches them.
 *
 * The control panel is an ordinary Aurora window. In overlay mode it is
 * re-raised above the tint layers; in filter mode the whole screen, including
 * this panel, is tinted.
 */

import aurora;
import aurora.platform.select : PlatformWindow;

import core.sys.windows.windows : BLACK_BRUSH, BOOL, BYTE, CreateWindowExW,
    DefWindowProcW, FreeLibrary, GetModuleHandleW, GetProcAddress,
    GetStockObject, GetSystemMetrics, HBRUSH, HINSTANCE, HMODULE, HWND,
    HWND_TOPMOST, IsWindow, LoadLibraryW, LPARAM, LRESULT, LWA_ALPHA,
    RegisterClassExW, SetLayeredWindowAttributes, SetWindowPos, ShowWindow,
    SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
    SM_YVIRTUALSCREEN, SWP_NOACTIVATE, SWP_NOOWNERZORDER, SWP_NOMOVE,
    SWP_NOSIZE, SWP_NOZORDER, SW_SHOWNOACTIVATE, UINT, WHITE_BRUSH,
    WNDCLASSEXW, WNDPROC, WPARAM, WM_DISPLAYCHANGE, WM_SETTINGCHANGE, WS_POPUP,
    WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TRANSPARENT;

import std.conv : to;
import std.format : format;
import std.string : startsWith, strip;
import std.utf : toUTF16z;

/// Dim levels are percentages of darkening: 0 = untouched, 90 = very dark.
private enum int minDimPercent = 0;
private enum int maxDimPercent = 90;

/// Brighten levels are percentages of lightening: 0 = untouched, 60 = strong.
private enum int minBrightenPercent = 0;
private enum int maxBrightenPercent = 60;

/// Which mechanism actually tints the screen.
enum TintEngine
{
    overlay,      ///< Full-screen window overlays (every monitor).
    screenFilter, ///< Magnification color matrix (primary monitor, all surfaces).
}

private int clampDimPercent(int value)
{
    if (value < minDimPercent) return minDimPercent;
    if (value > maxDimPercent) return maxDimPercent;
    return value;
}

private int clampBrightenPercent(int value)
{
    if (value < minBrightenPercent) return minBrightenPercent;
    if (value > maxBrightenPercent) return maxBrightenPercent;
    return value;
}

/// Per-channel scale the full-screen filter applies: <1 dims, >1 brightens.
float combinedTintScale(int dimPercent, bool dimEnabled,
    int brightenPercent, bool brightenEnabled)
{
    float scale = 1.0f;
    if (dimEnabled)
        scale *= 1.0f - (cast(float) dimPercent) / 100.0f;
    if (brightenEnabled)
        scale *= 1.0f + (cast(float) brightenPercent) / 100.0f;
    return scale;
}

// ---------------------------------------------------------------------------
// Full-screen filter engine (Windows Magnification API).
// ---------------------------------------------------------------------------

/// 5x5 color matrix used by `MagSetFullscreenColorEffect`.
private struct MAGCOLOREFFECT
{
    float[5][5] transform;
}

// The Magnification API is loaded at runtime so the app has no link-time
// dependency on Magnification.lib and degrades gracefully when the DLL or the
// entry points are missing.
private alias MagInitializeFn = extern(Windows) BOOL function();
private alias MagUninitializeFn = extern(Windows) BOOL function();
private alias MagSetColorEffectFn = extern(Windows) BOOL function(
    const(MAGCOLOREFFECT)* pEffect);
private alias MagSetTransformFn = extern(Windows) BOOL function(
    float magnification, int xOffset, int yOffset);

private __gshared HMODULE g_magModule;
private __gshared MagInitializeFn g_magInitialize;
private __gshared MagUninitializeFn g_magUninitialize;
private __gshared MagSetColorEffectFn g_magSetColorEffect;
private __gshared MagSetTransformFn g_magSetTransform;
private __gshared bool g_magTried;
private __gshared bool g_magActive;

/// Identity matrix; D floats default to NaN, so every cell is written.
private MAGCOLOREFFECT magIdentity()
{
    MAGCOLOREFFECT effect;
    foreach (i; 0 .. 5)
        foreach (j; 0 .. 5)
            effect.transform[i][j] = (i == j) ? 1.0f : 0.0f;
    return effect;
}

/// Resolve the Magnification entry points once. False if unavailable.
private bool magLoad()
{
    if (g_magTried) return g_magModule !is null;
    g_magTried = true;

    g_magModule = LoadLibraryW("Magnification.dll");
    if (g_magModule is null)
        return false;

    g_magInitialize = cast(MagInitializeFn)
        GetProcAddress(g_magModule, "MagInitialize");
    g_magUninitialize = cast(MagUninitializeFn)
        GetProcAddress(g_magModule, "MagUninitialize");
    g_magSetColorEffect = cast(MagSetColorEffectFn)
        GetProcAddress(g_magModule, "MagSetFullscreenColorEffect");
    g_magSetTransform = cast(MagSetTransformFn)
        GetProcAddress(g_magModule, "MagSetFullscreenTransform");

    if (g_magInitialize is null || g_magSetColorEffect is null ||
        g_magSetTransform is null)
    {
        FreeLibrary(g_magModule);
        g_magModule = null;
        g_magInitialize = null;
        g_magUninitialize = null;
        g_magSetColorEffect = null;
        g_magSetTransform = null;
        return false;
    }
    return true;
}

private void magUnload()
{
    if (g_magModule !is null)
    {
        FreeLibrary(g_magModule);
        g_magModule = null;
    }
    g_magInitialize = null;
    g_magUninitialize = null;
    g_magSetColorEffect = null;
    g_magSetTransform = null;
    g_magTried = false;
}

/// Start the full-screen magnifier at 1x on first use. False if unavailable.
private bool magEnsure()
{
    if (g_magActive) return true;
    if (!magLoad()) return false;
    if (g_magInitialize() == 0) return false;
    // 1x magnification passes the screen through unchanged; the color effect
    // is what tints it.
    g_magSetTransform(1.0f, 0, 0);
    g_magActive = true;
    return true;
}

/// Apply a per-channel scale to the whole primary display (1.0 = no tint).
private void magSetScale(float scale)
{
    if (!magEnsure()) return;
    auto effect = magIdentity();
    effect.transform[0][0] = scale;
    effect.transform[1][1] = scale;
    effect.transform[2][2] = scale;
    g_magSetColorEffect(&effect);
}

/// Clear any tint from the filter without tearing the magnifier down.
private void magReset()
{
    if (g_magActive)
        magSetScale(1.0f);
}

/// Remove the tint and release the magnifier (used when the app closes).
private void magShutdown()
{
    if (g_magActive)
    {
        magSetScale(1.0f);
        if (g_magUninitialize !is null)
            g_magUninitialize();
        g_magActive = false;
    }
    magUnload();
}

// ---------------------------------------------------------------------------
// Overlay engine.
// ---------------------------------------------------------------------------

/// Keep an overlay covering the whole virtual desktop (all monitors).
private void resizeOverlay(HWND hwnd)
{
    if (hwnd is null) return;
    SetWindowPos(hwnd, null,
        GetSystemMetrics(SM_XVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN),
        GetSystemMetrics(SM_CXVIRTUALSCREEN),
        GetSystemMetrics(SM_CYVIRTUALSCREEN),
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
}

/// Shared window procedure for both overlay classes; paints via class brush.
private extern(Windows) LRESULT overlayWindowProc(HWND hwnd, UINT message,
    WPARAM wParam, LPARAM lParam)
{
    switch (message)
    {
    case WM_DISPLAYCHANGE:
    case WM_SETTINGCHANGE:
        resizeOverlay(hwnd);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

/**
 * A single translucent overlay. Its window class carries a solid background
 * brush (black for the dimmer, white for the brightener) which the default
 * window procedure paints, and `SetLayeredWindowAttributes` blends that fill
 * over the desktop at the chosen alpha. The overlay is click-through and never
 * takes focus.
 */
private final class OverlayWindow
{
    private string _className;
    private string _title;
    private HBRUSH _brush;
    private HINSTANCE _module;
    private bool _classRegistered;
    private HWND _hwnd;
    private int _alpha;

    this(string className, string title, HBRUSH brush)
    {
        _className = className;
        _title = title;
        _brush = brush;
        _module = GetModuleHandleW(null);
    }

    /// True once the full-screen overlay exists and is showing.
    bool active() const
    {
        return _hwnd !is null && IsWindow(cast(HWND) _hwnd) != 0;
    }

    /// Create the overlay on first use and re-show it if it ever went away.
    HWND ensure()
    {
        if (active()) return _hwnd;

        if (!_classRegistered)
        {
            WNDCLASSEXW wc;
            wc.cbSize = WNDCLASSEXW.sizeof;
            wc.lpfnWndProc = cast(WNDPROC) &overlayWindowProc;
            wc.hInstance = _module;
            wc.hbrBackground = _brush;
            wc.lpszClassName = toUTF16z(_className);
            if (RegisterClassExW(&wc) == 0)
                return null;
            _classRegistered = true;
        }

        _hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            toUTF16z(_className), toUTF16z(_title),
            WS_POPUP,
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN),
            GetSystemMetrics(SM_CYVIRTUALSCREEN),
            null, null, _module, null);
        if (_hwnd is null)
            return null;

        SetWindowPos(_hwnd, HWND_TOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        ShowWindow(_hwnd, SW_SHOWNOACTIVATE);
        setAlpha(_alpha);
        return _hwnd;
    }

    /// Blend alpha for the layer, 0-255. 0 leaves the desktop untouched.
    void setAlpha(int value)
    {
        if (value < 0) value = 0;
        if (value > 255) value = 255;
        _alpha = value;
        if (active())
            SetLayeredWindowAttributes(_hwnd, 0, cast(BYTE) _alpha, LWA_ALPHA);
    }
}

// ---------------------------------------------------------------------------
// Controller: owns the dim and brighten levels and drives the active engine.
// ---------------------------------------------------------------------------

final class ScreenTintController
{
    private GuiWindow _window;
    private PlatformWindow _platform;
    private OverlayWindow _dimLayer;
    private OverlayWindow _brightenLayer;
    private int _dimPercent;
    private bool _dimEnabled;
    private int _brightenPercent;
    private bool _brightenEnabled;
    private TintEngine _engine;
    private string _lastError;

    this(GuiWindow window, int dimPercent, bool dimEnabled,
        int brightenPercent, bool brightenEnabled,
        TintEngine engine = TintEngine.screenFilter)
    {
        _window = window;
        _platform = cast(PlatformWindow) window.nativeWindow();
        _dimLayer = new OverlayWindow("AuroraDimmerDimOverlay",
            "Aurora Dimmer Overlay", cast(HBRUSH) GetStockObject(BLACK_BRUSH));
        _brightenLayer = new OverlayWindow("AuroraDimmerBrightenOverlay",
            "Aurora Brightener Overlay", cast(HBRUSH) GetStockObject(WHITE_BRUSH));
        _dimPercent = clampDimPercent(dimPercent);
        _dimEnabled = dimEnabled;
        _brightenPercent = clampBrightenPercent(brightenPercent);
        _brightenEnabled = brightenEnabled;
        _engine = engine;
        apply();
    }

    /// Requested darkening, 0-90 percent.
    int dimPercent() const { return _dimPercent; }

    bool dimEnabled() const { return _dimEnabled; }

    /// Overlay alpha actually applied to the dim layer, 0-255.
    int dimAlpha() const { return _dimEnabled ? (_dimPercent * 255) / 100 : 0; }

    /// Requested brightening, 0-60 percent.
    int brightenPercent() const { return _brightenPercent; }

    bool brightenEnabled() const { return _brightenEnabled; }

    /// Overlay alpha actually applied to the brighten layer, 0-255.
    int brightenAlpha() const
    {
        return _brightenEnabled ? (_brightenPercent * 255) / 100 : 0;
    }

    /// Active tint mechanism.
    TintEngine engine() const { return _engine; }

    /// Per-channel scale the full-screen filter would apply right now.
    float screenFilterScale() const
    {
        return combinedTintScale(_dimPercent, _dimEnabled,
            _brightenPercent, _brightenEnabled);
    }

    /// True once the full-screen dim overlay exists and is showing.
    bool dimOverlayActive() const { return _dimLayer.active(); }

    /// True once the full-screen brighten overlay exists and is showing.
    bool brightenOverlayActive() const { return _brightenLayer.active(); }

    /// Empty when the last update succeeded; otherwise the reason it failed.
    string lastError() const { return _lastError; }

    void setDimPercent(int value)
    {
        const next = clampDimPercent(value);
        if (next == _dimPercent) return;
        _dimPercent = next;
        apply();
    }

    void setDimEnabled(bool value)
    {
        if (value == _dimEnabled) return;
        _dimEnabled = value;
        apply();
    }

    void toggleDim() { setDimEnabled(!_dimEnabled); }

    void setBrightenPercent(int value)
    {
        const next = clampBrightenPercent(value);
        if (next == _brightenPercent) return;
        _brightenPercent = next;
        apply();
    }

    void setBrightenEnabled(bool value)
    {
        if (value == _brightenEnabled) return;
        _brightenEnabled = value;
        apply();
    }

    void toggleBrighten() { setBrightenEnabled(!_brightenEnabled); }

    void setEngine(TintEngine value)
    {
        if (value == _engine) return;
        _engine = value;
        apply();
    }

    /// Drop the tint immediately (used when the app is closing).
    void shutdown()
    {
        _dimLayer.setAlpha(0);
        _brightenLayer.setAlpha(0);
        magShutdown();
    }

    private void apply()
    {
        _lastError = "";
        if (_engine == TintEngine.screenFilter)
        {
            // Hide any overlay left over from a previous engine.
            _dimLayer.setAlpha(0);
            _brightenLayer.setAlpha(0);
            magSetScale(screenFilterScale());
        }
        else
        {
            magReset();
            if (_dimLayer.ensure() is null)
                _lastError = "Could not create the dim overlay window.";
            if (_brightenLayer.ensure() is null && _lastError.length == 0)
                _lastError = "Could not create the brighten overlay window.";
            _dimLayer.setAlpha(dimAlpha());
            _brightenLayer.setAlpha(brightenAlpha());
        }
        raiseControl();
    }

    /// Keep the control panel above the full-screen tint layers.
    private void raiseControl()
    {
        if (_platform is null) return;
        HWND hwnd = cast(HWND) _platform.hwnd();
        if (hwnd is null) return;
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    }
}

// ---------------------------------------------------------------------------
// Control panel.
// ---------------------------------------------------------------------------

final class ControlPanelRoot : VBox
{
    private ScreenTintController _controller;
    private Slider _dimSlider;
    private Slider _brightenSlider;
    private Label _dimValueLabel;
    private Label _brightenValueLabel;
    private Label _subtitle;
    private Label _engineHint;
    private Label _statusLabel;

    this(ScreenTintController controller)
    {
        super(12, Insets(18));
        _controller = controller;

        auto title = new Label("Aurora Dimmer");
        title.setScale(3);
        add(title);

        _subtitle = new Label(
            "Darken the desktop for night, brighten it for day.");
        add(_subtitle);

        auto filterBox = new CheckBox("Full-screen filter (covers menus, taskbar)",
            _controller.engine() == TintEngine.screenFilter);
        filterBox.onChanged = (bool value) {
            _controller.setEngine(value ? TintEngine.screenFilter : TintEngine.overlay);
            refresh();
        };
        add(filterBox);

        _engineHint = new Label("");
        add(_engineHint);

        add(new Separator());

        // ---- Dimmer ----
        auto dimHeading = new Label("Darken");
        dimHeading.setScale(2);
        add(dimHeading);

        auto dimRow = new HBox(10);
        // A nested container gets no intrinsic height, so state it explicitly.
        dimRow.layoutHints().preferredHeight = 32;
        auto dimLabel = new Label("Dim level");
        dimLabel.layoutHints().preferredWidth = 96;
        dimRow.add(dimLabel);

        _dimSlider = new Slider(minDimPercent, maxDimPercent, _controller.dimPercent());
        _dimSlider.layoutHints().flex = 1.0;
        _dimSlider.layoutHints().preferredWidth = 200;
        _dimSlider.onChanged = (double value) {
            _controller.setDimPercent(cast(int) (value + 0.5));
            refresh();
        };
        dimRow.add(_dimSlider);

        _dimValueLabel = new Label("");
        _dimValueLabel.setAlignment(HorizontalAlign.right);
        _dimValueLabel.layoutHints().preferredWidth = 56;
        dimRow.add(_dimValueLabel);
        add(dimRow);

        auto dimEnabledBox = new CheckBox("Dimming enabled", _controller.dimEnabled());
        dimEnabledBox.onChanged = (bool value) {
            _controller.setDimEnabled(value);
            refresh();
        };
        add(dimEnabledBox);

        add(buildPresets([0, 25, 45, 65, 85], &_dimSlider));

        add(new Separator());

        // ---- Brightener ----
        auto brightenHeading = new Label("Brighten");
        brightenHeading.setScale(2);
        add(brightenHeading);

        auto brightenRow = new HBox(10);
        brightenRow.layoutHints().preferredHeight = 32;
        auto brightenLabel = new Label("Brighten level");
        brightenLabel.layoutHints().preferredWidth = 96;
        brightenRow.add(brightenLabel);

        _brightenSlider = new Slider(minBrightenPercent, maxBrightenPercent,
            _controller.brightenPercent());
        _brightenSlider.layoutHints().flex = 1.0;
        _brightenSlider.layoutHints().preferredWidth = 200;
        _brightenSlider.onChanged = (double value) {
            _controller.setBrightenPercent(cast(int) (value + 0.5));
            refresh();
        };
        brightenRow.add(_brightenSlider);

        _brightenValueLabel = new Label("");
        _brightenValueLabel.setAlignment(HorizontalAlign.right);
        _brightenValueLabel.layoutHints().preferredWidth = 56;
        brightenRow.add(_brightenValueLabel);
        add(brightenRow);

        auto brightenEnabledBox = new CheckBox("Brightening enabled",
            _controller.brightenEnabled());
        brightenEnabledBox.onChanged = (bool value) {
            _controller.setBrightenEnabled(value);
            refresh();
        };
        add(brightenEnabledBox);

        add(buildPresets([0, 15, 30, 45, 60], &_brightenSlider));

        _statusLabel = new Label("");
        add(_statusLabel);

        refresh();
    }

    /// Build an equal-width row of preset buttons driving one slider.
    private HBox buildPresets(int[] percents, Slider* slider)
    {
        auto presets = new HBox(8);
        presets.layoutHints().preferredHeight = 34;
        foreach (preset; percents)
        {
            auto button = new Button(format("%d%%", preset));
            button.layoutHints().flex = 1.0;
            const target = preset;
            button.onClick = () {
                slider.setValue(target, true); // Routes back through onChanged.
                refresh();
            };
            presets.add(button);
        }
        return presets;
    }

    /// Re-apply theme colors and text. Safe to call after the widget is attached.
    void refresh()
    {
        _subtitle.setColor(theme().textMuted);
        _statusLabel.setColor(theme().textMuted);
        _engineHint.setColor(theme().textMuted);
        _dimValueLabel.setColor(theme().text);
        _brightenValueLabel.setColor(theme().text);

        const filter = _controller.engine() == TintEngine.screenFilter;
        _engineHint.setText(filter
            ? "Filter tints every surface on the primary monitor."
            : "Overlay covers all monitors but leaves menus bright.");

        _dimValueLabel.setText(_controller.dimEnabled()
            ? format("%d%%", _controller.dimPercent()) : "Off");
        _brightenValueLabel.setText(_controller.brightenEnabled()
            ? format("%d%%", _controller.brightenPercent()) : "Off");

        if (_controller.lastError().length > 0)
        {
            _statusLabel.setText(_controller.lastError());
            return;
        }

        string dimText = (_controller.dimEnabled() && _controller.dimPercent() > 0)
            ? format("Dimming to %d%%.", _controller.dimPercent())
            : "Dimming off.";
        string brightenText =
            (_controller.brightenEnabled() && _controller.brightenPercent() > 0)
            ? format("Brightening to %d%%.", _controller.brightenPercent())
            : "Brightening off.";
        _statusLabel.setText(dimText ~ " " ~ brightenText);
    }
}

// ---------------------------------------------------------------------------
// Entry point.
// ---------------------------------------------------------------------------

private WindowOptions dimmerWindowOptions()
{
    WindowOptions options;
    options.title = "Aurora Dimmer";
    options.width = 430;
    options.height = 560;
    options.resizable = false;
    options.decorated = true;
    options.alwaysOnTop = true;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    options.synchronizedDragPointer = false;
    options.enableFullscreenShortcut = false;
    return options;
}

/// Parse `--dim=NN`, `--brighten=NN`, `--off`, `--brighten-off`,
/// `--filter` and `--overlay`.
private void parseArgs(string[] args, ref int dimPercent, ref bool dimEnabled,
    ref int brightenPercent, ref bool brightenEnabled, ref TintEngine engine)
{
    foreach (arg; args[1 .. $])
    {
        const value = strip(arg);
        if (value == "--off" || value == "/off")
            dimEnabled = false;
        else if (value == "--brighten-off" || value == "/brighten-off")
            brightenEnabled = false;
        else if (value == "--filter" || value == "/filter")
            engine = TintEngine.screenFilter;
        else if (value == "--overlay" || value == "/overlay")
            engine = TintEngine.overlay;
        else if (value.startsWith("--dim="))
        {
            try
                dimPercent = clampDimPercent(strip(value["--dim=".length .. $]).to!int);
            catch (Exception)
            {
                // Ignore malformed levels and keep the default.
            }
        }
        else if (value.startsWith("--brighten="))
        {
            try
                brightenPercent =
                    clampBrightenPercent(strip(value["--brighten=".length .. $]).to!int);
            catch (Exception)
            {
                // Ignore malformed levels and keep the default.
            }
        }
    }
}

int run(string[] args)
{
    int initialDimPercent = 45;
    bool initialDimEnabled = true;
    int initialBrightenPercent = 0;
    bool initialBrightenEnabled = false;
    TintEngine initialEngine = TintEngine.screenFilter;
    parseArgs(args, initialDimPercent, initialDimEnabled,
        initialBrightenPercent, initialBrightenEnabled, initialEngine);

    auto window = new GuiWindow(dimmerWindowOptions(), Theme.dark());
    auto controller = new ScreenTintController(window, initialDimPercent,
        initialDimEnabled, initialBrightenPercent, initialBrightenEnabled,
        initialEngine);
    auto root = new ControlPanelRoot(controller);
    window.setRoot(root);
    root.refresh(); // Colors resolve once the widget is attached to the window.
    window.onCloseRequested = () {
        controller.shutdown();
        return true;
    };

    const code = window.run();
    controller.shutdown();
    return code;
}
