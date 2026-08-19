module aurora.widgets.titlebar;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, MouseButton;
import aurora.font : FontRole;
import aurora.icons : IconKind, drawIcon;
import aurora.image : RgbaImage;
import aurora.text.layout : TextLayoutOptions;
import aurora.types : CursorKind, HorizontalAlign, Point, PointF, Rect, Size,
    VerticalAlign, maxInt, minInt;
import aurora.widget : Widget;
import std.utf : toUTF32;

/** Identifies a TitleBar region hit by a local point. */
enum TitleBarControl : ubyte
{
    none,
    icon,
    title,
    minimize,
    maximize,
    close
}

/**
 * Drag-snap target derived from the pointer's position against the monitor
 * work area while the title bar is being dragged.
 */
enum TitleBarSnapTarget : ubyte
{
    /** No snap zone is active. */
    none,
    /** Pointer near the top edge: maximize to the full work area. */
    top,
    /** Pointer near the left edge: left half of the work area. */
    left,
    /** Pointer near the right edge: right half of the work area. */
    right,
    topLeft,
    topRight,
    bottomLeft,
    bottomRight
}

private struct OptionalColor
{
    Color value;
    bool customized;

    Color resolve(Color fallback) const @safe pure nothrow @nogc
    {
        return customized ? value : fallback;
    }
}

/**
 * A completely customizable in-canvas title bar.
 *
 * Everything from the title text, icon, caption buttons, colors, height, and
 * drag behavior is configurable. The bar can drive an in-canvas container
 * through drag delegates, or move a native frameless window through the host
 * (`systemMoveOnDrag`). A custom content widget can occupy the middle of the
 * bar, and a right-click opens the owner's system menu through `onSystemMenu`.
 */
class TitleBar : Widget
{
    private dstring _title;
    private IconKind _icon = IconKind.none;
    private RgbaImage _iconImage;
    private Widget _content;
    private int _barHeight = 40;
    private int _captionButtonWidth = 46;
    private int _iconSize = 24;    private int _spacing = 8;
    private bool _showIcon = true;
    private bool _showMinimize = true;
    private bool _showMaximize = true;
    private bool _showClose = true;
    private bool _draggable = true;
    private bool _doubleClickMaximizes = true;
    private bool _active = true;
    private bool _maximized;
    private bool _systemMoveOnDrag;
    private HorizontalAlign _titleAlign = HorizontalAlign.left;
    private int _cornerRadius = 0;
    private int _titleWidth;
    private int _titleMinWidth = 0;
    private int _contentWidth;
    private int _titleFontSize; // 0 = use the theme fontScale tier.

    private OptionalColor _background;
    private OptionalColor _inactiveBackground;
    private OptionalColor _borderColor;
    private OptionalColor _textColor;
    private OptionalColor _mutedTextColor;
    private OptionalColor _buttonHover;
    private OptionalColor _buttonPressed;
    private OptionalColor _closeHover;
    private OptionalColor _closePressed;

    private TitleBarControl _pressedControl;
    private TitleBarControl _hotControl;
    private bool _dragging;
    private bool _armDrag;
    private PointF _dragStartPointer;
    private PointF _dragStartPosition;
    private bool _snapEnabled = true;
    private int _snapThreshold = 8;
    private TitleBarSnapTarget _snapTarget;
    private Rect _snapBounds;
    private bool _snapSuppressed;
    private TitleBarSnapTarget _snapSuppressedZone;

    void delegate() onMinimize;
    void delegate() onMaximizeToggle;
    void delegate() onClose;
    void delegate() onDoubleClick;
    /**
     * Owner-drawn system menu, opened by a right click on the title area.
     */
    void delegate(Point globalPosition) onSystemMenu;
    /**
     * Restore-on-drag: fired once a real drag is detected while the bar is
     * maximized. The owner should leave the maximized/fullscreen state and, if
     * it wants the drag to continue under the pointer, reposition the window.
     * `pointer` is the current pointer and `pressPointer` the original press.
     */
    void delegate(PointF pointer, PointF pressPointer) onRestoreRequested;
    void delegate(PointF startPointer, PointF startPosition) onDragStarted;
    /** Owner-driven window move; return whether the position changed. */
    bool delegate(PointF pointer, bool requestFrame) onDragMoved;
    void delegate() onDragEnded;
    /**
     * Drag-snap target change while dragging. Fired whenever the target
     * changes, including a transition back to `TitleBarSnapTarget.none`
     * (`bounds` is then `Rect.init`). The owner should show/hide its snap
     * preview from the `bounds` (screen coordinates).
     */
    void delegate(TitleBarSnapTarget target, Rect bounds) onSnapChanged;
    /**
     * Drag released over an active snap zone. `bounds` is the target window
     * bounds in screen coordinates; the owner should apply it (typically
     * `GuiWindow.setWindowBounds`) and update its maximized/restored state.
     */
    void delegate(TitleBarSnapTarget target, Rect bounds) onSnapApplied;

