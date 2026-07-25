module aurora.widgets.label;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.font : FontRole, fontPixelSize;
import aurora.text.layout : TextLayoutOptions;
import aurora.types : HorizontalAlign, Rect, VerticalAlign;
import aurora.widget : Widget;
import std.utf : toUTF32;

class Label : Widget
{
    private dstring _text;
    private Color _color;
    private bool _customColor;
    private HorizontalAlign _horizontal = HorizontalAlign.left;
    private VerticalAlign _vertical = VerticalAlign.middle;
    private int _scale = 2;
    private bool _ellipsis = true;

    this(string text = "")
    {
        setText(text);
    }

    dstring text() const @safe pure nothrow @nogc { return _text; }

    void setText(string value)
    {
        setText(toUTF32(value));
    }

    void setText(dstring value)
    {
        if (value == _text && layoutHints().preferredHeight > 0) return;
        _text = value;
        measureAndInvalidate();
    }

    private void measureAndInvalidate()
    {
        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() palette.uiFont;
        options.pixelSize = fontPixelSize(_scale);
        options.wrap = false;
        const measured = fontSystem().textEngine.layout(_text, options).measuredSize();
        layoutHints().preferredWidth = measured.width;
        layoutHints().preferredHeight = measured.height;
        invalidate();
    }

    void setColor(Color value)
    {
        _color = value;
        _customColor = true;
        invalidate();
    }

    void useThemeColor()
    {
        _customColor = false;
        invalidate();
    }

    void setAlignment(HorizontalAlign horizontal, VerticalAlign vertical = VerticalAlign.middle)
    {
        _horizontal = horizontal;
        _vertical = vertical;
        invalidate();
    }

    void setScale(int value)
    {
        const next = value < 1 ? 1 : value;
        if (_scale == next && layoutHints().preferredHeight > 0) return;
        _scale = next;
        measureAndInvalidate();
    }

    void setEllipsis(bool value)
    {
        _ellipsis = value;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const color = _customColor ? _color : (enabled() ? palette.text : palette.disabled);
        canvas.drawTextInRect(Rect(0, 0, bounds().width, bounds().height), _text, color,
            _scale, _horizontal, _vertical, _ellipsis);
    }
}
