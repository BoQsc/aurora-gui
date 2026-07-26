module aurora.widgets.contextmenu;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.icons : IconKind, drawIcon;
import aurora.types : CursorKind, HorizontalAlign, Point, Rect, VerticalAlign,
    clampInt, maxInt, minInt;
import aurora.widget : Widget;
import aurora.widgets.popup : TransientPopup, dismissTransientPopups, popupRoot;
import std.utf : toUTF32;

/** One command, check item, or separator in an Aurora-rendered context menu. */
struct ContextMenuItem
{
    dstring label;
    dstring shortcut;
    IconKind icon = IconKind.none;
    bool separator;
    bool enabled = true;
    bool checked;
    void delegate() action;

    static ContextMenuItem command(string label, IconKind icon,
        void delegate() action, string shortcut = "", bool enabled = true)
    {
        ContextMenuItem result;
        result.label = toUTF32(label);
        result.shortcut = toUTF32(shortcut);
        result.icon = icon;
        result.enabled = enabled;
        result.action = action;
        return result;
    }

    static ContextMenuItem command(string label, void delegate() action,
        string shortcut = "", bool enabled = true)
    {
        return command(label, IconKind.none, action, shortcut, enabled);
    }

    static ContextMenuItem check(string label, bool checked,
        void delegate() action, bool enabled = true)
    {
        auto result = command(label, IconKind.none, action, "", enabled);
        result.checked = checked;
        return result;
    }

    static ContextMenuItem separatorItem()
    {
        ContextMenuItem result;
        result.separator = true;
        result.enabled = false;
        return result;
    }
}

/**
 * Full-window transparent popup layer. It owns dismissal, keyboard traversal,
 * and the rendered menu, so context menus never depend on a host-OS popup.
 */
class ContextMenu : TransientPopup
{
    private ContextMenuItem[] _items;
    private Point _requestedOrigin;
    private Rect _requestedAnchor;
    private bool _hasRequestedAnchor;
    private Rect _menuRect;
    private int _hot = -1;
    private int _pressed = -1;
    // Compact editor menus: roughly one third of the former surface area while
    // retaining readable labels and full keyboard/mouse hit targets.
    private int _rowHeight = 22;
    private int _separatorHeight = 4;
    private int _padding = 3;
    private int _scrollOffset;
    this(ContextMenuItem[] items, Widget focusReturn = null)
    {
        super(focusReturn);
        _items = items.dup;
        setCursor(CursorKind.arrow);
    }

    const(ContextMenuItem)[] items() const @safe pure nothrow @nogc
    {
        return _items;
    }

    Rect menuRect() const @safe pure nothrow @nogc
    {
        return _menuRect;
    }

    int rowHeightForTesting() const @safe pure nothrow @nogc
    {
        return _rowHeight;
    }