    this()
    {
        setCursor(CursorKind.arrow);
    }

    dstring title() const @safe pure nothrow @nogc { return _title; }
    IconKind iconKind() const @safe pure nothrow @nogc { return _icon; }
    RgbaImage iconImage() @safe pure nothrow @nogc { return _iconImage; }
    Widget content() @safe pure nothrow @nogc { return _content; }
    int barHeight() const @safe pure nothrow @nogc { return _barHeight; }
    bool active() const @safe pure nothrow @nogc { return _active; }
    bool maximized() const @safe pure nothrow @nogc { return _maximized; }
    bool draggable() const @safe pure nothrow @nogc { return _draggable; }
    bool systemMoveOnDrag() const @safe pure nothrow @nogc { return _systemMoveOnDrag; }
    bool doubleClickMaximizes() const @safe pure nothrow @nogc
    {
        return _doubleClickMaximizes;
    }
    TitleBarControl hotControl() const @safe pure nothrow @nogc { return _hotControl; }
    TitleBarControl pressedControl() const @safe pure nothrow @nogc
    {
        return _pressedControl;
    }
    bool dragging() const @safe pure nothrow @nogc { return _dragging; }
    bool snapEnabled() const @safe pure nothrow @nogc { return _snapEnabled; }
    int snapThreshold() const @safe pure nothrow @nogc { return _snapThreshold; }
    TitleBarSnapTarget snapTarget() const @safe pure nothrow @nogc
    {
        return _snapTarget;
    }
    /** Current snap preview bounds in screen coordinates; empty when inactive. */
    Rect snapBounds() const @safe pure nothrow @nogc { return _snapBounds; }

    void setTitle(string value)
    {
        const next = toUTF32(value);
        if (_title == next) return;
        _title = next;
        invalidate();
    }

    void setTitle(dstring value)
    {
        if (_title == value) return;
        _title = value;
        invalidate();
    }

    void setIcon(IconKind value)
    {
        if (_icon == value) return;
        _icon = value;
        invalidate();
    }

    /** Show a raster icon (for example the application's own ICO/PNG). */
    void setIconImage(RgbaImage value)
    {
        if (_iconImage is value) return;
        _iconImage = value;
        invalidate();
    }

    void clearIconImage()
    {
        if (_iconImage is null) return;
        _iconImage = null;
        invalidate();
    }

    void setShowIcon(bool value)
    {
        if (_showIcon == value) return;
        _showIcon = value;
        invalidate();
    }

    void setBarHeight(int value)
    {
        value = maxInt(1, value);
        if (_barHeight == value) return;
        _barHeight = value;
        onLayout();
        invalidate();
    }

    /** Icon glyph size drawn in the bar (default 24). */
    void setIconSize(int value)
    {
        value = maxInt(8, value);
        if (_iconSize == value) return;
        _iconSize = value;
        onLayout();
        invalidate();
    }

    void setCaptionButtonWidth(int value)
    {
        value = maxInt(1, value);
        if (_captionButtonWidth == value) return;
        _captionButtonWidth = value;
        onLayout();
        invalidate();
    }

    /** Override the title text pixel size (0 = use the theme fontScale tier). */
    void setTitleFontSize(int value)
    {
        value = maxInt(0, value);
        if (_titleFontSize == value) return;
        _titleFontSize = value;
        invalidate();
    }

    void setShowMinimize(bool value)
    {
        if (_showMinimize == value) return;
        _showMinimize = value;
        onLayout();
        invalidate();
    }

    void setShowMaximize(bool value)
    {
        if (_showMaximize == value) return;
        _showMaximize = value;
        onLayout();
        invalidate();
    }

    void setShowClose(bool value)
    {
        if (_showClose == value) return;
        _showClose = value;
        onLayout();
        invalidate();
    }

    void setDraggable(bool value)
    {
        _draggable = value;
        if (!value && (_dragging || _armDrag))
        {
            _dragging = false;
            _armDrag = false;
            _snapSuppressed = false;
            clearSnap();
            releaseMouse();
            setCursor(CursorKind.arrow);
        }
    }

    void setDoubleClickMaximizes(bool value)
    {
        _doubleClickMaximizes = value;
    }

    void setActive(bool value)
    {
        if (_active == value) return;
        _active = value;
        invalidate();
    }

    void setMaximized(bool value)
    {
        if (_maximized == value) return;
        _maximized = value;
        invalidate();
    }

    void setSystemMoveOnDrag(bool value)
    {
        _systemMoveOnDrag = value;
    }

    /** Enable/disable drag-snap zone detection (on by default). */
    void setSnapEnabled(bool value)
    {
        if (_snapEnabled == value) return;
        _snapEnabled = value;
        if (!value) clearSnap();
    }

    /** Pointer-to-edge distance (logical pixels) that engages a snap zone. */
    void setSnapThreshold(int value)
    {
        value = maxInt(0, value);
        if (_snapThreshold == value) return;
        _snapThreshold = value;
    }

