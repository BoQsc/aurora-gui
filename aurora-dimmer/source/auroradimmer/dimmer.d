module auroradimmer.dimmer;

/**
 * Aurora Dimmer - a tiny Windows night-time screen dimmer.
 *
 * The control panel is an ordinary Aurora window. The darkening itself is a
 * full virtual-screen, always-on-top, click-through layered Win32 window that
 * is blended over the desktop at a user-chosen alpha. Because it is only a
 * translucent layer, nothing behind it changes: windows, games and video keep
 * running normally and the pointer still reaches them.
 *
 * Because the layer lives above every other window, Aurora's own control
 * window is re-raised above it whenever the dim level changes.
 */

import aurora;
import aurora.platform.select : PlatformWindow;

import core.sys.windows.windows : BeginPaint, BLACK_BRUSH, BYTE, CreateWindowExW,
    DefWindowProcW, EndPaint, FillRect, GetClientRect, GetModuleHandleW,
    GetStockObject, GetSystemMetrics, HBRUSH, HDC, HINSTANCE, HWND, HWND_TOPMOST,
    IsWindow, LPARAM, LRESULT, LWA_ALPHA, PAINTSTRUCT, RECT, RegisterClassExW,
    SetLayeredWindowAttributes, SetWindowPos, ShowWindow, SM_CXVIRTUALSCREEN,
    SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SWP_NOACTIVATE,
    SWP_NOOWNERZORDER, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SW_SHOWNOACTIVATE,
    UINT, WNDCLASSEXW, WNDPROC, WPARAM, WM_DISPLAYCHANGE, WM_ERASEBKGND, WM_PAINT,
    WM_SETTINGCHANGE, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    WS_EX_TRANSPARENT, WS_POPUP;

import std.conv : to;
import std.format : format;
import std.string : startsWith, strip;
import std.utf : toUTF16z;

/// Dim levels are percentages of darkening: 0 = untouched, 90 = very dark.
private enum int minDimPercent = 0;
private enum int maxDimPercent = 90;
private enum string overlayClassName = "AuroraDimmerOverlay";

private int clampDimPercent(int value)
{
    if (value < minDimPercent) return minDimPercent;
    if (value > maxDimPercent) return maxDimPercent;
    return value;
}

// ---------------------------------------------------------------------------
// The translucent overlay window.
// ---------------------------------------------------------------------------

private __gshared HWND overlayWindow;
private __gshared HINSTANCE overlayModule;
private __gshared HBRUSH overlayBrush;
private __gshared bool overlayClassRegistered;
private __gshared int overlayAlpha;

/// Keep the overlay covering the whole virtual desktop (all monitors).
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

private extern(Windows) LRESULT overlayWindowProc(HWND hwnd, UINT message,
    WPARAM wParam, LPARAM lParam)
{
    switch (message)
    {
    case WM_ERASEBKGND:
        return 1; // Fully repainted in WM_PAINT; skip the flickery erase.
    case WM_PAINT:
    {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        if (dc !is null)
        {
            RECT rect;
            GetClientRect(hwnd, &rect);
            FillRect(dc, &rect, overlayBrush);
        }
        EndPaint(hwnd, &paint);
        return 0;
    }
    case WM_DISPLAYCHANGE:
    case WM_SETTINGCHANGE:
        resizeOverlay(hwnd);
        return 0;
    default:
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }
}

/// Create the overlay on first use and re-show it if it ever went away.
private HWND ensureOverlay()
{
    if (overlayWindow !is null && IsWindow(overlayWindow))
        return overlayWindow;

    if (!overlayClassRegistered)
    {
        overlayModule = GetModuleHandleW(null);
        WNDCLASSEXW wc;
        wc.cbSize = WNDCLASSEXW.sizeof;
        wc.lpfnWndProc = cast(WNDPROC) &overlayWindowProc;
        wc.hInstance = overlayModule;
        wc.lpszClassName = toUTF16z(overlayClassName);
        if (RegisterClassExW(&wc) == 0)
            return null;
        overlayClassRegistered = true;
    }

    overlayBrush = cast(HBRUSH) GetStockObject(BLACK_BRUSH);

    overlayWindow = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        toUTF16z(overlayClassName), toUTF16z("Aurora Dimmer Overlay"),
        WS_POPUP,
        GetSystemMetrics(SM_XVIRTUALSCREEN),
        GetSystemMetrics(SM_YVIRTUALSCREEN),
        GetSystemMetrics(SM_CXVIRTUALSCREEN),
        GetSystemMetrics(SM_CYVIRTUALSCREEN),
        null, null, overlayModule, null);
    if (overlayWindow is null)
        return null;

    SetWindowPos(overlayWindow, HWND_TOPMOST, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
    ShowWindow(overlayWindow, SW_SHOWNOACTIVATE);
    SetLayeredWindowAttributes(overlayWindow, 0, cast(BYTE) overlayAlpha, LWA_ALPHA);
    return overlayWindow;
}

private void applyOverlayAlpha(int value)
{
    if (value < 0) value = 0;
    if (value > 255) value = 255;
    overlayAlpha = value;
    if (overlayWindow !is null && IsWindow(overlayWindow))
        SetLayeredWindowAttributes(overlayWindow, 0, cast(BYTE) overlayAlpha, LWA_ALPHA);
}

// ---------------------------------------------------------------------------
// Controller: owns the dim level and keeps the overlay in sync.
// ---------------------------------------------------------------------------

final class DimmerController
{
    private GuiWindow _window;
    private PlatformWindow _platform;
    private int _percent;
    private bool _enabled;
    private string _lastError;

