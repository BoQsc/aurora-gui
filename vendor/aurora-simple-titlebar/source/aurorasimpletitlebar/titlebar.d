module aurorasimpletitlebar.titlebar;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, MouseButton;
import aurora.font : FontRole;
import aurora.icons : IconKind, drawIcon;
import aurora.text.layout : TextLayoutOptions;
import aurora.types : CursorKind, HorizontalAlign, Point, PointF, Rect, Size,
    VerticalAlign, maxInt, minInt;
import aurora.widget : Widget;
import std.utf : toUTF32;

/** The interactive regions exposed by SimpleTitleBar. */
enum SimpleTitleBarControl : ubyte
{
    none,
    icon,
    title,
    minimize,
    maximize,
    close
}

/** One quiet, Windows 10-inspired light caption palette. */
struct SimpleTitleBarColors
{
    Color activeBackground;
    Color inactiveBackground;
    Color text;
    Color inactiveText;
    Color border;
    Color buttonHover;
    Color buttonPressed;
    Color closeHover;
    Color closePressed;

    static SimpleTitleBarColors windows10Light() @safe pure nothrow @nogc
    {
        SimpleTitleBarColors colors;
        colors.activeBackground = Color.fromHex(0xffffff);
        colors.inactiveBackground = Color.fromHex(0xf0f0f0);
        colors.text = Color.fromHex(0x1a1a1a);
        colors.inactiveText = Color.fromHex(0x6a6a6a);
        colors.border = Color.fromHex(0xd6d6d6);
        colors.buttonHover = Color.fromHex(0xe5e5e5);
        colors.buttonPressed = Color.fromHex(0xcccccc);
        colors.closeHover = Color.fromHex(0xe81123);
        colors.closePressed = Color.fromHex(0xc42b1c);
        return colors;
    }
}

/**
 * A small, custom-painted titlebar for a frameless Aurora window.
 *
 * The widget deliberately contains no platform-specific window calls. It
 * asks the Aurora host to start a native move loop when possible and exposes
 * callbacks for the owner to supply minimize/maximize/close/system-menu
 * policy. A host that cannot start a native move loop can use the drag
 * callbacks instead.
 */
final class SimpleTitleBar : Widget
{
    private dstring _title;
    private IconKind _icon = IconKind.none;
    private int _barHeight = 23;
    private int _captionButtonWidth = 36;
    private int _titleFontSize = 12;
    private int _iconSize = 16;
    private int _spacing = 8;
    private bool _showIcon = true;
    private bool _showMinimize = true;
    private bool _showMaximize = true;
    private bool _showClose = true;
    private bool _active = true;
    private bool _maximized;
    private bool _systemMoveOnDrag = true;
    private bool _dragging;
    private bool _armDrag;
    private PointF _dragStartPointer;
    private SimpleTitleBarControl _hotControl;
    private SimpleTitleBarControl _pressedControl;
    private SimpleTitleBarColors _colors;

    void delegate() onMinimize;
    void delegate() onMaximizeToggle;
    void delegate() onClose;
    void delegate() onDoubleClick;
    void delegate(Point globalPosition) onSystemMenu;
    void delegate(PointF pointer) onDragStarted;
    bool delegate(PointF pointer, bool requestFrame) onDragMoved;
    void delegate() onDragEnded;

    this()
    {
        _colors = SimpleTitleBarColors.windows10Light();
        layoutHints().preferredHeight = _barHeight;
        setCursor(CursorKind.arrow);
    }