    void setTitleAlign(HorizontalAlign value)
    {
        if (_titleAlign == value) return;
        _titleAlign = value;
        invalidate();
    }

    /** Fixed title-region width; zero lets the bar auto-size it. */
    void setTitleWidth(int value)
    {
        value = maxInt(0, value);
        if (_titleWidth == value) return;
        _titleWidth = value;
        onLayout();
        invalidate();
    }

    void setTitleMinWidth(int value)
    {
        value = maxInt(0, value);
        if (_titleMinWidth == value) return;
        _titleMinWidth = value;
        onLayout();
        invalidate();
    }

    /** Constrain and center the content region; zero spans the full width. */
    void setContentWidth(int value)
    {
        value = maxInt(0, value);
        if (_contentWidth == value) return;
        _contentWidth = value;
        onLayout();
        invalidate();
    }

    int contentWidth() const @safe pure nothrow @nogc { return _contentWidth; }

    /** Round only the top corners; the bottom stays square. */
    void setCornerRadius(int value)
    {
        value = maxInt(0, value);
        if (_cornerRadius == value) return;
        _cornerRadius = value;
        invalidate();
    }

    void setBackground(Color value)
    {
        _background = OptionalColor(value, true);
        invalidate();
    }

    void setInactiveBackground(Color value)
    {
        _inactiveBackground = OptionalColor(value, true);
        invalidate();
    }

    void setBorderColor(Color value)
    {
        _borderColor = OptionalColor(value, true);
        invalidate();
    }

    void setTextColor(Color value)
    {
        _textColor = OptionalColor(value, true);
        invalidate();
    }

    void setMutedTextColor(Color value)
    {
        _mutedTextColor = OptionalColor(value, true);
        invalidate();
    }

    void setButtonHoverColor(Color value)
    {
        _buttonHover = OptionalColor(value, true);
        invalidate();
    }

    void setButtonPressedColor(Color value)
    {
        _buttonPressed = OptionalColor(value, true);
        invalidate();
    }

    void setCloseHoverColor(Color value)
    {
        _closeHover = OptionalColor(value, true);
        invalidate();
    }

    void setClosePressedColor(Color value)
    {
        _closePressed = OptionalColor(value, true);
        invalidate();
    }

    /** Insert a custom widget into the middle of the bar. */
    void setContent(Widget value)
    {
        if (_content !is null) remove(_content);
        _content = value;
        if (_content !is null) add(_content);
        onLayout();
        invalidate();
    }

    void clearContent()
    {
        if (_content is null) return;
        remove(_content);
        _content = null;
        onLayout();
        invalidate();
    }

    private bool titleEmpty() const @safe pure nothrow @nogc
    {
        return _title.length == 0;
    }

    private int titleAreaLeft() const @safe pure nothrow @nogc
    {
        const icon = iconRect();
        return icon.empty ? _spacing : icon.right() + _spacing;
    }

    private int buttonsLeft() const @safe pure nothrow @nogc
    {
        int count = 0;
        if (_showMinimize) ++count;
        if (_showMaximize) ++count;
        if (_showClose) ++count;
        return maxInt(0, bounds().width - count * _captionButtonWidth);
    }

    Rect iconRect() const @safe pure nothrow @nogc
    {
        if (!_showIcon || (_icon == IconKind.none && _iconImage is null))
            return Rect.init;
        const size = minInt(_iconSize, maxInt(1, bounds().height - 8));
        return Rect(_spacing, (bounds().height - size) / 2, size, size);
    }

    Rect titleRect() const @safe pure nothrow @nogc
    {
        const left = titleAreaLeft();
        const rightBound = buttonsLeft() - _spacing;
        if (rightBound <= left) return Rect.init;
        int right = rightBound;
        if (_content !is null && !titleEmpty())
        {
            const available = rightBound - left;
            const allocated = _titleWidth > 0 ? _titleWidth : available * 2 / 5;
            right = left + maxInt(_titleMinWidth, minInt(available, allocated));
        }
        return Rect(left, 0, maxInt(1, right - left), bounds().height);
    }

    Rect contentRect() const @safe pure nothrow @nogc
    {
        if (_content is null) return Rect.init;
        const left = titleEmpty() ? titleAreaLeft() : titleRect().right() + _spacing;
        const right = buttonsLeft() - _spacing;
        if (right <= left) return Rect.init;
        int width = right - left;
        int x = left;
        if (_contentWidth > 0 && _contentWidth < width)
        {
            width = _contentWidth;
            x = left + (right - left - width) / 2;
        }
        return Rect(x, 3, width, maxInt(1, bounds().height - 6));
    }