    this(GuiWindow window, int percent, bool enabled)
    {
        _window = window;
        _platform = cast(PlatformWindow) window.nativeWindow();
        _percent = clampDimPercent(percent);
        _enabled = enabled;
        apply();
    }

    /// Requested darkening, 0-90 percent.
    int percent() const { return _percent; }

    bool enabled() const { return _enabled; }

    /// Layer alpha actually applied to the overlay, 0-255.
    int alpha() const { return _enabled ? (_percent * 255) / 100 : 0; }

    /// True once the full-screen overlay exists and is showing.
    bool overlayActive() const
    {
        return overlayWindow !is null && IsWindow(overlayWindow) != 0;
    }

    /// Empty when the last update succeeded; otherwise the reason it failed.
    string lastError() const { return _lastError; }

    void setPercent(int value)
    {
        const next = clampDimPercent(value);
        if (next == _percent) return;
        _percent = next;
        apply();
    }

    void setEnabled(bool value)
    {
        if (value == _enabled) return;
        _enabled = value;
        apply();
    }

    void toggleEnabled() { setEnabled(!_enabled); }

    /// Drop the darkening immediately (used when the app is closing).
    void shutdown()
    {
        if (overlayWindow !is null && IsWindow(overlayWindow))
            SetLayeredWindowAttributes(overlayWindow, 0, 0, LWA_ALPHA);
    }

    private void apply()
    {
        _lastError = ensureOverlay() is null
            ? "Could not create the dim overlay window." : "";
        applyOverlayAlpha(alpha());
        raiseControl();
    }

    /// Keep the control panel above the full-screen dim layer.
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

final class DimmerRoot : VBox
{
    private DimmerController _controller;
    private Slider _slider;
    private Label _subtitle;
    private Label _valueLabel;
    private Label _statusLabel;
    private CheckBox _enabledBox;

    this(DimmerController controller)
    {
        super(12, Insets(18));
        _controller = controller;

        auto title = new Label("Aurora Dimmer");
        title.setScale(3);
        add(title);

        _subtitle = new Label(
            "Darkens the desktop for night-time use.");
        add(_subtitle);

        add(new Separator());

        auto levelRow = new HBox(10);
        // A nested container gets no intrinsic height, so state it explicitly.
        levelRow.layoutHints().preferredHeight = 32;
        auto levelLabel = new Label("Dim level");
        levelLabel.layoutHints().preferredWidth = 88;
        levelRow.add(levelLabel);

        _slider = new Slider(minDimPercent, maxDimPercent, _controller.percent());
        _slider.layoutHints().flex = 1.0;
        _slider.layoutHints().preferredWidth = 220;
        _slider.onChanged = (double value) {
            _controller.setPercent(cast(int) (value + 0.5));
            refresh();
        };
        levelRow.add(_slider);

        _valueLabel = new Label("");
        _valueLabel.setAlignment(HorizontalAlign.right);
        _valueLabel.layoutHints().preferredWidth = 56;
        levelRow.add(_valueLabel);
        add(levelRow);

        _enabledBox = new CheckBox("Dimming enabled", _controller.enabled());
        _enabledBox.onChanged = (bool value) {
            _controller.setEnabled(value);
            refresh();
        };
        add(_enabledBox);

        auto presets = new HBox(8);
        presets.layoutHints().preferredHeight = 34;
        foreach (preset; [0, 25, 45, 65, 85])
        {
            auto button = new Button(format("%d%%", preset));
            button.layoutHints().flex = 1.0;
            const target = preset;
            button.onClick = () {
                _slider.setValue(target, true); // Routes back through onChanged.
                refresh();
            };
            presets.add(button);
        }
        add(presets);

        _statusLabel = new Label("");
        add(_statusLabel);

        refresh();
    }

    /// Re-apply theme colors and text. Safe to call after the widget is attached.
    void refresh()
    {
        _subtitle.setColor(theme().textMuted);
        _statusLabel.setColor(theme().textMuted);

        if (!_controller.enabled())
            _valueLabel.setText("Off");
        else
            _valueLabel.setText(format("%d%%", _controller.percent()));

        if (_controller.lastError().length > 0)
            _statusLabel.setText(_controller.lastError());
        else if (!_controller.enabled())
            _statusLabel.setText("Dimming is off. The screen is at full brightness.");
        else if (_controller.percent() <= 0)
            _statusLabel.setText("Dim level 0% - no darkening applied.");
        else
            _statusLabel.setText(format(
                "Dimming the desktop to %d%% of normal brightness.",
                _controller.percent()));
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
    options.height = 312;
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

/// Parse `--dim=NN` and `--off`; anything else is ignored.
private void parseArgs(string[] args, ref int percent, ref bool enabled)
{
    foreach (arg; args[1 .. $])
    {
        const value = strip(arg);
        if (value == "--off" || value == "/off")
        {
            enabled = false;
        }
        else if (value.startsWith("--dim="))
        {
            try
                percent = clampDimPercent(strip(value["--dim=".length .. $]).to!int);
            catch (Exception)
            {
                // Ignore malformed levels and keep the default.
            }
        }
    }
}

int run(string[] args)
{
    int initialPercent = 45;
    bool initialEnabled = true;
    parseArgs(args, initialPercent, initialEnabled);

    auto window = new GuiWindow(dimmerWindowOptions(), Theme.dark());
    auto controller = new DimmerController(window, initialPercent, initialEnabled);
    auto root = new DimmerRoot(controller);
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
