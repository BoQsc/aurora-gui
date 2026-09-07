module auroradesktop.search;

import aurora;
import aurora.widgets.popup : TransientPopup, dismissTransientPopups, popupRoot;
import aurora.text.unicode.grapheme : previousGraphemeBoundary;
import std.utf : toUTF32;

/**
 * A Windows-10-style search flyout anchored beneath the taskbar search pill.
 *
 * It presents a single-line query field and a list of matching results
 * (applications and commands) that updates live as the user types. Keyboard
 * traversal (arrows + Enter) and mouse hover/click both activate a result. It
 * is a TransientPopup so it dismisses on click-away / Escape.
 */
final class SearchPopup : TransientPopup
{
    private struct Entry
    {
        dstring label;
        dstring description;
        IconKind icon;
        void delegate() action;
    }

    private Entry[] _entries;
    private Rect _anchorGlobal;
    private Rect _panelRect;
    private Rect _queryRect;
    private Rect _listRect;
    private dstring _query;
    private int _hot;      // -1 = none
    private int _pressed;  // -1 = none
    private int _rowHeight = 54;
    private int _panelWidth = 520;
    private int _maximumPanelHeight = 640;
    private int _margin = 8;
    private int _gap = 6;
    private int _padding = 14;
    private int _queryHeight = 44;
    private int _listGap = 8;
    private bool _opening;

    this(Widget focusReturn = null)
    {
        super(focusReturn);
        setCursor(CursorKind.arrow);
    }

    dstring query() const @safe pure nothrow @nogc { return _query; }
    Rect panelRect() const @safe pure nothrow @nogc { return _panelRect; }
    Rect queryRect() const @safe pure nothrow @nogc { return _queryRect; }
    int resultCount() const { return resultCountInternal(); }

    void add(string label, IconKind icon, void delegate() action,
        string description = "")
    {
        Entry entry;
        entry.label = toUTF32(label);
        entry.description = toUTF32(description);
        entry.icon = icon;
        entry.action = action;
        _entries ~= entry;
    }

    bool open()
    {
        return parent() !is null && !dismissed();
    }

    bool show(Widget owner, Rect globalAnchor)
    {
        auto root = popupRoot(owner);
        if (root is null) return false;
        if (open()) dismiss();
        dismissTransientPopups(root);
        prepareToOpen(owner);
        _opening = true;
        _anchorGlobal = globalAnchor;
        _query.length = 0;
        _hot = firstSelectable();
        _pressed = -1;
        root.add(this);
        setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
        root.bringChildToFront(this);
        recalculateLayout();
        requestFocus();
        _opening = false;
        invalidate();
        return true;
    }

    override void dismiss()
    {
        if (dismissed() || _opening) return;
        if (_pressed >= 0)
        {
            _pressed = -1;
            releaseMouse();
        }
        super.dismiss();
    }