    dstring title() const @safe pure nothrow @nogc { return _title; }
    IconKind iconKind() const @safe pure nothrow @nogc { return _icon; }
    int barHeight() const @safe pure nothrow @nogc { return _barHeight; }
    int captionButtonWidth() const @safe pure nothrow @nogc
    {
        return _captionButtonWidth;
    }
    /** Title EM pixel size; zero opts into the host theme's text tier. */
    int titleFontSize() const @safe pure nothrow @nogc
    {
        return _titleFontSize;
    }
    int iconSize() const @safe pure nothrow @nogc { return _iconSize; }
    bool active() const @safe pure nothrow @nogc { return _active; }
    bool maximized() const @safe pure nothrow @nogc { return _maximized; }
    bool systemMoveOnDrag() const @safe pure nothrow @nogc
    {
        return _systemMoveOnDrag;
    }
    bool dragging() const @safe pure nothrow @nogc { return _dragging; }
    SimpleTitleBarControl hotControl() const @safe pure nothrow @nogc
    {
        return _hotControl;
    }
    SimpleTitleBarControl pressedControl() const @safe pure nothrow @nogc
    {
        return _pressedControl;
    }

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
        onLayout();
        invalidate();
    }

    void setBarHeight(int value)
    {
        _barHeight = maxInt(1, value);
        layoutHints().preferredHeight = _barHeight;
        onLayout();
        invalidate();
    }

    void setCaptionButtonWidth(int value)
    {
        _captionButtonWidth = maxInt(1, value);
        onLayout();
        invalidate();
    }

    void setTitleFontSize(int value)
    {
        if (value < 0) value = 0;
        if (_titleFontSize == value) return;
        _titleFontSize = value;
        invalidate();
    }

    void setIconSize(int value)
    {
        _iconSize = maxInt(8, value);
        onLayout();
        invalidate();
    }

    void setShowIcon(bool value)
    {
        if (_showIcon == value) return;
        _showIcon = value;
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

    void setColors(SimpleTitleBarColors value)
    {
        _colors = value;
        invalidate();
    }

    Rect iconRect() const @safe pure nothrow @nogc
    {
        if (!_showIcon || _icon == IconKind.none) return Rect.init;
        const size = minInt(_iconSize, maxInt(1, bounds().height - 8));
        return Rect(_spacing, (bounds().height - size) / 2, size, size);
    }

    Rect captionRect(SimpleTitleBarControl control) const
        @safe pure nothrow @nogc
    {
        int index;
        bool shown;
        switch (control)
        {
            case SimpleTitleBarControl.minimize:
                index = 2;
                shown = _showMinimize;
                break;
            case SimpleTitleBarControl.maximize:
                index = 1;
                shown = _showMaximize;
                break;
            case SimpleTitleBarControl.close:
                index = 0;
                shown = _showClose;
                break;
            default:
                return Rect.init;
        }
        if (!shown) return Rect.init;
        const right = bounds().width - index * _captionButtonWidth;
        return Rect(right - _captionButtonWidth, 0, _captionButtonWidth,
            bounds().height);
    }

    Rect titleRect() const @safe pure nothrow @nogc
    {
        const icon = iconRect();
        const left = icon.empty ? _spacing : icon.right() + _spacing;
        const right = buttonsLeft() - _spacing;
        return right <= left ? Rect.init :
            Rect(left, 0, right - left, bounds().height);
    }

    SimpleTitleBarControl controlAt(Point position) const
        @safe pure nothrow @nogc
    {
        if (!containsLocal(position)) return SimpleTitleBarControl.none;
        foreach (control; [SimpleTitleBarControl.close,
            SimpleTitleBarControl.maximize, SimpleTitleBarControl.minimize])
        {
            const rect = captionRect(control);
            if (!rect.empty && rect.contains(position)) return control;
        }
        const icon = iconRect();
        if (!icon.empty && icon.contains(position))
            return SimpleTitleBarControl.icon;
        return SimpleTitleBarControl.title;
    }

    protected override Size onMeasure(Size available)
    {
        return Size(available.width, _barHeight);
    }

    protected override void onHostFocusChanged(bool focused)
    {
        setActive(focused);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const full = Rect(0, 0, bounds().width, bounds().height);
        const background = _active ? _colors.activeBackground :
            _colors.inactiveBackground;
        const text = _active ? _colors.text : _colors.inactiveText;
        canvas.fillRect(full, background);
        if (_colors.border.a != 0)
            canvas.fillRect(Rect(0, maxInt(0, bounds().height - 1),
                bounds().width, 1), _colors.border);

        const icon = iconRect();
        if (!icon.empty)
            drawIcon(canvas, _icon, icon, text);

        const title = titleRect();
        if (!title.empty && _title.length != 0)
        {
            if (_titleFontSize > 0)
            {
                TextLayoutOptions options;
                options.role = FontRole.ui;
                options.overrideFace = cast() theme().uiFont;
                options.pixelSize = _titleFontSize;
                options.wrap = false;
                auto layout = fontSystem().textEngine.layoutCached(_title, options);
                const measured = layout.measuredSize();
                const y = title.y + maxInt(0,
                    (title.height - measured.height) / 2);
                auto child = canvas.clipped(title);
                child.drawLayout(Point(title.x, y), layout, text);
            }
            else
            {
                canvas.drawTextInRect(title, _title, text, theme().fontScale,
                    HorizontalAlign.left, VerticalAlign.middle, true);
            }
        }

        drawCaptionButton(canvas, SimpleTitleBarControl.minimize);
        drawCaptionButton(canvas, SimpleTitleBarControl.maximize);
        drawCaptionButton(canvas, SimpleTitleBarControl.close);
    }

    protected override void onMouseLeave()
    {
        if (_hotControl == SimpleTitleBarControl.none) return;
        _hotControl = SimpleTitleBarControl.none;
        setCursor(CursorKind.arrow);
        invalidate();
    }

    override bool onMouseMove(ref Event event)
    {
        if (_dragging)
        {
            const pointer = pointerPosition(event);
            return onDragMoved !is null ? onDragMoved(pointer, true) : true;
        }

        const control = controlAt(event.position);
        if (control != _hotControl)
        {
            _hotControl = control;
            setCursor(control == SimpleTitleBarControl.minimize ||
                control == SimpleTitleBarControl.maximize ||
                control == SimpleTitleBarControl.close ? CursorKind.hand :
                CursorKind.arrow);
            invalidate();
        }

        if (_armDrag)
        {
            const pointer = pointerPosition(event);
            const dx = pointer.x - _dragStartPointer.x;
            const dy = pointer.y - _dragStartPointer.y;
            if (dx * dx + dy * dy >= 25.0)
            {
                _armDrag = false;
                _dragging = true;
                if (onDragStarted !is null) onDragStarted(pointer);
                if (onDragMoved !is null) onDragMoved(pointer, true);
            }
            return true;
        }
        return _pressedControl != SimpleTitleBarControl.none;
    }

    override bool onPointerLatch(PointF globalPosition)
    {
        if (!_dragging || onDragMoved is null) return false;
        return onDragMoved(globalPosition, false);
    }

    override bool wantsContinuousPointerFrames() const @safe pure nothrow @nogc
    {
        return _dragging;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            const control = controlAt(event.position);
            if ((control == SimpleTitleBarControl.title ||
                control == SimpleTitleBarControl.icon) &&
                onSystemMenu !is null)
            {
                onSystemMenu(event.globalPosition);
                return true;
            }
            return false;
        }
        if (event.button != MouseButton.left) return false;

        const control = controlAt(event.position);
        if (control == SimpleTitleBarControl.minimize ||
            control == SimpleTitleBarControl.maximize ||
            control == SimpleTitleBarControl.close)
        {
            _pressedControl = control;
            captureMouse();
            invalidate();
            return true;
        }
        if (control != SimpleTitleBarControl.title &&
            control != SimpleTitleBarControl.icon)
            return false;

        if (event.clickCount >= 2)
        {
            if (onDoubleClick !is null) onDoubleClick();
            if (onMaximizeToggle !is null) onMaximizeToggle();
            return true;
        }

        const pointer = pointerPosition(event);
        if (_systemMoveOnDrag && beginSystemMove()) return true;
        _armDrag = true;
        _dragStartPointer = pointer;
        captureMouse();
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;

        if (_dragging)
        {
            _dragging = false;
            _armDrag = false;
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
        if (_pressedControl == SimpleTitleBarControl.none) return false;

        const pressed = _pressedControl;
        const activate = controlAt(event.position) == pressed;
        _pressedControl = SimpleTitleBarControl.none;
        releaseMouse();
        invalidate();
        if (!activate) return true;

        switch (pressed)
        {
            case SimpleTitleBarControl.minimize:
                if (onMinimize !is null) onMinimize();
                break;
            case SimpleTitleBarControl.maximize:
                if (onMaximizeToggle !is null) onMaximizeToggle();
                break;
            case SimpleTitleBarControl.close:
                if (onClose !is null) onClose();
                break;
            default:
                break;
        }
        return true;
    }

    private int buttonsLeft() const @safe pure nothrow @nogc
    {
        int count;
        if (_showMinimize) ++count;
        if (_showMaximize) ++count;
        if (_showClose) ++count;
        return maxInt(0, bounds().width - count * _captionButtonWidth);
    }

    private void drawCaptionButton(ref Canvas canvas,
        SimpleTitleBarControl control)
    {
        const rect = captionRect(control);
        if (rect.empty) return;
        const hot = _pressedControl != SimpleTitleBarControl.none ?
            _pressedControl : _hotControl;
        const isHot = hot == control;
        if (isHot)
        {
            const fill = control == SimpleTitleBarControl.close ?
                (_pressedControl == control ? _colors.closePressed :
                    _colors.closeHover) : (_pressedControl == control ?
                    _colors.buttonPressed : _colors.buttonHover);
            canvas.fillRect(rect, fill);
        }

        const color = control == SimpleTitleBarControl.close && isHot ?
            Color.rgb(255, 255, 255) : (_active ? _colors.text :
            _colors.inactiveText);
        const cx = rect.x + rect.width / 2;
        const cy = rect.y + rect.height / 2 + (rect.height & 1);
        switch (control)
        {
            case SimpleTitleBarControl.minimize:
                canvas.fillRect(Rect(cx - 5, cy - 1, 10, 2), color);
                break;
            case SimpleTitleBarControl.maximize:
                if (_maximized)
                {
                    canvas.strokeRect(Rect(cx - 5, cy - 4, 8, 8), color, 1);
                    canvas.strokeRect(Rect(cx + 1, cy - 1, 8, 8), color, 1);
                }
                else
                {
                    canvas.strokeRect(Rect(cx - 5, cy - 5, 10, 10), color, 1);
                }
                break;
            case SimpleTitleBarControl.close:
                canvas.drawLine(Point(cx - 5, cy - 5), Point(cx + 5, cy + 5),
                    color, 1);
                canvas.drawLine(Point(cx + 5, cy - 5), Point(cx - 5, cy + 5),
                    color, 1);
                break;
            default:
                break;
        }
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
    auto bar = new SimpleTitleBar();
    bar.setBounds(Rect(0, 0, 800, 23));
    assert(bar.barHeight() == 23);
    assert(bar.captionButtonWidth() == 36);
    assert(bar.titleFontSize() == 12);
    assert(bar.captionRect(SimpleTitleBarControl.close) == Rect(764, 0, 36, 23));
    assert(bar.controlAt(Point(777, 11)) == SimpleTitleBarControl.close);
    assert(bar.controlAt(Point(100, 11)) == SimpleTitleBarControl.title);
    bar.setMaximized(true);
    assert(bar.maximized());
    bar.setShowIcon(false);
    assert(bar.iconRect().empty);
}