    override bool popupContains(Point globalPoint) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        return _menuRect.contains(Point(globalPoint.x - origin.x,
            globalPoint.y - origin.y));
    }

    void openAt(Point localPosition)
    {
        _requestedOrigin = localPosition;
        _requestedAnchor = Rect.init;
        _hasRequestedAnchor = false;
        _scrollOffset = 0;
        recalculateMenuRect();
        _hot = firstSelectable();
        revealHot();
        requestFocus();
        invalidate();
    }

    void openBelow(Rect localAnchor)
    {
        _requestedAnchor = localAnchor;
        _hasRequestedAnchor = true;
        _requestedOrigin = Point(localAnchor.x, localAnchor.bottom());
        _scrollOffset = 0;
        recalculateMenuRect();
        _hot = firstSelectable();
        revealHot();
        requestFocus();
        invalidate();
    }

    override void dismiss()
    {
        if (dismissed()) return;
        if (_pressed >= 0)
        {
            _pressed = -1;
            releaseMouse();
        }
        super.dismiss();
    }

    protected override void onBoundsChanged()
    {
        recalculateMenuRect();
    }

    private int preferredMenuWidth() const @safe pure nothrow @nogc
    {
        int width = 148;
        foreach (item; _items)
        {
            if (item.separator) continue;
            const estimatedLabel = cast(int) item.label.length * 7;
            const estimatedShortcut = cast(int) item.shortcut.length * 7;
            width = maxInt(width, 48 + estimatedLabel + estimatedShortcut);
        }
        return clampInt(width, 148, 280);
    }

    private int preferredMenuHeight() const @safe pure nothrow @nogc
    {
        int height = _padding * 2;
        foreach (item; _items)
            height += item.separator ? _separatorHeight : _rowHeight;
        return maxInt(1, height);
    }

    private int maximumScroll() const @safe pure nothrow @nogc
    {
        return maxInt(0, preferredMenuHeight() - _menuRect.height);
    }

    private void clampScroll()
    {
        _scrollOffset = clampInt(_scrollOffset, 0, maximumScroll());
    }

    private void recalculateMenuRect()
    {
        if (bounds().width <= 0 || bounds().height <= 0)
        {
            _menuRect = Rect.init;
            return;
        }

        const preferredWidth = preferredMenuWidth();
        int x;
        int width;
        if (_hasRequestedAnchor)
        {
            width = minInt(preferredWidth, maxInt(80, bounds().width - 8));
            x = _requestedAnchor.x;
            if (x + width > bounds().width - 4)
                x = _requestedAnchor.right() - width;
            x = clampInt(x, 4, maxInt(4, bounds().width - width - 4));
        }
        else
        {
            x = clampInt(_requestedOrigin.x + 2, 4, maxInt(4, bounds().width - 84));

            int availableWidth = maxInt(80, bounds().width - x - 4);
            width = minInt(preferredWidth, availableWidth);
            if (width < 180 && bounds().width >= 188)
            {
                width = minInt(preferredWidth, bounds().width - 8);
                x = bounds().width - width - 4;
            }
        }

        const preferredHeight = preferredMenuHeight();
        const minimumHeight = 40;
        const belowY = _hasRequestedAnchor ? _requestedAnchor.bottom() + 2 :
            _requestedOrigin.y + 2;
        const belowSpace = maxInt(0, bounds().height - 4 - belowY);
        const aboveBottom = _hasRequestedAnchor ? _requestedAnchor.y - 2 :
            _requestedOrigin.y - 2;
        const aboveSpace = maxInt(0, aboveBottom - 4);
        const openAbove = preferredHeight > belowSpace &&
            aboveSpace >= minimumHeight && aboveSpace >= belowSpace;

        int height;
        int y;
        if (openAbove)
        {
            height = minInt(preferredHeight, aboveSpace);
            y = aboveBottom - height;
        }
        else
        {
            height = minInt(preferredHeight, maxInt(minimumHeight, belowSpace));
            y = belowY;
        }
        height = minInt(height, maxInt(minimumHeight, bounds().height - 8));
        y = clampInt(y, 4, maxInt(4, bounds().height - height - 4));
        _menuRect = Rect(x, y, width, height);
        clampScroll();
    }

    private Rect itemRect(int requestedIndex) const @safe pure nothrow @nogc
    {
        int y = _menuRect.y + _padding - _scrollOffset;
        foreach (index, item; _items)
        {
            const height = item.separator ? _separatorHeight : _rowHeight;
            if (cast(int) index == requestedIndex)
                return Rect(_menuRect.x + _padding, y,
                    maxInt(0, _menuRect.width - _padding * 2), height);
            y += height;
        }
        return Rect.init;
    }

    private void revealHot()
    {
        if (_hot < 0 || _menuRect.empty()) return;
        const rect = itemRect(_hot);
        const top = _menuRect.y + _padding;
        const bottom = _menuRect.bottom() - _padding;
        if (rect.y < top) _scrollOffset -= top - rect.y;
        else if (rect.bottom() > bottom) _scrollOffset += rect.bottom() - bottom;
        clampScroll();
    }

    private int itemAt(Point point) const @safe pure nothrow @nogc
    {
        if (!_menuRect.contains(point)) return -1;
        foreach (index, item; _items)
        {
            if (!item.separator && itemRect(cast(int) index).contains(point))
                return cast(int) index;
        }
        return -1;
    }

    private bool selectable(int index) const @safe pure nothrow @nogc
    {
        return index >= 0 && index < cast(int) _items.length &&
            !_items[cast(size_t) index].separator &&
            _items[cast(size_t) index].enabled;
    }

    private int firstSelectable() const @safe pure nothrow @nogc
    {
        foreach (index, item; _items)
            if (!item.separator && item.enabled) return cast(int) index;
        return -1;
    }

    private int lastSelectable() const @safe pure nothrow @nogc
    {
        for (size_t index = _items.length; index > 0; --index)
        {
            const item = _items[index - 1];
            if (!item.separator && item.enabled) return cast(int) index - 1;
        }
        return -1;
    }

    private int nextSelectable(int start, int direction) const @safe pure nothrow @nogc
    {
        if (_items.length == 0) return -1;
        int index = start;
        foreach (_; 0 .. _items.length)
        {
            index += direction;
            if (index < 0) index = cast(int) _items.length - 1;
            if (index >= cast(int) _items.length) index = 0;
            if (selectable(index)) return index;
        }
        return -1;
    }

    private void setHot(int value)
    {
        if (_hot == value) return;
        _hot = value;
        revealHot();
        invalidate();
    }

    private void activate(int index)
    {
        if (!selectable(index)) return;
        auto action = _items[cast(size_t) index].action;
        dismiss();
        if (action !is null) action();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        if (_menuRect.empty()) return;
        const palette = theme();
        const shadow = _menuRect.translated(3, 4);
        canvas.fillRoundedRect(shadow, 5, palette.shadow.withAlpha(100));
        canvas.drawRoundedRect(_menuRect, 4, palette.panelElevated,
            palette.border.withAlpha(230), 1);

        auto content = canvas.clipped(_menuRect.inset(1));
        foreach (index, item; _items)
        {
            const rect = itemRect(cast(int) index);
            if (rect.bottom() <= _menuRect.y + 1 || rect.y >= _menuRect.bottom() - 1)
                continue;
            if (item.separator)
            {
                const y = rect.y + rect.height / 2;
                content.fillRect(Rect(rect.x + 8, y, maxInt(0, rect.width - 16), 1),
                    palette.border.withAlpha(180));
                continue;
            }

            const active = cast(int) index == _hot;
            if (active)
                content.fillRoundedRect(rect.inset(1), 3,
                    item.enabled ? palette.buttonHover : palette.buttonHover.withAlpha(55));

            const foreground = item.enabled ? palette.text : palette.disabled;
            const iconRect = Rect(rect.x + 5, rect.y + (rect.height - 16) / 2, 16, 16);
            if (item.checked)
            {
                const cx = iconRect.x + iconRect.width / 2;
                const cy = iconRect.y + iconRect.height / 2;
                content.drawLine(Point(cx - 6, cy), Point(cx - 1, cy + 5), foreground, 2);
                content.drawLine(Point(cx - 1, cy + 5), Point(cx + 7, cy - 5), foreground, 2);
            }
            else if (item.icon != IconKind.none)
                drawIcon(content, item.icon, iconRect, foreground, palette.accent);

            const shortcutWidth = item.shortcut.length == 0 ? 0 :
                maxInt(42, cast(int) item.shortcut.length * 7 + 8);
            content.drawTextInRect(Rect(rect.x + 25, rect.y,
                    maxInt(0, rect.width - 31 - shortcutWidth), rect.height),
                item.label, foreground, palette.fontScale,
                HorizontalAlign.left, VerticalAlign.middle, true);
            if (shortcutWidth > 0)
                content.drawTextInRect(Rect(rect.right() - shortcutWidth - 5, rect.y,
                        shortcutWidth, rect.height), item.shortcut,
                    item.enabled ? palette.textMuted : palette.disabled,
                    palette.fontScale, HorizontalAlign.right, VerticalAlign.middle, true);
        }

        if (_scrollOffset > 0)
            content.fillVerticalGradient(Rect(_menuRect.x + 2, _menuRect.y + 2,
                _menuRect.width - 4, 10), palette.panelElevated,
                palette.panelElevated.withAlpha(0));
        if (_scrollOffset < maximumScroll())
            content.fillVerticalGradient(Rect(_menuRect.x + 2, _menuRect.bottom() - 12,
                _menuRect.width - 4, 10), palette.panelElevated.withAlpha(0),
                palette.panelElevated);
    }

    override bool onMouseMove(ref Event event)
    {
        const index = itemAt(event.position);
        setHot(index >= 0 && _items[cast(size_t) index].enabled ? index : -1);
        return true;
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left && event.button != MouseButton.right)
            return true;
        if (!_menuRect.contains(event.position))
        {
            dismiss();
            return true;
        }
        const index = itemAt(event.position);
        setHot(index >= 0 && _items[cast(size_t) index].enabled ? index : -1);
        if (event.button == MouseButton.left && selectable(index))
        {
            _pressed = index;
            captureMouse();
            invalidate();
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return true;
        const pressed = _pressed;
        _pressed = -1;
        releaseMouse();
        if (pressed >= 0 && pressed == itemAt(event.position))
            activate(pressed);
        else
            invalidate();
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (maximumScroll() <= 0) return true;
        const old = _scrollOffset;
        _scrollOffset = clampInt(_scrollOffset - event.wheelY * _rowHeight,
            0, maximumScroll());
        if (_scrollOffset != old)
        {
            _hot = itemAt(event.position);
            invalidate();
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
            case Key.down:
                setHot(nextSelectable(_hot < 0 ? cast(int) _items.length - 1 : _hot, 1));
                return true;
            case Key.up:
                setHot(nextSelectable(_hot < 0 ? 0 : _hot, -1));
                return true;
            case Key.home:
                setHot(firstSelectable());
                return true;
            case Key.end:
                setHot(lastSelectable());
                return true;
            case Key.enter:
            case Key.space:
                activate(_hot);
                return true;
            default:
                return true;
        }
    }
}

