module aurora.widgets.scrollbar;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.types : Orientation, Point, Rect, Size, clampInt, maxInt, minInt;
import aurora.widget : Widget;

/**
 * Reusable Aurora-rendered scrollbar.
 *
 * The control owns its value, geometry, painting, paging, keyboard behavior,
 * wheel accumulation, and pointer capture. Content remains owned by the
 * consumer through `onValueChanged`.
 */
class Scrollbar : Widget
{
    private enum wheelUnitsPerNotch = 3;

    private Orientation _orientation;
    private int _minimum;
    private int _maximum;
    private int _pageSize = 1;
    private int _value;
    private int _lineStep = 40;
    private int _pageStep;
    private int _minimumThumbLength = 24;
    private int _thumbCrossInset = 2;
    private int _trackRadius;
    private int _thumbRadius = 2;
    private int _wheelRemainder;
    private bool _draggingThumb;
    private int _thumbGrabOffset;
    private bool _synchronizeNativeHost = true;
    private bool _customColors;
    private Color _trackColor;
    private Color _thumbColor;
    private Color _thumbHoverColor;
    private Color _thumbActiveColor;

    void delegate(int value) onValueChanged;

    this(Orientation orientation = Orientation.vertical)
    {
        _orientation = orientation;
        setFocusable(true);
        if (_orientation == Orientation.vertical)
        {
            layoutHints().minWidth = 8;
            layoutHints().minHeight = 32;
            layoutHints().preferredWidth = 12;
        }
        else
        {
            layoutHints().minWidth = 32;
            layoutHints().minHeight = 8;
            layoutHints().preferredHeight = 12;
        }
    }

    Orientation orientation() const @safe pure nothrow @nogc
    {
        return _orientation;
    }

    int minimum() const @safe pure nothrow @nogc { return _minimum; }
    int maximum() const @safe pure nothrow @nogc { return _maximum; }
    int pageSize() const @safe pure nothrow @nogc { return _pageSize; }
    int value() const @safe pure nothrow @nogc { return _value; }
    int lineStep() const @safe pure nothrow @nogc { return _lineStep; }
    bool draggingThumb() const @safe pure nothrow @nogc { return _draggingThumb; }
    bool scrollable() const @safe pure nothrow @nogc
    {
        return _maximum > _minimum;
    }

    override bool nativeVerticalScrollInfo(Point localPosition, out Widget source,
        out int position, out int maximum, out int pageSize)
    {
        if (_orientation != Orientation.vertical || !visible())
        {
            source = null;
            position = 0;
            maximum = 0;
            pageSize = 1;
            return false;
        }
        source = this;
        position = _value - _minimum;
        maximum = _maximum - _minimum;
        pageSize = _pageSize;
        return true;
    }

    void setRange(int minimum, int maximum, int pageSize, bool notify = false)
    {
        if (maximum < minimum) maximum = minimum;
        pageSize = maxInt(1, pageSize);
        const nextValue = clampInt(_value, minimum, maximum);
        const valueChanged = nextValue != _value;
        const changed = minimum != _minimum || maximum != _maximum ||
            pageSize != _pageSize || valueChanged;
        _minimum = minimum;
        _maximum = maximum;
        _pageSize = pageSize;
        _value = nextValue;
        if (!scrollable()) cancelDrag();
        synchronizeNativeHost();
        if (changed) invalidate();
        if (valueChanged && notify && onValueChanged !is null)
            onValueChanged(_value);
    }

    void setValue(int value, bool notify = true)
    {
        const next = clampInt(value, _minimum, _maximum);
        if (next == _value)
        {
            synchronizeNativeHost();
            return;
        }
        _value = next;
        synchronizeNativeHost();
        invalidate();
        if (notify && onValueChanged !is null)
            onValueChanged(_value);
    }

    void scrollBy(int delta, bool notify = true)
    {
        setValue(_value + delta, notify);
    }

    void setLineStep(int value)
    {
        _lineStep = maxInt(1, value);
    }

    /** A non-positive value makes track clicks use the current page size. */
    void setPageStep(int value)
    {
        _pageStep = value;
    }

