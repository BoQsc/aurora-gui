module aurora.layout;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.theme : Theme;
import aurora.types : Insets, Orientation, Rect, Size, maxInt, minInt;
import aurora.widget : Widget;

/** Simple solid or bordered panel. */
class Panel : Widget
{
    private Color _background;
    private Color _border;
    private bool _drawBorder;
    private int _radius;

    this(Color background = Color.rgba(0, 0, 0, 0))
    {
        _background = background;
    }

    void setBackground(Color value)
    {
        _background = value;
        invalidate();
    }

    void setBorder(Color value, int radius = 0)
    {
        _border = value;
        _drawBorder = true;
        _radius = radius;
        invalidate();
    }

    void clearBorder()
    {
        _drawBorder = false;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const rect = Rect(0, 0, bounds().width, bounds().height);
        if (_drawBorder)
            canvas.drawRoundedRect(rect, _radius, _background, _border, 1);
        else if (_background.a != 0)
        {
            if (_radius > 0) canvas.fillRoundedRect(rect, _radius, _background);
            else canvas.fillRect(rect, _background);
        }
    }
}

class Spacer : Widget
{
    this(double flex = 1.0)
    {
        layoutHints().flex = flex;
    }
}

/** Horizontal or vertical flex box. */
class Box : Panel
{
    private Orientation _orientation;
    private Insets _padding;
    private int _spacing;

    this(Orientation orientation, int spacing = 8, Insets padding = Insets(0))
    {
        super();
        _orientation = orientation;
        _spacing = spacing;
        _padding = padding;
    }

    void setPadding(Insets value)
    {
        _padding = value;
        invalidate();
    }

    void setSpacing(int value)
    {
        _spacing = maxInt(0, value);
        invalidate();
    }

    Insets padding() const @safe pure nothrow @nogc { return _padding; }
    int spacing() const @safe pure nothrow @nogc { return _spacing; }

    protected override Size onMeasure(Size available)
    {
        Widget[] visibleChildren;
        foreach (child; children())
            if (child.visible() && !child.layoutHints().excludeFromLayout)
                visibleChildren ~= child;

        const horizontal = _orientation == Orientation.horizontal;
        const paddingMain = horizontal ? _padding.left + _padding.right :
            _padding.top + _padding.bottom;
        const paddingCross = horizontal ? _padding.top + _padding.bottom :
            _padding.left + _padding.right;
        const spacingTotal = visibleChildren.length == 0 ? 0 :
            _spacing * (cast(int) visibleChildren.length - 1);
        const childAvailable = Size(
            maxInt(0, available.width - _padding.left - _padding.right),
            maxInt(0, available.height - _padding.top - _padding.bottom));

        long main = paddingMain + spacingTotal;
        int cross = 0;
        foreach (child; visibleChildren)
        {
            const measured = child.measure(childAvailable);
            main += horizontal ? measured.width : measured.height;
            cross = maxInt(cross, horizontal ? measured.height : measured.width);
        }
        const maximum = cast(long) int.max;
        const mainInt = cast(int) (main > maximum ? maximum : main);
        const crossInt = cross > int.max - paddingCross ? int.max : cross + paddingCross;
        return horizontal ? Size(minInt(mainInt, available.width),
                minInt(crossInt, available.height)) :
            Size(minInt(crossInt, available.width), minInt(mainInt, available.height));
    }

    protected override void onLayout()
    {
        Widget[] visibleChildren;
        foreach (child; children())
            if (child.visible() && !child.layoutHints().excludeFromLayout)
                visibleChildren ~= child;
        if (visibleChildren.length == 0) return;

        const horizontal = _orientation == Orientation.horizontal;
        const availableMain = maxInt(0, (horizontal ? bounds().width : bounds().height) -
            (horizontal ? _padding.left + _padding.right : _padding.top + _padding.bottom) -
            _spacing * (cast(int) visibleChildren.length - 1));
        const availableCross = maxInt(0, (horizontal ? bounds().height : bounds().width) -
            (horizontal ? _padding.top + _padding.bottom : _padding.left + _padding.right));

        int fixedSize;
        int flexCount;
        double totalFlex = 0.0;
        foreach (child; visibleChildren)
        {
            const hints = child.layoutHints();
            const preferred = horizontal ? hints.preferredWidth : hints.preferredHeight;
            const minimum = horizontal ? hints.minWidth : hints.minHeight;
            fixedSize += maxInt(minimum, preferred >= 0 ? preferred : minimum);
            if (hints.flex > 0.0)
            {
                totalFlex += hints.flex;
                ++flexCount;
            }
        }

        int remaining = maxInt(0, availableMain - fixedSize);
        int cursor = horizontal ? _padding.left : _padding.top;
        foreach (index, child; visibleChildren)
        {
            const hints = child.layoutHints();
            const preferred = horizontal ? hints.preferredWidth : hints.preferredHeight;
            const minimum = horizontal ? hints.minWidth : hints.minHeight;
            int mainSize = maxInt(minimum, preferred >= 0 ? preferred : minimum);
            if (hints.flex > 0.0 && totalFlex > 0.0)
            {
                // Give the final flexible child the exact remainder so integer
                // and floating-point rounding never leave unused pixels.
                const share = flexCount == 1
                    ? remaining
                    : cast(int) (remaining * (hints.flex / totalFlex));
                mainSize += share;
                remaining -= share;
                totalFlex -= hints.flex;
                --flexCount;
            }

            int crossSize = availableCross;
            if (!hints.fillCrossAxis)
            {
                const preferredCross = horizontal ? hints.preferredHeight : hints.preferredWidth;
                const minimumCross = horizontal ? hints.minHeight : hints.minWidth;
                crossSize = maxInt(minimumCross, preferredCross >= 0 ? preferredCross : minimumCross);
                crossSize = crossSize < availableCross ? crossSize : availableCross;
            }

            if (horizontal)
                child.setBounds(Rect(cursor, _padding.top, mainSize, crossSize));
            else
                child.setBounds(Rect(_padding.left, cursor, crossSize, mainSize));
            cursor += mainSize + _spacing;
        }
    }
}

class HBox : Box
{
    this(int spacing = 8, Insets padding = Insets(0))
    {
        super(Orientation.horizontal, spacing, padding);
    }
}

class VBox : Box
{
    this(int spacing = 8, Insets padding = Insets(0))
    {
        super(Orientation.vertical, spacing, padding);
    }
}


unittest
{
    auto row = new HBox(0);
    auto first = row.add(new Spacer(0.1));
    auto second = row.add(new Spacer(0.2));
    auto fixed = row.add(new Spacer(0.0));
    fixed.layoutHints().preferredWidth = 1;

    row.setBounds(Rect(0, 0, 101, 10));
    row.layoutTree();

    assert(first.bounds().width + second.bounds().width + fixed.bounds().width == 101);
    assert(fixed.bounds().right() == 101);
}
