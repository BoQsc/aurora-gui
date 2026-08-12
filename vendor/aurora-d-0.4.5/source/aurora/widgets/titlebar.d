module aurora.widgets.titlebar;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, MouseButton;
import aurora.icons : IconKind, drawIcon;
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
    private Widget _content;
    private int _barHeight = 40;
    private int _captionButtonWidth = 46;
    private int _iconSize = 24;
    private int _spacing = 8;
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

    void delegate() onMinimize;
    void delegate() onMaximizeToggle;
    void delegate() onClose;
    void delegate() onDoubleClick;
    /** Owner-drawn system menu, opened by a right click on the title area. */
    void delegate(Point globalPosition) onSystemMenu;
    void delegate(PointF startPointer, PointF startPosition) onDragStarted;
    /** Owner-driven window move; return whether the position changed. */
    bool delegate(PointF pointer, bool requestFrame) onDragMoved;
    void delegate() onDragEnded;

    this()
    {
        setCursor(CursorKind.arrow);
    }

    dstring title() const @safe pure nothrow @nogc { return _title; }
    IconKind iconKind() const @safe pure nothrow @nogc { return _icon; }
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

    void setCaptionButtonWidth(int value)
    {
        value = maxInt(1, value);
        if (_captionButtonWidth == value) return;
        _captionButtonWidth = value;
        onLayout();
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
        if (!_showIcon || _icon == IconKind.none) return Rect.init;
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
        return Rect(left, 3, right - left, maxInt(1, bounds().height - 6));
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
        const titleArea = titleRect();
        if (!titleArea.empty && titleArea.contains(position))
            return TitleBarControl.title;
        return TitleBarControl.none;
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
            drawIcon(canvas, _icon, icon, _active ? text : muted);

        const titleArea = titleRect();
        if (!titleArea.empty && !titleEmpty())
        {
            canvas.drawTextInRect(titleArea, _title, _active ? text : muted,
                palette.fontScale, _titleAlign, VerticalAlign.middle, true);
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
        if (_systemMoveOnDrag && !_maximized)
        {
            // The OS move loop owns capture (it releases any held capture and
            // swallows the mouse-up), so no logical capture is taken here.
            beginSystemMove();
            return true;
        }
        if (_draggable && !_maximized)
        {
            _armDrag = true;
            _dragStartPointer = pointerPosition(event);
            _dragStartPosition = precisePosition();
            captureMouse();
            invalidate();
        }
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        const control = controlAt(event.position);
        if (control != _hotControl)
        {
            _hotControl = control;
            setCursor(control == TitleBarControl.minimize ||
                control == TitleBarControl.maximize ||
                control == TitleBarControl.close ? CursorKind.hand : CursorKind.arrow);
            invalidate();
        }
        if (_dragging)
        {
            const pointer = pointerPosition(event);
            return updateDrag(pointer, true);
        }
        if (_armDrag && _draggable)
        {
            const pointer = pointerPosition(event);
            const dx = pointer.x - _dragStartPointer.x;
            const dy = pointer.y - _dragStartPointer.y;
            if (dx * dx + dy * dy >= 25.0)
            {
                _armDrag = false;
                _dragging = true;
                setCursor(CursorKind.move);
                // Re-enter capture now that wantsContinuousPointerFrames() is
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
        return _dragging && updateDrag(globalPosition, false);
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
            const pointer = pointerPosition(event);
            updateDrag(pointer, true);
            _dragging = false;
            _armDrag = false;
            setCursor(CursorKind.arrow);
            releaseMouse();
            if (onDragEnded !is null) onDragEnded();
            invalidate();
            return true;
        }
        if (_armDrag)
        {
            _armDrag = false;
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

    private static PointF pointerPosition(ref Event event)
        @safe pure nothrow @nogc
    {
        return event.hasPrecisePosition ? event.preciseGlobalPosition :
            PointF(event.globalPosition);
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
}
