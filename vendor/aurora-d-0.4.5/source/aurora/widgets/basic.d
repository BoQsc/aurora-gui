module aurora.widgets.basic;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.types : CursorKind, HorizontalAlign, Orientation, Point, Rect, VerticalAlign,
    clampDouble, clampInt, maxInt;
import aurora.widget : Widget;
import std.utf : toUTF32;

/** Horizontal or vertical one-pixel visual separator. */
class Separator : Widget
{
    private Orientation _orientation;

    this(Orientation orientation = Orientation.horizontal)
    {
        _orientation = orientation;
        if (orientation == Orientation.horizontal)
        {
            layoutHints().preferredHeight = 9;
            layoutHints().minHeight = 1;
        }
        else
        {
            layoutHints().preferredWidth = 9;
            layoutHints().minWidth = 1;
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const color = theme().border;
        if (_orientation == Orientation.horizontal)
            canvas.fillRect(Rect(0, bounds().height / 2, bounds().width, 1), color);
        else
            canvas.fillRect(Rect(bounds().width / 2, 0, 1, bounds().height), color);
    }
}

/** Standard focusable checkbox. */
class CheckBox : Widget
{
    private dstring _text;
    private bool _checked;
    private bool _pressed;

    void delegate(bool checked) onChanged;

    this(string text = "", bool checked = false)
    {
        _text = toUTF32(text);
        _checked = checked;
        setFocusable(true);
        setCursor(CursorKind.hand);
        layoutHints().preferredHeight = 32;
        layoutHints().preferredWidth = maxInt(32, 34 + cast(int) _text.length * 12);
    }

    bool checked() const @safe pure nothrow @nogc { return _checked; }

    void setChecked(bool value, bool notify = true)
    {
        if (_checked == value) return;
        _checked = value;
        invalidate();
        if (notify && onChanged !is null) onChanged(_checked);
    }

    void toggle()
    {
        setChecked(!_checked);
    }

    void setText(string value)
    {
        const next = toUTF32(value);
        if (next == _text) return;
        _text = next;
        layoutHints().preferredWidth = maxInt(32, 34 + cast(int) _text.length * 12);
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const box = Rect(3, (bounds().height - 18) / 2, 18, 18);
        const background = !enabled() ? palette.buttonBackground :
            (_pressed ? palette.buttonPressed : (hovered() ? palette.buttonHover : palette.fieldBackground));
        canvas.drawRoundedRect(box, 3, _checked ? palette.accent : background,
            focused() ? palette.accent : palette.border, focused() ? 2 : 1);
        if (_checked)
        {
            const checkColor = Color.rgb(255, 255, 255);
            canvas.drawLine(Point(box.x + 4, box.y + 9), Point(box.x + 8, box.y + 13), checkColor, 2);
            canvas.drawLine(Point(box.x + 8, box.y + 13), Point(box.x + 15, box.y + 5), checkColor, 2);
        }
        canvas.drawTextInRect(Rect(28, 0, maxInt(0, bounds().width - 28), bounds().height),
            _text, enabled() ? palette.text : palette.disabled, palette.fontScale,
            HorizontalAlign.left, VerticalAlign.middle, true);
    }

    override bool onMouseDown(ref Event event)
    {
        if (!enabled() || event.button != MouseButton.left) return false;
        _pressed = true;
        requestFocus();
        captureMouse();
        invalidate();
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_pressed) return false;
        const activate = containsLocal(event.position);
        _pressed = false;
        releaseMouse();
        invalidate();
        if (activate) toggle();
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.enter)
        {
            _pressed = true;
            invalidate();
            return true;
        }
        return false;
    }

    override bool onKeyUp(ref Event event)
    {
        if (_pressed && event.key == Key.enter)
        {
            _pressed = false;
            invalidate();
            toggle();
            return true;
        }
        return false;
    }

    protected override void onFocusChanged(bool focused)
    {
        if (!focused)
        {
            _pressed = false;
            releaseMouse();
        }
    }
}

/** Read-only progress indicator with an optional centered label. */
class ProgressBar : Widget
{
    private double _value;
    private dstring _label;
    private bool _showPercent = true;

    this(double value = 0.0)
    {
        _value = clampDouble(value, 0.0, 1.0);
        layoutHints().preferredHeight = 28;
        layoutHints().minWidth = 80;
    }

    double value() const @safe pure nothrow @nogc { return _value; }

    void setValue(double value)
    {
        const next = clampDouble(value, 0.0, 1.0);
        if (next == _value) return;
        _value = next;
        invalidate();
    }

    void setLabel(string value)
    {
        const next = toUTF32(value);
        if (next == _label) return;
        _label = next;
        invalidate();
    }

