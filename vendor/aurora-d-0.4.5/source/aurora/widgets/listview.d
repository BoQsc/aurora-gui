module aurora.widgets.listview;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.icons : IconKind, drawIcon;
import aurora.types : CursorKind, HorizontalAlign, Point, Rect, VerticalAlign, clampInt, maxInt;
import aurora.widget : Widget;
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
    private bool _draggingScrollbar;
    private int _thumbGrabOffset;
    private int _scrollbarWidth = 12;

    void delegate(int index) onSelectionChanged;
    void delegate(int index) onActivated;

    this()
    {
        setFocusable(true);
        layoutHints().minWidth = 100;
        layoutHints().minHeight = 80;
        layoutHints().flex = 1.0;
    }

    const(ListItem)[] items() const @safe pure nothrow @nogc { return _items; }
    int selectedIndex() const @safe pure nothrow @nogc { return _selected; }
    int rowHeight() const @safe pure nothrow @nogc { return _rowHeight; }
    int scrollOffset() const @safe pure nothrow @nogc { return _scrollOffset; }
    bool draggingScrollbarForTesting() const @safe pure nothrow @nogc
    {
        return _draggingScrollbar;
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
        clampScroll();
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
        _scrollOffset = 0;
        invalidate();
    }

    void setSelectedIndex(int value, bool notify = true)
    {
        if (_items.length == 0) value = -1;
        else value = clampInt(value, -1, cast(int) _items.length - 1);
        if (_selected == value) return;
        _selected = value;
        ensureSelectionVisible();
        invalidate();
        if (notify && onSelectionChanged !is null)
            onSelectionChanged(_selected);
    }

    void setRowHeight(int value)
    {
        _rowHeight = maxInt(28, value);
        clampScroll();
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

    private void clampScroll()
    {
        _scrollOffset = clampInt(_scrollOffset, 0, maxScroll());
    }

    private void ensureSelectionVisible()
    {
        if (_selected < 0) return;
        const top = _selected * _rowHeight;
        const bottom = top + _rowHeight;
        if (top < _scrollOffset) _scrollOffset = top;
        else if (bottom > _scrollOffset + bounds().height)
            _scrollOffset = bottom - bounds().height;
        clampScroll();
    }

    private int rowAt(Point position) const @safe pure nothrow @nogc
    {
        const row = (position.y + _scrollOffset) / _rowHeight;
        return row >= 0 && row < cast(int) _items.length ? row : -1;
    }

    protected override void onBoundsChanged()
    {
        clampScroll();
    }

    protected override void onMouseLeave()
    {
        _hoveredRow = -1;
        if (!_draggingScrollbar) setCursor(CursorKind.arrow);
    }

    private bool showScrollbar() const @safe pure nothrow @nogc
    {
        return contentHeight() > bounds().height;
    }

    private Rect scrollbarTrack() const @safe pure nothrow @nogc
    {
        return showScrollbar() ? Rect(maxInt(0, bounds().width - _scrollbarWidth - 3),
            4, _scrollbarWidth, maxInt(1, bounds().height - 8)) : Rect.init;
    }

    private Rect scrollbarThumb() const @safe pure nothrow @nogc
    {
        const track = scrollbarTrack();
        if (track.empty()) return Rect.init;
        const thumbHeight = clampInt(track.height * bounds().height /
            maxInt(1, contentHeight()), 24, track.height);
        const travel = maxInt(0, track.height - thumbHeight);
        const y = track.y + (maxScroll() == 0 ? 0 :
            travel * _scrollOffset / maxInt(1, maxScroll()));
        return Rect(track.x, y, track.width, thumbHeight);
    }

    private void updateScrollbarThumb(int pointerY)
    {
        const track = scrollbarTrack();
        const thumb = scrollbarThumb();
        if (track.empty() || thumb.empty()) return;
        const travel = maxInt(1, track.height - thumb.height);
        const y = clampInt(pointerY - _thumbGrabOffset, track.y,
            track.bottom() - thumb.height);
        _scrollOffset = clampInt((y - track.y) * maxScroll() / travel,
            0, maxScroll());
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_showBorder)
            canvas.drawRoundedRect(full, palette.cornerRadius, palette.fieldBackground, palette.border, 1);
        else
            canvas.fillRect(full, palette.fieldBackground);

        auto content = canvas.clipped(full.inset(_showBorder ? 1 : 0));
        const first = _scrollOffset / _rowHeight;
        const last = clampInt((_scrollOffset + bounds().height) / _rowHeight + 1,
            0, cast(int) _items.length);

        foreach (index; first .. last)
        {
            const y = index * _rowHeight - _scrollOffset;
            const row = Rect(1, y, maxInt(0, bounds().width - 2), _rowHeight);
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
                drawIcon(content, item.icon, Rect(8, y + (_rowHeight - 24) / 2, 24, 24),
                    foreground, palette.accent);
                textLeft = 40;
            }

            if (item.secondary.length == 0)
            {
                content.drawTextInRect(Rect(textLeft, y, maxInt(0, bounds().width - textLeft - 12), _rowHeight),
                    item.text, foreground, palette.fontScale, HorizontalAlign.left, VerticalAlign.middle, true);
            }
            else
            {
                content.drawTextInRect(Rect(textLeft, y + 2,
                    maxInt(0, bounds().width - textLeft - 12), 22),
                    item.text, foreground, palette.fontScale,
                    HorizontalAlign.left, VerticalAlign.top, true);
                content.drawTextInRect(Rect(textLeft, y + 24,
                    maxInt(0, bounds().width - textLeft - 12), 18),
                    item.secondary, foreground.withAlpha(180), 1,
                    HorizontalAlign.left, VerticalAlign.top, true);
            }
        }

        if (showScrollbar())
        {
            const track = scrollbarTrack();
            const thumb = scrollbarThumb();
            content.fillRoundedRect(track, track.width / 2,
                palette.border.withAlpha(70));
            content.fillRoundedRect(thumb.inset(2, 1, 2, 1),
                maxInt(2, (thumb.width - 4) / 2),
                (_draggingScrollbar || hovered() ? palette.textMuted : palette.disabled)
                    .withAlpha(_draggingScrollbar ? 230 : 170));
        }

        if (focused())
            canvas.strokeRect(full.inset(2), palette.accent.withAlpha(180), 1);
    }

    override bool onMouseMove(ref Event event)
    {
        if (_draggingScrollbar)
        {
            updateScrollbarThumb(event.position.y);
            return true;
        }
        if (scrollbarTrack().contains(event.position))
        {
            if (_hoveredRow != -1)
            {
                _hoveredRow = -1;
                invalidate();
            }
            setCursor(CursorKind.hand);
            return true;
        }
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
        const track = scrollbarTrack();
        if (track.contains(event.position))
        {
            const thumb = scrollbarThumb();
            _draggingScrollbar = true;
            _thumbGrabOffset = thumb.contains(event.position) ?
                event.position.y - thumb.y : thumb.height / 2;
            captureMouse();
            updateScrollbarThumb(event.position.y);
            setCursor(CursorKind.hand);
            return true;
        }
        const row = rowAt(event.position);
        if (row >= 0 && !_items[cast(size_t) row].disabled)
        {
            setSelectedIndex(row);
            if (event.clickCount >= 2 && onActivated !is null)
                onActivated(row);
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_draggingScrollbar) return false;
        updateScrollbarThumb(event.position.y);
        _draggingScrollbar = false;
        releaseMouse();
        setCursor(CursorKind.arrow);
        invalidate();
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        _scrollOffset = clampInt(_scrollOffset - event.wheelY * _rowHeight / 3,
            0, maxScroll());
        invalidate();
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (_items.length == 0) return false;
        int next = _selected < 0 ? 0 : _selected;
        switch (event.key)
        {
            case Key.up: --next; break;
            case Key.down: ++next; break;
            case Key.pageUp: next -= maxInt(1, bounds().height / _rowHeight); break;
            case Key.pageDown: next += maxInt(1, bounds().height / _rowHeight); break;
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
