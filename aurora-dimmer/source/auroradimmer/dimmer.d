module auroradimmer.dimmer;

/**
 * Aurora Dimmer - a tiny Windows night-time screen dimmer, plus a matching
 * brightener for daytime use.
 *
 * The control panel is an ordinary Aurora window. The tinting itself is one or
 * two full virtual-screen, always-on-top, click-through layered Win32 windows
 * blended over the desktop at a user-chosen alpha:
 *
 *   - the dimmer paints black, lowering apparent brightness; and
 *   - the brightener paints white, lifting the black level of dark content.
 *
 * Because each layer is only a translucent window, nothing behind it changes:
 * windows, games and video keep running normally and the pointer still reaches
 * them. The two layers are independent and can be combined.
 *
 * Because the layers live above every other window, Aurora's own control
 * window is re-raised above them whenever a level changes.
 */

import aurora;
import aurora.platform.select : PlatformWindow;

import core.sys.windows.windows : BLACK_BRUSH, BYTE, CreateWindowExW,
    DefWindowProcW, GetModuleHandleW, GetStockObject, GetSystemMetrics, HBRUSH,
    HINSTANCE, HWND, HWND_TOPMOST, IsWindow, LPARAM, LRESULT, LWA_ALPHA,
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

/// Brighten levels are percentages of white wash: 0 = untouched, 60 = strong.
private enum int minBrightenPercent = 0;
private enum int maxBrightenPercent = 60;

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
// Controller: owns the dim and brighten levels and keeps the overlays in sync.
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
    private string _lastError;

    this(GuiWindow window, int dimPercent, bool dimEnabled,
        int brightenPercent, bool brightenEnabled)
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
        apply();
    }

    /// Requested darkening, 0-90 percent.
    int dimPercent() const { return _dimPercent; }

    bool dimEnabled() const { return _dimEnabled; }

    /// Layer alpha actually applied to the dim overlay, 0-255.
    int dimAlpha() const { return _dimEnabled ? (_dimPercent * 255) / 100 : 0; }

    /// Requested brightening, 0-60 percent.
    int brightenPercent() const { return _brightenPercent; }

    bool brightenEnabled() const { return _brightenEnabled; }

    /// Layer alpha actually applied to the brighten overlay, 0-255.
    int brightenAlpha() const
    {
        return _brightenEnabled ? (_brightenPercent * 255) / 100 : 0;
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

    /// Drop both tints immediately (used when the app is closing).
    void shutdown()
    {
        _dimLayer.setAlpha(0);
        _brightenLayer.setAlpha(0);
    }

    private void apply()
    {
        _lastError = "";
        if (_dimLayer.ensure() is null)
            _lastError = "Could not create the dim overlay window.";
        if (_brightenLayer.ensure() is null && _lastError.length == 0)
            _lastError = "Could not create the brighten overlay window.";
        _dimLayer.setAlpha(dimAlpha());
        _brightenLayer.setAlpha(brightenAlpha());
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
        _dimValueLabel.setColor(theme().text);
        _brightenValueLabel.setColor(theme().text);

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
    options.height = 500;
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

/// Parse `--dim=NN`, `--brighten=NN`, `--off` and `--brighten-off`.
private void parseArgs(string[] args, ref int dimPercent, ref bool dimEnabled,
    ref int brightenPercent, ref bool brightenEnabled)
{
    foreach (arg; args[1 .. $])
    {
        const value = strip(arg);
        if (value == "--off" || value == "/off")
            dimEnabled = false;
        else if (value == "--brighten-off" || value == "/brighten-off")
            brightenEnabled = false;
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
    parseArgs(args, initialDimPercent, initialDimEnabled,
        initialBrightenPercent, initialBrightenEnabled);

    auto window = new GuiWindow(dimmerWindowOptions(), Theme.dark());
    auto controller = new ScreenTintController(window, initialDimPercent,
        initialDimEnabled, initialBrightenPercent, initialBrightenEnabled);
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