    Rect captionRect(TitleBarControl control) const @safe pure nothrow @nogc
    {
        // Caption buttons stack right-to-left: close, maximize, minimize.
        int index;
        bool shown;
        switch (control)
        {
            case TitleBarControl.minimize:
                shown = _showMinimize;
                index = 2;
                break;
            case TitleBarControl.maximize:
                shown = _showMaximize;
                index = 1;
                break;
            case TitleBarControl.close:
                shown = _showClose;
                index = 0;
                break;
            default:
                return Rect.init;
        }
        if (!shown) return Rect.init;
        const right = bounds().width - index * _captionButtonWidth;
        return Rect(right - _captionButtonWidth, 0, _captionButtonWidth,
            bounds().height);
    }

    TitleBarControl controlAt(Point position) const @safe pure nothrow @nogc
    {
        if (!containsLocal(position)) return TitleBarControl.none;
        foreach (control; [TitleBarControl.close, TitleBarControl.maximize,
            TitleBarControl.minimize])
        {
            const rect = captionRect(control);
            if (!rect.empty && rect.contains(position)) return control;
        }
        const icon = iconRect();
        if (!icon.empty && icon.contains(position)) return TitleBarControl.icon;
        // Everything else on the bar is the draggable title surface, including
        // the space around a narrow, centered content widget. The content
        // widget itself is hit-tested as a child first, so this is only
        // reached for points outside it.
        return TitleBarControl.title;
    }

    protected override Size onMeasure(Size available)
    {
        return Size(available.width, _barHeight);
    }

    protected override void onLayout()
    {
        if (_content !is null)
            _content.setBounds(contentRect());
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        const background = _background.resolve(palette.panelElevated);
        const inactive = _inactiveBackground.resolve(palette.panelBackground);
        const border = _borderColor.resolve(palette.border);
        const text = _textColor.resolve(palette.text);
        const muted = _mutedTextColor.resolve(palette.textMuted);

        canvas.fillRect(full, _active ? background : inactive);
        if (_cornerRadius > 0 && bounds().height > _cornerRadius)
        {
            // Round the top corners only: a taller rounded rect whose lower
            // half is squared off with the ordinary fill rect above.
            canvas.fillRoundedRect(Rect(0, 0, bounds().width,
                bounds().height + _cornerRadius), _cornerRadius,
                _active ? background : inactive);
            canvas.fillRect(Rect(0, _cornerRadius, bounds().width,
                maxInt(0, bounds().height - _cornerRadius)),
                _active ? background : inactive);
        }
        if (border.a != 0)
            canvas.fillRect(Rect(0, bounds().height - 1, bounds().width, 1), border);

        const icon = iconRect();
        if (!icon.empty)
        {
            if (_iconImage !is null)
                canvas.drawImage(icon, _iconImage, true);
            else
                drawIcon(canvas, _icon, icon, _active ? text : muted);
        }

        const titleArea = titleRect();
        if (!titleArea.empty && !titleEmpty())
        {
            if (_titleFontSize > 0)
            {
                // Custom title pixel size (native 9 pt Windows 10 caption).
                TextLayoutOptions options;
                options.role = FontRole.ui;
                options.overrideFace = cast() palette.uiFont;
                options.pixelSize = _titleFontSize;
                options.wrap = false;
                auto layout = fontSystem().textEngine.layoutCached(_title, options);
                const measured = layout.measuredSize();
                int x = titleArea.x;
                if (_titleAlign == HorizontalAlign.center)
                    x += maxInt(0, (titleArea.width - measured.width) / 2);
                else if (_titleAlign == HorizontalAlign.right)
                    x += maxInt(0, titleArea.width - measured.width);
                const y = titleArea.y + maxInt(0,
                    (titleArea.height - measured.height) / 2);
                auto child = canvas.clipped(titleArea);
                child.drawLayout(Point(x, y), layout, _active ? text : muted);
            }
            else
            {
                canvas.drawTextInRect(titleArea, _title, _active ? text : muted,
                    palette.fontScale, _titleAlign, VerticalAlign.middle, true);
            }
        }

        drawCaptionButton(canvas, TitleBarControl.minimize);
        drawCaptionButton(canvas, TitleBarControl.maximize);
        drawCaptionButton(canvas, TitleBarControl.close);
    }

