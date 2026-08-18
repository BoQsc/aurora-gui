module aurora.widgets.listview;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.icons : IconKind, drawIcon;
import aurora.types : CursorKind, HorizontalAlign, Point, Rect, VerticalAlign,
    clampInt, maxInt;
import aurora.widget : Widget;
import aurora.widgets.scrollbar : Scrollbar;
import std.utf : toUTF32;

struct ListItem
{
    dstring text;
    dstring secondary;
    IconKind icon = IconKind.none;
    bool disabled;

    this(string text, IconKind icon = IconKind.none, string secondary = "")
    {
        this.text = toUTF32(text);
        this.secondary = toUTF32(secondary);
        this.icon = icon;
    }
}

class ListView : Widget
{
    private ListItem[] _items;
    private int _selected = -1;
    private int _hoveredRow = -1;
    private int _scrollOffset;
    private int _rowHeight = 44;
    private bool _showBorder = true;
    private int _scrollbarWidth = 12;
    private Scrollbar _verticalScrollbar;

    void delegate(int index) onSelectionChanged;
    void delegate(int index) onActivated;

    this()
    {
        setFocusable(true);
        layoutHints().minWidth = 100;
        layoutHints().minHeight = 80;
        layoutHints().flex = 1.0;

        _verticalScrollbar = new Scrollbar();
        _verticalScrollbar.layoutHints().excludeFromLayout = true;
        _verticalScrollbar.onValueChanged = delegate(int value)
        {
            applyScrollOffset(value);
        };
        add(_verticalScrollbar);
    }

    const(ListItem)[] items() const @safe pure nothrow @nogc { return _items; }
    int selectedIndex() const @safe pure nothrow @nogc { return _selected; }
    int rowHeight() const @safe pure nothrow @nogc { return _rowHeight; }
    int scrollOffset() const @safe pure nothrow @nogc { return _scrollOffset; }
    Scrollbar verticalScrollbar() @safe pure nothrow @nogc
    {
        return _verticalScrollbar;
    }
    bool draggingScrollbarForTesting() const @safe pure nothrow @nogc
    {
        return _verticalScrollbar !is null && _verticalScrollbar.draggingThumb();
    }

    /** Returns the item index beneath a local point, or -1. */
    int indexAt(Point position) const @safe pure nothrow @nogc
    {
        return rowAt(position);
    }

    void setItems(ListItem[] value)
    {
        _items = value;
        if (_selected >= cast(int) _items.length)
            _selected = _items.length == 0 ? -1 : cast(int) _items.length - 1;
        setScrollOffset(_scrollOffset);
        synchronizeScrollbar();
        invalidate();
    }

    void setStrings(string[] values, IconKind icon = IconKind.none)
    {
        ListItem[] converted;
        converted.reserve(values.length);
        foreach (value; values)
            converted ~= ListItem(value, icon);
        setItems(converted);
    }

    void clear()
    {
        _items.length = 0;
        _selected = -1;
        setScrollOffset(0);
        synchronizeScrollbar();
        invalidate();
    }

    void setSelectedIndex(int value, bool notify = true, bool ensureVisible = true)
    {
        if (_items.length == 0) value = -1;
        else value = clampInt(value, -1, cast(int) _items.length - 1);
        if (_selected == value) return;
        _selected = value;
        if (ensureVisible) ensureSelectionVisible();
        invalidate();
        if (notify && onSelectionChanged !is null)
            onSelectionChanged(_selected);
    }

    void setRowHeight(int value)
    {
        _rowHeight = maxInt(28, value);
        setScrollOffset(_scrollOffset);
        synchronizeScrollbar();
        invalidate();
    }

    void setShowBorder(bool value)
    {
        _showBorder = value;
        invalidate();
    }

    int contentHeight() const @safe pure nothrow @nogc
    {
        return cast(int) _items.length * _rowHeight;
    }

