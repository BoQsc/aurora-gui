module auroradesigner.titlebar;

import aurora;
import std.string : format;

/**
 * The Aurora Designer titlebar.
 *
 * Frameless window chrome built on the vendored `TitleBar` exactly like the
 * Notepad's: slim bar, compact Win10-style caption buttons, owner-driven
 * window move, work-area maximize/restore, restore-on-drag, drag snapping,
 * and an owner-drawn system menu.
 */
final class DesignerTitleBar : TitleBar
{
    private GuiWindow _window;
    private bool _maximized;
    private Rect _restoredBounds;
    private PointF _dragStartWindowOrigin;
    private PointF _dragStartScreenPointer;
    private bool _anchorReady;
    private PointF _pendingOrigin;
    private PointF _pendingPointer;
    private bool _dark;

    /** Fired from `onSnapChanged` while dragging; the root shows the preview. */
    void delegate(TitleBarSnapTarget target, Rect bounds) onSnapPreview;

    this(GuiWindow window)
    {
        _window = window;
        setTitle("Untitled — Aurora Designer");
        setIcon(IconKind.settings);
        setBarHeight(28);
        setIconSize(14);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        setCaptionButtonWidth(36);
        setTitleFontSize(12);
        setDarkMode(true);

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

    /// Re-apply the designer palette (dark by default).
    void setDarkMode(bool dark)
    {
        _dark = dark;
        if (dark)
        {
            setBackground(Color.fromHex(0x202020));
            setInactiveBackground(Color.fromHex(0x191919));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0xffffff));
            setMutedTextColor(Color.fromHex(0xa0a0a0));
            setButtonHoverColor(Color.fromHex(0x3c3c3c));
            setButtonPressedColor(Color.fromHex(0x4a4a4a));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
        else
        {
            setBackground(Color.fromHex(0xf5f5f5));
            setInactiveBackground(Color.fromHex(0xe8e8e8));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0x1a1a1a));
            setMutedTextColor(Color.fromHex(0x6a6a6a));
            setButtonHoverColor(Color.fromHex(0xe5e5e5));
            setButtonPressedColor(Color.fromHex(0xcccccc));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
    }

    bool darkMode() const @safe pure nothrow @nogc { return _dark; }
    bool maximizedState() const @safe pure nothrow @nogc { return _maximized; }

    void setDocumentTitle(string name, bool dirty)
    {
        setTitle((dirty ? "*" : "") ~ name ~ " — Aurora Designer");
    }

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

    private void restoreFromDrag(PointF pointer, PointF pressPointer)
    {
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

    private void broadcastSnapPreview(TitleBarSnapTarget target, Rect bounds)
    {
        if (onSnapPreview !is null) onSnapPreview(target, bounds);
    }

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