/** Remove any Aurora context menu or other transient popup attached to the root. */
void dismissContextMenus(Widget owner)
{
    dismissTransientPopups(owner);
}

/** Show a context menu at a host-window global logical position. */
ContextMenu showContextMenu(Widget owner, Point globalPosition, ContextMenuItem[] items)
{
    if (owner is null || items.length == 0) return null;
    auto root = popupRoot(owner);
    if (root is null) return null;
    dismissTransientPopups(root);
    auto popup = new ContextMenu(items, owner);
    root.add(popup);
    popup.setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
    root.bringChildToFront(popup);
    popup.openAt(root.globalToLocal(globalPosition));
    return popup;
}

/** Show a context menu directly below the owner widget as a dropdown. */
ContextMenu showContextMenuBelow(Widget owner, ContextMenuItem[] items)
{
    if (owner is null || items.length == 0) return null;
    auto root = popupRoot(owner);
    if (root is null) return null;
    dismissTransientPopups(root);
    auto popup = new ContextMenu(items, owner);
    root.add(popup);
    popup.setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
    root.bringChildToFront(popup);
    const ownerOrigin = owner.globalOrigin();
    const rootOrigin = root.globalOrigin();
    popup.openBelow(Rect(ownerOrigin.x - rootOrigin.x,
        ownerOrigin.y - rootOrigin.y, owner.bounds().width,
        owner.bounds().height));
    return popup;
}

unittest
{
    auto root = new ContextMenuTestRoot();
    root.setBounds(Rect(0, 0, 640, 480));
    bool activated;
    auto anchored = showContextMenu(root, Point(120, 90), [
        ContextMenuItem.command("Anchor", delegate() {})
    ]);
    assert(anchored.menuRect().x == 122 && anchored.menuRect().y == 92);
    anchored.dismiss();

    auto menu = showContextMenu(root, Point(630, 470), [
        ContextMenuItem.command("Open", IconKind.open, delegate() { activated = true; }),
        ContextMenuItem.separatorItem(),
        ContextMenuItem.check("Align to grid", true, delegate() {})
    ]);
    assert(menu !is null);
    assert(menu.menuRect().right() <= 636);
    assert(menu.menuRect().bottom() <= 476);
    Event key;
    key.key = Key.enter;
    assert(menu.onKeyDown(key));
    assert(activated);
    assert(menu.dismissed());
}

private final class ContextMenuTestRoot : Widget
{
}