    void setShowPercent(bool value)
    {
        if (_showPercent == value) return;
        _showPercent = value;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        import std.conv : to;

        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.drawRoundedRect(full, palette.cornerRadius, palette.buttonBackground, palette.border, 1);
        const inner = full.inset(2);
        const fillWidth = cast(int) (inner.width * _value + 0.5);
        if (fillWidth > 0)
            canvas.fillRoundedRect(Rect(inner.x, inner.y, fillWidth, inner.height),
                maxInt(1, palette.cornerRadius - 2), palette.accent);

        dstring text = _label;
        if (text.length == 0 && _showPercent)
            text = toUTF32(to!string(cast(int) (_value * 100.0 + 0.5)) ~ "%");
        if (text.length > 0)
            canvas.drawTextInRect(full, text, palette.text, 1,
                HorizontalAlign.center, VerticalAlign.middle, true);
    }
}

/** Mouse- and keyboard-operable scalar slider. */
class Slider : Widget
{
    private double _minimum;
    private double _maximum = 1.0;
    private double _value;
    private bool _dragging;

    void delegate(double value) onChanged;

    this(double minimum = 0.0, double maximum = 1.0, double value = 0.0)
    {
        _minimum = minimum;
        _maximum = maximum > minimum ? maximum : minimum + 1.0;
        _value = clampDouble(value, _minimum, _maximum);
        setFocusable(true);
        setCursor(CursorKind.hand);
        layoutHints().preferredHeight = 32;
        layoutHints().minWidth = 80;
    }

    double value() const @safe pure nothrow @nogc { return _value; }
    double minimum() const @safe pure nothrow @nogc { return _minimum; }
    double maximum() const @safe pure nothrow @nogc { return _maximum; }

    void setRange(double minimum, double maximum)
    {
        const nextMaximum = maximum > minimum ? maximum : minimum + 1.0;
        const rangeChanged = minimum != _minimum || nextMaximum != _maximum;
        _minimum = minimum;
        _maximum = nextMaximum;
        const nextValue = clampDouble(_value, _minimum, _maximum);
        const valueChanged = nextValue != _value;
        _value = nextValue;
        // The thumb's normalized position changes when either endpoint changes,
        // even if the numeric value itself remains identical. The previous
        // implementation skipped invalidation in that case and could leave a
        // retained/composited slider painted at an obsolete location.
        if (rangeChanged || valueChanged) invalidate();
    }

    void setValue(double value, bool notify = true)
    {
        const next = clampDouble(value, _minimum, _maximum);
        if (next == _value) return;
        _value = next;
        invalidate();
        if (notify && onChanged !is null) onChanged(_value);
    }

    private double normalized() const @safe pure nothrow @nogc
    {
        return (_value - _minimum) / (_maximum - _minimum);
    }

    private void updateFromPoint(Point point)
    {
        const left = 10;
        const width = maxInt(1, bounds().width - 20);
        const ratio = clampDouble(cast(double) (point.x - left) / width, 0.0, 1.0);
        setValue(_minimum + ratio * (_maximum - _minimum));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const centerY = bounds().height / 2;
        const left = 10;
        const width = maxInt(1, bounds().width - 20);
        canvas.fillRoundedRect(Rect(left, centerY - 2, width, 4), 2, palette.border);
        const thumbX = left + cast(int) (normalized() * width + 0.5);
        canvas.fillRoundedRect(Rect(left, centerY - 2, maxInt(0, thumbX - left), 4),
            2, palette.accent);
        const thumb = Rect(thumbX - 7, centerY - 7, 14, 14);
        canvas.drawRoundedRect(thumb, 7,
            _dragging ? palette.accentPressed : (hovered() ? palette.accentHover : palette.accent),
            focused() ? palette.accent.darker(30) : palette.border, focused() ? 2 : 1);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left || !enabled()) return false;
        requestFocus();
        _dragging = true;
        captureMouse();
        updateFromPoint(event.position);
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_dragging) return false;
        updateFromPoint(event.position);
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_dragging) return false;
        _dragging = false;
        releaseMouse();
        updateFromPoint(event.position);
        invalidate();
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        const step = (_maximum - _minimum) / (event.shift() ? 100.0 : 20.0);
        switch (event.key)
        {
            case Key.left:
            case Key.down:
                setValue(_value - step);
                return true;
            case Key.right:
            case Key.up:
                setValue(_value + step);
                return true;
            case Key.home:
                setValue(_minimum);
                return true;
            case Key.end:
                setValue(_maximum);
                return true;
            default:
                return false;
        }
    }
}
