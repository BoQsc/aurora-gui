module aurora.widgets.startmenu;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.icons : IconKind, drawIcon;
import aurora.text.unicode.grapheme : previousGraphemeBoundary;
import aurora.types : CursorKind, HorizontalAlign, Point, Rect, Size,
    VerticalAlign, clampInt, maxInt, minInt;
import aurora.widget : Widget;
import aurora.widgets.popup : TransientPopup, dismissTransientPopups, popupRoot;
import std.utf : toUTF32;

/** Semantic group used by the Start-menu interaction and test APIs. */
enum StartMenuEntryKind : ubyte
{
    none,
    application,
    systemCommand
}

/** One launchable application or fixed system command in an Aurora Start menu. */
struct StartMenuEntry
{
    dstring label;
    dstring description;
    IconKind icon = IconKind.none;
    bool enabled = true;
    bool danger;
    void delegate() action;

    static StartMenuEntry application(string label, IconKind icon,
        void delegate() action, string description = "")
    {
        StartMenuEntry result;
        result.label = toUTF32(label);
        result.description = toUTF32(description);
        result.icon = icon;
        result.action = action;
        return result;
    }

    static StartMenuEntry command(string label, IconKind icon,
        void delegate() action, bool danger = false, string description = "")
    {
        auto result = application(label, icon, action, description);
        result.danger = danger;
        return result;
    }
}

private struct StartMenuSelection
{
    StartMenuEntryKind kind;
    int index = -1;

    bool valid() const @safe pure nothrow @nogc
    {
        return kind != StartMenuEntryKind.none && index >= 0;
    }
}

/**
 * Aurora-rendered, click-away Start menu with measured panel placement, fixed
 * footer commands, searchable applications, keyboard traversal, and a
 * scrollable application viewport. The footer is never placed in the scrolling
 * region, so power/session actions cannot be partially clipped by a short host.
 */
class StartMenu : TransientPopup
{
    private StartMenuEntry[] _applications;
    private StartMenuEntry[] _systemCommands;
    private Rect _anchorGlobal;
    private Rect _panelRect;
    private Rect _headerRect;
    private Rect _searchRect;
    private Rect _sectionRect;
    private Rect _applicationViewport;
    private Rect _footerSeparator;
    private Rect _footerRect;
    private dstring _query;
    private StartMenuSelection _hot;
    private StartMenuSelection _pressed;
    private int _scrollY;
    private int _applicationContentHeight;
    private int _panelWidth = 390;
    private int _maximumPanelHeight = 610;
    private int _margin = 8;
    private int _gap = 6;
    private int _rowHeight = 54;
    private int _systemRowHeight = 48;
    private int _headerHeight = 68;
    private int _searchHeight = 42;
    private int _sectionHeight = 28;
    private int _padding = 12;
    private bool _opening;

    void delegate(bool open) onOpenChanged;

    this(Widget focusReturn = null)
    {
        super(focusReturn);
        setCursor(CursorKind.arrow);
    }

    const(StartMenuEntry)[] applications() const @safe pure nothrow @nogc
    {
        return _applications;
    }

    const(StartMenuEntry)[] systemCommands() const @safe pure nothrow @nogc
    {
        return _systemCommands;
    }

    Rect panelRect() const @safe pure nothrow @nogc { return _panelRect; }
    Rect headerRect() const @safe pure nothrow @nogc { return _headerRect; }
    Rect searchRect() const @safe pure nothrow @nogc { return _searchRect; }
    Rect applicationViewportRect() const @safe pure nothrow @nogc
    {
        return _applicationViewport;
    }
    Rect footerRect() const @safe pure nothrow @nogc { return _footerRect; }
    dstring query() const @safe pure nothrow @nogc { return _query; }
    int scrollY() const @safe pure nothrow @nogc { return _scrollY; }
    int maxScroll() const @safe pure nothrow @nogc
    {
        return maxInt(0, _applicationContentHeight - _applicationViewport.height);
    }
    bool open()
    {
        return parent() !is null && !dismissed();
    }

    void setPanelWidth(int value)
    {
        _panelWidth = maxInt(280, value);
        recalculateLayout();
        invalidate();
    }

