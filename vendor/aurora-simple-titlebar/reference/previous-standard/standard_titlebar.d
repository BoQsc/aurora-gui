module aurora.widgets.standard_titlebar;

import aurora.widgets.titlebar;
import aurora.window : GuiWindow;
import aurora.widget : Widget;
import aurora.color : Color;
import aurora.icons : IconKind;
import aurora.types : Rect, Point, PointF, HorizontalAlign, maxInt;
import aurora.event : Event;
import aurora.platform.base : WindowOptions;

/**
 * StandardTitleBar — distilled vendor standard.
 * Moved into vendor/aurora-d-0.4.5/source/aurora/widgets/ per project policy:
 * all Aurora apps share this via `../vendor/aurora-d-0.4.5/source` (no separate top-level lib).
 *
 * Distilled from:
 *   vendor/aurora/widgets/titlebar.d:66  (engine: 8-zone snap, precisePosition, snapSuppressed)
 *   aurora-notepad/source/auroranotepad/titlebar.d:25          (W10 23px, 46px caps, workArea maximize, fractional restore)
 *   aurora-designer/source/auroradesigner/titlebar.d:14        (28px tool variant, 36px caps, dark-first)
 *   aurora-stream/source/app_titlebar.d:24                     (40px broadcast, rounded 6, tray-minimize hook)
 */
enum StandardPreset : ubyte { notepad, designer, stream, browser }

final class StandardTitleBar : TitleBar
{
    private GuiWindow _window;
    private bool _maximized;
    private Rect _restoredBounds;
    private PointF _dragStartWindowOrigin;
    private PointF _dragStartScreenPointer;
    private bool _anchorReady;
    private PointF _pendingOrigin;
    private PointF _pendingPointer;
    private StandardPreset _preset;

    void delegate(TitleBarSnapTarget target, Rect bounds) onSnapPreview;

    this(GuiWindow window, StandardPreset preset = StandardPreset.designer)
    {
        _window = window;
        _preset = preset;
        applyPreset(preset);

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

    StandardPreset preset() const @safe pure nothrow @nogc { return _preset; }
    bool maximizedState() const @safe pure nothrow @nogc { return _maximized; }

    void setPreset(StandardPreset p)
    {
        _preset = p;
        applyPreset(p);
    }

    void setDocumentTitle(string name, bool dirty)
    {
        final switch (_preset)
        {
            case StandardPreset.notepad:
                setTitle((dirty ? "*" : "") ~ name ~ " \u2014 Aurora Notepad");
                break;
            case StandardPreset.designer:
                setTitle((dirty ? "*" : "") ~ name ~ " \u2014 Aurora Designer");
                break;
            case StandardPreset.stream:
                setTitle(name ~ " \u2014 Twitch + YouTube Broadcaster");
                break;
            case StandardPreset.browser:
                setTitle(name.length ? name ~ " \u2014 Aurora Browser" : "Aurora Browser");
                break;
        }
    }

    void setDarkMode(bool dark)
    {
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
            const bg = _preset == StandardPreset.designer ? 0xf5f5f5 : 0xffffff;
            const inactive = _preset == StandardPreset.designer ? 0xe8e8e8 : 0xf0f0f0;
            setBackground(Color.fromHex(bg));
            setInactiveBackground(Color.fromHex(inactive));
            setBorderColor(Color.rgba(0, 0, 0, 0));
            setTextColor(Color.fromHex(0x1a1a1a));
            setMutedTextColor(Color.fromHex(0x6a6a6a));
            setButtonHoverColor(Color.fromHex(0xe5e5e5));
            setButtonPressedColor(Color.fromHex(0xcccccc));
            setCloseHoverColor(Color.fromHex(0xe81123));
            setClosePressedColor(Color.fromHex(0xc42b1c));
        }
    }

    bool delegate() onMinimizeRequestTray;

    private void applyPreset(StandardPreset p)
    {
        final switch (p)
        {
            case StandardPreset.notepad:
                setTitle("Untitled \u2014 Aurora Notepad");
                setIcon(IconKind.notepad);
                setBarHeight(23);
                setIconSize(16);
                setCornerRadius(0);
                setTitleAlign(HorizontalAlign.left);
                setCaptionButtonWidth(46);
                setTitleFontSize(12);
                setDarkMode(false);
                break;
            case StandardPreset.designer:
                setTitle("Untitled \u2014 Aurora Designer");
                setIcon(IconKind.settings);
                setBarHeight(28);
                setIconSize(14);
                setCornerRadius(0);
                setTitleAlign(HorizontalAlign.left);
                setCaptionButtonWidth(36);
                setTitleFontSize(12);
                setDarkMode(true);
                break;
            case StandardPreset.stream:
                setTitle("Aurora Stream \u2014 Twitch + YouTube Broadcaster");
                setIcon(IconKind.terminal);
                setBarHeight(40);
                setIconSize(24);
                setCornerRadius(6);
                setTitleAlign(HorizontalAlign.left);
                setCaptionButtonWidth(46);
                setTitleFontSize(0);
                setBackground(Color.fromHex(0x1b2026));
                setInactiveBackground(Color.fromHex(0x161a1f));
                setBorderColor(Color.fromHex(0x0c0f12));
                setTextColor(Color.fromHex(0xf2f6fa));
                setMutedTextColor(Color.fromHex(0x9ba7b5));
                setButtonHoverColor(Color.fromHex(0x2b333d));
                setButtonPressedColor(Color.fromHex(0x20262d));
                setCloseHoverColor(Color.fromHex(0xe5484d));
                setClosePressedColor(Color.fromHex(0xbf3438));
                onMinimize = delegate() {
                    if (onMinimizeRequestTray !is null && onMinimizeRequestTray())
                        return;
                    _window.minimize();
                };
                break;
            case StandardPreset.browser:
                setTitle("Aurora Browser");
                setIcon(IconKind.none);
                setBarHeight(0);
                setShowIcon(false);
                setCaptionButtonWidth(46);
                break;
        }
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
            if (_window.queryWorkArea(Point(current.x, current.y), workArea) && !workArea.empty)
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
        if (wasFullscreen) _window.toggleFullscreen();
        if (!_restoredBounds.empty) _window.setWindowBounds(_restoredBounds);
        Rect restored;
        _window.windowBounds(restored);
        double grabX = pressPointer.x;
        double grabY = pressPointer.y;
        if (maximizedBounds.width > 0 && restored.width > 0)
            grabX = pressPointer.x * restored.width / maximizedBounds.width;
        grabX = clampDouble(grabX, 0.0, cast(double) maxInt(0, restored.width - 1));
        grabY = clampDouble(grabY, 0.0, cast(double) maxInt(0, restored.height - 1));
        const origin = (hasScreen ? screen : pointer) - PointF(cast(double) grabX, cast(double) grabY);
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
        if (_window.windowBounds(bounds) && rounded.x == bounds.x && rounded.y == bounds.y)
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
        import aurora.widgets.contextmenu : ContextMenuItem, showContextMenu;
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Restore", IconKind.open, delegate() { if (_maximized) toggleMaximize(); }, "", _maximized);
        items ~= ContextMenuItem.command(_maximized ? "Restore down" : "Maximize", IconKind.maximize, delegate() { toggleMaximize(); });
        items ~= ContextMenuItem.command("Minimize", IconKind.minimize, delegate() {
            if (onMinimizeRequestTray !is null && onMinimizeRequestTray()) return;
            _window.minimize();
        }, "", !_window.isMinimized());
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Close", IconKind.close, delegate() { _window.close(); }, "Alt+F4");
        showContextMenu(this, globalPosition, items);
    }
}
