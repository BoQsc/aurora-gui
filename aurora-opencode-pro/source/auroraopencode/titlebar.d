module auroraopencode.titlebar;

import aurora;
import auroraopencode.core : opencodeBackground, opencodeMuted,
    opencodePressed, opencodeSelection, opencodeText, opencodeTitleBarHeight;

/**
 * The Aurora OpenCode Pro titlebar.
 *
 * A frameless window's top strip, built on the vendored `TitleBar` exactly like
 * the Notepad's and Designer's: compact Win10-style caption buttons,
 * owner-driven window move (the OS caption move loop is unreliable on a
 * frameless popup), work-area maximize/restore, restore-on-drag, drag snapping,
 * and an owner-drawn system menu.
 *
 * The application toolbar is installed as the middle content widget, so the
 * native titlebar and the old separate toolbar row collapse into this single
 * 40 px band.
 */
public final class OpenCodeTitleBar : TitleBar
{
    /// Height shared by the titlebar and the merged toolbar.
    public static immutable int titleBarHeight = opencodeTitleBarHeight;

    private GuiWindow _window;
    private bool _maximized;
    private Rect _restoredBounds;
    private PointF _dragStartWindowOrigin;
    private PointF _dragStartScreenPointer;
    private bool _anchorReady;
    private PointF _pendingOrigin;
    private PointF _pendingPointer;

    /** Fired from `onSnapChanged` while dragging; the root shows the preview. */
    void delegate(TitleBarSnapTarget target, Rect bounds) onSnapPreview;

    this(GuiWindow window)
    {
        _window = window;
        // No title text: the app identity is the icon and the merged toolbar,
        // and the whole band is needed for the toolbar controls.
        setTitle("");
        setIcon(IconKind.terminal);
        setBarHeight(titleBarHeight);
        layoutHints().preferredHeight = titleBarHeight;
        setIconSize(16);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        setCaptionButtonWidth(46);
        applyPalette();

        onMinimize = delegate() { _window.minimize(); };
        onMaximizeToggle = &toggleMaximize;
        onClose = delegate() { _window.close(); };
        onSystemMenu = &showSystemMenu;
        onRestoreRequested = &restoreFromDrag;
        onDragStarted = &beginDrag;
        onDragMoved = &moveDrag;
        onSnapChanged = &broadcastSnapPreview;
        onSnapApplied = &applySnap;
    }

    /// Re-apply the app's dark opencode palette.
    private void applyPalette()
    {
        setBackground(opencodeBackground);
        setInactiveBackground(opencodeBackground.lighter(6));
        setBorderColor(Color.rgba(0, 0, 0, 0));
        setTextColor(opencodeText);
        setMutedTextColor(opencodeMuted);
        setButtonHoverColor(opencodePressed);
        setButtonPressedColor(opencodeSelection);
        setCloseHoverColor(Color.fromHex(0xe81123));
        setClosePressedColor(Color.fromHex(0xc42b1c));
    }

    /// True when the window is currently maximized to its work area.
    bool maximizedState() const @safe pure nothrow @nogc { return _maximized; }

    /** Maximize to the monitor work area, or restore the saved bounds. */
    private void toggleMaximize()
    {
        const next = !_maximized;
        _maximized = next;
        setMaximized(next);
        if (next)
        {
            Rect current;
            if (_window.windowBounds(current)) _restoredBounds = current;
            Rect workArea;
            if (_window.queryWorkArea(Point(current.x, current.y), workArea) &&
                !workArea.empty)
                _window.setWindowBounds(workArea);
            else
                _window.toggleFullscreen();
        }
        else if (!_restoredBounds.empty)
        {
            _window.setWindowBounds(_restoredBounds);
        }
    }

    /// Restore-on-drag while maximized, re-anchoring the grabbed spot.
    private void restoreFromDrag(PointF pointer, PointF pressPointer)
    {
        // NOTE: the vendored TitleBar clears its own maximized flag BEFORE
        // firing onRestoreRequested, so the guard uses the app's own state.
        if (!_maximized) return;
        Rect maximizedBounds;
        _window.windowBounds(maximizedBounds);
        const wasFullscreen = _window.fullscreen();
        PointF screen;
        const hasScreen = _window.queryPointerScreenPosition(screen);
        _maximized = false;
        setMaximized(false);
        if (wasFullscreen)
            _window.toggleFullscreen();
        if (!_restoredBounds.empty)
            _window.setWindowBounds(_restoredBounds);
        Rect restored;
        _window.windowBounds(restored);
        double grabX = pressPointer.x;
        double grabY = pressPointer.y;
        if (maximizedBounds.width > 0 && restored.width > 0)
            grabX = pressPointer.x * restored.width / maximizedBounds.width;
        grabX = clampDouble(grabX, 0.0, cast(double) maxInt(0, restored.width - 1));
        grabY = clampDouble(grabY, 0.0, cast(double) maxInt(0, restored.height - 1));
        const origin = (hasScreen ? screen : pointer) -
            PointF(cast(double) grabX, cast(double) grabY);
        _window.setWindowPosition(origin.rounded());
        _pendingOrigin = origin;
        _pendingPointer = hasScreen ? screen : pointer;
        _anchorReady = true;
    }

    /**
     * Owner-driven drag. Aurora pointer positions are window-relative, so the
     * grab's absolute screen position is captured here and every move re-applies
     * the delta against the fixed drag-start window origin.
     */
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

    /// Forward a drag-snap target change to the root for its preview overlay.
    private void broadcastSnapPreview(TitleBarSnapTarget target, Rect bounds)
    {
        if (onSnapPreview !is null) onSnapPreview(target, bounds);
    }

    /// Apply a drag-snap target to the real window on release.
    private void applySnap(TitleBarSnapTarget target, Rect bounds)
    {
        _maximized = target == TitleBarSnapTarget.top;
        setMaximized(_maximized);
        if (_maximized && !_window.fullscreen())
        {
            Rect current;
            if (_window.windowBounds(current)) _restoredBounds = current;
        }
        _window.setWindowBounds(bounds);
    }

    /// Owner-drawn system menu, opened by a right click on the title area.
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
}
