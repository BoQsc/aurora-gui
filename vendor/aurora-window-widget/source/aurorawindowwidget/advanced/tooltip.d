// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.tooltip;

import aurora.canvas : Canvas;
import aurora.types : HorizontalAlign, Rect, VerticalAlign, maxInt;
import aurora.widget : Widget;
import std.utf : toUTF32;

/// Bordered hint surface. The owner positions and shows it.
class Tooltip : Widget
{
    private dstring _text;

    this(string text = "")
    {
        layoutHints().preferredHeight = 26;
        setText(text);
    }

    dstring text() const @safe pure nothrow @nogc { return _text; }

    void setText(string value)
    {
        const next = toUTF32(value);
        if (next == _text) return;
        _text = next;
        layoutHints().preferredWidth = maxInt(32, 20 + cast(int) _text.length * 7);
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        canvas.drawRoundedRect(Rect(0, 0, bounds().width, bounds().height),
            palette.cornerRadius, palette.panelElevated, palette.border, 1);
        canvas.drawTextInRect(Rect(8, 0, maxInt(0, bounds().width - 16),
            bounds().height), _text, palette.text, palette.fontScale,
            HorizontalAlign.left, VerticalAlign.middle, true);
    }
}