    void setMinimumThumbLength(int value)
    {
        const next = maxInt(1, value);
        if (next == _minimumThumbLength) return;
        _minimumThumbLength = next;
        invalidate();
    }

    void setThumbCrossInset(int value)
    {
        const next = maxInt(0, value);
        if (next == _thumbCrossInset) return;
        _thumbCrossInset = next;
        invalidate();
    }

    void setCornerRadii(int trackRadius, int thumbRadius)
    {
        _trackRadius = maxInt(0, trackRadius);
        _thumbRadius = maxInt(0, thumbRadius);
        invalidate();
    }

    void setColors(Color track, Color thumb)
    {
        _customColors = true;
        _trackColor = track;
        _thumbColor = thumb;
        _thumbHoverColor = thumb;
        _thumbActiveColor = thumb;
        invalidate();
    }

    void setInteractionColors(Color hover, Color active)
    {
        _customColors = true;
        _thumbHoverColor = hover;
        _thumbActiveColor = active;
        invalidate();
    }

    /**
     * Opt out of automatic native-host synchronization. Vertical controls are
     * synchronized by default; the host accepts updates only from the retained
     * scroll target under the pointer.
     */
    void setSynchronizeNativeHost(bool value)
    {
        if (_synchronizeNativeHost == value) return;
        _synchronizeNativeHost = value;
        synchronizeNativeHost();
    }

    Rect trackRect() const @safe pure nothrow @nogc
    {
        return Rect(0, 0, bounds().width, bounds().height);
    }

    Rect thumbRect() const @safe pure nothrow @nogc
    {
        if (!scrollable()) return Rect.init;
        const track = trackRect();
        const primaryLength = _orientation == Orientation.vertical ?
            track.height : track.width;
        const crossLength = _orientation == Orientation.vertical ?
            track.width : track.height;
        if (primaryLength <= 0 || crossLength <= 0) return Rect.init;

        const valueRange = maxInt(1, _maximum - _minimum);
        const contentExtent = valueRange + _pageSize;
        const minimumThumb = minInt(_minimumThumbLength, primaryLength);
        const thumbLength = clampInt(primaryLength * _pageSize /
            maxInt(1, contentExtent), minimumThumb, primaryLength);
        const travel = maxInt(0, primaryLength - thumbLength);
        const offset = travel * (_value - _minimum) / valueRange;
        const crossInset = clampInt(_thumbCrossInset, 0, crossLength / 2);

        if (_orientation == Orientation.vertical)
            return Rect(crossInset, offset,
                maxInt(1, track.width - crossInset * 2), thumbLength);
        return Rect(offset, crossInset, thumbLength,
            maxInt(1, track.height - crossInset * 2));
    }

    protected override Size onMeasure(Size available)
    {
        return _orientation == Orientation.vertical ?
            Size(layoutHints().preferredWidth, 64) :
            Size(64, layoutHints().preferredHeight);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (!scrollable()) return;
        const palette = theme();
        const track = trackRect();
        const thumb = thumbRect();
        const trackColor = _customColors ? _trackColor :
            palette.border.withAlpha(75);
        Color thumbColor;
        if (_customColors)
            thumbColor = _draggingThumb ? _thumbActiveColor :
                (hovered() ? _thumbHoverColor : _thumbColor);
        else
            thumbColor = (_draggingThumb || hovered() ?
                palette.textMuted : palette.disabled)
                .withAlpha(_draggingThumb ? 220 : 165);

        if (_trackRadius > 0)
            canvas.fillRoundedRect(track, _trackRadius, trackColor);
        else
            canvas.fillRect(track, trackColor);
        if (_thumbRadius > 0)
            canvas.fillRoundedRect(thumb, _thumbRadius, thumbColor);
        else
            canvas.fillRect(thumb, thumbColor);
    }