    private void drawCaptionButton(ref Canvas canvas, TitleBarControl control)
    {
        const rect = captionRect(control);
        if (rect.empty) return;
        const palette = theme();
        const hover = _buttonHover.resolve(palette.buttonHover);
        const pressed = _buttonPressed.resolve(palette.buttonPressed);
        const closeHover = _closeHover.resolve(palette.danger);
        const closePressed = _closePressed.resolve(palette.danger.withAlpha(220));
        const hot = _pressedControl != TitleBarControl.none ? _pressedControl :
            _hotControl;
        const isHot = hot == control;
        if (isHot)
        {
            Color fill;
            if (control == TitleBarControl.close)
                fill = _pressedControl == control ? closePressed : closeHover;
            else
                fill = _pressedControl == control ? pressed : hover;
            canvas.fillRoundedRect(rect.inset(1), 4, fill);
        }
        const color = control == TitleBarControl.close && isHot ?
            Color.rgb(255, 255, 255) : (_active ? palette.text : palette.textMuted);
        const cx = rect.x + rect.width / 2;
        const cy = rect.y + rect.height / 2;
        switch (control)
        {
            case TitleBarControl.minimize:
                canvas.fillRect(Rect(cx - 6, cy + 3, 12, 2), color);
                break;
            case TitleBarControl.maximize:
                if (_maximized)
                {
                    canvas.strokeRect(Rect(cx - 6, cy - 5, 9, 9), color, 1);
                    canvas.strokeRect(Rect(cx + 1, cy - 1, 9, 9), color, 1);
                }
                else
                {
                    canvas.strokeRect(Rect(cx - 6, cy - 6, 12, 12), color, 1);
                }
                break;
            case TitleBarControl.close:
                canvas.drawLine(Point(cx - 6, cy - 6), Point(cx + 6, cy + 6), color, 1);
                canvas.drawLine(Point(cx + 6, cy - 6), Point(cx - 6, cy + 6), color, 1);
                break;
            default:
                break;
        }
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            const control = controlAt(event.position);
            if ((control == TitleBarControl.title || control == TitleBarControl.icon) &&
                onSystemMenu !is null)
            {
                onSystemMenu(event.globalPosition);
                return true;
            }
            return false;
        }
        if (event.button != MouseButton.left) return false;
        const control = controlAt(event.position);
        if (control == TitleBarControl.minimize ||
            control == TitleBarControl.maximize ||
            control == TitleBarControl.close)
        {
            _pressedControl = control;
            captureMouse();
            invalidate();
            return true;
        }
        if (control != TitleBarControl.title && control != TitleBarControl.icon)
            return false;

