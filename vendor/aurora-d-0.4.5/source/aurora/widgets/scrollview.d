module aurora.widgets.scrollview;

import aurora.canvas : Canvas;
import aurora.event : Event, Key, MouseButton;
import aurora.types : CursorKind, Point, Rect, Size, clampInt, maxInt, minInt;
import aurora.widget : Widget;

/** Single-child vertical viewport with wheel, keyboard, and thumb scrolling. */
class ScrollView : Widget
{
    private Widget _content;
    private int _scrollY;
    private int _contentHeight;
    private bool _showScrollbar;
    private bool _draggingThumb;
    private int _thumbGrabOffset;
    private int _scrollbarWidth = 10;

    this(Widget content = null)
    {
        setFocusable(true);
        layoutHints().minWidth = 80;
        layoutHints().minHeight = 64;
        layoutHints().allowOverflow = true;
        if (content !is null) setContent(content);
    }

    Widget content() @safe pure nothrow @nogc { return _content; }
    int scrollY() const @safe pure nothrow @nogc { return _scrollY; }
    int contentHeight() const @safe pure nothrow @nogc { return _contentHeight; }
    int maxScroll() const @safe pure nothrow @nogc
    {
        return maxInt(0, _contentHeight - bounds().height);
    }

    void setContent(Widget value)
    {
        if (_content is value) return;
        if (_content !is null) remove(_content);
        _content = value;
        _scrollY = 0;
        if (_content !is null)
        {
            _content.layoutHints().excludeFromLayout = true;
            _content.layoutHints().allowOverflow = true;
            add(_content);
        }
        invalidate();
    }

    void setScrollY(int value)
    {
        const next = clampInt(value, 0, maxScroll());
        if (_scrollY == next) return;
        _scrollY = next;
        if (_content !is null)
            _content.setBounds(Rect(0, -_scrollY, contentViewportWidth(), _contentHeight));
        invalidate();
    }

    void scrollBy(int delta)
    {
        setScrollY(_scrollY + delta);
    }

    void ensureVisible(Rect contentRect)
    {
        if (contentRect.y < _scrollY)
            setScrollY(contentRect.y);
        else if (contentRect.bottom() > _scrollY + bounds().height)
            setScrollY(contentRect.bottom() - bounds().height);
    }

    protected override Size onMeasure(Size available)
    {
        if (_content is null) return Size(0, 0);
        const measured = _content.measure(Size(maxInt(0, available.width), int.max));
        return Size(minInt(measured.width, available.width),
            minInt(measured.height, available.height));
    }

    private int contentViewportWidth() const @safe pure nothrow @nogc
    {
        return maxInt(0, bounds().width - (_showScrollbar ? _scrollbarWidth + 4 : 0));
    }

    protected override void onLayout()
    {
        if (_content is null)
        {
            _contentHeight = 0;
            _showScrollbar = false;
            _scrollY = 0;
            return;
        }

        auto measured = _content.measure(Size(maxInt(0, bounds().width), int.max));
        _showScrollbar = measured.height > bounds().height;
        const width = contentViewportWidth();
        if (_showScrollbar)
            measured = _content.measure(Size(width, int.max));
        _contentHeight = maxInt(bounds().height, measured.height);
        _scrollY = clampInt(_scrollY, 0, maxScroll());
        _content.setBounds(Rect(0, -_scrollY, width, _contentHeight));
    }

    private Rect scrollbarTrack() const @safe pure nothrow @nogc
    {
        return _showScrollbar ? Rect(maxInt(0, bounds().width - _scrollbarWidth - 2),
            3, _scrollbarWidth, maxInt(1, bounds().height - 6)) : Rect.init;
    }

    private Rect scrollbarThumb() const @safe pure nothrow @nogc
    {
        const track = scrollbarTrack();
        if (track.empty()) return Rect.init;
        const minimumThumb = 24;
        const height = clampInt(bounds().height * track.height /
            maxInt(1, _contentHeight), minimumThumb, track.height);
        const travel = maxInt(0, track.height - height);
        const y = track.y + (maxScroll() == 0 ? 0 : travel * _scrollY / maxScroll());
        return Rect(track.x, y, track.width, height);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (!_showScrollbar) return;
        const track = scrollbarTrack();
        const thumb = scrollbarThumb();
        canvas.fillRoundedRect(track, track.width / 2,
            theme().border.withAlpha(75));
        canvas.fillRoundedRect(thumb, thumb.width / 2,
            (_draggingThumb || hovered() ? theme().textMuted : theme().disabled)
                .withAlpha(_draggingThumb ? 220 : 165));
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left || !_showScrollbar) return false;
        const track = scrollbarTrack();
        if (!track.contains(event.position)) return false;
        requestFocus();
        const thumb = scrollbarThumb();
        _draggingThumb = true;
        _thumbGrabOffset = thumb.contains(event.position) ? event.position.y - thumb.y :
            thumb.height / 2;
        captureMouse();
        updateThumb(event.position.y);
        setCursor(CursorKind.hand);
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_draggingThumb) return false;
        updateThumb(event.position.y);
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_draggingThumb) return false;
        updateThumb(event.position.y);
        _draggingThumb = false;
        releaseMouse();
        setCursor(CursorKind.arrow);
        invalidate();
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (!_showScrollbar || event.wheelY == 0) return false;
        scrollBy(-event.wheelY * 42);
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        switch (event.key)
        {
            case Key.pageUp:
                scrollBy(-maxInt(42, bounds().height - 42));
                return true;
            case Key.pageDown:
                scrollBy(maxInt(42, bounds().height - 42));
                return true;
            case Key.home:
                setScrollY(0);
                return true;
            case Key.end:
                setScrollY(maxScroll());
                return true;
            case Key.up:
                scrollBy(-42);
                return true;
            case Key.down:
                scrollBy(42);
                return true;
            default:
                return false;
        }
    }

    private void updateThumb(int pointerY)
    {
        const track = scrollbarTrack();
        const thumb = scrollbarThumb();
        const travel = maxInt(1, track.height - thumb.height);
        const y = clampInt(pointerY - _thumbGrabOffset, track.y,
            track.bottom() - thumb.height);
        setScrollY((y - track.y) * maxScroll() / travel);
    }
}

unittest
{
    final class TallPanel : Widget
    {
        this()
        {
            layoutHints().preferredWidth = 180;
            layoutHints().preferredHeight = 600;
        }
    }
    auto view = new ScrollView(new TallPanel());
    view.setBounds(Rect(0, 0, 200, 180));
    view.layoutTree();
    assert(view.maxScroll() == 420);
    view.setScrollY(999);
    assert(view.scrollY() == 420);
    assert(view.content().bounds().y == -420);
}