    override bool popupContains(Point globalPoint) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return _panelRect.contains(Point(globalPoint.x - origin.x,
            globalPoint.y - origin.y));
    }

    override bool dismissPopupForPointer(Point globalPoint, MouseButton button)
    {
        const consume = _anchorGlobal.contains(globalPoint);
        dismiss();
        return consume;
    }

    private bool matches(Entry entry) const
    {
        if (_query.length == 0) return true;
        return containsFolded(entry.label, _query) ||
            containsFolded(entry.description, _query);
    }

    private static bool containsFolded(const(dchar)[] haystack,
        const(dchar)[] needle) @safe pure nothrow @nogc
    {
        if (needle.length == 0) return true;
        if (needle.length > haystack.length) return false;
        foreach (start; 0 .. haystack.length - needle.length + 1)
        {
            bool equal = true;
            foreach (offset; 0 .. needle.length)
            {
                if (foldAscii(haystack[start + offset]) != foldAscii(needle[offset]))
                {
                    equal = false;
                    break;
                }
            }
            if (equal) return true;
        }
        return false;
    }

    private static dchar foldAscii(dchar value) @safe pure nothrow @nogc
    {
        return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
    }

    private int resultCountInternal() const
    {
        int count;
        foreach (entry; _entries)
            if (matches(entry)) ++count;
        return count;
    }

    private int entryIndexAt(int visibleOrder) const
    {
        int order;
        foreach (index, entry; _entries)
        {
            if (!matches(entry)) continue;
            if (order == visibleOrder) return cast(int) index;
            ++order;
        }
        return -1;
    }

    private int visibleOrderOf(int entryIndex) const
    {
        int order;
        foreach (index, entry; _entries)
        {
            if (!matches(entry)) continue;
            if (cast(int) index == entryIndex) return order;
            ++order;
        }
        return -1;
    }

    private int firstSelectable() const
    {
        foreach (index, entry; _entries)
            if (matches(entry))
                return cast(int) index;
        return -1;
    }

    private void setHot(int value)
    {
        if (_hot == value) return;
        _hot = value;
        invalidate();
    }

    private void moveSelection(int direction)
    {
        int count = resultCountInternal();
        if (count == 0)
        {
            setHot(-1);
            return;
        }
        int current = _hot >= 0 ? visibleOrderOf(_hot) : -1;
        int next;
        if (direction < 0)
            next = current <= 0 ? count - 1 : current - 1;
        else
            next = current < 0 || current + 1 >= count ? 0 : current + 1;
        setHot(entryIndexAt(next));
    }

    private void activate(int entryIndex)
    {
        if (entryIndex < 0 || entryIndex >= cast(int) _entries.length) return;
        void delegate() action = _entries[cast(size_t) entryIndex].action;
        dismiss();
        if (action !is null) action();
    }

    private int entryAt(Point point) const
    {
        if (!_listRect.contains(point)) return -1;
        const order = (point.y - _listRect.y) / _rowHeight;
        if (order < 0 || order >= resultCountInternal()) return -1;
        return entryIndexAt(order);
    }

    protected override void onBoundsChanged()
    {
        recalculateLayout();
    }

    private void recalculateLayout()
    {
        if (bounds().width <= 0 || bounds().height <= 0)
        {
            _panelRect = Rect.init;
            _queryRect = Rect.init;
            _listRect = Rect.init;
            return;
        }

        const availableWidth = maxInt(1, bounds().width - _margin * 2);
        const availableHeight = maxInt(1, bounds().height - _margin * 2);
        const width = minInt(_panelWidth, availableWidth);
        const count = resultCountInternal();
        const rows = count == 0 ? 1 : count;
        const desiredHeight = _padding + _queryHeight + _listGap +
            rows * _rowHeight + _padding;
        const height = clampInt(minInt(_maximumPanelHeight, desiredHeight),
            minInt(300, availableHeight), availableHeight);

        const rootOrigin = globalOrigin();
        const anchor = Rect(_anchorGlobal.x - rootOrigin.x,
            _anchorGlobal.y - rootOrigin.y, _anchorGlobal.width,
            _anchorGlobal.height);
        // Anchor ABOVE the pill would overlap the taskbar; Windows-11 search
        // opens BELOW. The pill sits at the taskbar top, so its bottom edge is
        // the anchor for the popup top.
        int x = anchor.x + anchor.width / 2 - width / 2;
        int y = anchor.y;
        if (y + height > bounds().height - _margin) y = anchor.y - height - _gap;
        x = clampInt(x, _margin, maxInt(_margin, bounds().width - width - _margin));
        y = clampInt(y, _margin, maxInt(_margin, bounds().height - height - _margin));
        _panelRect = Rect(x, y, width, height);

        const innerX = _panelRect.x + _padding;
        const innerWidth = maxInt(1, _panelRect.width - _padding * 2);
        _queryRect = Rect(innerX, _panelRect.y + _padding, innerWidth, _queryHeight);
        _listRect = Rect(innerX, _queryRect.bottom() + _listGap, innerWidth,
            maxInt(0, _panelRect.bottom() - _padding - _queryRect.bottom() - _listGap));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_panelRect.empty()) return;
        const palette = theme();
        canvas.fillRoundedRect(_panelRect.translated(4, 5), 10,
            palette.shadow.withAlpha(150));
        canvas.drawRoundedRect(_panelRect, 9, palette.panelElevated,
            palette.border.withAlpha(230), 1);

        // Query field.
        canvas.drawRoundedRect(_queryRect, 8, palette.fieldBackground,
            focused() ? palette.accent : palette.border, focused() ? 2 : 1);
        drawIcon(canvas, IconKind.search,
            Rect(_queryRect.x + 10, _queryRect.y + (_queryRect.height - 20) / 2,
                20, 20),
            palette.textMuted, palette.accent);
        const placeholder = _query.length == 0 ? "Search apps, files, settings"d : _query;
        canvas.drawTextInRect(Rect(_queryRect.x + 42, _queryRect.y,
                maxInt(0, _queryRect.width - 54), _queryRect.height), placeholder,
            _query.length == 0 ? palette.textMuted : palette.text,
            1, HorizontalAlign.left, VerticalAlign.middle, true);

        const count = resultCountInternal();
        if (count == 0)
        {
            canvas.drawTextInRect(_listRect, "No results"d, palette.textMuted,
                1, HorizontalAlign.center, VerticalAlign.middle, true);
            return;
        }

        auto clipped = canvas.clipped(_listRect);
        foreach (visibleOrder; 0 .. count)
        {
            const entryIndex = entryIndexAt(visibleOrder);
            if (entryIndex < 0) break;
            const entry = _entries[cast(size_t) entryIndex];
            const row = Rect(_listRect.x,
                _listRect.y + visibleOrder * _rowHeight,
                _listRect.width, _rowHeight);
            const active = entryIndex == _hot;
            if (active || entryIndex == _pressed)
            {
                const background = entryIndex == _pressed ?
                    palette.buttonPressed : palette.buttonHover;
                clipped.fillRoundedRect(row.inset(2), 7, background);
            }
            const iconRect = Rect(row.x + 12, row.y + (row.height - 28) / 2, 28, 28);
            drawIcon(clipped, entry.icon, iconRect, palette.text, palette.accent);
            if (entry.description.length == 0)
            {
                clipped.drawTextInRect(Rect(row.x + 52, row.y,
                        maxInt(0, row.width - 64), row.height), entry.label,
                    palette.text, 2, HorizontalAlign.left, VerticalAlign.middle, true);
            }
            else
            {
                clipped.drawTextInRect(Rect(row.x + 52, row.y + 4,
                        maxInt(0, row.width - 64), 29), entry.label,
                    palette.text, 2, HorizontalAlign.left, VerticalAlign.middle, true);
                clipped.drawTextInRect(Rect(row.x + 52, row.y + 29,
                        maxInt(0, row.width - 64), 21), entry.description,
                    palette.textMuted, 1, HorizontalAlign.left, VerticalAlign.middle, true);
            }
        }
    }

    override bool onMouseMove(ref Event event)
    {
        if (_pressed >= 0) return true;
        setHot(entryAt(event.position));
        return true;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left && event.button != MouseButton.right)
            return true;
        if (!_panelRect.contains(event.position))
        {
            dismiss();
            return true;
        }
        requestFocus();
        if (event.button == MouseButton.right) return true;
        const entryIndex = entryAt(event.position);
        if (entryIndex >= 0)
        {
            _pressed = entryIndex;
            setHot(entryIndex);
            captureMouse();
            invalidate();
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return true;
        const pressed = _pressed;
        if (pressed >= 0)
        {
            _pressed = -1;
            releaseMouse();
            const released = entryAt(event.position);
            if (pressed == released) activate(pressed);
            else invalidate();
        }
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        switch (event.key)
        {
            case Key.escape:
                dismiss();
                return true;
            case Key.up:
                moveSelection(-1);
                return true;
            case Key.down:
                moveSelection(1);
                return true;
            case Key.enter:
            case Key.space:
                activate(_hot);
                return true;
            case Key.backspace:
                if (_query.length != 0)
                {
                    _query.length = previousGraphemeBoundary(_query, _query.length);
                    queryChanged();
                }
                return true;
            case Key.deleteKey:
                if (_query.length != 0)
                {
                    _query.length = 0;
                    queryChanged();
                }
                return true;
            default:
                return true;
        }
    }

    override bool onTextInput(ref Event event)
    {
        bool changed;
        foreach (character; event.text)
        {
            if (character < 0x20 || character == 0x7f) continue;
            _query ~= character;
            changed = true;
        }
        if (changed) queryChanged();
        return true;
    }

    private void queryChanged()
    {
        recalculateLayout();
        _hot = firstSelectable();
        invalidate();
    }
}