        // Double-click must win over the single-click move path, otherwise the
        // second press of a double-click (clickCount >= 2) starts another
        // system-move loop and the title bar never maximizes.
        if (_doubleClickMaximizes && event.clickCount >= 2)
        {
            if (onDoubleClick !is null) onDoubleClick();
            if (onMaximizeToggle !is null) onMaximizeToggle();
            return true;
        }
        if (_systemMoveOnDrag)
        {
            // While maximized the OS move loop cannot run yet (the owner must
            // restore the window first). Arm the drag and start the loop once
            // real movement is detected so restore-on-drag can leave maximize
            // and follow the pointer.
            if (_maximized)
            {
                _armDrag = true;
                _snapSuppressed = false;
                _dragStartPointer = pointerPosition(event);
                _dragStartPosition = precisePosition();
                invalidate();
            }
            else
            {
                beginSystemMove();
            }
            return true;
        }
        if (_draggable)
        {
            _armDrag = true;
            _snapSuppressed = false;
            _dragStartPointer = pointerPosition(event);
            _dragStartPosition = precisePosition();
            captureMouse();
            invalidate();
        }
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (_dragging)
        {
            // While dragging, keep the cursor and the hover visuals frozen:
            // synthesized mouse-moves arrive as the window moves under the
            // pointer, and re-running the hot control would flicker the cursor.
            const pointer = pointerPosition(event);
            updateSnapFromScreen();
            return updateDrag(pointer, true);
        }
        const control = controlAt(event.position);
        if (control != _hotControl)
        {
            _hotControl = control;
            setCursor(control == TitleBarControl.minimize ||
                control == TitleBarControl.maximize ||
                control == TitleBarControl.close ? CursorKind.hand : CursorKind.arrow);
            invalidate();
        }
        if (_armDrag && _draggable)
        {
            const pointer = pointerPosition(event);
            const dx = pointer.x - _dragStartPointer.x;
            const dy = pointer.y - _dragStartPointer.y;
            if (dx * dx + dy * dy >= 25.0)
            {
                _armDrag = false;
                if (_maximized)
                {
                    // Restore-on-drag: leave maximize before moving so the
                    // window drops back to its restored size and follows the
                    // pointer. Re-anchor the drag to the current pointer and
                    // position because the owner's restore may have moved or
                    // resized the window. Snap is suppressed until the pointer
                    // leaves the zone it just restored from, so a quick release
                    // cannot snap the window straight back to maximized.
                    _maximized = false;
                    _snapSuppressed = true;
                    _snapSuppressedZone = currentSnapZone();
                    invalidate();
                    if (onRestoreRequested !is null)
                        onRestoreRequested(pointer, _dragStartPointer);
                    _dragStartPointer = pointer;
                    _dragStartPosition = precisePosition();
                }
                if (_systemMoveOnDrag)
                {
                    beginSystemMove();
                    return true;
                }
                _dragging = true;
                // Leave the arrow cursor untouched: dragging the window should
                // not change the pointer. Re-enter capture now that
                // wantsContinuousPointerFrames() is
                // true, activating Aurora's late-latched synchronized pointer.
                captureMouse();
                if (onDragStarted !is null)
                    onDragStarted(_dragStartPointer, _dragStartPosition);
                updateDrag(pointer, true);
            }
            return true;
        }
        return _pressedControl != TitleBarControl.none;
    }

    override bool onPointerLatch(PointF globalPosition)
    {
        if (!_dragging) return false;
        updateSnapFromScreen();
        return updateDrag(globalPosition, false);
    }

    override bool wantsContinuousPointerFrames() const @safe pure nothrow @nogc
    {
        return _dragging;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (_dragging)
        {
            // Final drag move is skipped when releasing over an active snap
            // zone: the owner applies the snap bounds instead, so the window
            // never lands on the last pointer position first.
            if (_snapTarget == TitleBarSnapTarget.none)
            {
                const pointer = pointerPosition(event);
                updateDrag(pointer, true);
            }
            else
            {
                const applied = _snapTarget;
                const appliedBounds = _snapBounds;
                _snapTarget = TitleBarSnapTarget.none;
                _snapBounds = Rect.init;
                if (onSnapChanged !is null)
                    onSnapChanged(TitleBarSnapTarget.none, Rect.init);
                if (onSnapApplied !is null)
                    onSnapApplied(applied, appliedBounds);
            }
            _dragging = false;
            _armDrag = false;
            _snapSuppressed = false;
            setCursor(CursorKind.arrow);
            releaseMouse();
            if (onDragEnded !is null) onDragEnded();
            invalidate();
            return true;
        }
        if (_armDrag)
        {
            _armDrag = false;
            _snapSuppressed = false;
            releaseMouse();
            invalidate();
            return true;
        }
        if (_pressedControl != TitleBarControl.none)
        {
            const pressed = _pressedControl;
            const activate = controlAt(event.position) == pressed;
            _pressedControl = TitleBarControl.none;
            releaseMouse();
            invalidate();
            if (activate)
            {
                switch (pressed)
                {
                    case TitleBarControl.minimize:
                        if (onMinimize !is null) onMinimize();
                        break;
                    case TitleBarControl.maximize:
                        if (onMaximizeToggle !is null) onMaximizeToggle();
                        break;
                    case TitleBarControl.close:
                        if (onClose !is null) onClose();
                        break;
                    default:
                        break;
                }
            }
            return true;
        }
        return false;
    }

    protected override void onMouseLeave()
    {
        if (_hotControl != TitleBarControl.none)
        {
            _hotControl = TitleBarControl.none;
            invalidate();
        }
    }

    private bool updateDrag(PointF pointer, bool requestFrame)
    {
        if (onDragMoved !is null)
            return onDragMoved(pointer, requestFrame);
        if (!_draggable) return false;
        return setPrecisePosition(_dragStartPosition + (pointer - _dragStartPointer),
            requestFrame);
    }

    /** Re-evaluate the drag-snap zone from the live screen pointer position. */
    private void updateSnapFromScreen()
    {
        if (!_snapEnabled || !_dragging)
        {
            clearSnap();
            return;
        }
        PointF screen;
        if (!queryPointerScreenPosition(screen))
        {
            clearSnap();
            return;
        }
        Rect workArea;
        if (!queryWorkArea(screen.rounded(), workArea))
        {
            clearSnap();
            return;
        }
        const target = snapTargetFor(screen, workArea, _snapThreshold);
        if (_snapSuppressed)
        {
            // Restore-on-drag just left a maximized window, so the pointer is
            // still inside the zone it restored from (usually the top edge).
            // Releasing there must NOT snap the window straight back to
            // maximized. Stay suppressed only while the pointer remains in that
            // same zone; leaving it (into another zone or the center) resumes
            // normal snapping immediately.
            if (target == _snapSuppressedZone)
            {
                clearSnap();
                return;
            }
            _snapSuppressed = false;
        }
        if (target == _snapTarget)
        {
            if (target != TitleBarSnapTarget.none)
                _snapBounds = snapBoundsFor(target, workArea);
            return;
        }
        _snapTarget = target;
        _snapBounds = target == TitleBarSnapTarget.none ? Rect.init :
            snapBoundsFor(target, workArea);
        if (onSnapChanged !is null)
            onSnapChanged(target, _snapBounds);
    }

    private void clearSnap()
    {
        if (_snapTarget == TitleBarSnapTarget.none) return;
        _snapTarget = TitleBarSnapTarget.none;
        _snapBounds = Rect.init;
        if (onSnapChanged !is null)
            onSnapChanged(TitleBarSnapTarget.none, Rect.init);
    }

    /** The snap zone the pointer currently sits in, if any (screen-based). */
    private TitleBarSnapTarget currentSnapZone()
    {
        PointF screen;
        if (!queryPointerScreenPosition(screen)) return TitleBarSnapTarget.none;
        Rect workArea;
        if (!queryWorkArea(screen.rounded(), workArea)) return TitleBarSnapTarget.none;
        return snapTargetFor(screen, workArea, _snapThreshold);
    }

    /**
     * Map a screen pointer to the snap zone it engages. A corner wins over its
     * adjacent edges; the top edge alone maximizes; the left/right edges give
     * half-screen targets; the bottom edge alone never snaps (matching the
     * platform standard).
     */
    private static TitleBarSnapTarget snapTargetFor(PointF pointer, Rect workArea,
        int threshold) @safe pure nothrow @nogc
    {
        if (workArea.empty) return TitleBarSnapTarget.none;
        const t = maxInt(0, threshold);
        const nearLeft = pointer.x <= cast(double) workArea.x + t;
        const nearRight = pointer.x >= cast(double) workArea.right() - t;
        const nearTop = pointer.y <= cast(double) workArea.y + t;
        const nearBottom = pointer.y >= cast(double) workArea.bottom() - t;
        if (!nearLeft && !nearRight && !nearTop) return TitleBarSnapTarget.none;
        if (nearLeft && nearTop) return TitleBarSnapTarget.topLeft;
        if (nearRight && nearTop) return TitleBarSnapTarget.topRight;
        if (nearLeft && nearBottom) return TitleBarSnapTarget.bottomLeft;
        if (nearRight && nearBottom) return TitleBarSnapTarget.bottomRight;
        if (nearTop) return TitleBarSnapTarget.top;
        if (nearLeft) return TitleBarSnapTarget.left;
        if (nearRight) return TitleBarSnapTarget.right;
        return TitleBarSnapTarget.none;
    }

    /** Target window bounds (screen coordinates) for a snap target. */
    private static Rect snapBoundsFor(TitleBarSnapTarget target, Rect workArea)
        @safe pure nothrow @nogc
    {
        const halfW = workArea.width / 2;
        const halfH = workArea.height / 2;
        switch (target)
        {
            case TitleBarSnapTarget.top:
                return workArea;
            case TitleBarSnapTarget.left:
                return Rect(workArea.x, workArea.y, halfW, workArea.height);
            case TitleBarSnapTarget.right:
                return Rect(workArea.x + halfW, workArea.y,
                    workArea.width - halfW, workArea.height);
            case TitleBarSnapTarget.topLeft:
                return Rect(workArea.x, workArea.y, halfW, halfH);
            case TitleBarSnapTarget.topRight:
                return Rect(workArea.x + halfW, workArea.y,
                    workArea.width - halfW, halfH);
            case TitleBarSnapTarget.bottomLeft:
                return Rect(workArea.x, workArea.y + halfH, halfW,
                    workArea.height - halfH);
            case TitleBarSnapTarget.bottomRight:
                return Rect(workArea.x + halfW, workArea.y + halfH,
                    workArea.width - halfW, workArea.height - halfH);
            default:
                return Rect.init;
        }
    }

    private static PointF pointerPosition(ref Event event)
        @safe pure nothrow @nogc
    {
        return event.hasPrecisePosition ? event.preciseGlobalPosition :
            PointF(event.globalPosition);
    }
}

