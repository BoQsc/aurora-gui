module auroranotepad.titlebar;

import aurora;
import auroranotepad.notepadsize : NotepadCaptionButtonWidth,
    NotepadStatusFontPixelSize, NotepadTitleBarHeight;

/**
 * The custom downstream titlebar of the Aurora Notepad.
 *
 * A frameless window's top strip: this widget owns every piece of window
 * chrome behavior for the Notepad and packages it as a single reusable
 * downstream component instead of scattering the wiring across the app root.
 *
 * Built on the vendored `TitleBar` (drag-snap foundation), it adds:
 *  - the Notepad's own light styling;
 *  - owner-driven window move (`onDragStarted`/`onDragMoved`), which for a
 *    frameless WS_POPUP window is used instead of the OS caption move loop;
 *  - restore-on-drag while maximized, re-anchoring the grab under the pointer;
 *  - real work-area maximize/restore through `GuiWindow.setWindowBounds`
 *    (never native fullscreen, so the taskbar stays visible);
 *  - an owner system menu (Restore / Maximize / Minimize / Close);
 *  - aero-style drag snapping, broadcasting preview updates through
 *    `onSnapPreview` and applying the target on release.
 */
final class NotepadTitleBar : TitleBar
{
    private GuiWindow _window;
    private bool _maximized;
    private Rect _restoredBounds;
    private PointF _dragStartWindowOrigin;
    private PointF _dragStartScreenPointer;
    private bool _anchorReady;
    private PointF _pendingOrigin;
    private PointF _pendingPointer;

    /**
     * Fired from `onSnapChanged` while dragging. The root shows its
     * `TitleBarSnapPreview` with the given screen-space bounds, or hides it
     * when `target` is `TitleBarSnapTarget.none`.
     */
    void delegate(TitleBarSnapTarget target, Rect bounds) onSnapPreview;

    this(GuiWindow window)
    {
        _window = window;

        // --- Notepad identity. ---
        setTitle("Untitled — Aurora Notepad");
        setIcon(IconKind.notepad);
        // Slim bar (slightly taller than the first version): the Notepad
        // toolbar takes over the action buttons.
        setBarHeight(NotepadTitleBarHeight);
        // Compact 16 px titlebar icon (Win10-style).
        setIconSize(16);
        setCornerRadius(0);
        setTitleAlign(HorizontalAlign.left);
        // Windows 10 caption buttons are 46 px wide at 120 DPI (36 logical px
        // at 96 DPI), matching SM_CXSIZE = 46 physical.
        setCaptionButtonWidth(NotepadCaptionButtonWidth);
        // Windows 10 caption title is Segoe UI 9 pt (12 px EM at 96 DPI).
        setTitleFontSize(NotepadStatusFontPixelSize);

        // --- Custom downstream styling (light by default). ---
        setDarkMode(false);

        // --- Caption buttons. ---
        onMinimize = delegate() { _window.minimize(); };
        onMaximizeToggle = &toggleMaximize;
        onClose = delegate() { _window.close(); };
        onSystemMenu = &showSystemMenu;

        // --- Drag / restore / snap. ---
        onRestoreRequested = &restoreFromDrag;
        onDragStarted = &beginDrag;
        onDragMoved = &moveDrag;
        onSnapChanged = &broadcastSnapPreview;
        onSnapApplied = &applySnap;
    }

    /** Re-apply the custom downstream light or dark palette (Windows 10). */
    void setDarkMode(bool dark)
    {
        if (dark)
        {
            setBackground(Color.fromHex(0x202020));
            setInactiveBackground(Color.fromHex(0x191919));
            // Borderless: the menu bar below sits flush with the titlebar.
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
            setBackground(Color.fromHex(0xffffff));
            setInactiveBackground(Color.fromHex(0xf0f0f0));
            // Borderless: the menu bar below sits flush with the titlebar.
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0x1a1a1a));
            setMutedTextColor(Color.fromHex(0x6a6a6a));
            setButtonHoverColor(Color.fromHex(0xe5e5e5));
            setButtonPressedColor(Color.fromHex(0xcccccc));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
    }

    /// True when the Notepad window is currently maximized to its work area.
    bool maximizedState() const @safe pure nothrow @nogc { return _maximized; }

    /** Update the visible title from a document name and dirty marker. */
    void setDocumentTitle(string name, bool dirty)
    {
        setTitle((dirty ? "*" : "") ~ name ~ " — Aurora Notepad");
    }

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

    /**
     * Restore-on-drag: the user pressed the titlebar while maximized and
     * dragged. Drop back to the pre-maximize bounds regardless of how the
     * window was maximized (caption button, double-click, or drag-snap to the
     * top edge), then re-anchor the window so the grabbed spot of the titlebar
     * stays under the pointer before the drag continues.
     */
    private void restoreFromDrag(PointF pointer, PointF pressPointer)
    {
        // NOTE: the vendored TitleBar clears its own maximized flag BEFORE
        // firing onRestoreRequested, so the guard must use the app's own
        // `_maximized`, never `maximized()`.
        if (!_maximized) return;
        Rect maximizedBounds;
        _window.windowBounds(maximizedBounds);
        const wasFullscreen = _window.fullscreen();
        PointF screen;
        const hasScreen = _window.queryPointerScreenPosition(screen);
        _maximized = false;
        setMaximized(false);
        // Leave fullscreen when the window was maximized to fullscreen, then
        // ALWAYS force the tracked pre-maximize size so the window reliably
        // returns to its initial size instead of keeping the maximized extent.
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
        if (maximizedBounds.width > 0 && restored.width > 0)
            grabX = pressPointer.x * restored.width / maximizedBounds.width;
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