    void setMaximumPanelHeight(int value)
    {
        _maximumPanelHeight = maxInt(300, value);
        recalculateLayout();
        invalidate();
    }

    void addApplication(string label, IconKind icon, void delegate() action,
        string description = "")
    {
        _applications ~= StartMenuEntry.application(label, icon, action, description);
        contentChanged();
    }

    void addApplication(StartMenuEntry entry)
    {
        _applications ~= entry;
        contentChanged();
    }

    void addSystemCommand(string label, IconKind icon, void delegate() action,
        bool danger = false, string description = "")
    {
        _systemCommands ~= StartMenuEntry.command(label, icon, action,
            danger, description);
        contentChanged();
    }

    void addSystemCommand(StartMenuEntry entry)
    {
        _systemCommands ~= entry;
        contentChanged();
    }

    void clearApplications()
    {
        _applications.length = 0;
        contentChanged();
    }

    void clearSystemCommands()
    {
        _systemCommands.length = 0;
        contentChanged();
    }

    /** Attach this reusable instance as the root's topmost transient surface. */
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
        _scrollY = 0;
        _pressed = StartMenuSelection.init;
        root.add(this);
        setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
        root.bringChildToFront(this);
        recalculateLayout();
        _hot = firstSelectable();
        requestFocus();
        _opening = false;
        invalidate();
        if (onOpenChanged !is null) onOpenChanged(true);
        return true;
    }

    void toggle(Widget owner, Rect globalAnchor)
    {
        if (open()) dismiss();
        else show(owner, globalAnchor);
    }

    override void dismiss()
    {
        if (dismissed() || _opening) return;
        if (_pressed.valid())
        {
            _pressed = StartMenuSelection.init;
            releaseMouse();
        }
        const wasOpen = parent() !is null;
        super.dismiss();
        if (wasOpen && onOpenChanged !is null) onOpenChanged(false);
    }

    override bool popupContains(Point globalPoint) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return _panelRect.contains(Point(globalPoint.x - origin.x,
            globalPoint.y - origin.y));
    }

    override bool dismissPopupForPointer(Point globalPoint, MouseButton button)
    {
        // The Start anchor is a toggle. Consume its closing press so the same
        // event cannot close and immediately reopen this menu.
        const consume = _anchorGlobal.contains(globalPoint);
        dismiss();
        return consume;
    }

    /** Rect for a specific entry. Empty means filtered or outside the viewport. */
    Rect entryRect(StartMenuEntryKind kind, size_t index) const
        @safe pure nothrow @nogc
    {
        if (kind == StartMenuEntryKind.application)
        {
            int order;
            foreach (applicationIndex, entry; _applications)
            {
                if (!matchesQuery(entry)) continue;
                if (applicationIndex == index)
                {
                    const row = Rect(_applicationViewport.x,
                        _applicationViewport.y + order * _rowHeight - _scrollY,
                        _applicationViewport.width, _rowHeight);
                    return row.intersection(_applicationViewport);
                }
                ++order;
            }
            return Rect.init;
        }
        if (kind == StartMenuEntryKind.systemCommand && index < _systemCommands.length)
            return Rect(_footerRect.x,
                _footerRect.y + cast(int) index * _systemRowHeight,
                _footerRect.width, _systemRowHeight);
        return Rect.init;
    }

    /** Structural contract used by shell tests and release validation. */
    bool layoutValid() const @safe pure nothrow @nogc
    {
        if (_panelRect.empty() || bounds().width <= 0 || bounds().height <= 0)
            return false;
        const rootRect = Rect(0, 0, bounds().width, bounds().height);
        if (_panelRect.intersection(rootRect) != _panelRect) return false;
        foreach (rect; [_headerRect, _searchRect, _sectionRect,
                _applicationViewport, _footerSeparator, _footerRect])
        {
            if (rect.empty()) continue;
            if (rect.intersection(_panelRect) != rect) return false;
        }
        if (!_applicationViewport.empty() && !_footerRect.empty() &&
            _applicationViewport.bottom() > _footerSeparator.y)
            return false;
        foreach (index, entry; _systemCommands)
        {
            const rect = entryRect(StartMenuEntryKind.systemCommand, index);
            if (rect.height < 32 || rect.intersection(_panelRect) != rect)
                return false;
        }
        return true;
    }

    protected override void onBoundsChanged()
    {
        recalculateLayout();
    }

    private void contentChanged()
    {
        _scrollY = clampInt(_scrollY, 0, maxScroll());
        recalculateLayout();
        if (!_hot.valid()) _hot = firstSelectable();
        invalidate();
    }

    private int filteredApplicationCount() const @safe pure nothrow @nogc
    {
        int count;
        foreach (entry; _applications)
            if (matchesQuery(entry)) ++count;
        return count;
    }

    private bool matchesQuery(const ref StartMenuEntry entry) const
        @safe pure nothrow @nogc
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

    private int fixedHeight() const @safe pure nothrow @nogc
    {
        const footerHeight = cast(int) _systemCommands.length * _systemRowHeight;
        return _padding + _headerHeight + 8 + _searchHeight + 8 +
            _sectionHeight + 8 + 1 + 8 + footerHeight + _padding;
    }

    private void recalculateLayout()
    {
        if (bounds().width <= 0 || bounds().height <= 0)
        {
            _panelRect = Rect.init;
            _headerRect = Rect.init;
            _searchRect = Rect.init;
            _sectionRect = Rect.init;
            _applicationViewport = Rect.init;
            _footerSeparator = Rect.init;
            _footerRect = Rect.init;
            return;
        }

        const availableWidth = maxInt(1, bounds().width - _margin * 2);
        const availableHeight = maxInt(1, bounds().height - _margin * 2);
        const width = minInt(_panelWidth, availableWidth);
        const applicationRows = maxInt(1, minInt(6, filteredApplicationCount()));
        const desiredHeight = fixedHeight() + applicationRows * _rowHeight;
        const minimumHeight = minInt(availableHeight, maxInt(300, fixedHeight() + 48));
        const height = clampInt(minInt(_maximumPanelHeight, desiredHeight),
            minInt(minimumHeight, availableHeight), availableHeight);

        const rootOrigin = globalOrigin();
        const anchor = Rect(_anchorGlobal.x - rootOrigin.x,
            _anchorGlobal.y - rootOrigin.y, _anchorGlobal.width, _anchorGlobal.height);
        int x = anchor.x;
        int y = anchor.y - height - _gap;
        if (y < _margin) y = anchor.bottom() + _gap;
        x = clampInt(x, _margin, maxInt(_margin, bounds().width - width - _margin));
        y = clampInt(y, _margin, maxInt(_margin, bounds().height - height - _margin));
        _panelRect = Rect(x, y, width, height);

        const innerX = _panelRect.x + _padding;
        const innerWidth = maxInt(1, _panelRect.width - _padding * 2);
        int cursorY = _panelRect.y + _padding;
        _headerRect = Rect(innerX, cursorY, innerWidth, _headerHeight);
        cursorY = _headerRect.bottom() + 8;
        _searchRect = Rect(innerX, cursorY, innerWidth, _searchHeight);
        cursorY = _searchRect.bottom() + 8;
        _sectionRect = Rect(innerX, cursorY, innerWidth, _sectionHeight);
        cursorY = _sectionRect.bottom() + 4;

        const footerHeight = cast(int) _systemCommands.length * _systemRowHeight;
        const footerBottom = _panelRect.bottom() - _padding;
        _footerRect = Rect(innerX, footerBottom - footerHeight,
            innerWidth, footerHeight);
        _footerSeparator = Rect(innerX, maxInt(cursorY, _footerRect.y - 9),
            innerWidth, 1);
        const viewportBottom = maxInt(cursorY, _footerSeparator.y - 8);
        _applicationViewport = Rect(innerX, cursorY, innerWidth,
            maxInt(0, viewportBottom - cursorY));
        _applicationContentHeight = filteredApplicationCount() * _rowHeight;
        _scrollY = clampInt(_scrollY, 0, maxScroll());
        ensureSelectionVisible();
    }

    private StartMenuSelection itemAt(Point point) const
    {
        if (!_panelRect.contains(point)) return StartMenuSelection.init;
        if (_applicationViewport.contains(point))
        {
            int visibleOrder;
            foreach (index, entry; _applications)
            {
                if (!matchesQuery(entry)) continue;
                const row = Rect(_applicationViewport.x,
                    _applicationViewport.y + visibleOrder * _rowHeight - _scrollY,
                    _applicationViewport.width, _rowHeight);
                if (row.contains(point))
                    return StartMenuSelection(StartMenuEntryKind.application,
                        cast(int) index);
                ++visibleOrder;
            }
        }
        if (_footerRect.contains(point))
        {
            const index = (point.y - _footerRect.y) / _systemRowHeight;
            if (index >= 0 && index < cast(int) _systemCommands.length)
                return StartMenuSelection(StartMenuEntryKind.systemCommand, index);
        }
        return StartMenuSelection.init;
    }

    private bool selectable(StartMenuSelection selection) const
        @safe pure nothrow @nogc
    {
        if (!selection.valid()) return false;
        final switch (selection.kind)
        {
            case StartMenuEntryKind.application:
                return selection.index < cast(int) _applications.length &&
                    matchesQuery(_applications[cast(size_t) selection.index]) &&
                    _applications[cast(size_t) selection.index].enabled;
            case StartMenuEntryKind.systemCommand:
                return selection.index < cast(int) _systemCommands.length &&
                    _systemCommands[cast(size_t) selection.index].enabled;
            case StartMenuEntryKind.none:
                return false;
        }
    }

    private StartMenuSelection[] selectableEntries() const
    {
        StartMenuSelection[] result;
        foreach (index, entry; _applications)
            if (matchesQuery(entry) && entry.enabled)
                result ~= StartMenuSelection(StartMenuEntryKind.application,
                    cast(int) index);
        foreach (index, entry; _systemCommands)
            if (entry.enabled)
                result ~= StartMenuSelection(StartMenuEntryKind.systemCommand,
                    cast(int) index);
        return result;
    }

    private StartMenuSelection firstSelectable() const
    {
        const entries = selectableEntries();
        return entries.length == 0 ? StartMenuSelection.init : entries[0];
    }

    private StartMenuSelection lastSelectable() const
    {
        const entries = selectableEntries();
        return entries.length == 0 ? StartMenuSelection.init : entries[$ - 1];
    }

    private void moveSelection(int direction)
    {
        const entries = selectableEntries();
        if (entries.length == 0)
        {
            setHot(StartMenuSelection.init);
            return;
        }
        int current = -1;
        foreach (index, selection; entries)
            if (selection == _hot) current = cast(int) index;
        int next;
        if (direction < 0)
            next = current <= 0 ? cast(int) entries.length - 1 : current - 1;
        else
            next = current < 0 || current + 1 >= cast(int) entries.length ? 0 : current + 1;
        setHot(entries[cast(size_t) next]);
    }

    private void setHot(StartMenuSelection selection)
    {
        if (_hot == selection) return;
        _hot = selection;
        ensureSelectionVisible();
        invalidate();
    }

    private void ensureSelectionVisible()
    {
        if (_hot.kind != StartMenuEntryKind.application || _applicationViewport.empty())
            return;
        int visibleOrder = -1;
        int candidate;
        foreach (index, entry; _applications)
        {
            if (!matchesQuery(entry)) continue;
            if (cast(int) index == _hot.index)
            {
                visibleOrder = candidate;
                break;
            }
            ++candidate;
        }
        if (visibleOrder < 0) return;
        const top = visibleOrder * _rowHeight;
        const bottom = top + _rowHeight;
        if (top < _scrollY) _scrollY = top;
        else if (bottom > _scrollY + _applicationViewport.height)
            _scrollY = bottom - _applicationViewport.height;
        _scrollY = clampInt(_scrollY, 0, maxScroll());
    }

    private void activate(StartMenuSelection selection)
    {
        if (!selectable(selection)) return;
        void delegate() action;
        final switch (selection.kind)
        {
            case StartMenuEntryKind.application:
                action = _applications[cast(size_t) selection.index].action;
                break;
            case StartMenuEntryKind.systemCommand:
                action = _systemCommands[cast(size_t) selection.index].action;
                break;
            case StartMenuEntryKind.none:
                break;
        }
        dismiss();
        if (action !is null) action();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_panelRect.empty()) return;
        const palette = theme();
        canvas.fillRoundedRect(_panelRect.translated(4, 5), 10,
            palette.shadow.withAlpha(145));
        canvas.drawRoundedRect(_panelRect, 9, palette.panelElevated,
            palette.border.withAlpha(230), 1);

        // Header / identity area.
        canvas.fillRoundedRect(_headerRect, 7, palette.panelBackground);
        const brandIcon = Rect(_headerRect.x + 10,
            _headerRect.y + (_headerRect.height - 34) / 2, 34, 34);
        canvas.fillRoundedRect(brandIcon, 7, palette.accent);
        drawIcon(canvas, IconKind.start, brandIcon.inset(8), Color.rgb(255, 255, 255),
            palette.accent);
        canvas.drawTextInRect(Rect(brandIcon.right() + 12, _headerRect.y + 4,
                maxInt(0, _headerRect.width - 66), 34), "Aurora"d,
            palette.text, 3, HorizontalAlign.left, VerticalAlign.middle, true);
        canvas.drawTextInRect(Rect(brandIcon.right() + 12, _headerRect.y + 35,
                maxInt(0, _headerRect.width - 66), 24), "Local desktop session"d,
            palette.textMuted, 1, HorizontalAlign.left, VerticalAlign.middle, true);

        // Search box. Keyboard text input is routed to the popup itself.
        canvas.drawRoundedRect(_searchRect, 7, palette.fieldBackground,
            focused() ? palette.accent : palette.border, focused() ? 2 : 1);
        drawIcon(canvas, IconKind.search,
            Rect(_searchRect.x + 10, _searchRect.y + 10, 22, 22),
            palette.textMuted, palette.accent);
        const searchText = _query.length == 0 ? "Search apps"d : _query;
        canvas.drawTextInRect(Rect(_searchRect.x + 40, _searchRect.y,
                maxInt(0, _searchRect.width - 50), _searchRect.height), searchText,
            _query.length == 0 ? palette.textMuted : palette.text,
            1, HorizontalAlign.left, VerticalAlign.middle, true);

        canvas.drawTextInRect(_sectionRect,
            _query.length == 0 ? "Pinned"d : "Search results"d,
            palette.textMuted, 1, HorizontalAlign.left, VerticalAlign.middle, true);

        auto clipped = canvas.clipped(_applicationViewport);
        int visibleOrder;
        foreach (index, entry; _applications)
        {
            if (!matchesQuery(entry)) continue;
            const selection = StartMenuSelection(StartMenuEntryKind.application,
                cast(int) index);
            const row = Rect(_applicationViewport.x,
                _applicationViewport.y + visibleOrder * _rowHeight - _scrollY,
                _applicationViewport.width, _rowHeight);
            if (!row.intersection(_applicationViewport).empty())
                drawEntry(clipped, row, entry, selection);
            ++visibleOrder;
        }
        if (visibleOrder == 0)
            clipped.drawTextInRect(_applicationViewport, "No matching applications"d,
                palette.textMuted, 1, HorizontalAlign.center, VerticalAlign.middle, true);

        if (maxScroll() > 0)
        {
            const track = Rect(_applicationViewport.right() - 5,
                _applicationViewport.y + 3, 4,
                maxInt(1, _applicationViewport.height - 6));
            const thumbHeight = clampInt(track.height * _applicationViewport.height /
                maxInt(1, _applicationContentHeight), 24, track.height);
            const travel = maxInt(0, track.height - thumbHeight);
            const thumbY = track.y + (maxScroll() == 0 ? 0 :
                travel * _scrollY / maxScroll());
            canvas.fillRoundedRect(track, 2, palette.border.withAlpha(75));
            canvas.fillRoundedRect(Rect(track.x, thumbY, track.width, thumbHeight),
                2, palette.textMuted.withAlpha(175));
        }

        canvas.fillRect(_footerSeparator, palette.border.withAlpha(180));
        foreach (index, entry; _systemCommands)
        {
            const selection = StartMenuSelection(StartMenuEntryKind.systemCommand,
                cast(int) index);
            const row = entryRect(StartMenuEntryKind.systemCommand, index);
            drawEntry(canvas, row, entry, selection);
        }
    }

    private void drawEntry(ref Canvas canvas, Rect row, const ref StartMenuEntry entry,
        StartMenuSelection selection)
    {
        const palette = theme();
        const active = selection == _hot;
        const pressed = selection == _pressed;
        if (active || pressed)
        {
            Color background = pressed ? palette.buttonPressed : palette.buttonHover;
            if (entry.danger) background = palette.danger.withAlpha(pressed ? 205 : 165);
            canvas.fillRoundedRect(row.inset(2), 7, background);
        }
        const foreground = !entry.enabled ? palette.disabled :
            entry.danger && (active || pressed) ? Color.rgb(255, 255, 255) : palette.text;
        const iconRect = Rect(row.x + 11, row.y + (row.height - 28) / 2, 28, 28);
        drawIcon(canvas, entry.icon, iconRect, foreground,
            entry.danger ? palette.danger : palette.accent);
        if (entry.description.length == 0)
        {
            canvas.drawTextInRect(Rect(row.x + 51, row.y,
                    maxInt(0, row.width - 63), row.height), entry.label,
                foreground, 2, HorizontalAlign.left, VerticalAlign.middle, true);
        }
        else
        {
            canvas.drawTextInRect(Rect(row.x + 51, row.y + 4,
                    maxInt(0, row.width - 63), 29), entry.label,
                foreground, 2, HorizontalAlign.left, VerticalAlign.middle, true);
            canvas.drawTextInRect(Rect(row.x + 51, row.y + 29,
                    maxInt(0, row.width - 63), 21), entry.description,
                entry.enabled ? palette.textMuted : palette.disabled,
                1, HorizontalAlign.left, VerticalAlign.middle, true);
        }
    }

    override bool onMouseMove(ref Event event)
    {
        if (_pressed.valid()) return true;
        const selection = itemAt(event.position);
        setHot(selectable(selection) ? selection : StartMenuSelection.init);
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
        const selection = itemAt(event.position);
        if (selectable(selection))
        {
            _pressed = selection;
            setHot(selection);
            captureMouse();
            invalidate();
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return true;
        const pressed = _pressed;
        if (_pressed.valid())
        {
            _pressed = StartMenuSelection.init;
            releaseMouse();
            const released = itemAt(event.position);
            if (pressed == released) activate(pressed);
            else invalidate();
        }
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (event.wheelY == 0 || maxScroll() == 0) return true;
        _scrollY = clampInt(_scrollY - event.wheelY * _rowHeight,
            0, maxScroll());
        invalidate();
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
            case Key.home:
                setHot(firstSelectable());
                return true;
            case Key.end:
                setHot(lastSelectable());
                return true;
            case Key.pageUp:
                _scrollY = clampInt(_scrollY - maxInt(_rowHeight,
                    _applicationViewport.height - _rowHeight), 0, maxScroll());
                invalidate();
                return true;
            case Key.pageDown:
                _scrollY = clampInt(_scrollY + maxInt(_rowHeight,
                    _applicationViewport.height - _rowHeight), 0, maxScroll());
                invalidate();
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
        _scrollY = 0;
        recalculateLayout();
        _hot = firstSelectable();
        invalidate();
    }
}

unittest
{
    final class StartRoot : Widget {}
    auto root = new StartRoot();
    root.setBounds(Rect(0, 0, 640, 480));
    auto taskbarButton = root.add(new StartRoot());
    taskbarButton.setFocusable(true);
    taskbarButton.setBounds(Rect(6, 430, 42, 42));
    auto menu = new StartMenu(taskbarButton);
    foreach (index; 0 .. 12)
        menu.addApplication("Application", IconKind.file, delegate() {}, "Pinned app");
    menu.addSystemCommand("Full screen", IconKind.maximize, delegate() {});
    menu.addSystemCommand("Shut down", IconKind.close, delegate() {}, true);
    assert(menu.show(taskbarButton, Rect(6, 430, 42, 42)));
    assert(menu.layoutValid());
    assert(menu.panelRect().bottom() <= 472);
    assert(menu.footerRect().bottom() <= menu.panelRect().bottom() - 12);
    assert(menu.maxScroll() > 0);
    const anchorConsumed = menu.dismissPopupForPointer(Point(20, 450),
        MouseButton.left);
    assert(anchorConsumed && menu.dismissed());
}
