module app_titlebar;

import aurora;
import aurorastream.appversion : appDisplayName, appFullVersion;
import aurorastream.audiobridge : runAudioBridgeHelper;
import aurorastream.entry : applicationIconPath, printAudioEndpointsJson,
    recordStartupFailure, runAudioBridgeSessionTest;
import aurorastream.ffmpegbundle : enableBundledFfmpeg;
import aurorastream.pacingdiagnostic : runStreamPacingDiagnostic;
import aurorastream.root : StreamRoot;
import std.stdio : writeln;

/**
 * Custom-titlebar entry for Aurora Stream.
 *
 * A frameless window whose top strip is the reusable `TitleBar` widget,
 * hosting the unchanged `StreamRoot` broadcaster UI below it. This is the
 * default build configuration (`application`, target `aurora-stream`); the
 * `notitlebar` configuration (`aurora-stream-notitlebar`) keeps the plain
 * OS-titlebar window.
 */
final class TitleBarStreamRoot : Widget
{
    private GuiWindow _window;
    private TitleBar _titleBar;
    private StreamRoot _stream;
    private bool _maximized;
    private PointF _dragStartWindowOrigin;
    private PointF _dragStartScreenPointer;
    private bool _anchorReady;
    private PointF _pendingOrigin;
    private PointF _pendingPointer;

    this(GuiWindow window, string executablePath)
    {
        _window = window;
        _titleBar = add(new TitleBar());
        _titleBar.setTitle(appDisplayName);
        // Show the application's own icon (from assets or beside the exe).
        const iconPath = applicationIconPath();
        try
        {
            auto icon = loadIcoImage(iconPath, 24);
            if (icon !is null) _titleBar.setIconImage(icon);
        }
        catch (Exception)
        {
            _titleBar.setIcon(IconKind.terminal);
        }
        if (_titleBar.iconImage() is null)
            _titleBar.setIcon(IconKind.terminal);
        _titleBar.setBarHeight(40);
        _titleBar.setCornerRadius(6);
        _titleBar.setBackground(Color.fromHex(0x1b2026));
        _titleBar.setInactiveBackground(Color.fromHex(0x161a1f));
        _titleBar.setBorderColor(Color.fromHex(0x0c0f12));
        _titleBar.setTextColor(Color.fromHex(0xf2f6fa));
        _titleBar.setMutedTextColor(Color.fromHex(0x9ba7b5));
        _titleBar.setButtonHoverColor(Color.fromHex(0x2b333d));
        _titleBar.setButtonPressedColor(Color.fromHex(0x20262d));
        _titleBar.setCloseHoverColor(Color.fromHex(0xe5484d));
        _titleBar.setClosePressedColor(Color.fromHex(0xbf3438));
        _titleBar.onMinimize = delegate() { _window.minimize(); };
        _titleBar.onMaximizeToggle = &toggleMaximize;
        _titleBar.onClose = delegate() { _window.close(); };
        _titleBar.onSystemMenu = &showSystemMenu;
        _titleBar.onRestoreRequested = &restoreFromDrag;
        _titleBar.onDragStarted = &beginDrag;
        _titleBar.onDragMoved = &moveDrag;

        _stream = add(new StreamRoot(window, executablePath));
    }

    void shutdown()
    {
        _stream.shutdown();
    }

    private void toggleMaximize()
    {
        _maximized = !_maximized;
        _titleBar.setMaximized(_maximized);
        _window.toggleFullscreen();
    }

    private void restoreFromDrag(PointF pointer, PointF pressPointer)
    {
        if (!_maximized) return;
        Rect fullscreen;
        const hadFullscreen = _window.windowBounds(fullscreen);
        PointF screen;
        const hasScreen = _window.queryPointerScreenPosition(screen);
        _maximized = false;
        _titleBar.setMaximized(false);
        _window.toggleFullscreen();
        Rect restored;
        _window.windowBounds(restored);
        // Map the grab point from the fullscreen titlebar into the restored
        // titlebar by preserving its fractional position (the maximized window
        // is wider than the restored one). The titlebar height is unchanged, so
        // only X is scaled; both are clamped to the restored size.
        double grabX = pressPointer.x;
        double grabY = pressPointer.y;
        if (hadFullscreen && fullscreen.width > 0 && restored.width > 0)
            grabX = pressPointer.x * restored.width / fullscreen.width;
        grabX = clampDouble(grabX, 0.0, cast(double) maxInt(0, restored.width - 1));
        grabY = clampDouble(grabY, 0.0, cast(double) maxInt(0, restored.height - 1));
        // Capture the cursor ONCE and reuse it as the drag anchor so the
        // restore position and the continuing drag agree exactly.
        const origin = (hasScreen ? screen : pointer) -
            PointF(cast(double) grabX, cast(double) grabY);
        _window.setWindowPosition(origin.rounded());
        _pendingOrigin = origin;
        _pendingPointer = hasScreen ? screen : pointer;
        _anchorReady = true;
    }

    private void beginDrag(PointF startPointer, PointF startPosition)
    {
        if (_anchorReady)
        {
            _dragStartWindowOrigin = _pendingOrigin;
            _dragStartScreenPointer = _pendingPointer;
            _anchorReady = false;
            return;
        }
        PointF screen;
        if (_window.queryPointerScreenPosition(screen))
        {
            Rect bounds;
            if (_window.windowBounds(bounds))
                _dragStartWindowOrigin = PointF(bounds.x, bounds.y);
            else
                _dragStartWindowOrigin = startPosition;
            _dragStartScreenPointer = screen;
        }
        else
        {
            _dragStartWindowOrigin = startPosition;
            _dragStartScreenPointer = startPointer;
        }
    }

