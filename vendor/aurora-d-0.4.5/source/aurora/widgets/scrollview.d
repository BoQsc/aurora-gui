module aurora.widgets.scrollview;

import aurora.event : Event;
import aurora.types : Point, Rect, Size, maxInt, minInt;
import aurora.widget : Widget;
import aurora.widgets.scrollbar : Scrollbar;

/** Single-child vertical viewport backed by the reusable Scrollbar widget. */
class ScrollView : Widget
{
    private Widget _content;
    private Scrollbar _verticalScrollbar;
    private int _scrollY;
    private int _contentHeight;
    private int _scrollbarWidth = 10;

    this(Widget content = null)
    {
        setFocusable(true);
        layoutHints().minWidth = 80;
        layoutHints().minHeight = 64;
        layoutHints().allowOverflow = true;
        if (content !is null) setContent(content);

        _verticalScrollbar = new Scrollbar();
        _verticalScrollbar.layoutHints().excludeFromLayout = true;
        _verticalScrollbar.setLineStep(42);
        _verticalScrollbar.onValueChanged = delegate(int value)
        {
            applyScrollY(value);
        };
        add(_verticalScrollbar);
    }

    Widget content() @safe pure nothrow @nogc { return _content; }
    Scrollbar verticalScrollbar() @safe pure nothrow @nogc
    {
        return _verticalScrollbar;
    }
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
            if (_verticalScrollbar !is null)
                bringChildToFront(_verticalScrollbar);
        }
        synchronizeScrollbar();
        invalidate();
    }

    void setScrollY(int value)
    {
        if (_verticalScrollbar is null)
            applyScrollY(value);
        else
            _verticalScrollbar.setValue(value);
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

    override bool nativeVerticalScrollInfo(Point localPosition, out Widget source,
        out int position, out int maximum, out int pageSize)
    {
        if (_verticalScrollbar is null || !_verticalScrollbar.visible())
        {
            source = null;
            position = 0;
            maximum = 0;
            pageSize = 1;
            return false;
        }
        return _verticalScrollbar.nativeVerticalScrollInfo(localPosition, source,
            position, maximum, pageSize);
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
        return maxInt(0, bounds().width -
            (maxScroll() > 0 ? _scrollbarWidth + 4 : 0));
    }

    protected override void onLayout()
    {
        if (_content is null)
        {
            _contentHeight = 0;
            _scrollY = 0;
            synchronizeScrollbar();
            return;
        }

        auto measured = _content.measure(Size(maxInt(0, bounds().width), int.max));
        const needsScrollbar = measured.height > bounds().height;
        const width = maxInt(0, bounds().width -
            (needsScrollbar ? _scrollbarWidth + 4 : 0));
        if (needsScrollbar)
            measured = _content.measure(Size(width, int.max));
        _contentHeight = maxInt(bounds().height, measured.height);
        _scrollY = _scrollY < 0 ? 0 : minInt(_scrollY, maxScroll());
        _content.setBounds(Rect(0, -_scrollY, width, _contentHeight));
        synchronizeScrollbar();
    }

    override bool onMouseWheel(ref Event event)
    {
        return _verticalScrollbar !is null && _verticalScrollbar.visible() &&
            _verticalScrollbar.onMouseWheel(event);
    }

    override bool onKeyDown(ref Event event)
    {
        return _verticalScrollbar !is null && _verticalScrollbar.visible() &&
            _verticalScrollbar.onKeyDown(event);
    }

    private void synchronizeScrollbar()
    {
        if (_verticalScrollbar is null) return;
        const maximum = maxScroll();
        _verticalScrollbar.setBounds(Rect(
            maxInt(0, bounds().width - _scrollbarWidth - 2), 3,
            _scrollbarWidth, maxInt(1, bounds().height - 6)));
        _verticalScrollbar.setPageStep(maxInt(42, bounds().height - 42));
        _verticalScrollbar.setRange(0, maximum, maxInt(1, bounds().height));
        _verticalScrollbar.setValue(_scrollY, false);
        _verticalScrollbar.setVisible(maximum > 0);
    }

    private void applyScrollY(int value)
    {
        const next = value < 0 ? 0 : minInt(value, maxScroll());
        if (_scrollY == next) return;
        _scrollY = next;
        if (_content !is null)
            _content.setBounds(Rect(0, -_scrollY, contentViewportWidth(),
                _contentHeight));
        invalidate();
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
    assert(view.verticalScrollbar().visible());
    view.setScrollY(999);
    assert(view.scrollY() == 420);
    assert(view.verticalScrollbar().value() == 420);
    assert(view.content().bounds().y == -420);
}