/**
 * Reusable translucent drag-snap preview overlay.
 *
 * Add it as the last child of a frameless window root so it paints above all
 * content, then drive it from the `TitleBar`'s `onSnapChanged`: map the snap
 * bounds from screen coordinates to window-local coordinates with the window
 * origin, call `show`, and `hide` on `TitleBarSnapTarget.none`.
 *
 * The overlay is created disabled (`setEnabled(false)`), which keeps it
 * painting on top while making it completely transparent to hit testing: the
 * host's `Widget.hitTest` skips disabled widgets, so a full-size preview never
 * swallows clicks meant for the titlebar or the content beneath it.
 */
class TitleBarSnapPreview : Widget
{
    private Rect _preview;
    private Color _fillColor = Color.rgba(90, 142, 240, 70);
    private Color _borderColor = Color.rgba(140, 180, 255, 170);

    this()
    {
        // Paint-only overlay: never intercepts pointer input (see class docs).
        setEnabled(false);
    }

    bool active() const @safe pure nothrow @nogc { return !_preview.empty; }

    void setFillColor(Color value)
    {
        _fillColor = value;
        invalidate();
    }

    void setBorderColor(Color value)
    {
        _borderColor = value;
        invalidate();
    }

    /** Show the preview at `localBounds` (window-local coordinates). */
    void show(Rect localBounds)
    {
        if (_preview == localBounds) return;
        _preview = localBounds;
        invalidate();
    }

    void hide()
    {
        if (_preview.empty) return;
        _preview = Rect.init;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_preview.empty || _preview.width <= 0 || _preview.height <= 0) return;
        canvas.fillRoundedRect(_preview, 5, _fillColor);
        canvas.strokeRect(_preview, _borderColor, 1);
    }
}