    private bool moveDrag(PointF pointer, bool requestFrame)
    {
        PointF screen;
        if (!_window.queryPointerScreenPosition(screen)) return false;
        const target = _dragStartWindowOrigin + (screen - _dragStartScreenPointer);
        const rounded = target.rounded();
        Rect bounds;
        if (_window.windowBounds(bounds) &&
            rounded.x == bounds.x && rounded.y == bounds.y)
            return true;
        _window.setWindowPosition(rounded);
        _window.redrawWindow();
        return true;
    }

    private void showSystemMenu(Point globalPosition)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Restore", IconKind.open,
            delegate()
            {
                if (_maximized) toggleMaximize();
            }, "", _maximized);
        items ~= ContextMenuItem.command(_maximized ? "Restore down" : "Maximize",
            IconKind.maximize, delegate() { toggleMaximize(); });
        items ~= ContextMenuItem.command("Minimize", IconKind.minimize,
            delegate() { _window.minimize(); }, "", !_window.isMinimized());
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Close", IconKind.close,
            delegate() { _window.close(); }, "Alt+F4");
        showContextMenu(this, globalPosition, items);
    }

    protected override void onLayout()
    {
        const barHeight = _titleBar.barHeight();
        _titleBar.setBounds(Rect(0, 0, bounds().width, barHeight));
        _stream.setBounds(Rect(0, barHeight, bounds().width,
            maxInt(0, bounds().height - barHeight)));
    }
}

private int runTitleBarApplication(string executablePath)
{
    WindowOptions options;
    options.title = appDisplayName ~ " — Twitch + YouTube Broadcaster";
    options.iconPath = applicationIconPath();
    options.width = 1280;
    options.height = 780;
    options.resizable = true;
    options.lowLatency = true;
    options.synchronizedDragPointer = false;
    options.decorated = false;
    options.vsync = true;
    options.renderer = RendererPreference.automatic;

    auto theme = Theme.dark();
    theme.windowBackground = Color.fromHex(0x121519);
    theme.panelBackground = Color.fromHex(0x1b2026);
    theme.panelElevated = Color.fromHex(0x252c34);
    theme.fieldBackground = Color.fromHex(0x0e1115);
    theme.buttonBackground = Color.fromHex(0x2b333d);
    theme.buttonHover = Color.fromHex(0x37424e);
    theme.buttonPressed = Color.fromHex(0x20262d);
    theme.border = Color.fromHex(0x414b57);
    theme.accent = Color.fromHex(0x5a8ef0);
    theme.selection = Color.fromHex(0x385f9c);
    theme.cornerRadius = 5;
    theme.controlHeight = 36;
    theme.spacing = 7;

    auto window = new GuiWindow(options, theme);
    auto root = new TitleBarStreamRoot(window, executablePath);
    window.setRoot(root);
    window.onCloseRequested = delegate() {
        root.shutdown();
        return true;
    };
    return window.run();
}

int main(string[] arguments)
{
    // A single-exe build embeds ffmpeg.exe/ffprobe.exe; extract them (first
    // run) and put them first on PATH so every "ffmpeg"/"ffprobe" invocation
    // in this process uses the bundled copies.
    enableBundledFfmpeg();

    // The titlebar build is GUI-subsystem (no console), so a diagnostic
    // command must create one for its stdout output.
    if (arguments.length > 1 && isDiagnosticCommand(arguments[1]))
        attachDiagnosticConsole();

    if (arguments.length > 1 &&
        (arguments[1] == "--version" || arguments[1] == "-v"))
    {
        writeln(appFullVersion);
        return 0;
    }
    if (arguments.length > 1 && arguments[1] == "--list-audio-endpoints-json")
        return printAudioEndpointsJson();
    if (arguments.length > 1 && arguments[1] == "--audio-bridge-session-test")
        return runAudioBridgeSessionTest(arguments[0], arguments);
    if (arguments.length > 1 && arguments[1] == "--audio-rtp-helper")
        return runAudioBridgeHelper(arguments);
    if (arguments.length > 1 && arguments[1] == "--pacing-test")
        return runStreamPacingDiagnostic(arguments[0]);

    try return runTitleBarApplication(arguments[0]);
    catch (Throwable error)
    {
        string details;
        try details = "Aurora Stream could not start.\r\n\r\n" ~ error.toString();
        catch (Throwable) details = "Aurora Stream could not start: " ~ error.msg;
        recordStartupFailure(details);
        return 1;
    }
}

private bool isDiagnosticCommand(string command)
{
    // `--audio-rtp-helper` is deliberately NOT a console-allocating diagnostic
    // command: the broadcaster spawns it with Config.suppressConsole, it
    // communicates only through status/metrics files and UDP, and it never
    // writes to stdout, so allocating a console would pop up a stray command
    // prompt on every Start streaming.
    return command == "--version" || command == "-v" ||
        command == "--list-audio-endpoints-json" ||
        command == "--audio-bridge-session-test" ||
        command == "--pacing-test";
}

private void attachDiagnosticConsole()
{
    version (Windows)
    {
        import core.sys.windows.windows : AllocConsole;
        import core.stdc.stdio : fflush, freopen, stderr, stdin, stdout;
        if (!AllocConsole()) return;
        freopen("CONOUT$", "w", stdout);
        freopen("CONOUT$", "w", stderr);
        freopen("CONIN$", "r", stdin);
    }
}
