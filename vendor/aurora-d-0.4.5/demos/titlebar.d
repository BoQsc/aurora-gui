module demos.titlebar;

import aurora;
import std.conv : to;
import std.stdio : writeln;

/**
 * Aurora TitleBar demo.
 *
 * A frameless window whose entire top strip is a completely customized
 * `TitleBar` widget. The window is moved owner-side through the TitleBar's
 * drag delegates (`onDragStarted`/`onDragMoved`) using `setWindowPosition`,
 * not the OS caption loop: for a frameless WS_POPUP window the native move
 * loop draws the system frame and flashes aero-snap borders, and the software
 * resize proxy can present stale frames while it runs.
 */
final class TitleBarDemoRoot : Widget
{
    private TitleBar _titleBar;
    private Label _message;
    private int _eventCount;
    private bool _maximized;
    private GuiWindow _window;
    private PointF _dragStartPointer;

    this(GuiWindow window)
    {
        _window = window;
        _titleBar = add(new TitleBar());
        _titleBar.setTitle("Aurora Custom TitleBar");
        _titleBar.setIcon(IconKind.computer);
        _titleBar.setBarHeight(44);
        _titleBar.setCornerRadius(8);
        _titleBar.setBackground(Color.fromHex(0x232a33));
        _titleBar.setInactiveBackground(Color.fromHex(0x1b2129));
        _titleBar.setBorderColor(Color.fromHex(0x10141a));
        setAccentColors();

        auto searchField = new TextField();
        searchField.setPlaceholder("Search clips, tracks, effects…");
        searchField.setContentCentered(true);
        searchField.setTransparentBackground(true);
        searchField.setTextColor(Color.fromHex(0xf2f6fa));
        _titleBar.setContent(searchField);

        _message = add(new Label("Drag the bar, double-click, right-click, or press the caption buttons."));
        _message.setAlignment(HorizontalAlign.center, VerticalAlign.middle);
        _message.setColor(Color.fromHex(0xd8e2ec));
        _message.setScale(2);

        _titleBar.onMinimize = delegate() { announce("Minimize requested (native minimize not exposed)"); };
        _titleBar.onMaximizeToggle = delegate()
        {
            _maximized = !_maximized;
            _titleBar.setMaximized(_maximized);
            _window.toggleFullscreen();
            announce(_maximized ? "Maximized" : "Restored");
        };
        _titleBar.onDoubleClick = delegate() { announce("Double-clicked the title"); };
        _titleBar.onClose = delegate() { _window.close(); };
        _titleBar.onSystemMenu = &showSystemMenu;
        _titleBar.onRestoreRequested = &restoreFromDrag;
        _titleBar.onDragStarted = &beginDrag;
        _titleBar.onDragMoved = &moveDrag;
    }

    /**
     * Restore-on-drag: the user pressed the titlebar while fullscreen and
     * dragged. Exit fullscreen, then re-anchor the window so the grabbed spot
     * of the titlebar stays under the pointer before the drag continues.
     */
    private void restoreFromDrag(PointF pointer, PointF pressPointer)
    {
        if (!_maximized) return;
        Rect fullscreenBounds;
        const hadBounds = _window.windowBounds(fullscreenBounds);
        _maximized = false;
        _titleBar.setMaximized(false);
        _window.toggleFullscreen();
        if (hadBounds)
        {
            const grabOffset = pressPointer - PointF(fullscreenBounds.x,
                fullscreenBounds.y);
            const topLeft = pointer - grabOffset;
            _window.setWindowPosition(topLeft.rounded());
        }
        announce("Restored (drag)");
    }

    /**
     * Owner-driven drag. Aurora pointer positions are window-relative, while
     * window bounds are screen positions; the window must be moved by the
     * pointer DELTA from the drag start (deltas are identical in both spaces).
     * Using an absolute grab offset here would feed the synthesized mouse-move
     * back into the move and make the window hunt/shake.
     */
    private void beginDrag(PointF startPointer, PointF startPosition)
    {
        _dragStartPointer = startPointer;
    }

    private bool moveDrag(PointF pointer, bool requestFrame)
    {
        // The pointer arrives in window-relative coordinates, and moving the
        // window synthesizes further mouse-moves inside it. Apply the pointer
        // delta against the CURRENT window origin: a real cursor move yields
        // the true delta, while a synthesized event yields delta 0 (the cursor
        // sits at the same grab offset), so the loop closes instead of
        // bouncing the window between two spots.
        Rect bounds;
        if (!_window.windowBounds(bounds)) return false;
        const delta = pointer - _dragStartPointer;
        const target = PointF(bounds.x, bounds.y) + delta;
        const rounded = target.rounded();
        if (rounded.x == bounds.x && rounded.y == bounds.y) return true;
        _window.setWindowPosition(rounded);
        // Synchronously repaint after each move so DWM re-captures the surface
        // immediately: regions dragged back from off-screen would otherwise
        // stay white until a deferred paint reached them.
        _window.redrawWindow();
        return true;
    }

    private void setAccentColors()
    {
        _titleBar.setTextColor(Color.fromHex(0xf2f6fa));
        _titleBar.setMutedTextColor(Color.fromHex(0x9fb0c0));
        _titleBar.setButtonHoverColor(Color.fromHex(0x3b4757));
        _titleBar.setButtonPressedColor(Color.fromHex(0x222a33));
        _titleBar.setCloseHoverColor(Color.fromHex(0xe5484d));
        _titleBar.setClosePressedColor(Color.fromHex(0xbf3438));
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
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Close", IconKind.close,
            delegate() { _window.close(); }, "Alt+F4");
        showContextMenu(this, globalPosition, items);
    }

    private void toggleMaximize()
    {
        _maximized = !_maximized;
        _titleBar.setMaximized(_maximized);
        _window.toggleFullscreen();
        announce(_maximized ? "Maximized" : "Restored");
    }

    private void announce(string text)
    {
        ++_eventCount;
        _message.setText(text ~ "  •  event " ~ to!string(_eventCount));
        writeln("Aurora titlebar: ", text);
    }

    protected override void onLayout()
    {
        _titleBar.setBounds(Rect(0, 0, bounds().width, _titleBar.barHeight()));
        _message.setBounds(Rect(0, _titleBar.barHeight(), bounds().width,
            maxInt(0, bounds().height - _titleBar.barHeight())));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        canvas.fillVerticalGradient(Rect(0, 0, bounds().width, bounds().height),
            Color.fromHex(0x22334a), Color.fromHex(0x141b24));
    }
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Custom TitleBar Demo";
    options.width = 1080;
    options.height = 640;
    options.x = 60;
    options.y = 60;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    // Keep the native pointer during titlebar drags; Aurora's synchronized
    // drawn cursor is meant for dragging retained compositor layers.
    options.synchronizedDragPointer = false;
    auto window = new GuiWindow(options, Theme.dark());
    window.setRoot(new TitleBarDemoRoot(window));
    return window.run();
}
