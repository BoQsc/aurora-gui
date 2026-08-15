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
    private TitleBarSnapPreview _snapPreview;
    private int _eventCount;
    private bool _maximized;
    private Rect _restoredBounds;
    private GuiWindow _window;
    private PointF _dragStartWindowOrigin;
    private PointF _dragStartScreenPointer;
    private bool _anchorReady;
    private PointF _pendingOrigin;
    private PointF _pendingPointer;

    this(GuiWindow window)
    {
        _window = window;
        _titleBar = add(new TitleBar());
        _titleBar.setTitle("Aurora");
        // Balance the left title region against the right caption buttons so
        // the hosted search field is centered horizontally in the titlebar.
        _titleBar.setTitleWidth(100);
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
        _titleBar.setContentWidth(300);
        _titleBar.setContent(searchField);

        _message = add(new Label("Drag the bar, double-click, right-click, or press the caption buttons."));
        _message.setAlignment(HorizontalAlign.center, VerticalAlign.middle);
        _message.setColor(Color.fromHex(0xd8e2ec));
        _message.setScale(2);

        // Snap-preview overlay: added last so it paints above all content. The
        // overlay is created disabled, so it never intercepts pointer input.
        _snapPreview = add(new TitleBarSnapPreview());

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
        _titleBar.onSnapChanged = &updateSnapPreview;
        _titleBar.onSnapApplied = &applySnap;
    }

    /** Show/hide the translucent preview while a drag crosses a snap zone. */
    private void updateSnapPreview(TitleBarSnapTarget target, Rect bounds)
    {
        if (target == TitleBarSnapTarget.none)
        {
            _snapPreview.hide();
            return;
        }
        Rect origin;
        _window.windowBounds(origin);
        _snapPreview.show(Rect(bounds.x - origin.x, bounds.y - origin.y,
            bounds.width, bounds.height));
    }

    /** Apply a drag-snap target to the real window on release. */
    private void applySnap(TitleBarSnapTarget target, Rect bounds)
    {
        _snapPreview.hide();
        _maximized = target == TitleBarSnapTarget.top;
        _titleBar.setMaximized(_maximized);
        if (_maximized && !_window.fullscreen())
        {
            Rect current;
            if (_window.windowBounds(current)) _restoredBounds = current;
        }
        _window.setWindowBounds(bounds);
        announce(_maximized ? "Snapped: maximize" : "Snapped to bounds");
    }

    /**
     * Restore-on-drag: the user pressed the titlebar while maximized and
     * dragged. Leave fullscreen when the window was maximized to fullscreen,
     * then ALWAYS force the tracked pre-maximize size so the window reliably
     * returns to its initial size instead of keeping the maximized extent.
     * Finally re-anchor the window so the grabbed spot of the titlebar stays
     * under the pointer before the drag continues.
     */
    private void restoreFromDrag(PointF pointer, PointF pressPointer)
    {
        if (!_maximized) return;
        Rect maximized;
        _window.windowBounds(maximized);
        const wasFullscreen = _window.fullscreen();
        PointF screen;
        const hasScreen = _window.queryPointerScreenPosition(screen);
        _maximized = false;
        _titleBar.setMaximized(false);
        if (wasFullscreen)
            _window.toggleFullscreen();
        if (!_restoredBounds.empty)
            _window.setWindowBounds(_restoredBounds);
        Rect restored;
        _window.windowBounds(restored);
        // Map the grab point from the maximized titlebar into the restored
        // titlebar by preserving its FRACTIONAL position (the maximized window
        // is wider than the restored one, so keeping the raw client offset
        // leaves the cursor noticeably off — e.g. grabbing the middle would
        // land past center). The titlebar height is unchanged, so only X is
        // scaled; both are clamped to the restored size.
        double grabX = pressPointer.x;
        double grabY = pressPointer.y;
        if (maximized.width > 0 && restored.width > 0)
            grabX = pressPointer.x * restored.width / maximized.width;
        grabX = clampDouble(grabX, 0.0, cast(double) maxInt(0, restored.width - 1));
        grabY = clampDouble(grabY, 0.0, cast(double) maxInt(0, restored.height - 1));
        // Capture the cursor ONCE and reuse it as the drag anchor, so the
        // restore position and the continuing drag agree exactly.
        const origin = (hasScreen ? screen : pointer) -
            PointF(cast(double) grabX, cast(double) grabY);
        _window.setWindowPosition(origin.rounded());
        _pendingOrigin = origin;
        _pendingPointer = hasScreen ? screen : pointer;
        _anchorReady = true;
        announce("Restored (drag)");
    }

    /**
     * Owner-driven drag. Aurora pointer positions are window-relative, so the
     * grab's absolute screen position is captured here and every move re-applies
     * the delta against the FIXED drag-start window origin. Computing from the
     * current window bounds would accumulate each move's full delta and make
     * the window drift away from the cursor. Using the real screen cursor
     * position (GetCursorPos) also keeps synthesized mouse-moves — generated
     * while the captured window moves under the pointer — from feeding back.
     */
    private void beginDrag(PointF startPointer, PointF startPosition)
    {
        if (_anchorReady)
        {
            // Restore-on-drag already sampled the cursor and positioned the
            // window; reuse that exact sample as the drag anchor.
            _dragStartWindowOrigin = _pendingOrigin;
            _dragStartScreenPointer = _pendingPointer;
            _anchorReady = false;
            return;
        }
        // Anchor the grab to the REAL screen cursor position, never to the
        // event's window-relative pointer combined with the current bounds.
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
        // Synchronously repaint after each move so regions dragged back from
        // off-screen are filled instead of showing stale DWM composition.
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
        if (_maximized || _window.fullscreen())
        {
            // Leaving maximize: force the tracked pre-maximize size so the
            // window never stays at the maximized extent.
            _maximized = false;
            _titleBar.setMaximized(false);
            if (_window.fullscreen()) _window.toggleFullscreen();
            if (!_restoredBounds.empty) _window.setWindowBounds(_restoredBounds);
        }
        else
        {
            Rect bounds;
            if (_window.windowBounds(bounds)) _restoredBounds = bounds;
            _maximized = true;
            _titleBar.setMaximized(true);
            _window.toggleFullscreen();
        }
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
        _snapPreview.setBounds(Rect(0, 0, bounds().width, bounds().height));
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
