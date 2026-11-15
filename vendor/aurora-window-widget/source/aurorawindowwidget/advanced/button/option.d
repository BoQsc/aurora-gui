// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.button.option;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.types : CursorKind, HorizontalAlign, Rect, VerticalAlign, maxInt;
import aurora.widget : Widget;
import std.utf : toUTF32;

/// Single-choice control. The caller owns the group: when one option reports
/// selection, a group owner clears the others.
class Option : Widget
{
    private dstring _text;
    private bool _selected;
    private bool _pressed;

    void delegate(bool selected) onSelected;

    this(string text = "", bool selected = false)
    {
        _text = toUTF32(text);
        _selected = selected;
        setFocusable(true);
        setCursor(CursorKind.hand);
        layoutHints().preferredHeight = 32;
        layoutHints().preferredWidth = maxInt(32, 34 + cast(int) _text.length * 12);
    }

    dstring text() const @safe pure nothrow @nogc { return _text; }
    bool selected() const @safe pure nothrow @nogc { return _selected; }

    void setText(string value)
    {
        const next = toUTF32(value);
        if (next == _text) return;
        _text = next;
        layoutHints().preferredWidth = maxInt(32, 34 + cast(int) _text.length * 12);
        invalidate();
    }

    void setSelected(bool value, bool notify = true)
    {
        if (_selected == value) return;
        _selected = value;
        invalidate();
        if (notify && onSelected !is null) onSelected(_selected);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const diameter = 18;
        const circle = Rect(3, (bounds().height - diameter) / 2, diameter,
            diameter);
        const background = !enabled() ? palette.buttonBackground :
            (_pressed ? palette.buttonPressed :
                (hovered() ? palette.buttonHover : palette.fieldBackground));
        canvas.drawRoundedRect(circle, diameter / 2,
            _selected ? palette.accent : background,
            focused() ? palette.accent : palette.border, focused() ? 2 : 1);
        if (_selected)
            canvas.drawRoundedRect(Rect(circle.x + 5, circle.y + 5,
                diameter - 10, diameter - 10), (diameter - 10) / 2,
                Color.rgb(255, 255, 255), Color.rgb(255, 255, 255), 1);
        canvas.drawTextInRect(Rect(28, 0, maxInt(0, bounds().width - 28),
            bounds().height), _text,
            enabled() ? palette.text : palette.disabled, palette.fontScale,
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
        if (activate) setSelected(true);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key != Key.enter) return false;
        _pressed = true;
        invalidate();
        return true;
    }

    override bool onKeyUp(ref Event event)
    {
        if (!_pressed || event.key != Key.enter) return false;
        _pressed = false;
        invalidate();
        setSelected(true);
        return true;
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