unittest
{
    // Standalone self-move drag: the bar relocates by the exact pointer delta.
    auto bar = new TitleBar();
    bar.setBounds(Rect(40, 20, 600, 40));
    bar.setTitle("Drag me");
    const original = bar.precisePosition();

    Event down;
    down.button = MouseButton.left;
    down.position = Point(80, 12);
    down.precisePosition = PointF(120, 32);
    down.globalPosition = Point(80, 12);
    down.preciseGlobalPosition = PointF(120, 32);
    down.hasPrecisePosition = true;
    assert(bar.onMouseDown(down));
    assert(!bar.dragging());

    // A stationary release is a plain click, not a drag.
    Event stillUp;
    stillUp.button = MouseButton.left;
    stillUp.preciseGlobalPosition = PointF(120, 32);
    stillUp.hasPrecisePosition = true;
    assert(bar.onMouseUp(stillUp));
    assert(bar.precisePosition() == original);

    assert(bar.onMouseDown(down));
    Event move;
    move.preciseGlobalPosition = PointF(220, 92);
    move.hasPrecisePosition = true;
    assert(bar.onMouseMove(move));
    assert(bar.dragging());
    assert(bar.precisePosition() == original + PointF(100, 60));

    Event up;
    up.button = MouseButton.left;
    up.preciseGlobalPosition = PointF(220, 92);
    up.hasPrecisePosition = true;
    assert(bar.onMouseUp(up));
    assert(!bar.dragging());

    // Caption button geometry and custom content slot.
    bar.setBounds(Rect(0, 0, 600, 40));
    const close = bar.captionRect(TitleBarControl.close);
    assert(bar.controlAt(Point(close.x + close.width / 2,
        close.y + close.height / 2)) == TitleBarControl.close);
    bar.setShowClose(false);
    assert(bar.captionRect(TitleBarControl.close).empty);

    // --- Drag-snap target mapping. ---
    const work = Rect(0, 0, 1920, 1080);
    assert(TitleBar.snapTargetFor(PointF(5, 5), work, 8) ==
        TitleBarSnapTarget.topLeft);
    assert(TitleBar.snapTargetFor(PointF(1915, 5), work, 8) ==
        TitleBarSnapTarget.topRight);
    assert(TitleBar.snapTargetFor(PointF(5, 1075), work, 8) ==
        TitleBarSnapTarget.bottomLeft);
    assert(TitleBar.snapTargetFor(PointF(1915, 1075), work, 8) ==
        TitleBarSnapTarget.bottomRight);
    assert(TitleBar.snapTargetFor(PointF(960, 5), work, 8) ==
        TitleBarSnapTarget.top);
    assert(TitleBar.snapTargetFor(PointF(5, 540), work, 8) ==
        TitleBarSnapTarget.left);
    assert(TitleBar.snapTargetFor(PointF(1915, 540), work, 8) ==
        TitleBarSnapTarget.right);
    // Inside the zone the pointer engages nothing.
    assert(TitleBar.snapTargetFor(PointF(400, 400), work, 8) ==
        TitleBarSnapTarget.none);
    // The bottom edge alone never snaps.
    assert(TitleBar.snapTargetFor(PointF(960, 1075), work, 8) ==
        TitleBarSnapTarget.none);
    // An empty work area never snaps.
    assert(TitleBar.snapTargetFor(PointF(5, 5), Rect.init, 8) ==
        TitleBarSnapTarget.none);

    assert(TitleBar.snapBoundsFor(TitleBarSnapTarget.top, work) == work);
    assert(TitleBar.snapBoundsFor(TitleBarSnapTarget.left, work) ==
        Rect(0, 0, 960, 1080));
    assert(TitleBar.snapBoundsFor(TitleBarSnapTarget.right, work) ==
        Rect(960, 0, 960, 1080));
    assert(TitleBar.snapBoundsFor(TitleBarSnapTarget.topLeft, work) ==
        Rect(0, 0, 960, 540));
    assert(TitleBar.snapBoundsFor(TitleBarSnapTarget.bottomRight, work) ==
        Rect(960, 540, 960, 540));
    assert(TitleBar.snapBoundsFor(TitleBarSnapTarget.none, work).empty);

    // A non-zero work-area origin is preserved in every target.
    const offsetWork = Rect(100, 50, 1600, 900);
    assert(TitleBar.snapBoundsFor(TitleBarSnapTarget.right, offsetWork) ==
        Rect(900, 50, 800, 900));
    assert(TitleBar.snapBoundsFor(TitleBarSnapTarget.bottomLeft, offsetWork) ==
        Rect(100, 500, 800, 450));

    // Snap state accessors and toggling.
    assert(bar.snapEnabled());
    assert(bar.snapTarget() == TitleBarSnapTarget.none);
    assert(bar.snapBounds().empty);
    bar.setSnapThreshold(16);
    assert(bar.snapThreshold() == 16);
    bar.setSnapEnabled(false);
    assert(!bar.snapEnabled());
    bar.setSnapEnabled(true);
    assert(bar.snapEnabled());

    // The reusable preview overlay shows and hides a local rect and, being
    // disabled, can never become a hit-test target.
    auto preview = new TitleBarSnapPreview();
    assert(!preview.active());
    preview.show(Rect(10, 20, 500, 300));
    assert(preview.active());
    preview.hide();
    assert(!preview.active());
    assert(!preview.enabled(),
        "Snap preview must be disabled so it never intercepts input");
}
