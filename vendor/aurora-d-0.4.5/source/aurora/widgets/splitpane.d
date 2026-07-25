module aurora.widgets.splitpane;

import aurora.canvas : Canvas;
import aurora.event : Event, MouseButton;
import aurora.types : CursorKind, Orientation, Point, Rect, clampDouble, clampInt, maxInt;
import aurora.widget : Widget;

/** Two-child container with a draggable divider. */
class SplitPane : Widget
{
    private Widget _first;
    private Widget _second;
    private Orientation _orientation;
    private double _ratio = 0.3;
    private int _dividerSize = 7;
    private bool _dragging;

    void delegate(double ratio) onRatioChanged;

    this(Widget first, Widget second, Orientation orientation = Orientation.horizontal)
    {
        _orientation = orientation;
        _first = add(first);
        _second = add(second);
        setCursor(orientation == Orientation.horizontal
            ? CursorKind.resizeHorizontal : CursorKind.resizeVertical);
        layoutHints().minWidth = 120;
        layoutHints().minHeight = 80;
        layoutHints().flex = 1.0;
    }

    Widget first() @safe pure nothrow @nogc { return _first; }
    Widget second() @safe pure nothrow @nogc { return _second; }
    double ratio() const @safe pure nothrow @nogc { return _ratio; }

    void setRatio(double value, bool notify = true)
    {
        const next = clampDouble(value, 0.08, 0.92);
        if (next == _ratio) return;
        _ratio = next;
        // Reflow the entire subtree immediately so hit-testing remains correct
        // during an interactive divider drag, before the next paint frame.
        layoutTree();
        invalidate();
        if (notify && onRatioChanged !is null) onRatioChanged(_ratio);
    }

    void setDividerSize(int value)
    {
        _dividerSize = maxInt(3, value);
        layoutTree();
        invalidate();
    }

    private int boundedFirstSize(int available) @safe pure nothrow @nogc
    {
        if (available <= 0) return 0;
        const firstMinimum = _orientation == Orientation.horizontal
            ? _first.layoutHints().minWidth : _first.layoutHints().minHeight;
        const secondMinimum = _orientation == Orientation.horizontal
            ? _second.layoutHints().minWidth : _second.layoutHints().minHeight;
        int requested = cast(int) (available * _ratio + 0.5);

        if (firstMinimum + secondMinimum <= available)
            return clampInt(requested, firstMinimum, available - secondMinimum);

        // When the host is smaller than both declared minimums, divide the
        // available space proportionally instead of allowing either child to
        // overflow across the divider and steal pointer events.
        const totalMinimum = maxInt(1, firstMinimum + secondMinimum);
        return clampInt(firstMinimum * available / totalMinimum, 0, available);
    }

    private Rect dividerRect() @safe pure nothrow @nogc
    {
        if (_orientation == Orientation.horizontal)
        {
            const available = maxInt(0, bounds().width - _dividerSize);
            return Rect(boundedFirstSize(available), 0, _dividerSize, bounds().height);
        }
        const available = maxInt(0, bounds().height - _dividerSize);
        return Rect(0, boundedFirstSize(available), bounds().width, _dividerSize);
    }

    protected override void onLayout()
    {
        const divider = dividerRect();
        if (_orientation == Orientation.horizontal)
        {
            _first.setBounds(Rect(0, 0, divider.x, bounds().height));
            _second.setBounds(Rect(divider.right(), 0,
                maxInt(0, bounds().width - divider.right()), bounds().height));
        }
        else
        {
            _first.setBounds(Rect(0, 0, bounds().width, divider.y));
            _second.setBounds(Rect(0, divider.bottom(), bounds().width,
                maxInt(0, bounds().height - divider.bottom())));
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const divider = dividerRect();
        canvas.fillRect(divider, _dragging ? theme().accent.withAlpha(120) : theme().border);
        if (_orientation == Orientation.horizontal)
            canvas.fillRoundedRect(Rect(divider.x + divider.width / 2 - 1,
                maxInt(4, divider.height / 2 - 12), 3, 24), 1, theme().textMuted.withAlpha(120));
        else
            canvas.fillRoundedRect(Rect(maxInt(4, divider.width / 2 - 12),
                divider.y + divider.height / 2 - 1, 24, 3), 1, theme().textMuted.withAlpha(120));
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left || !dividerRect().contains(event.position)) return false;
        _dragging = true;
        captureMouse();
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_dragging) return false;
        if (_orientation == Orientation.horizontal)
            setRatio(cast(double) event.position.x / maxInt(1, bounds().width));
        else
            setRatio(cast(double) event.position.y / maxInt(1, bounds().height));
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_dragging) return false;
        _dragging = false;
        releaseMouse();
        invalidate();
        return true;
    }
}