    override bool onMouseDown(ref Event event)
    {
        if (!enabled() || event.button != MouseButton.left || !scrollable())
            return false;
        const thumb = thumbRect();
        const pointer = primaryCoordinate(event.position);
        requestFocus();
        if (thumb.contains(event.position))
        {
            _draggingThumb = true;
            _thumbGrabOffset = pointer - primaryStart(thumb);
            captureMouse();
            invalidate();
            return true;
        }

        const step = effectivePageStep();
        setValue(_value + (pointer < primaryStart(thumb) ? -step : step));
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_draggingThumb) return false;
        updateThumb(primaryCoordinate(event.position));
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_draggingThumb) return false;
        updateThumb(primaryCoordinate(event.position));
        cancelDrag();
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (!scrollable()) return false;
        if (_orientation == Orientation.vertical &&
            event.hasVerticalScrollPosition)
        {
            setValue(event.verticalScrollPosition);
            return true;
        }

        const units = _orientation == Orientation.vertical ?
            (event.wheelY != 0 ? event.wheelY : event.wheelX) :
            (event.wheelX != 0 ? event.wheelX : event.wheelY);
        if (units == 0) return false;
        if ((units > 0 && _wheelRemainder < 0) ||
            (units < 0 && _wheelRemainder > 0))
            _wheelRemainder = 0;
        const scaled = -units * _lineStep + _wheelRemainder;
        const delta = scaled / wheelUnitsPerNotch;
        _wheelRemainder = scaled - delta * wheelUnitsPerNotch;
        if (delta != 0) scrollBy(delta);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (!scrollable()) return false;
        switch (event.key)
        {
            case Key.home: setValue(_minimum); return true;
            case Key.end: setValue(_maximum); return true;
            case Key.pageUp: scrollBy(-effectivePageStep()); return true;
            case Key.pageDown: scrollBy(effectivePageStep()); return true;
            case Key.up:
                if (_orientation == Orientation.vertical)
                {
                    scrollBy(-_lineStep);
                    return true;
                }
                return false;
            case Key.down:
                if (_orientation == Orientation.vertical)
                {
                    scrollBy(_lineStep);
                    return true;
                }
                return false;
            case Key.left:
                if (_orientation == Orientation.horizontal)
                {
                    scrollBy(-_lineStep);
                    return true;
                }
                return false;
            case Key.right:
                if (_orientation == Orientation.horizontal)
                {
                    scrollBy(_lineStep);
                    return true;
                }
                return false;
            default:
                return false;
        }
    }

    protected override void onFocusChanged(bool focused)
    {
        if (!focused) cancelDrag();
    }

    protected override void onHostFocusChanged(bool focused)
    {
        if (!focused) cancelDrag();
    }

    private int primaryCoordinate(Point point) const @safe pure nothrow @nogc
    {
        return _orientation == Orientation.vertical ? point.y : point.x;
    }

    private int primaryStart(Rect rect) const @safe pure nothrow @nogc
    {
        return _orientation == Orientation.vertical ? rect.y : rect.x;
    }

    private int primaryLength(Rect rect) const @safe pure nothrow @nogc
    {
        return _orientation == Orientation.vertical ? rect.height : rect.width;
    }

    private int effectivePageStep() const @safe pure nothrow @nogc
    {
        return maxInt(1, _pageStep > 0 ? _pageStep : _pageSize);
    }

    private void updateThumb(int pointer)
    {
        const track = trackRect();
        const thumb = thumbRect();
        if (track.empty() || thumb.empty()) return;
        const travel = maxInt(1, primaryLength(track) - primaryLength(thumb));
        const position = clampInt(pointer - _thumbGrabOffset, 0, travel);
        const valueRange = maxInt(1, _maximum - _minimum);
        setValue(_minimum + position * valueRange / travel);
    }

    private void cancelDrag()
    {
        if (!_draggingThumb) return;
        _draggingThumb = false;
        releaseMouse();
        invalidate();
    }

    private void synchronizeNativeHost()
    {
        if (!_synchronizeNativeHost || _orientation != Orientation.vertical ||
            host() is null)
            return;
        host().synchronizeVerticalScrollInfo(this, _value - _minimum,
            _maximum - _minimum, _pageSize);
    }
}
