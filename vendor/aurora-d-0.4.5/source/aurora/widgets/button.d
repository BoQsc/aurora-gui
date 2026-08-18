module aurora.widgets.button;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.font : FontRole, fontPixelSize;
import aurora.icons : IconKind, drawIcon;
import aurora.text.layout : TextLayoutOptions;
import aurora.types : CursorKind, HorizontalAlign, Rect, VerticalAlign, maxInt;
import aurora.widget : Widget;
import std.utf : toUTF32;

class Button : Widget
{
    private dstring _text;
    private IconKind _icon;
    private bool _pressed;
    private bool _flat;
    private bool _accent;
    private bool _danger;
    // Focus reached by a mouse click, not keyboard Tab navigation. The focus
    // ring is suppressed for pointer focus so a clicked button does not keep a
    // blue outline after the press is released.
    private bool _focusedByPointer;
    // Smaller default icon so button icons read as compact Win10-style glyphs;
    // button size is text-measured and never follows the icon size.
    private int _iconSize = 18;

    void delegate() onClick;

    this(string text = "", IconKind icon = IconKind.none)
    {
        _text = toUTF32(text);
        _icon = icon;
        setFocusable(true);
        setCursor(CursorKind.hand);
        updatePreferredSize();
    }

    dstring text() const @safe pure nothrow @nogc { return _text; }
    bool pressed() const @safe pure nothrow @nogc { return _pressed; }

    void setText(string value)
    {
        const next = toUTF32(value);
        if (next == _text) return;
        _text = next;
        updatePreferredSize();
        invalidate();
    }

    void setIcon(IconKind value)
    {
        if (_icon == value) return;
        _icon = value;
        updatePreferredSize();
        invalidate();
    }

    /** Icon glyph size in logical pixels; button size is unaffected. */
    void setIconSize(int value)
    {
        value = maxInt(8, value);
        if (_iconSize == value) return;
        _iconSize = value;
        invalidate();
    }

    private void updatePreferredSize()
    {
        const palette = theme();
        const controlHeight = maxInt(38, palette.controlHeight);
        layoutHints().preferredHeight = controlHeight;
        if (_text.length == 0)
        {
            layoutHints().preferredWidth = _icon == IconKind.none ?
                controlHeight : maxInt(controlHeight, 40);
            return;
        }

        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() palette.uiFont;
        options.pixelSize = fontPixelSize(palette.fontScale);
        options.wrap = false;
        const measured = fontSystem().textEngine.layout(_text, options).measuredSize();
        const horizontalChrome = _icon == IconKind.none ? 24 : 52;
        layoutHints().preferredWidth = maxInt(controlHeight,
            measured.width + horizontalChrome);
    }

    void setFlat(bool value)
    {
        if (_flat == value) return;
        _flat = value;
        invalidate();
    }

    void setAccent(bool value)
    {
        if (_accent == value && (!value || !_danger)) return;
        _accent = value;
        if (value) _danger = false;
        invalidate();
    }

    void setDanger(bool value)
    {
        if (_danger == value && (!value || !_accent)) return;
        _danger = value;
        if (value) _accent = false;
        invalidate();
    }

    void activate()
    {
        if (enabled() && onClick !is null)
            onClick();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        Color background;
        Color foreground = enabled() ? palette.text : palette.disabled;
        Color border = palette.border;

        if (_danger)
        {
            background = palette.danger;
            foreground = Color.rgb(255, 255, 255);
            border = palette.danger.darker(18);
        }
        else if (_accent)
        {
            background = _pressed ? palette.accentPressed :
                (hovered() ? palette.accentHover : palette.accent);
            foreground = Color.rgb(255, 255, 255);
            border = background.darker(20);
        }
        else if (_flat)
        {
            background = _pressed ? palette.buttonPressed :
                (hovered() ? palette.buttonHover : Color.rgba(0, 0, 0, 0));
            border = Color.rgba(0, 0, 0, 0);
        }
        else
        {
            background = _pressed ? palette.buttonPressed :
                (hovered() ? palette.buttonHover : palette.buttonBackground);
        }

        const rect = Rect(0, 0, bounds().width, bounds().height);
        if (background.a != 0)
        {
            if (border.a != 0)
                canvas.drawRoundedRect(rect, palette.cornerRadius, background, border, 1);
            else
                canvas.fillRoundedRect(rect, palette.cornerRadius, background);
        }

        if (focused() && !_focusedByPointer)
            canvas.drawRoundedRect(rect.inset(2), maxInt(1, palette.cornerRadius - 2),
                Color.rgba(0, 0, 0, 0), palette.accent.withAlpha(180), 1);

        const contentOffset = _pressed ? 1 : 0;
        if (_icon != IconKind.none)
        {
            const iconRect = Rect(8 + contentOffset,
                (bounds().height - _iconSize) / 2 + contentOffset, _iconSize, _iconSize);
            drawIcon(canvas, _icon, iconRect, foreground, palette.accent);
        }

        if (_text.length > 0)
        {
            const left = _icon == IconKind.none ? 8 : 36;
            canvas.drawTextInRect(Rect(left + contentOffset, contentOffset,
                maxInt(0, bounds().width - left - 8), bounds().height), _text, foreground,
                palette.fontScale, _icon == IconKind.none ? HorizontalAlign.center : HorizontalAlign.left,
                VerticalAlign.middle, true);
        }
    }

    override bool onMouseDown(ref Event event)
    {
        if (!enabled() || event.button != MouseButton.left) return false;
        _pressed = true;
        _focusedByPointer = true;
        requestFocus();
        captureMouse();
        invalidate();
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_pressed) return false;
        const shouldActivate = containsLocal(event.position);
        _pressed = false;
        releaseMouse();
        invalidate();
        if (shouldActivate) activate();
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (!enabled()) return false;
        if (event.key == Key.enter || event.key == Key.space)
        {
            _pressed = true;
            invalidate();
            return true;
        }
        return false;
    }

    override bool onKeyUp(ref Event event)
    {
        if (_pressed && (event.key == Key.enter || event.key == Key.space))
        {
            _pressed = false;
            invalidate();
            activate();
            return true;
        }
        return false;
    }

    protected override void onFocusChanged(bool value)
    {
        if (!value)
        {
            _pressed = false;
            _focusedByPointer = false;
            releaseMouse();
        }
    }
}

class IconButton : Button
{
    this(IconKind icon)
    {
        super("", icon);
        layoutHints().preferredWidth = 40;
    }
}