    int maxScroll() const @safe pure nothrow @nogc
    {
        return maxInt(0, contentHeight() - bounds().height);
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

    private void setScrollOffset(int value)
    {
        if (_verticalScrollbar is null)
            applyScrollOffset(value);
        else
            _verticalScrollbar.setValue(value);
    }

    private void applyScrollOffset(int value)
    {
        const next = clampInt(value, 0, maxScroll());
        if (_scrollOffset == next) return;
        _scrollOffset = next;
        invalidate();
    }

    private void ensureSelectionVisible()
    {
        if (_selected < 0) return;
        const top = _selected * _rowHeight;
        const bottom = top + _rowHeight;
        int next = _scrollOffset;
        if (top < next) next = top;
        else if (bottom > next + bounds().height)
            next = bottom - bounds().height;
        setScrollOffset(next);
    }

    private int rowAt(Point position) const @safe pure nothrow @nogc
    {
        const row = (position.y + _scrollOffset) / _rowHeight;
        return row >= 0 && row < cast(int) _items.length ? row : -1;
    }

    protected override void onBoundsChanged()
    {
        synchronizeScrollbar();
        setScrollOffset(_scrollOffset);
    }

    protected override void onLayout()
    {
        synchronizeScrollbar();
    }

    protected override void onMouseLeave()
    {
        _hoveredRow = -1;
        setCursor(CursorKind.arrow);
    }

    private bool showScrollbar() const @safe pure nothrow @nogc
    {
        return contentHeight() > bounds().height;
    }

    private void synchronizeScrollbar()
    {
        if (_verticalScrollbar is null) return;
        const maximum = maxScroll();
        // A resize can shrink the content viewport below a previously applied
        // scroll offset (for example a popup panel grown after its initial
        // layout). Re-clamp so the field and scrollbar cannot disagree and
        // silently scroll every row out of view.
        if (_scrollOffset > maximum) applyScrollOffset(maximum);
        _verticalScrollbar.setBounds(Rect(
            maxInt(0, bounds().width - _scrollbarWidth - 3), 4,
            _scrollbarWidth, maxInt(1, bounds().height - 8)));
        _verticalScrollbar.setLineStep(_rowHeight);
        _verticalScrollbar.setPageStep(maxInt(_rowHeight,
            bounds().height - _rowHeight));
        _verticalScrollbar.setRange(0, maximum, maxInt(1, bounds().height));
        _verticalScrollbar.setValue(_scrollOffset, false);
        _verticalScrollbar.setVisible(maximum > 0);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_showBorder)
            canvas.drawRoundedRect(full, palette.cornerRadius,
                palette.fieldBackground, palette.border, 1);
        else
            canvas.fillRect(full, palette.fieldBackground);

        auto content = canvas.clipped(full.inset(_showBorder ? 1 : 0));
        const first = _scrollOffset / _rowHeight;
        const last = clampInt((_scrollOffset + bounds().height) / _rowHeight + 1,
            0, cast(int) _items.length);
        const contentWidth = maxInt(0, bounds().width -
            (showScrollbar() ? _scrollbarWidth + 3 : 0));

        foreach (index; first .. last)
        {
            const y = index * _rowHeight - _scrollOffset;
            const row = Rect(1, y, maxInt(0, contentWidth - 2), _rowHeight);
            const item = _items[cast(size_t) index];
            Color foreground = item.disabled ? palette.disabled : palette.text;
            if (index == _selected)
            {
                content.fillRect(row, palette.selection);
                foreground = palette.selectionText;
            }
            else if (index == _hoveredRow)
            {
                content.fillRect(row, palette.buttonHover.withAlpha(150));
            }

            int textLeft = 10;
            if (item.icon != IconKind.none)
            {
                drawIcon(content, item.icon,
                    Rect(8, y + (_rowHeight - 24) / 2, 24, 24),
                    foreground, palette.accent);
                textLeft = 40;
            }

            if (item.secondary.length == 0)
            {
                content.drawTextInRect(Rect(textLeft, y,
                    maxInt(0, contentWidth - textLeft - 12), _rowHeight),
                    item.text, foreground, palette.fontScale,
                    HorizontalAlign.left, VerticalAlign.middle, true);
            }
            else
            {
                // Split the row height in two so the secondary line can never
                // paint past the row boundary and overlap the next item. A tall
                // row keeps both lines readable; a short row still confines them.
                const mainHeight = maxInt(12, (maxInt(2, _rowHeight) - 4) / 2);
                const mainTop = y + 2;
                const secondaryTop = y + 2 + mainHeight;
                const secondaryHeight = maxInt(2,
                    maxInt(1, _rowHeight) - (secondaryTop - y));
                content.drawTextInRect(Rect(textLeft, mainTop,
                    maxInt(0, contentWidth - textLeft - 12), mainHeight),
                    item.text, foreground, palette.fontScale,
                    HorizontalAlign.left, VerticalAlign.top, true);
                content.drawTextInRect(Rect(textLeft, secondaryTop,
                    maxInt(0, contentWidth - textLeft - 12), secondaryHeight),
                    item.secondary, foreground.withAlpha(180), 1,
                    HorizontalAlign.left, VerticalAlign.top, true);
            }
        }

        if (focused())
            canvas.strokeRect(full.inset(2), palette.accent.withAlpha(180), 1);
    }

    override bool onMouseMove(ref Event event)
    {
        setCursor(CursorKind.arrow);
        const next = rowAt(event.position);
        if (next != _hoveredRow)
        {
            _hoveredRow = next;
            invalidate();
        }
        return true;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        requestFocus();
        const row = rowAt(event.position);
        if (row >= 0 && !_items[cast(size_t) row].disabled)
        {
            setSelectedIndex(row);
            if (event.clickCount >= 2 && onActivated !is null)
                onActivated(row);
        }
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        return _verticalScrollbar.visible() &&
            _verticalScrollbar.onMouseWheel(event);
    }

    override bool onKeyDown(ref Event event)
    {
        if (_items.length == 0) return false;
        int next = _selected < 0 ? 0 : _selected;
        switch (event.key)
        {
            case Key.up: --next; break;
            case Key.down: ++next; break;
            case Key.pageUp:
                next -= maxInt(1, bounds().height / _rowHeight);
                break;
            case Key.pageDown:
                next += maxInt(1, bounds().height / _rowHeight);
                break;
            case Key.home: next = 0; break;
            case Key.end: next = cast(int) _items.length - 1; break;
            case Key.enter:
                if (_selected >= 0 && onActivated !is null) onActivated(_selected);
                return true;
            default:
                return false;
        }
        next = clampInt(next, 0, cast(int) _items.length - 1);
        while (_items[cast(size_t) next].disabled)
        {
            if (next < _selected) --next; else ++next;
            if (next < 0 || next >= cast(int) _items.length) return true;
        }
        setSelectedIndex(next);
        return true;
    }
}
