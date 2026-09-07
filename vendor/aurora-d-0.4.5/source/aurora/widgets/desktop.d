module aurora.widgets.desktop;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.icons : IconKind, drawIcon;
import aurora.image : RgbaImage;
import aurora.types : CursorKind, HorizontalAlign, Point, PointF, Rect, Size, VerticalAlign,
    clampDouble, clampInt, maxInt, minInt;
import aurora.widget : Widget;
import aurora.widgets.contextmenu : ContextMenuItem, showContextMenu;
import core.stdc.time : localtime, time, time_t, tm;
import std.format : format;
import std.utf : toUTF32, toUTF8;

/** Aurora-rendered desktop shortcut with selection, drag/drop, and context actions. */
class DesktopIcon : Widget
{
    private dstring _text;
    private IconKind _icon;
    private bool _selected;
    private bool _pressed;
    private bool _dragging;
    private bool _dropTarget;
    private bool _draggable = true;
    private PointF _pressPointer;

    void delegate() onActivated;
    void delegate(DesktopIcon icon) onSelected;
    void delegate(DesktopIcon icon) onRenameRequested;
    void delegate(DesktopIcon icon) onDeleteRequested;
    void delegate(DesktopIcon icon) onPropertiesRequested;

    // DesktopSurface owns these module-private drag/context hooks. Keeping drag
    // coordination in the surface allows collision handling and drop targets.
    private void delegate(DesktopIcon icon, PointF pointer) _onDragStarted;
    private void delegate(DesktopIcon icon, PointF pointer, bool requestFrame) _onDragMoved;
    private void delegate(DesktopIcon icon, PointF pointer) _onDragDropped;
    private void delegate(DesktopIcon icon, Point globalPosition) _onContextMenu;

    this(string text, IconKind icon)
    {
        _text = toUTF32(text);
        _icon = icon;
        setComposited(true);
        setFocusable(true);
        setCursor(CursorKind.hand);
        layoutHints().preferredWidth = 96;
        layoutHints().preferredHeight = 98;
    }

    dstring text() const @safe pure nothrow @nogc { return _text; }
    IconKind iconKind() const @safe pure nothrow @nogc { return _icon; }
    bool selected() const @safe pure nothrow @nogc { return _selected; }
    bool dragging() const @safe pure nothrow @nogc { return _dragging; }
    bool dropTarget() const @safe pure nothrow @nogc { return _dropTarget; }
    bool draggable() const @safe pure nothrow @nogc { return _draggable; }

    void setText(string value)
    {
        _text = toUTF32(value);
        invalidate();
    }

    void setIcon(IconKind value)
    {
        if (_icon == value) return;
        _icon = value;
        invalidate();
    }

    void setSelected(bool value)
    {
        if (_selected == value) return;
        _selected = value;
        invalidate();
    }

    void setDraggable(bool value)
    {
        _draggable = value;
        if (!value && _dragging)
        {
            _dragging = false;
            _pressed = false;
            releaseMouse();
            setCursor(CursorKind.hand);
        }
    }

    private void setDropTarget(bool value)
    {
        if (_dropTarget == value) return;
        _dropTarget = value;
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        if (_selected || hovered() || _dropTarget)
        {
            Color background = _selected ? palette.selection : palette.buttonHover;
            if (_dropTarget) background = palette.accent.withAlpha(145);
            canvas.fillRoundedRect(full.inset(2), 6, background.withAlpha(180));
        }
        if (_dropTarget)
            canvas.drawRoundedRect(full.inset(1), 7, Color.rgba(0, 0, 0, 0),
                palette.accent, 2);
        const iconRect = Rect((bounds().width - 44) / 2,
            7 + (_pressed && !_dragging ? 1 : 0), 44, 44);
        drawIcon(canvas, _icon, iconRect, Color.rgb(245, 247, 250), palette.accent);
        canvas.drawTextInRect(Rect(3, 56, maxInt(0, bounds().width - 6),
                bounds().height - 58), _text, Color.rgb(255, 255, 255), 1,
            HorizontalAlign.center, VerticalAlign.top, true);
        if (focused())
            canvas.strokeRect(full.inset(1), palette.accent.withAlpha(210), 1);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            requestFocus();
            if (onSelected !is null) onSelected(this);
            if (_onContextMenu !is null) _onContextMenu(this, event.globalPosition);
            return true;
        }
        if (event.button != MouseButton.left) return false;
        _pressed = true;
        _dragging = false;
        _pressPointer = pointerPosition(event);
        requestFocus();
        captureMouse();
        if (onSelected !is null) onSelected(this);
        invalidate();
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_pressed || !_draggable) return false;
        const pointer = pointerPosition(event);
        if (!_dragging)
        {
            const dx = pointer.x - _pressPointer.x;
            const dy = pointer.y - _pressPointer.y;
            if (dx * dx + dy * dy < 25.0) return true;
            _dragging = true;
            setCursor(CursorKind.move);
            // Re-enter capture now that wantsContinuousPointerFrames() is true.
            // This activates Aurora's late-latched synchronized drag pointer.
            captureMouse();
            if (_onDragStarted !is null) _onDragStarted(this, _pressPointer);
            invalidate();
        }
        if (_onDragMoved !is null) _onDragMoved(this, pointer, true);
        return true;
    }

    override bool onPointerLatch(PointF globalPosition)
    {
        if (!_dragging || _onDragMoved is null) return false;
        _onDragMoved(this, globalPosition, false);
        return true;
    }

    override bool wantsContinuousPointerFrames() const @safe pure nothrow @nogc
    {
        return _dragging;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_pressed) return false;
        const wasDragging = _dragging;
        const pointer = pointerPosition(event);
        _pressed = false;
        _dragging = false;
        releaseMouse();
        setCursor(CursorKind.hand);
        invalidate();
        if (wasDragging)
        {
            if (_onDragDropped !is null) _onDragDropped(this, pointer);
            return true;
        }
        if (containsLocal(event.position) && event.clickCount >= 2 && onActivated !is null)
            onActivated();
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        switch (event.key)
        {
            case Key.enter:
            case Key.space:
                if (onActivated !is null) onActivated();
                return true;
            case Key.f2:
                if (onRenameRequested !is null) onRenameRequested(this);
                return true;
            case Key.deleteKey:
                if (onDeleteRequested !is null) onDeleteRequested(this);
                return true;
            case Key.f10:
                if (event.shift() && _onContextMenu !is null)
                {
                    _onContextMenu(this,
                        localToGlobal(Point(bounds().width / 2, bounds().height)));
                    return true;
                }
                return false;
            default:
                return false;
        }
    }

    private static PointF pointerPosition(ref Event event)
        @safe pure nothrow @nogc
    {
        return event.hasPrecisePosition ? event.preciseGlobalPosition :
            PointF(event.globalPosition);
    }
}

/** Wallpaper-like absolute-position container with retained draggable shortcuts. */
class DesktopSurface : Widget
{
    private DesktopIcon[] _icons;
    private DesktopIcon _draggedIcon;
    private DesktopIcon _dropTarget;
    private Rect _dragOriginBounds;
    private PointF _dragOffset;
    private size_t _dragOriginalChildIndex = size_t.max;
    private bool _alignToGrid = true;
    private int _gridOriginX = 16;
    private int _gridOriginY = 18;
    private int _gridStepX = 104;
    private int _gridStepY = 104;

    bool delegate(DesktopIcon source, DesktopIcon target) onIconDropped;
    void delegate(DesktopIcon icon) onIconMoved;
    void delegate() onRefresh;
    void delegate() onNewItem;
    void delegate() onDisplaySettings;
    void delegate() onPersonalize;

    this()
    {
        layoutHints().flex = 1.0;
    }

    size_t iconCount() const @safe pure nothrow @nogc { return _icons.length; }
    bool alignToGrid() const @safe pure nothrow @nogc { return _alignToGrid; }

    DesktopIcon iconAt(size_t index) @safe pure nothrow @nogc
    {
        return index < _icons.length ? _icons[index] : null;
    }

    DesktopIcon selectedIcon() @safe pure nothrow @nogc
    {
        foreach (item; _icons)
            if (item.selected()) return item;
        return null;
    }

    DesktopIcon addIcon(string text, IconKind icon, void delegate() activated = null)
    {
        auto item = add(new DesktopIcon(text, icon));
        const initial = automaticPosition(_icons.length);
        item.setBounds(Rect(initial.x, initial.y, 96, 98));
        item.onActivated = activated;
        item.onSelected = &selectIcon;
        item._onDragStarted = &beginIconDrag;
        item._onDragMoved = &moveIconDrag;
        item._onDragDropped = &finishIconDrag;
        item._onContextMenu = &showIconContextMenu;
        _icons ~= item;
        // Keep all wallpaper shortcuts below floating windows and menus, even
        // when a shortcut is created after those higher-level shell layers.
        moveChildToIndex(item, _icons.length - 1);
        return item;
    }

    bool removeIcon(DesktopIcon icon)
    {
        if (icon is null) return false;
        size_t found = size_t.max;
        foreach (index, item; _icons)
        {
            if (item is icon)
            {
                found = index;
                break;
            }
        }
        if (found == size_t.max) return false;
        if (_dropTarget is icon) setDropTarget(null);
        if (_draggedIcon is icon) _draggedIcon = null;
        for (size_t index = found; index + 1 < _icons.length; ++index)
            _icons[index] = _icons[index + 1];
        _icons.length = _icons.length - 1;
        remove(icon);
        return true;
    }

    T addWindow(T)(T window) if (is(T : FloatingWindow))
    {
        return add(window);
    }

    void clearSelection()
    {
        foreach (item; _icons) item.setSelected(false);
    }

    void setAlignToGrid(bool value)
    {
        if (_alignToGrid == value) return;
        _alignToGrid = value;
        if (value) alignIconsToGrid();
    }

    void arrangeIcons()
    {
        foreach (index, item; _icons)
        {
            const position = automaticPosition(index);
            item.setPrecisePosition(PointF(position), true);
        }
    }

    void alignIconsToGrid()
    {
        DesktopIcon[] placed;
        foreach (item; _icons)
        {
            const position = nearestFreeGridPosition(item.bounds().x, item.bounds().y,
                item, placed);
            item.setPrecisePosition(PointF(position), true);
            placed ~= item;
        }
    }

    private Point automaticPosition(size_t index) const @safe pure nothrow @nogc
    {
        const rows = bounds().height <= _gridOriginY ? 6 :
            maxInt(1, maxInt(_gridStepY, bounds().height - _gridOriginY) / _gridStepY);
        const row = cast(int) (index % cast(size_t) rows);
        const column = cast(int) (index / cast(size_t) rows);
        return Point(_gridOriginX + column * _gridStepX,
            _gridOriginY + row * _gridStepY);
    }

    private void selectIcon(DesktopIcon selected)
    {
        foreach (item; _icons) item.setSelected(item is selected);
    }

    private void beginIconDrag(DesktopIcon icon, PointF pointer)
    {
        if (icon is null) return;
        _draggedIcon = icon;
        _dragOriginBounds = icon.bounds();
        _dragOffset = pointer - icon.preciseGlobalOrigin();
        _dragOriginalChildIndex = childIndex(icon);
        // Raise only within the desktop-icon stratum. Floating windows remain
        // above wallpaper shortcuts and continue to receive hit testing first.
        if (_icons.length != 0) moveChildToIndex(icon, _icons.length - 1);
        selectIcon(icon);
    }

    private void moveIconDrag(DesktopIcon icon, PointF pointer, bool requestFrame)
    {
        if (icon is null || icon !is _draggedIcon) return;
        const origin = preciseGlobalOrigin();
        double x = pointer.x - origin.x - _dragOffset.x;
        double y = pointer.y - origin.y - _dragOffset.y;
        x = clampDouble(x, 0.0, maxInt(0, bounds().width - icon.bounds().width));
        y = clampDouble(y, 0.0, maxInt(0, bounds().height - icon.bounds().height));
        icon.setPrecisePosition(PointF(x, y), requestFrame);
        setDropTarget(dropTargetAt(pointer, icon));
    }

    private void finishIconDrag(DesktopIcon icon, PointF pointer)
    {
        if (icon is null || icon !is _draggedIcon) return;
        moveIconDrag(icon, pointer, true);
        auto target = _dropTarget;
        setDropTarget(null);
        _draggedIcon = null;
        const originalChildIndex = _dragOriginalChildIndex;
        _dragOriginalChildIndex = size_t.max;

        bool consumed;
        if (target !is null && onIconDropped !is null)
            consumed = onIconDropped(icon, target);
        if (consumed)
        {
            if (icon.parent() is this)
            {
                icon.setBounds(_dragOriginBounds);
                if (originalChildIndex != size_t.max)
                    moveChildToIndex(icon, originalChildIndex);
            }
            return;
        }
        if (icon.parent() !is this) return;
        if (_alignToGrid)
        {
            const position = nearestFreeGridPosition(icon.bounds().x, icon.bounds().y,
                icon, _icons);
            icon.setPrecisePosition(PointF(position), true);
        }
        if (originalChildIndex != size_t.max)
            moveChildToIndex(icon, originalChildIndex);
        if (onIconMoved !is null) onIconMoved(icon);
    }

    private DesktopIcon dropTargetAt(PointF pointer, DesktopIcon source)
    {
        const point = pointer.rounded();
        for (size_t index = _icons.length; index > 0; --index)
        {
            auto candidate = _icons[index - 1];
            if (candidate is source || !candidate.visible()) continue;
            const origin = candidate.globalOrigin();
            if (Rect(origin.x, origin.y, candidate.bounds().width,
                    candidate.bounds().height).contains(point))
                return candidate;
        }
        return null;
    }

    private void setDropTarget(DesktopIcon value)
    {
        if (_dropTarget is value) return;
        if (_dropTarget !is null) _dropTarget.setDropTarget(false);
        _dropTarget = value;
        if (_dropTarget !is null) _dropTarget.setDropTarget(true);
    }

    private Point nearestFreeGridPosition(int x, int y, DesktopIcon ignore,
        DesktopIcon[] considered) const
    {
        const columns = maxInt(1,
            maxInt(_gridStepX, bounds().width - _gridOriginX) / _gridStepX);
        const rows = maxInt(1,
            maxInt(_gridStepY, bounds().height - _gridOriginY) / _gridStepY);
        const nearestColumn = clampInt((x - _gridOriginX + _gridStepX / 2) /
            _gridStepX, 0, columns - 1);
        const nearestRow = clampInt((y - _gridOriginY + _gridStepY / 2) /
            _gridStepY, 0, rows - 1);
        const maximumRadius = columns + rows;
        foreach (radius; 0 .. maximumRadius + 1)
        {
            foreach (dy; -radius .. radius + 1)
            {
                const remaining = radius - (dy < 0 ? -dy : dy);
                foreach (sign; 0 .. (remaining == 0 ? 1 : 2))
                {
                    const dx = remaining == 0 ? 0 : (sign == 0 ? -remaining : remaining);
                    const column = nearestColumn + dx;
                    const row = nearestRow + dy;
                    if (column < 0 || column >= columns || row < 0 || row >= rows)
                        continue;
                    const candidate = Point(_gridOriginX + column * _gridStepX,
                        _gridOriginY + row * _gridStepY);
                    if (!gridPositionOccupied(candidate, ignore, considered))
                        return candidate;
                }
            }
        }
        return Point(clampInt(x, 0, maxInt(0, bounds().width - 96)),
            clampInt(y, 0, maxInt(0, bounds().height - 98)));
    }

    private static bool gridPositionOccupied(Point position, DesktopIcon ignore,
        DesktopIcon[] considered) @safe pure nothrow @nogc
    {
        foreach (item; considered)
        {
            if (item is null || item is ignore || !item.visible()) continue;
            if (item.bounds().x == position.x && item.bounds().y == position.y)
                return true;
        }
        return false;
    }

    private void showIconContextMenu(DesktopIcon icon, Point globalPosition)
    {
        if (icon is null) return;
        selectIcon(icon);
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Open", IconKind.open,
            delegate() { if (icon.onActivated !is null) icon.onActivated(); }, "Enter",
            icon.onActivated !is null);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Rename", IconKind.none,
            delegate() { if (icon.onRenameRequested !is null) icon.onRenameRequested(icon); },
            "F2", icon.onRenameRequested !is null);
        items ~= ContextMenuItem.command("Delete", IconKind.trash,
            delegate() { if (icon.onDeleteRequested !is null) icon.onDeleteRequested(icon); },
            "Del", icon.onDeleteRequested !is null);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Properties", IconKind.settings,
            delegate()
            {
                if (icon.onPropertiesRequested !is null)
                    icon.onPropertiesRequested(icon);
            }, "", icon.onPropertiesRequested !is null);
        showContextMenu(this, globalPosition, items);
    }

    private void showDesktopContextMenu(Point globalPosition)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Refresh", IconKind.refresh,
            delegate() { if (onRefresh !is null) onRefresh(); }, "F5", true);
        items ~= ContextMenuItem.command("Arrange icons", IconKind.none,
            delegate() { arrangeIcons(); });
        items ~= ContextMenuItem.check("Align icons to grid", _alignToGrid,
            delegate() { setAlignToGrid(!_alignToGrid); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("New", IconKind.newDocument,
            delegate() { if (onNewItem !is null) onNewItem(); }, "", onNewItem !is null);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Display settings", IconKind.computer,
            delegate()
            {
                if (onDisplaySettings !is null) onDisplaySettings();
            }, "", onDisplaySettings !is null);
        items ~= ContextMenuItem.command("Personalize", IconKind.settings,
            delegate() { if (onPersonalize !is null) onPersonalize(); }, "",
            onPersonalize !is null);
        showContextMenu(this, globalPosition, items);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillVerticalGradient(full, Color.fromHex(0x152848), Color.fromHex(0x315d7d));
        canvas.fillCircle(Point(bounds().width - 130, 110), 90,
            Color.rgba(255, 255, 255, 14));
        canvas.fillCircle(Point(bounds().width - 58, 190), 46,
            Color.rgba(88, 189, 255, 20));
        canvas.fillCircle(Point(bounds().width / 2, bounds().height + 100),
            maxInt(180, bounds().width / 3), Color.rgba(70, 160, 210, 22));
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            // A right click that bubbled out of a child window belongs to that
            // child, not to the wallpaper. Only open the desktop menu on empty space.
            foreach (child; children())
            {
                if (!child.visible()) continue;
                const origin = child.globalOrigin();
                if (Rect(origin.x, origin.y, child.bounds().width,
                        child.bounds().height).contains(event.globalPosition))
                    return false;
            }
            clearSelection();
            showDesktopContextMenu(event.globalPosition);
            return true;
        }
        if (event.button != MouseButton.left) return false;
        clearSelection();
        return true;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.f5)
        {
            if (onRefresh !is null) onRefresh();
            return true;
        }
        if (event.key == Key.f10 && event.shift())
        {
            showDesktopContextMenu(localToGlobal(Point(24, 24)));
            return true;
        }
        return false;
    }
}

/** Draggable in-canvas desktop window with native-style system commands. */
class FloatingWindow : Widget
{
    private dstring _title;
    private IconKind _icon;
    private Widget _content;
    private bool _dragging;
    private PointF _dragStartPrecise;
    private PointF _startPositionPrecise;
    private int _titleHeight = 40;
    private int _pressedControl;
    private bool _maximized;
    private Rect _restoreBounds;

    void delegate(FloatingWindow window) onActivated;
    void delegate(FloatingWindow window) onClosed;
    void delegate(FloatingWindow window) onMinimized;
    void delegate(FloatingWindow window) onRestored;
    void delegate(FloatingWindow window) onTitleChanged;

    this(string title, IconKind icon, Widget content = null)
    {
        setComposited(true);
        _title = toUTF32(title);
        _icon = icon;
        layoutHints().minWidth = 220;
        layoutHints().minHeight = 120;
        if (content !is null) setContent(content);
    }

    dstring title() const @safe pure nothrow @nogc { return _title; }
    IconKind iconKind() const @safe pure nothrow @nogc { return _icon; }
    Widget content() @safe pure nothrow @nogc { return _content; }
    bool maximized() const @safe pure nothrow @nogc { return _maximized; }

    void setTitle(string value)
    {
        _title = toUTF32(value);
        invalidate();
        if (onTitleChanged !is null) onTitleChanged(this);
    }

    void setContent(Widget value)
    {
        if (_content !is null) remove(_content);
        _content = value;
        if (_content !is null) add(_content);
        onLayout();
        invalidate();
    }

    void activate()
    {
        if (parent() !is null) parent().bringChildToFront(this);
        if (onActivated !is null) onActivated(this);
    }

    void minimize()
    {
        if (!visible()) return;
        setVisible(false);
        if (onMinimized !is null) onMinimized(this);
    }

    void restore()
    {
        setVisible(true);
        activate();
        if (onRestored !is null) onRestored(this);
    }

    void toggleMaximize()
    {
        if (parent() is null) return;
        if (_maximized)
        {
            _maximized = false;
            setBounds(_restoreBounds);
        }
        else
        {
            _restoreBounds = bounds();
            _maximized = true;
            setBounds(Rect(0, 0, parent().bounds().width, parent().bounds().height));
        }
        activate();
    }

    void closeWindow()
    {
        auto owner = parent();
        if (owner !is null) owner.remove(this);
        if (onClosed !is null) onClosed(this);
    }

    private Rect closeRect() const @safe pure nothrow @nogc
    {
        return Rect(maxInt(0, bounds().width - 38), 5, 32, 30);
    }

    private Rect maximizeRect() const @safe pure nothrow @nogc
    {
        return Rect(maxInt(0, bounds().width - 74), 5, 32, 30);
    }

    private Rect minimizeRect() const @safe pure nothrow @nogc
    {
        return Rect(maxInt(0, bounds().width - 110), 5, 32, 30);
    }

    private int controlAt(Point point) const @safe pure nothrow @nogc
    {
        if (closeRect().contains(point)) return 3;
        if (maximizeRect().contains(point)) return 2;
        if (minimizeRect().contains(point)) return 1;
        return 0;
    }

    protected override void onLayout()
    {
        if (_content !is null)
            _content.setBounds(Rect(1, _titleHeight,
                maxInt(0, bounds().width - 2),
                maxInt(0, bounds().height - _titleHeight - 1)));
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.drawRoundedRect(full, 7, palette.panelBackground, palette.border, 1);
        canvas.fillRoundedRect(Rect(1, 1, maxInt(0, bounds().width - 2), _titleHeight),
            6, palette.panelElevated);
        canvas.fillRect(Rect(1, _titleHeight - 6, maxInt(0, bounds().width - 2), 6),
            palette.panelElevated);
        canvas.fillRect(Rect(1, _titleHeight - 1, maxInt(0, bounds().width - 2), 1),
            palette.border);
        drawIcon(canvas, _icon, Rect(8, 8, 24, 24), palette.text, palette.accent);
        canvas.drawTextInRect(Rect(40, 0, maxInt(0, bounds().width - 164), _titleHeight),
            _title, palette.text, palette.fontScale, HorizontalAlign.left,
            VerticalAlign.middle, true);

        drawCaptionButton(canvas, minimizeRect(), 1, _pressedControl == 1);
        drawCaptionButton(canvas, maximizeRect(), 2, _pressedControl == 2);
        drawCaptionButton(canvas, closeRect(), 3, _pressedControl == 3);
    }

    private void drawCaptionButton(ref Canvas canvas, Rect rect, int kind, bool pressed)
    {
        const palette = theme();
        Color background = pressed ? palette.buttonPressed : Color.rgba(0, 0, 0, 0);
        if (!pressed && hovered()) background = palette.buttonHover.withAlpha(90);
        if (kind == 3 && pressed) background = palette.danger;
        if (background.a != 0) canvas.fillRoundedRect(rect, 4, background);
        const color = kind == 3 && pressed ? Color.rgb(255, 255, 255) : palette.text;
        const cx = rect.x + rect.width / 2;
        const cy = rect.y + rect.height / 2;
        if (kind == 1)
            canvas.drawLine(Point(cx - 5, cy + 4), Point(cx + 5, cy + 4), color, 1);
        else if (kind == 2)
            canvas.strokeRect(Rect(cx - 5, cy - 5, 10, 10), color, 1);
        else
        {
            canvas.drawLine(Point(cx - 5, cy - 5), Point(cx + 5, cy + 5), color, 1);
            canvas.drawLine(Point(cx + 5, cy - 5), Point(cx - 5, cy + 5), color, 1);
        }
    }

    private void showSystemMenu(Point globalPosition)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Restore", IconKind.open,
            delegate()
            {
                if (_maximized) toggleMaximize();
                else restore();
            }, "", _maximized || !visible());
        items ~= ContextMenuItem.command("Minimize", IconKind.minimize,
            delegate() { minimize(); }, "", visible());
        items ~= ContextMenuItem.command(_maximized ? "Restore down" : "Maximize",
            IconKind.maximize, delegate() { toggleMaximize(); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Close", IconKind.close,
            delegate() { closeWindow(); }, "Alt+F4");
        showContextMenu(this, globalPosition, items);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right && event.position.y < _titleHeight)
        {
            activate();
            showSystemMenu(event.globalPosition);
            return true;
        }
        if (event.button != MouseButton.left) return false;
        activate();
        const control = controlAt(event.position);
        if (control != 0)
        {
            _pressedControl = control;
            captureMouse();
            invalidate();
            return true;
        }
        if (event.position.y < _titleHeight)
        {
            if (event.clickCount >= 2)
            {
                toggleMaximize();
                return true;
            }
            if (!_maximized)
            {
                _dragging = true;
                _dragStartPrecise = pointerPosition(event);
                _startPositionPrecise = precisePosition();
                captureMouse();
            }
            return true;
        }
        return false;
    }

    override bool onPointerLatch(PointF globalPosition)
    {
        return _dragging && updateDrag(globalPosition, false);
    }

    override bool wantsContinuousPointerFrames() const @safe pure nothrow @nogc
    {
        return _dragging;
    }

    override bool onMouseMove(ref Event event)
    {
        if (_dragging)
        {
            updateDrag(pointerPosition(event), true);
            return true;
        }
        return _pressedControl != 0;
    }

    private bool updateDrag(PointF pointer, bool requestFrame)
    {
        const dx = pointer.x - _dragStartPrecise.x;
        const dy = pointer.y - _dragStartPrecise.y;
        double x = _startPositionPrecise.x + dx;
        double y = _startPositionPrecise.y + dy;
        if (parent() !is null)
        {
            x = clampDouble(x, -bounds().width + 80.0,
                maxInt(0, parent().bounds().width - 80));
            y = clampDouble(y, 0.0,
                maxInt(0, parent().bounds().height - _titleHeight));
        }
        return setPrecisePosition(PointF(x, y), requestFrame);
    }

    private static PointF pointerPosition(ref Event event)
        @safe pure nothrow @nogc
    {
        return event.hasPrecisePosition ? event.preciseGlobalPosition :
            PointF(event.globalPosition);
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (_dragging)
        {
            updateDrag(pointerPosition(event), true);
            _dragging = false;
            releaseMouse();
            return true;
        }
        if (_pressedControl != 0)
        {
            const pressed = _pressedControl;
            const shouldActivate = controlAt(event.position) == pressed;
            _pressedControl = 0;
            releaseMouse();
            invalidate();
            if (shouldActivate)
            {
                if (pressed == 1) minimize();
                else if (pressed == 2) toggleMaximize();
                else closeWindow();
            }
            return true;
        }
        return false;
    }
}

/** Stable identity for a taskbar entry. Zero is never assigned. */
alias TaskEntryId = ulong;
enum TaskEntryId invalidTaskEntryId = 0;

private struct TaskEntry
{
    TaskEntryId id;
    FloatingWindow window;
    dstring title;
    IconKind icon;
    void delegate() command;
    /// Non-zero when this entry maps to an external OS top-level window rather
    /// than an in-shell FloatingWindow. When set, window is null and clicks are
    /// routed to the OS (activate/minimize) via the taskbar's host callbacks.
    ulong hostHwnd;
    /// Real raster icon for an external OS window (null = fall back to `icon`).
    RgbaImage iconImage;
}

private enum int taskDragProxyMargin = 6;

/**
 * Immutable snapshot of the Windows system status shown in the taskbar tray.
 *
 * The taskbar only renders from this state and forwards clicks; the desktop
 * application owns querying the live Win32 battery / volume / network APIs and
 * publishing changes here (so a headless test can also drive a fake snapshot).
 */
struct SystemTrayState
{
    bool wifiConnected;
    bool hasBattery;
    bool batteryCharging;
    int batteryPercent = -1;
    int volumePercent = 50;
    bool volumeMuted;
    size_t hiddenIconCount = 5;
}

/**
 * One application notification icon shown in the taskbar notification cluster.
 * The taskbar owns the model and paints visible icons; the desktop app registers
 * them and renders the hidden-icon grid. On Windows 11's XAML taskbar the
 * real Explorer overflow toolbar returns zero metadata (proven with a probe),
 * so these are shell-owned notifications rather than a live OS scan.
 */
struct NotificationIcon
{
    size_t id;
    dstring label;
    IconKind icon = IconKind.none;
    bool hidden;
    void delegate() action;
    void delegate() showMenu; // right-click context (opened by the app/web)
}

/**
 * Independently retained visual for the task currently being reordered.
 *
 * The proxy is attached as a root-level compositor layer. Its content is built
 * once when the drag begins; subsequent pointer samples only change the layer
 * transform. This lets GuiWindow's late-latch pass move the task and Aurora's
 * synchronized cursor in the same submitted frame.
 */
private final class TaskDragProxy : Widget
{
    private dstring _title;
    private IconKind _icon;
    private bool _running;
    private bool _active;
    private int _entryWidth;
    private int _entryHeight;

    this(dstring title, IconKind icon, bool running, bool active,
        int entryWidth, int entryHeight)
    {
        _title = title;
        _icon = icon;
        _running = running;
        _active = active;
        _entryWidth = maxInt(1, entryWidth);
        _entryHeight = maxInt(1, entryHeight);
        setComposited(true);
        setEnabled(false);
        layoutHints().excludeFromLayout = true;
        layoutHints().allowOverflow = true;
        setBounds(Rect(0, 0, _entryWidth + taskDragProxyMargin * 2,
            _entryHeight + taskDragProxyMargin * 2));
    }

    Rect contentRect() const @safe pure nothrow @nogc
    {
        return Rect(taskDragProxyMargin, taskDragProxyMargin,
            _entryWidth, _entryHeight);
    }

    PointF contentGlobalOrigin() const @safe pure nothrow @nogc
    {
        const origin = preciseGlobalOrigin();
        return PointF(origin.x + taskDragProxyMargin,
            origin.y + taskDragProxyMargin);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const panel = contentRect();
        canvas.fillRoundedRect(panel.translated(2, 3), 7,
            Color.rgba(0, 0, 0, 95));
        canvas.fillRoundedRect(panel, 6, palette.taskbarHover);
        canvas.drawRoundedRect(panel.inset(1), 6, Color.rgba(0, 0, 0, 0),
            palette.accent, 2);
        // Icon-only, matching the taskbar buttons (no title text).
        enum int iconSize = 26;
        drawIcon(canvas, _icon,
            Rect(panel.x + (panel.width - iconSize) / 2,
                panel.y + (panel.height - iconSize) / 2 - 2,
                iconSize, iconSize),
            Color.rgb(245, 248, 252), palette.accent);
        if (_running)
            canvas.fillRect(Rect(panel.x + (panel.width - 16) / 2,
                panel.bottom() - 4, 16, _active ? 3 : 2),
                _active ? palette.accent : palette.textMuted);
    }
}

/**
 * A small root-level hover tooltip for the taskbar. Shows a single line of text
 * in a rounded panel just above the hovered taskbar region; it is owned by the
 * Taskbar (added to the root like the drag proxy) and auto-sizes to its text.
 */
private final class TaskbarTooltip : Widget
{
    private dstring _text;
    private Size _textSize;

    this(string text)
    {
        _text = toUTF32(text);
        _textSize = measureTooltipText(_text);
        setComposited(true);
        setEnabled(false);
        layoutHints().excludeFromLayout = true;
        layoutHints().allowOverflow = true;
        setBounds(Rect(0, 0, _textSize.width + 20,
            maxInt(1, _textSize.height + 12)));
    }

    this(dstring text)
    {
        _text = text;
        _textSize = measureTooltipText(_text);
        setComposited(true);
        setEnabled(false);
        layoutHints().excludeFromLayout = true;
        layoutHints().allowOverflow = true;
        setBounds(Rect(0, 0, _textSize.width + 20,
            maxInt(1, _textSize.height + 12)));
    }

    // Measure a single-line label with the caption tier so the panel hugs it.
    private Size measureTooltipText(const(dchar)[] text)
    {
        import aurora.text.layout : TextLayoutOptions;
        import aurora.font : FontRole, fontPixelSize;
        const palette = theme();
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() palette.uiFont;
        options.pixelSize = fontPixelSize(1);
        options.wrap = false;
        return fontSystem().textEngine.layout(text, options).measuredSize();
    }

    void setText(string value)
    {
        _text = toUTF32(value);
        _textSize = measureTooltipText(_text);
        setBounds(Rect(0, 0, _textSize.width + 20,
            maxInt(1, _textSize.height + 12)));
        invalidate();
    }

    void setText(dstring value)
    {
        _text = value;
        _textSize = measureTooltipText(_text);
        setBounds(Rect(0, 0, _textSize.width + 20,
            maxInt(1, _textSize.height + 12)));
        invalidate();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRoundedRect(full.translated(1, 2), 6,
            Color.rgba(0, 0, 0, 95));
        canvas.fillRoundedRect(full, 6, palette.panelElevated);
        canvas.drawRoundedRect(full.inset(1), 6, Color.rgba(0, 0, 0, 0),
            palette.border.withAlpha(160), 1);
        canvas.drawTextInRect(Rect(10, 6, maxInt(0, bounds().width - 20),
            maxInt(0, bounds().height - 12)), _text, palette.text, 1,
            HorizontalAlign.center, VerticalAlign.middle, true);
    }
}

/** Full Aurora taskbar with activation, reordering, menus, and Show Desktop. */
class Taskbar : Widget
{
    private TaskEntry[] _entries;
    private NotificationIcon[] _notifications;
    private int _pressed = -2;
    private int _hot = -2;
    private int _keyboardIndex = -1;
    private TaskEntryId _pressedEntryId = invalidTaskEntryId;
    private TaskEntryId _dragEntryId = invalidTaskEntryId;
    private int _dragOriginIndex = -1;
    private int _dragCurrentIndex = -1;
    private bool _reordering;
    // Reorder slide-and-swap animation. When the target slot changes the
    // non-dragged entries ease from their previous slot to the new one instead
    // of jumping, so a dragged task visibly pushes neighbors toward it before
    // they settle into the swapped position. The model order is unchanged by
    // this; it only affects where each neutral task is painted mid-drag.
    private double _reorderAnim;             // 0..1 within the current slide
    private int[] _reorderFromSlot;          // per model index, slot at prev boundary
    private int[] _reorderToSlot;            // per model index, slot at current boundary
    private bool _reorderAnimActive;
    private enum double reorderAnimSeconds = 0.14;
    private PointF _pressPointer;
    private PointF _dragGrabOffset;
    private PointF _dragPointerPosition;
    private TaskDragProxy _dragProxy;
    private TaskEntryId _nextEntryId = 1;
    private bool _startMenuOpen;
    private FloatingWindow _activeWindow;
    private FloatingWindow[] _showDesktopWindows;
    private TaskbarTooltip _tooltip;
    private double _tooltipHoverSeconds;
    private int _tooltipRegion = -2;   // the _hot code the tooltip is for
    private enum double tooltipDelaySeconds = 0.6;
    private dstring _clock;
    private dstring _date;
    private double _clockAccumulator = 0.0;
    private int _clockHour = -1;
    private int _clockMinute = -1;
    private int _clockDay = -1;
    private int _clockMonth = -1;
    private int _clockYear = -1;
    private SystemTrayState _tray;
    /**
     * Windows-shell look (search pill, tray cluster, two-line clock) versus
     * the previous classic look (entries from x=54, single-line clock, thin
     * show-desktop strip). Defaults to the new shell; the desktop app exposes
     * this through System Settings and persists the choice.
     */
    private bool _modernShell = true;

    void delegate() onStart;
    void delegate() onShowDesktop;
    void delegate() onTaskbarSettings;
    void delegate() onDateTimeSettings;
    void delegate() onToggleFullscreen;
    void delegate() onVolumeToggle;
    void delegate() onVolumeChanged;
    void delegate() onVolumeClick;
    void delegate() onBatteryClick;
    void delegate() onWifiClick;
    void delegate() onHiddenIconsClick;
    void delegate() onSearchClick;
    void delegate(int from, int to) onEntryMoved;
    void delegate(int index) onEntryRemoved;
    /** Stable-ID snapshot emitted after every completed order mutation. */
    void delegate(TaskEntryId[] order) onEntryOrderChanged;
    /** Fired when the hot entry changes to a window/command task (index >= 0). */
    void delegate(int index) onTaskHover;
    /** Fired when the pointer leaves a hovered task entry. */
    void delegate() onTaskHoverLeave;
    /** Activate/minimize/focus an external OS window task (hostHwnd). */
    void delegate(ulong hwnd, bool minimized) onExternalActivate;
    void delegate(ulong hwnd) onExternalMinimize;
    void delegate(ulong hwnd) onExternalClose;
    /** Live visibility of an external window (true = visible, not minimized). */
    bool delegate(ulong hwnd) onExternalVisible;
    /** Live foreground/focus state of an external window. */
    bool delegate(ulong hwnd) onExternalFocused;

    this()
    {
        setComposited(true);
        setFocusable(true);
        layoutHints().preferredHeight = 52;
        layoutHints().minHeight = 48;
        updateClock();
    }

    size_t entryCount() const @safe pure nothrow @nogc { return _entries.length; }
    FloatingWindow activeWindow() @safe pure nothrow @nogc { return _activeWindow; }
    bool startMenuOpen() const @safe pure nothrow @nogc { return _startMenuOpen; }

    dstring entryTitle(size_t index) const @safe pure nothrow @nogc
    {
        return index < _entries.length ? _entries[index].title : null;
    }

    FloatingWindow entryWindow(size_t index) @safe pure nothrow @nogc
    {
        return index < _entries.length ? _entries[index].window : null;
    }

    IconKind entryIcon(size_t index) const @safe pure nothrow @nogc
    {
        return index < _entries.length ? _entries[index].icon : IconKind.none;
    }

    TaskEntryId entryId(size_t index) const @safe pure nothrow @nogc
    {
        return index < _entries.length ? _entries[index].id : invalidTaskEntryId;
    }

    int indexOfEntry(TaskEntryId id) const @safe pure nothrow @nogc
    {
        if (id == invalidTaskEntryId) return -1;
        foreach (index, entry; _entries)
            if (entry.id == id) return cast(int) index;
        return -1;
    }

    /** Copy the current task order using stable identifiers. */
    TaskEntryId[] entryOrder() const
    {
        TaskEntryId[] result;
        result.reserve(_entries.length);
        foreach (entry; _entries) result ~= entry.id;
        return result;
    }

    /**
     * Restore a persisted stable-ID order. The supplied set must exactly match
     * the current entries; invalid, duplicate, or partial snapshots are rejected.
     */
    bool setEntryOrder(const(TaskEntryId)[] order)
    {
        if (_reordering) cancelTaskReorder();
        if (order.length != _entries.length) return false;
        TaskEntry[] reordered;
        reordered.reserve(_entries.length);
        foreach (id; order)
        {
            const index = indexOfEntry(id);
            if (index < 0) return false;
            foreach (existing; reordered)
                if (existing.id == id) return false;
            reordered ~= _entries[cast(size_t) index];
        }
        const pressedId = stateEntryId(_pressed);
        const hotId = stateEntryId(_hot);
        const keyboardId = stateEntryId(_keyboardIndex);
        _entries = reordered;
        restoreStateIndex(_pressed, pressedId);
        restoreStateIndex(_hot, hotId);
        restoreStateIndex(_keyboardIndex, keyboardId);
        debug assert(taskOrderValid());
        invalidate();
        notifyEntryOrderChanged();
        return true;
    }

    bool reordering() const @safe pure nothrow @nogc { return _reordering; }

    /** Current insertion slot while a pointer reorder is active. */
    int dragTargetIndex() const @safe pure nothrow @nogc
    {
        return _reordering ? _dragCurrentIndex : -1;
    }

    /**
     * Global logical point inside the drag proxy that corresponds to the
     * original pointer grab. It must equal the latest sampled pointer position.
     */
    PointF dragAnchorGlobalPosition() const @safe pure nothrow @nogc
    {
        return _reordering && _dragProxy !is null ?
            _dragPointerPosition : PointF.init;
    }

    Rect dragPreviewGlobalBounds() const @safe pure nothrow @nogc
    {
        if (!_reordering || _dragProxy is null) return Rect.init;
        const origin = _dragProxy.contentGlobalOrigin().rounded();
        const content = _dragProxy.contentRect();
        return Rect(origin.x, origin.y, content.width, content.height);
    }

    void setStartMenuOpen(bool value)
    {
        if (_startMenuOpen == value) return;
        _startMenuOpen = value;
        invalidate();
    }

    bool modernShell() const @safe pure nothrow @nogc { return _modernShell; }

    void setModernShell(bool value)
    {
        if (_modernShell == value) return;
        _modernShell = value;
        invalidate();
    }

    const(SystemTrayState) trayState() const @safe pure nothrow @nogc
    {
        return _tray;
    }

    const(NotificationIcon)[] notifications() const @safe pure nothrow @nogc
    {
        return _notifications;
    }

    void addNotification(NotificationIcon icon)
    {
        _notifications ~= icon;
        invalidate();
    }

    void clearNotifications()
    {
        _notifications.length = 0;
        invalidate();
    }

    void setNotificationHidden(size_t id, bool hidden)
    {
        foreach (ref icon; _notifications)
        {
            if (icon.id == id)
            {
                icon.hidden = hidden;
                _tray.hiddenIconCount = hiddenNotificationCount();
                invalidate();
                return;
            }
        }
        _tray.hiddenIconCount = hiddenNotificationCount();
    }

    private size_t hiddenNotificationCount() const
    {
        size_t hidden;
        foreach (icon; _notifications)
            if (icon.hidden) ++hidden;
        return hidden;
    }

    /** Global bounds of the notification cluster j-th visible icon. */
    Rect notificationIconGlobalBounds(size_t index) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        const local = notificationIconRect(index);
        return local.empty() ? Rect.init :
            Rect(origin.x + local.x, origin.y + local.y,
                local.width, local.height);
    }

    void setTrayState(const(SystemTrayState) value)
    {
        if (_tray.wifiConnected != value.wifiConnected ||
            _tray.hasBattery != value.hasBattery ||
            _tray.batteryCharging != value.batteryCharging ||
            _tray.batteryPercent != value.batteryPercent ||
            _tray.volumePercent != value.volumePercent ||
            _tray.volumeMuted != value.volumeMuted ||
            _tray.hiddenIconCount != value.hiddenIconCount)
        {
            _tray = value;
            invalidate();
        }
    }

    Rect startButtonBounds() const @safe pure nothrow @nogc
    {
        return startRect();
    }

    Rect startButtonGlobalBounds() const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        const local = startRect();
        return Rect(origin.x + local.x, origin.y + local.y, local.width, local.height);
    }

    /** Global bounds of one system-tray icon (0=wifi, 1=volume, 2=battery, 3=hidden). */
    Rect trayIconGlobalBounds(int index) const @safe pure nothrow @nogc
    {
        if (index < 0 || index >= 4) return Rect.init;
        const origin = globalOrigin();
        const local = trayIconRect(index);
        return Rect(origin.x + local.x, origin.y + local.y, local.width, local.height);
    }

    /**
     * The currently hovered taskbar region as a signed code, for tests and
     * accessibility: -1 start, -3 clock, -4 show-desktop, -5 search,
     * -6..-9 tray icons (wifi/volume/battery/chevron), >= 0 a task entry index,
     * -2 none. Tray hovers use the negative block so they can never collide
     * with a task-entry index.
     */
    int hotRegion() const @safe pure nothrow @nogc
    {
        return _hot;
    }

    Rect entryBounds(size_t index) const @safe pure nothrow @nogc
    {
        return index < _entries.length ? entryRect(cast(int) index) : Rect.init;
    }

    /** Global bounds of a task entry (for popups/previews anchored above it). */
    Rect entryGlobalBounds(size_t index) const @safe pure nothrow @nogc
    {
        if (index >= _entries.length) return Rect.init;
        const origin = globalOrigin();
        const local = entryRect(cast(int) index);
        return Rect(origin.x + local.x, origin.y + local.y,
            local.width, local.height);
    }

    // Read-only geometry for tests (clock and show-desktop are private). Padded
    // so the date/time never visually merges with the show-desktop button.
    Rect clockBounds() const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        const local = clockRect();
        return Rect(origin.x + local.x, origin.y + local.y, local.width, local.height);
    }

    Rect showDesktopBounds() const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        const local = showDesktopRect();
        return Rect(origin.x + local.x, origin.y + local.y, local.width, local.height);
    }

    /** Global bounds of the search pill (Rect.init when the classic shell). */
    Rect searchButtonGlobalBounds() const @safe pure nothrow @nogc
    {
        if (!_modernShell) return Rect.init;
        const origin = globalOrigin();
        const local = searchRect();
        return Rect(origin.x + local.x, origin.y + local.y, local.width, local.height);
    }

    private TaskEntryId allocateEntryId()
    {
        auto result = _nextEntryId++;
        if (result == invalidTaskEntryId) result = _nextEntryId++;
        return result;
    }

    void addWindow(FloatingWindow window, string title, IconKind icon)
    {
        if (_reordering) cancelTaskReorder();
        const existing = indexOfWindow(window);
        if (window !is null && existing >= 0)
        {
            _entries[cast(size_t) existing].title = toUTF32(title);
            _entries[cast(size_t) existing].icon = icon;
            invalidate();
            return;
        }
        _entries ~= TaskEntry(allocateEntryId(), window, toUTF32(title), icon, null, 0);
        if (_activeWindow is null && window !is null && window.visible())
            _activeWindow = window;
        debug assert(taskOrderValid());
        invalidate();
        notifyEntryOrderChanged();
    }

    void addCommand(string title, IconKind icon, void delegate() command)
    {
        if (_reordering) cancelTaskReorder();
        _entries ~= TaskEntry(allocateEntryId(), null, toUTF32(title), icon, command, 0);
        debug assert(taskOrderValid());
        invalidate();
        notifyEntryOrderChanged();
    }

    /// Add (or update) an external OS top-level window task. The entry is keyed
    /// by hostHwnd; repeated calls refresh its title without duplicating.
    void addExternalTask(ulong hostHwnd, string title, IconKind icon = IconKind.none)
    {
        if (_reordering) cancelTaskReorder();
        foreach (ref entry; _entries)
        {
            if (entry.hostHwnd == hostHwnd)
            {
                if (toUTF32(title) != entry.title)
                {
                    entry.title = toUTF32(title);
                    invalidate();
                    notifyEntryOrderChanged();
                }
                return;
            }
        }
        _entries ~= TaskEntry(allocateEntryId(), null, toUTF32(title), icon, null,
            hostHwnd);
        debug assert(taskOrderValid());
        invalidate();
        notifyEntryOrderChanged();
    }

    int indexOfExternal(ulong hostHwnd) const @safe pure nothrow @nogc
    {
        foreach (index, entry; _entries)
            if (entry.hostHwnd == hostHwnd) return cast(int) index;
        return -1;
    }

    ulong entryHostHwnd(size_t index) const @safe pure nothrow @nogc
    {
        return index < _entries.length ? _entries[index].hostHwnd : 0;
    }

    bool removeExternal(ulong hostHwnd)
    {
        const index = indexOfExternal(hostHwnd);
        return index >= 0 && removeEntry(index);
    }

    int indexOfWindow(FloatingWindow window) const @safe pure nothrow @nogc
    {
        foreach (index, entry; _entries)
            if (entry.window is window) return cast(int) index;
        return -1;
    }

    void setActiveWindow(FloatingWindow window)
    {
        if (_activeWindow is window) return;
        _activeWindow = window;
        invalidate();
    }

    void updateWindowTitle(FloatingWindow window)
    {
        const index = indexOfWindow(window);
        if (index < 0 || window is null) return;
        _entries[cast(size_t) index].title = window.title();
        invalidate();
    }

    bool removeWindow(FloatingWindow window)
    {
        const index = indexOfWindow(window);
        return index >= 0 && removeEntry(index);
    }

    bool removeEntry(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length) return false;
        const removed = _entries[cast(size_t) index];
        const removedWindow = removed.window;
        for (size_t position = cast(size_t) index;
            position + 1 < _entries.length; ++position)
            _entries[position] = _entries[position + 1];
        _entries.length = _entries.length - 1;
        if (_activeWindow is removedWindow) _activeWindow = null;
        if (removedWindow !is null)
        {
            for (size_t position = _showDesktopWindows.length; position > 0; --position)
            {
                if (_showDesktopWindows[position - 1] !is removedWindow) continue;
                _showDesktopWindows = _showDesktopWindows[0 .. position - 1] ~
                    _showDesktopWindows[position .. $];
            }
        }

        if (_dragProxy !is null) destroyDragProxy();
        if (_dragEntryId == removed.id || _pressed != -2 || _reordering)
        {
            releaseMouse();
            setCursor(CursorKind.arrow);
        }
        _pressed = -2;
        _pressedEntryId = invalidTaskEntryId;
        _hot = -2;
        _dragEntryId = invalidTaskEntryId;
        _dragOriginIndex = -1;
        _dragCurrentIndex = -1;
        _dragGrabOffset = PointF.init;
        _dragPointerPosition = PointF.init;
        _reordering = false;
        if (_keyboardIndex > index) --_keyboardIndex;
        else if (_keyboardIndex == index)
            _keyboardIndex = minInt(index, cast(int) _entries.length - 1);
        debug assert(taskOrderValid());
        invalidate();
        if (onEntryRemoved !is null) onEntryRemoved(index);
        notifyEntryOrderChanged();
        return true;
    }

    bool removeEntry(TaskEntryId id)
    {
        const index = indexOfEntry(id);
        return index >= 0 && removeEntry(index);
    }

    bool moveEntry(int from, int to)
    {
        if (_reordering) cancelTaskReorder();
        return moveEntryInternal(from, to, true);
    }

    bool moveEntry(TaskEntryId id, int to)
    {
        if (_reordering) cancelTaskReorder();
        const from = indexOfEntry(id);
        return from >= 0 && moveEntryInternal(from, to, true);
    }

    private bool moveEntryInternal(int from, int to, bool notify)
    {
        if (from < 0 || to < 0 || from >= cast(int) _entries.length ||
            to >= cast(int) _entries.length || from == to)
            return false;

        // Indices are presentation details. Preserve all interaction state by
        // stable identity so repeated programmatic and pointer reorders cannot
        // make hover, keyboard focus, or the pressed task refer to a neighbour.
        const pressedId = stateEntryId(_pressed);
        const hotId = stateEntryId(_hot);
        const keyboardId = stateEntryId(_keyboardIndex);
        auto value = _entries[cast(size_t) from];
        if (from < to)
        {
            for (int index = from; index < to; ++index)
                _entries[cast(size_t) index] = _entries[cast(size_t) index + 1];
        }
        else
        {
            for (int index = from; index > to; --index)
                _entries[cast(size_t) index] = _entries[cast(size_t) index - 1];
        }
        _entries[cast(size_t) to] = value;
        restoreStateIndex(_pressed, pressedId);
        restoreStateIndex(_hot, hotId);
        restoreStateIndex(_keyboardIndex, keyboardId);
        debug assert(taskOrderValid());
        invalidate();
        if (notify)
        {
            if (onEntryMoved !is null) onEntryMoved(from, to);
            notifyEntryOrderChanged();
        }
        return true;
    }

    private TaskEntryId stateEntryId(int index) const @safe pure nothrow @nogc
    {
        return index >= 0 && index < cast(int) _entries.length ?
            _entries[cast(size_t) index].id : invalidTaskEntryId;
    }

    private void restoreStateIndex(ref int index, TaskEntryId id)
        @safe pure nothrow @nogc
    {
        if (index >= 0) index = indexOfEntry(id);
    }

    private void notifyEntryOrderChanged()
    {
        if (onEntryOrderChanged !is null) onEntryOrderChanged(entryOrder());
    }

    /** Verify the internal model after tests or persistence reloads. */
    bool taskOrderValid() const @safe pure nothrow @nogc
    {
        foreach (index, entry; _entries)
        {
            if (entry.id == invalidTaskEntryId) return false;
            foreach (otherIndex, other; _entries)
                if (index != otherIndex && entry.id == other.id) return false;
        }
        if (_dragEntryId != invalidTaskEntryId && indexOfEntry(_dragEntryId) < 0)
            return false;
        if (_reordering)
        {
            if (_dragEntryId == invalidTaskEntryId || _dragProxy is null) return false;
            if (_dragOriginIndex < 0 || _dragOriginIndex >= cast(int) _entries.length)
                return false;
            if (_dragCurrentIndex < 0 || _dragCurrentIndex >= cast(int) _entries.length)
                return false;
        }
        else if (_dragProxy !is null)
            return false;
        return true;
    }

    void showDesktop()
    {
        _showDesktopWindows.length = 0;
        foreach (entry; _entries)
        {
            if (entry.window !is null && entry.window.visible())
            {
                _showDesktopWindows ~= entry.window;
                entry.window.minimize();
            }
        }
        _activeWindow = null;
        invalidate();
        if (onShowDesktop !is null) onShowDesktop();
    }

    void restoreDesktop()
    {
        auto windows = _showDesktopWindows.dup;
        _showDesktopWindows.length = 0;
        foreach (window; windows)
        {
            if (window !is null)
            {
                window.restore();
                _activeWindow = window;
            }
        }
        invalidate();
    }

    void toggleShowDesktop()
    {
        if (_showDesktopWindows.length == 0) showDesktop();
        else restoreDesktop();
    }

    private Rect startRect() const @safe pure nothrow @nogc
    {
        return Rect(6, 6, 42, maxInt(1, bounds().height - 12));
    }

    private enum int searchBoxWidth = 150;
    private enum int searchBoxGap = 8;

    private Rect searchRect() const @safe pure nothrow @nogc
    {
        if (!_modernShell) return Rect.init;
        return Rect(startRect().right() + searchBoxGap, 6, searchBoxWidth,
            maxInt(1, bounds().height - 12));
    }

    private int entriesStartX() const @safe pure nothrow @nogc
    {
        if (!_modernShell) return 54;
        return searchRect().right() + searchBoxGap;
    }

    // Right-side reserved region, laid out from the right edge leftward:
    // show-desktop strip, a padding gap, two-line clock, then the tray cluster.
    // The classic shell keeps the previous compact geometry instead.
    private enum int showDesktopWidth = 16;
    private enum int clockRightPadding = 8; // gap between date/time and show-desktop
    private enum int clockWidth = 90;
    private enum int trayIconWidth = 34;
    private enum int trayIconGap = 4;
    private enum int fixedTrayCount = 4; // wifi, volume, battery, hidden chevron

    // Right edge of the fixed glyph block (start packing notifications left).
    private int fixedTrayLeftX() const @safe pure nothrow @nogc
    {
        return maxInt(0, clockRect().x -
            (fixedTrayCount * trayIconWidth +
                (fixedTrayCount - 1) * trayIconGap));
    }

    private int visibleNotificationCount() const @safe pure nothrow @nogc
    {
        int count;
        foreach (icon; _notifications)
            if (!icon.hidden) ++count;
        return count;
    }

    private int visibleNotificationWidth() const @safe pure nothrow @nogc
    {
        const count = visibleNotificationCount();
        return count == 0 ? 0 : count * trayIconWidth +
            (cast(int) count - 1) * trayIconGap;
    }

    /** One visible notification icon's local rect by visible-order index. */
    private Rect notificationIconRect(size_t visibleOrder) const
        @safe pure nothrow @nogc
    {
        int seen;
        foreach (icon; _notifications)
        {
            if (icon.hidden) continue;
            if (cast(size_t) seen == visibleOrder)
            {
                const x = fixedTrayLeftX() - visibleNotificationWidth() +
                    seen * (trayIconWidth + trayIconGap);
                return Rect(x, 0, trayIconWidth, bounds().height);
            }
            ++seen;
        }
        return Rect.init;
    }

    private Rect showDesktopRect() const @safe pure nothrow @nogc
    {
        if (!_modernShell)
            return Rect(maxInt(0, bounds().width - 7), 0, 7, bounds().height);
        return Rect(maxInt(0, bounds().width - showDesktopWidth), 0,
            showDesktopWidth, bounds().height);
    }

    private Rect clockRect() const @safe pure nothrow @nogc
    {
        if (!_modernShell)
            return Rect(maxInt(54, bounds().width - 94), 0, 84, bounds().height);
        // Inset the clock's right edge from the show-desktop strip so the date
        // and time do not visually merge with the show-desktop button.
        const right = showDesktopRect().x - clockRightPadding;
        return Rect(maxInt(0, right - clockWidth), 0, clockWidth, bounds().height);
    }

    private int trayLeftX() const @safe pure nothrow @nogc
    {
        if (!_modernShell) return clockRect().x;
        return fixedTrayLeftX() - visibleNotificationWidth();
    }

    private Rect trayRect() const @safe pure nothrow @nogc
    {
        return Rect(trayLeftX(), 0, maxInt(0, clockRect().x - trayLeftX()),
            bounds().height);
    }

    private Rect trayIconRect(int index) const @safe pure nothrow @nogc
    {
        const x = fixedTrayLeftX() + index * (trayIconWidth + trayIconGap);
        return Rect(x, 0, trayIconWidth, bounds().height);
    }

    private int trayIconHit(Point point) const @safe pure nothrow @nogc
    {
        if (!_modernShell) return -1;
        foreach (index; 0 .. 4)
            if (trayIconRect(index).contains(point)) return index;
        return -1;
    }

    /** Visible-order index of a notification icon at the point, or -1. */
    private int notificationHit(Point point) const @safe pure nothrow @nogc
    {
        if (!_modernShell) return -1;
        int seen;
        foreach (icon; _notifications)
        {
            if (icon.hidden) continue;
            if (notificationIconRect(cast(size_t) seen).contains(point))
                return seen;
            ++seen;
        }
        return -1;
    }

    /// How far (px) a notification must be dragged left before it hides.
    private enum int notificationDragHideDistance = 70;

    private void hideNotification(int visibleOrder)
    {
        int seen;
        foreach (ref icon; _notifications)
        {
            if (icon.hidden) continue;
            if (seen == visibleOrder)
            {
                icon.hidden = true;
                _tray.hiddenIconCount = hiddenNotificationCount();
                _pressed = -2;
                releaseMouse();
                invalidate();
                return;
            }
            ++seen;
        }
    }

    private Rect entriesRect() const @safe pure nothrow @nogc
    {
        return Rect(entriesStartX(), 0,
            maxInt(0, trayLeftX() - entriesStartX()), bounds().height);
    }

    // Icon-only task buttons (Windows-11 style): a fixed centered slot per
    // entry. Titles live in the model only (entryTitle) for accessibility and
    // tests; the bar itself never paints text.
    private enum int taskIconSlotWidth = 48;
    private enum int taskIconSize = 26;

    private int entryWidth() const @safe pure nothrow @nogc
    {
        if (_entries.length == 0) return 0;
        if (!_modernShell)
        {
            const available = maxInt(1, bounds().width - 158);
            return clampInt((available - maxInt(0, cast(int) _entries.length - 1) * 4) /
                cast(int) _entries.length, 90, 180);
        }
        return taskIconSlotWidth;
    }

    private Rect entryRect(int index) const @safe pure nothrow @nogc
    {
        const width = entryWidth();
        return Rect(entriesStartX() + index * (width + 4), 6, width,
            maxInt(1, bounds().height - 12));
    }

    // The dragged entry's in-row x: horizontal position follows the pointer
    // (offset by the original grab) but stays clamped to the taskbar's entry
    // track, so the icon never leaves the bar.
    private int draggedEntryX(Rect base) const @safe pure nothrow @nogc
    {
        const origin = preciseGlobalOrigin();
        double x = _dragPointerPosition.x - origin.x - _dragGrabOffset.x;
        const left = cast(double) entriesStartX();
        const right = cast(double) trayLeftX() - base.width;
        if (x < left) x = left;
        if (x > right) x = right;
        return cast(int) (x + 0.5);
    }

    private int hitEntry(Point point) const @safe pure nothrow @nogc
    {
        foreach (index, entry; _entries)
            if (entryRect(cast(int) index).contains(point)) return cast(int) index;
        return -1;
    }

    private void activateEntry(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length) return;
        auto entry = _entries[cast(size_t) index];
        if (entry.window !is null)
        {
            if (entry.window.visible() && _activeWindow is entry.window)
            {
                entry.window.minimize();
                _activeWindow = null;
            }
            else
            {
                entry.window.restore();
                _activeWindow = entry.window;
            }
            invalidate();
        }
        else if (entry.hostHwnd != 0)
        {
            // External OS window task: toggle via the host (activate+restore or
            // minimize). The host reports the window's visibility.
            const visible = onExternalVisible is null ? true :
                onExternalVisible(entry.hostHwnd);
            if (visible)
            {
                if (onExternalMinimize !is null)
                    onExternalMinimize(entry.hostHwnd);
                _activeWindow = null;
            }
            else
            {
                if (onExternalActivate !is null)
                    onExternalActivate(entry.hostHwnd, false);
                _activeWindow = null;
            }
        }
        else if (entry.command !is null)
        {
            entry.command();
        }
    }

    /// Activate the visible notification at the given visible-order index.
    private void activateNotification(int visibleOrder)
    {
        int seen;
        foreach (icon; _notifications)
        {
            if (icon.hidden) continue;
            if (seen == visibleOrder && icon.action !is null)
                icon.action();
            ++seen;
        }
    }

    private Widget rootWidget() @safe pure nothrow @nogc
    {
        Widget result = this;
        while (result.parent() !is null) result = result.parent();
        return result;
    }

    private bool beginTaskReorder(PointF pointer)
    {
        if (_entries.length < 2) return false;
        const modelIndex = indexOfEntry(_pressedEntryId);
        if (modelIndex < 0) return false;
        const rect = entryRect(modelIndex);
        const origin = preciseGlobalOrigin();
        _dragEntryId = _pressedEntryId;
        _dragOriginIndex = modelIndex;
        _dragCurrentIndex = modelIndex;
        // Start settled (no slide) so the entry under the grab doesn't warp.
        _reorderFromSlot = visualSlotsFor(modelIndex, modelIndex);
        _reorderToSlot = visualSlotsFor(modelIndex, modelIndex);
        _reorderAnim = 1.0;
        _reorderAnimActive = false;
        _dragGrabOffset = PointF(
            clampDouble(_pressPointer.x - origin.x - rect.x, 0.0, rect.width),
            clampDouble(_pressPointer.y - origin.y - rect.y, 0.0, rect.height));

        const entry = _entries[cast(size_t) modelIndex];
        const running = entry.window !is null && entry.window.visible();
        const active = running && entry.window is _activeWindow;
        // Keep the proxy object for the drag API/taskOrderValid contract, but
        // hide it: the dragged task is now repainted in the taskbar row itself,
        // so the floating copy is never shown.
        _dragProxy = new TaskDragProxy(entry.title, entry.icon, running, active,
            rect.width, rect.height);
        _dragProxy.setVisible(false);
        auto root = rootWidget();
        root.add(_dragProxy);
        root.bringChildToFront(_dragProxy);

        _reordering = true;
        _hot = -2;
        setCursor(CursorKind.move);
        // Capture again after _reordering becomes true. GuiWindow can now hide
        // the host cursor and late-latch both the Aurora cursor and this proxy.
        captureMouse();
        updateDragProxyPosition(pointer, true);
        invalidate();
        return true;
    }

    private bool updateDragProxyPosition(PointF pointer, bool requestFrame)
    {
        // The visible dragged task is painted in-row; the proxy is only a
        // hidden geometry holder. Position it at the dragged entry's in-row
        // rect so dragPreviewGlobalBounds reports a sane (on-taskbar) rect.
        if (_dragProxy is null || _dragProxy.parent() is null) return false;
        _dragPointerPosition = pointer;
        const draggedModelIndex = indexOfEntry(_dragEntryId);
        const rect = draggedModelIndex >= 0 ? entryRect(_dragCurrentIndex) :
            Rect(0, 0, _dragProxy.contentRect().width,
                _dragProxy.contentRect().height);
        const parentOrigin = _dragProxy.parent().preciseGlobalOrigin();
        const x = draggedModelIndex >= 0 ? draggedEntryX(rect) : rect.x;
        // The proxy includes taskDragProxyMargin padding around its content;
        // place it so the content sits on the in-row rect.
        return _dragProxy.setPrecisePosition(PointF(
            parentOrigin.x + x - taskDragProxyMargin,
            parentOrigin.y + rect.y - taskDragProxyMargin),
            requestFrame);
    }

    private int targetIndexFromPointer(PointF pointer) const
        @safe pure nothrow @nogc
    {
        if (!_reordering || _entries.length == 0) return -1;
        const width = entryWidth();
        const stride = cast(double) width + 4.0;
        if (width <= 0 || stride <= 0.0) return _dragCurrentIndex;

        const origin = preciseGlobalOrigin();
        const proxyCenter = pointer.x - origin.x - _dragGrabOffset.x +
            cast(double) width * 0.5;
        const firstCenter = cast(double) entriesStartX() +
            cast(double) width * 0.5;
        int target = clampInt(_dragCurrentIndex, 0,
            cast(int) _entries.length - 1);
        enum double hysteresis = 3.0;

        while (target + 1 < cast(int) _entries.length)
        {
            const boundary = firstCenter + (cast(double) target + 0.5) * stride;
            if (proxyCenter <= boundary + hysteresis) break;
            ++target;
        }
        while (target > 0)
        {
            const boundary = firstCenter + (cast(double) target - 0.5) * stride;
            if (proxyCenter >= boundary - hysteresis) break;
            --target;
        }
        return target;
    }

    private bool updateTaskReorder(PointF pointer, bool requestFrame)
    {
        if (!_reordering) return false;
        bool changed = updateDragProxyPosition(pointer, requestFrame);
        const target = targetIndexFromPointer(pointer);
        if (target >= 0 && target != _dragCurrentIndex)
        {
            const draggedModelIndex = indexOfEntry(_dragEntryId);
            // Restart the slide from the CURRENT (possibly mid-flight) layout
            // rather than the original, so rapid crossings chain smoothly.
            if (draggedModelIndex >= 0)
                _reorderFromSlot = visualSlotsFor(_dragCurrentIndex, draggedModelIndex);
            _dragCurrentIndex = target;
            if (draggedModelIndex >= 0)
                _reorderToSlot = visualSlotsFor(target, draggedModelIndex);
            _reorderAnim = 0.0;
            _reorderAnimActive = true;
            // Only a slot-boundary crossing rebuilds taskbar content. Every
            // in-slot pointer sample is a transform-only proxy update.
            invalidate();
            changed = true;
        }
        return changed;
    }

    private int visualSlotForEntry(int modelIndex) const
        @safe pure nothrow @nogc
    {
        if (!_reordering) return modelIndex;
        const draggedIndex = indexOfEntry(_dragEntryId);
        if (draggedIndex < 0) return modelIndex;
        if (modelIndex == draggedIndex) return _dragCurrentIndex;
        const reduced = modelIndex < draggedIndex ? modelIndex : modelIndex - 1;
        return reduced >= _dragCurrentIndex ? reduced + 1 : reduced;
    }

    // Visual slot for every non-dragged model index under a hypothetical
    // dragged slot. Used to snapshot the "from"/"to" layouts for the reorder
    // slide animation. -1 means the dragged entry (never painted in the row).
    private int[] visualSlotsFor(int draggedSlot, int draggedModelIndex) const
    {
        int[] slots;
        slots.length = _entries.length;
        foreach (modelIndex, _; _entries)
        {
            if (cast(int) modelIndex == draggedModelIndex)
            {
                slots[modelIndex] = -1;
                continue;
            }
            const reduced = modelIndex < draggedModelIndex ?
                cast(int) modelIndex : cast(int) modelIndex - 1;
            slots[modelIndex] = reduced >= draggedSlot ? reduced + 1 : reduced;
        }
        return slots;
    }

    private static double reorderEase(double t) @safe pure nothrow @nogc
    {
        // Ease-in-out so the neighbors first nudge toward the dragged task
        // (the "zone") then settle into the swapped slot.
        if (t <= 0.0) return 0.0;
        if (t >= 1.0) return 1.0;
        return t < 0.5 ? 2.0 * t * t : 1.0 - (-2.0 * t + 2.0) * (-2.0 * t + 2.0) / 2.0;
    }

    // Begin (or restart) the slide animation between the current
    // _dragCurrentIndex layout and `target`, snapshotting the from/to slots.
    private void beginReorderSlide(int target, int draggedModelIndex)
    {
        _reorderFromSlot = visualSlotsFor(_dragCurrentIndex, draggedModelIndex);
        _reorderToSlot = visualSlotsFor(target, draggedModelIndex);
        _reorderAnim = 0.0;
        _reorderAnimActive = true;
    }

    private void destroyDragProxy()
    {
        auto proxy = _dragProxy;
        _dragProxy = null;
        if (proxy !is null && proxy.parent() !is null)
            proxy.parent().remove(proxy);
    }

    private void paintTaskEntry(ref Canvas canvas, TaskEntry entry, Rect rect)
    {
        const palette = theme();
        // For external OS windows the live state comes from the host; for
        // in-shell windows it is the FloatingWindow's visibility + focus.
        bool externalVisible;
        if (entry.hostHwnd != 0 && onExternalVisible !is null)
            externalVisible = onExternalVisible(entry.hostHwnd);
        const active = entry.hostHwnd != 0 ?
            externalTaskFocusedState(entry.hostHwnd) :
            entry.window !is null && entry.window is _activeWindow &&
            entry.window.visible();
        const pressedId = stateEntryId(_pressed);
        const hotId = stateEntryId(_hot);
        const keyboardId = stateEntryId(_keyboardIndex);
        const highlighted = entry.id == pressedId || entry.id == hotId || active ||
            entry.id == keyboardId;
        if (highlighted)
            canvas.fillRoundedRect(rect, 5, active ? palette.taskbarHover :
                palette.taskbarHover.withAlpha(180));
        // Centered icon; the running indicator is a short underline.
        const iconX = rect.x + (rect.width - taskIconSize) / 2;
        const iconY = rect.y + (rect.height - taskIconSize) / 2 - 2;
        if (!_modernShell)
        {
            // Previous labeled look: icon at the left, title text, and a
            // full-width running indicator.
            drawIcon(canvas, entry.icon, Rect(rect.x + 8, rect.y + 7, 24, 24),
                Color.rgb(245, 248, 252), palette.accent);
            canvas.drawTextInRect(Rect(rect.x + 38, rect.y,
                    maxInt(0, rect.width - 44), rect.height), entry.title,
                Color.rgb(245, 248, 252), 1, HorizontalAlign.left,
                VerticalAlign.middle, true);
            const classicVisible = entry.hostHwnd != 0 ? externalVisible :
                entry.window !is null && entry.window.visible();
            if (classicVisible)
                canvas.fillRect(Rect(rect.x + 8, rect.bottom() - 3,
                    maxInt(1, rect.width - 16), active ? 3 : 2),
                    active ? palette.accent : palette.textMuted);
            return;
        }
        drawIcon(canvas, entry.icon,
            Rect(iconX, iconY, taskIconSize, taskIconSize),
            Color.rgb(245, 248, 252), palette.accent);
        const hasWindow = entry.window !is null || entry.hostHwnd != 0;
        if (hasWindow)
        {
            // Running indicator under the icon, with three tiers:
            //  - active (focused + visible): solid accent
            //  - running but unfocused: muted
            //  - minimized (window exists, not visible): dimmed/dotted
            const minimized = entry.hostHwnd != 0 ? !externalVisible :
                !entry.window.visible();
            const underlineWidth = 16;
            const underlineX = rect.x + (rect.width - underlineWidth) / 2;
            if (active)
                canvas.fillRect(Rect(underlineX, rect.bottom() - 4,
                    underlineWidth, 3), palette.accent);
            else if (minimized)
                canvas.fillRect(Rect(underlineX, rect.bottom() - 4,
                    underlineWidth, 2), palette.textMuted.withAlpha(90));
            else
                canvas.fillRect(Rect(underlineX, rect.bottom() - 4,
                    underlineWidth, 2), palette.textMuted);
        }
    }

    /// Whether an external OS window is the focused/foreground window.
    private bool externalTaskFocusedState(ulong hwnd) const
    {
        return onExternalFocused !is null && onExternalFocused(hwnd);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        const full = Rect(0, 0, bounds().width, bounds().height);
        canvas.fillRect(full, palette.taskbar);
        canvas.fillRect(Rect(0, 0, bounds().width, 1), Color.rgba(255, 255, 255, 35));

        const start = startRect();
        if (_pressed == -1 || _hot == -1 || _startMenuOpen)
            canvas.fillRoundedRect(start, 5, palette.taskbarHover);
        drawIcon(canvas, IconKind.start, start.inset(8), Color.rgb(245, 248, 252),
            palette.accent);

        if (_modernShell)
            paintSearchBox(canvas);

        // The dragged task stays on the taskbar: it is painted in-row at its
        // live slot. For every entry we ease from the previous boundary slot to
        // the current one; the dragged entry additionally glides toward the
        // pointer's x so it visibly pushes neighbors before they swap in place.
        foreach (index, entry; _entries)
        {
            const visualSlot = visualSlotForEntry(cast(int) index);
            if (visualSlot < 0) continue;
            const draggedModelIndex = indexOfEntry(_dragEntryId);
            const isDragged = _reordering && cast(int) index == draggedModelIndex;
            Rect rect = entryRect(visualSlot);
            // Slide-and-swap: during a reorder boundary transition, ease the
            // entries from their previous slot to the current one.
            if (_reorderAnimActive && _reorderFromSlot.length == _entries.length &&
                _reorderToSlot.length == _entries.length &&
                cast(size_t) index < _reorderFromSlot.length &&
                _reorderFromSlot[index] >= 0 && _reorderToSlot[index] >= 0)
            {
                const from = entryRect(_reorderFromSlot[index]);
                const to = entryRect(_reorderToSlot[index]);
                const t = reorderEase(_reorderAnim);
                const x = from.x + cast(int) ((to.x - from.x) * t + 0.5);
                rect.x = x;
            }
            if (isDragged)
            {
                // In-row lift: follow the pointer's x (clamped to the row),
                // never floating above the bar. A soft outline marks it as the
                // one being moved.
                rect.x = draggedEntryX(rect);
                rect.y = 6;
            }
            paintTaskEntry(canvas, entry, rect);
            if (isDragged)
                canvas.drawRoundedRect(rect.inset(1), 5, Color.rgba(0, 0, 0, 0),
                    palette.accent.withAlpha(210), 2);
        }

        if (_modernShell)
            paintTray(canvas);

        const clock = clockRect();
        if (_hot == -3) canvas.fillRect(clock, palette.taskbarHover.withAlpha(160));
        if (!_modernShell)
        {
            // Previous single-line clock, centered.
            canvas.drawTextInRect(clock, _clock, Color.rgb(245, 248, 252), 1,
                HorizontalAlign.center, VerticalAlign.middle, true);
        }
        else
        {
            // Two-line clock: time on the top line, date below, both centered.
            const clockInset = Rect(clock.x, clock.y + 4, clock.width,
                maxInt(1, clock.height - 8));
            canvas.drawTextInRect(Rect(clockInset.x, clockInset.y, clockInset.width,
                clockInset.height / 2), _clock, Color.rgb(245, 248, 252), 1,
                HorizontalAlign.center, VerticalAlign.middle, true);
            canvas.drawTextInRect(Rect(clockInset.x, clockInset.y + clockInset.height / 2,
                clockInset.width, clockInset.height / 2), _date,
                Color.rgb(245, 248, 252), 1, HorizontalAlign.center,
                VerticalAlign.middle, true);
        }

        const show = showDesktopRect();
        if (_hot == -4 || _showDesktopWindows.length > 0)
            canvas.fillRect(show, palette.accent.withAlpha(150));
        else
            canvas.fillRect(Rect(show.x, 5, 1, maxInt(0, show.height - 10)),
                Color.rgba(255, 255, 255, 90));
    }

    private void paintSearchBox(ref Canvas canvas)
    {
        const palette = theme();
        const search = searchRect();
        // The Windows-11 pill-style search box at the left of the centered apps.
        if (_pressed == -5 || _hot == -5)
            canvas.fillRoundedRect(search, 17, palette.taskbarHover);
        else
            canvas.fillRoundedRect(search, 17, palette.fieldBackground);
        const centerY = search.y + search.height / 2;
        drawIcon(canvas, IconKind.search,
            Rect(search.x + 10, centerY - 9, 18, 18), palette.textMuted, palette.accent);
        canvas.drawTextInRect(Rect(search.x + 36, search.y,
                maxInt(0, search.width - 42), search.height), "Search"d,
            palette.textMuted, 1, HorizontalAlign.left, VerticalAlign.middle, true);
    }

    private void paintTray(ref Canvas canvas)
    {
        const palette = theme();
        const trayLeft = fixedTrayLeftX();
        const iconSize = 18;
        const iconRect = Rect(trayLeft + (trayIconWidth - iconSize) / 2,
            (bounds().height - iconSize) / 2, iconSize, iconSize);

        // Visible notification cluster (left of the fixed glyphs).
        int seen;
        foreach (icon; _notifications)
        {
            if (icon.hidden) continue;
            const notifRect = notificationIconRect(cast(size_t) seen);
            // Hover code for notifications: -10.. (see onMouseMove).
            if (_hot == -(10 + seen))
                canvas.fillRoundedRect(notifRect, 5, palette.taskbarHover);
            const nicon = Rect(notifRect.x + (trayIconWidth - iconSize) / 2,
                (bounds().height - iconSize) / 2, iconSize, iconSize);
            drawIcon(canvas, icon.icon, nicon,
                Color.rgb(245, 248, 252), palette.accent);
            ++seen;
        }

        // 0: wifi, 1: volume, 2: battery, 3: hidden-icons chevron.
        // Hover codes are -6..-9 (see onMouseMove) so they never collide with
        // the 0..N task-entry index range.
        const wifiRect = trayIconRect(0);
        if (_hot == -6) canvas.fillRoundedRect(wifiRect, 5, palette.taskbarHover);
        drawIcon(canvas, IconKind.wifi, iconRect.translated(0, 0),
            Color.rgb(245, 248, 252), palette.accent);

        const volumeRect = trayIconRect(1);
        if (_hot == -7) canvas.fillRoundedRect(volumeRect, 5, palette.taskbarHover);
        drawIcon(canvas, _tray.volumeMuted ? IconKind.volumeMuted : IconKind.volume,
            iconRect.translated(trayIconWidth + trayIconGap, 0),
            Color.rgb(245, 248, 252), palette.accent);

        const batteryRect = trayIconRect(2);
        if (_hot == -8) canvas.fillRoundedRect(batteryRect, 5, palette.taskbarHover);
        if (_tray.hasBattery)
        {
            drawIcon(canvas,
                _tray.batteryCharging ? IconKind.batteryCharging : IconKind.battery,
                iconRect.translated((trayIconWidth + trayIconGap) * 2, 0),
                Color.rgb(245, 248, 252), palette.accent);
        }

        const hiddenRect = trayIconRect(3);
        if (_hot == -9) canvas.fillRoundedRect(hiddenRect, 5, palette.taskbarHover);
        drawIcon(canvas, IconKind.chevronUp,
            iconRect.translated((trayIconWidth + trayIconGap) * 3, 0),
            Color.rgb(245, 248, 252), palette.accent);
    }

    // --- Tooltip --------------------------------------------------------
    // Hovering a taskbar region for `tooltipDelaySeconds` shows a small label
    // above that region. The tooltip is a root-level composited widget (like
    // the drag proxy), so it can float above the taskbar without layout impact.

    private dstring tooltipForRegion(int code) const
    {
        if (code == -1) return "Start"d;
        if (code == -3) return "Date and time"d;
        if (code == -4) return _showDesktopWindows.length == 0 ?
            "Show desktop"d : "Restore windows"d;
        if (code == -5) return "Search"d;
        if (code >= -9 && code <= -6)
        {
            const tray = -6 - code; // 0 wifi, 1 volume, 2 battery, 3 hidden
            if (tray == 0) return "Wi-Fi"d;
            if (tray == 1) return "Volume"d;
            if (tray == 2) return "Battery"d;
            if (tray == 3) return "Hidden icons"d;
        }
        if (code <= -10)
        {
            const order = -10 - code;
            if (order >= 0 && order < notificationCountForTooltip())
                return notificationLabelForTooltip(order);
        }
        if (code >= 0 && code < cast(int) _entries.length)
        {
            const entry = _entries[cast(size_t) code];
            // Lead with the real task name, then a short action hint.
            const name = toUTF32(titleEntry(entry));
            if (entry.hostHwnd != 0)
            {
                const visible = onExternalVisible is null ? true :
                    onExternalVisible(entry.hostHwnd);
                return visible ? name ~ " — click to focus"d :
                    name ~ " — click to restore"d;
            }
            if (entry.window !is null)
            {
                if (entry.window.visible())
                {
                    if (entry.window is _activeWindow)
                        return name ~ " — click to minimize"d;
                    return toUTF32(titleEntry(entry) ~ " — click to focus");
                }
                return toUTF32(titleEntry(entry) ~ " — click to restore");
            }
            return name;
        }
        return null;
    }

    private static string titleEntry(const ref TaskEntry entry)
    {
        // Keep a plain UTF-8 label for the tooltip (entry.title is a dstring).
        import std.utf : toUTF8;
        return toUTF8(entry.title);
    }

    private Rect tooltipAnchorForRegion(int code) const
    {
        if (code == -1) return startRect();
        if (code == -3) return clockRect();
        if (code == -4) return showDesktopRect();
        if (code == -5) return searchRect();
        if (code >= -9 && code <= -6) return trayIconRect(-6 - code);
        if (code <= -10)
        {
            const order = -10 - code;
            if (order >= 0 && order < notificationCountForTooltip())
                return notificationIconRect(cast(size_t) order);
        }
        if (code >= 0 && code < cast(int) _entries.length)
            return entryRect(code);
        return Rect.init;
    }

    private int notificationCountForTooltip() const nothrow @nogc
    {
        int seen;
        foreach (icon; _notifications)
            if (!icon.hidden) ++seen;
        return seen;
    }

    private dstring notificationLabelForTooltip(int visibleOrder) const
    {
        int seen;
        foreach (icon; _notifications)
        {
            if (icon.hidden) continue;
            if (seen == visibleOrder) return icon.label;
            ++seen;
        }
        return null;
    }

    private void updateTooltip(int code)
    {
        // If the hovered region changed, reset the hover-timer. If it is a
        // region with no tooltip, clear any shown tooltip.
        if (code != _tooltipRegion)
        {
            const oldTask = _tooltipRegion >= 0;
            const newTask = code >= 0;
            if (oldTask && !newTask)
            {
                if (onTaskHoverLeave !is null) onTaskHoverLeave();
            }
            else if (newTask && !oldTask)
            {
                if (onTaskHover !is null) onTaskHover(code);
            }
            else if (newTask && oldTask)
            {
                // Moved directly from one task entry to another.
                if (onTaskHoverLeave !is null) onTaskHoverLeave();
                if (onTaskHover !is null) onTaskHover(code);
            }
            _tooltipRegion = code;
            _tooltipHoverSeconds = 0.0;
            _tooltip = destroyTooltip();
            // No further action: the timer accumulates while the pointer stays.
        }
    }

    private TaskbarTooltip destroyTooltip()
    {
        auto tip = _tooltip;
        _tooltip = null;
        if (tip !is null && tip.parent() !is null)
            tip.parent().remove(tip);
        return null;
    }

    private void advanceTooltip(double deltaSeconds)
    {
        if (_tooltipRegion == -2) return;
        _tooltipHoverSeconds += deltaSeconds;
        const text = tooltipForRegion(_tooltipRegion);
        if (text is null || text.length == 0)
        {
            _tooltipHoverSeconds = 0.0;
            _tooltip = destroyTooltip();
            return;
        }
        if (_tooltipHoverSeconds < tooltipDelaySeconds) return;

        if (_tooltip is null)
        {
            _tooltip = new TaskbarTooltip(text);
            auto root = rootWidget();
            root.add(_tooltip);
            root.bringChildToFront(_tooltip);
        }
        else
            _tooltip.setText(text);

        // Position above the anchored region, centered horizontally, clamped to
        // the root so it never goes off the top/left/right.
        auto anchor = tooltipAnchorForRegion(_tooltipRegion);
        const origin = preciseGlobalOrigin();
        anchor = Rect(cast(int) (origin.x + anchor.x),
            cast(int) (origin.y + anchor.y), anchor.width, anchor.height);
        const root = rootWidget();
        const rootRect = Rect(0, 0, root.bounds().width, root.bounds().height);
        const tip = _tooltip.bounds();
        int x = anchor.x + (anchor.width - tip.width) / 2;
        int y = anchor.y - tip.height - 6;
        x = clampInt(x, 4, maxInt(4, rootRect.width - tip.width - 4));
        if (y < 4) y = anchor.bottom() + 6;
        const taskbarRootOrigin = root.preciseGlobalOrigin();
        _tooltip.setPrecisePosition(PointF(
            x - taskbarRootOrigin.x, y - taskbarRootOrigin.y), true);
    }

    // Hide the tooltip when the pointer leaves the taskbar or a gesture begins.
    private void hideTooltip()
    {
        if (_tooltipRegion >= 0)
        {
            if (onTaskHoverLeave !is null) onTaskHoverLeave();
        }
        _tooltip = destroyTooltip();
        _tooltipRegion = -2;
        _tooltipHoverSeconds = 0.0;
    }

    override bool onMouseDown(ref Event event)
    {
        hideTooltip();
        if (event.button == MouseButton.right)
        {
            requestFocus();
            const notif = notificationHit(event.position);
            if (notif >= 0)
            {
                showNotificationContextMenu(notif, event.globalPosition);
                return true;
            }
            const entry = hitEntry(event.position);
            if (entry >= 0) showEntryContextMenu(entry, event.globalPosition);
            else if (startRect().contains(event.position))
                showStartContextMenu(event.globalPosition);
            else if (clockRect().contains(event.position))
                showClockContextMenu(event.globalPosition);
            else
                showTaskbarContextMenu(event.globalPosition);
            return true;
        }
        if (event.button != MouseButton.left) return false;
        requestFocus();
        if (_reordering || _dragProxy !is null) cancelTaskReorder();
        _reordering = false;
        _pressedEntryId = invalidTaskEntryId;
        _dragEntryId = invalidTaskEntryId;
        _dragOriginIndex = -1;
        _dragCurrentIndex = -1;
        _dragGrabOffset = PointF.init;
        _dragPointerPosition = PointF.init;
        _pressPointer = pointerPosition(event);
        if (startRect().contains(event.position)) _pressed = -1;
        else if (showDesktopRect().contains(event.position)) _pressed = -4;
        else if (clockRect().contains(event.position)) _pressed = -3;
        else if (searchRect().contains(event.position)) _pressed = -5;
        else if (trayIconHit(event.position) >= 0) _pressed = 100 + trayIconHit(event.position);
        else if (notificationHit(event.position) >= 0) _pressed = 200 + notificationHit(event.position);
        else _pressed = hitEntry(event.position);
        if (_pressed >= 0 && _pressed < 100)
            _pressedEntryId = _entries[cast(size_t) _pressed].id;
        if (_pressed >= -1 || _pressed == -3 || _pressed == -4 ||
            _pressed == -5 || _pressed >= 100)
        {
            captureMouse();
            invalidate();
            return true;
        }
        return false;
    }

    override bool onMouseMove(ref Event event)
    {
        if (_pressed >= 200)
        {
            // Drag a visible notification far enough and it moves into the
            // overflow (hides). Windows lets you drag a tray icon away from the
            // cluster; we hide it past the entry area.
            const pointer = pointerPosition(event);
            const dx = pointer.x - _pressPointer.x;
            const pressedNotif = _pressed - 200;
            if (dx <= -notificationDragHideDistance)
                hideNotification(pressedNotif);
            return true;
        }
        if (_pressed >= 0 && _pressed < 100)
        {
            const pointer = pointerPosition(event);
            if (!_reordering)
            {
                const dx = pointer.x - _pressPointer.x;
                const dy = pointer.y - _pressPointer.y;
                if (dx * dx + dy * dy >= 25.0)
                    beginTaskReorder(pointer);
            }
            if (_reordering) updateTaskReorder(pointer, true);
            return true;
        }
        if (_pressed == -1 || _pressed == -3 || _pressed == -4 ||
            _pressed == -5 || _pressed >= 100)
            return true;
        int hot;
        if (startRect().contains(event.position)) hot = -1;
        else if (showDesktopRect().contains(event.position)) hot = -4;
        else if (clockRect().contains(event.position)) hot = -3;
        else if (searchRect().contains(event.position)) hot = -5;
        else if (notificationHit(event.position) >= 0)
            hot = -(10 + notificationHit(event.position));
        else if (trayIconHit(event.position) >= 0)
            // Distinct negative codes (-6..-9) so a tray hover can never be
            // mistaken for a task-entry index (0..N); otherwise the first few
            // entries also highlight when the pointer is over a tray icon.
            hot = -6 - trayIconHit(event.position);
        else
        {
            // hitEntry returns -1 for empty space, which is ALSO the start
            // button's code - so an empty hover lit the start button. Map it
            // to the true "no hit" sentinel (-2) instead.
            const entry = hitEntry(event.position);
            hot = entry >= 0 ? entry : -2;
        }
        if (_hot != hot)
        {
            _hot = hot;
            invalidate();
        }
        updateTooltip(hot);
        return true;
    }

    protected override void onMouseLeave()
    {
        if (_pressed == -2 && _hot != -2)
        {
            _hot = -2;
            invalidate();
        }
        hideTooltip();
    }

    protected override void onHostFocusChanged(bool focused)
    {
        if (!focused)
        {
            if (_reordering || _pressed != -2)
                cancelTaskReorder();
            hideTooltip();
        }
    }

    protected override void onBoundsChanged()
    {
        if (_reordering) cancelTaskReorder();
        hideTooltip();
    }

    override bool onPointerLatch(PointF globalPosition)
    {
        return _reordering ? updateTaskReorder(globalPosition, false) : false;
    }

    override bool wantsContinuousPointerFrames() const @safe pure nothrow @nogc
    {
        return _reordering;
    }

    private void cancelTaskReorder()
    {
        destroyDragProxy();
        _pressed = -2;
        _pressedEntryId = invalidTaskEntryId;
        _hot = -2;
        _reordering = false;
        _dragEntryId = invalidTaskEntryId;
        _dragOriginIndex = -1;
        _dragCurrentIndex = -1;
        _reorderAnim = 1.0;
        _reorderAnimActive = false;
        _reorderFromSlot.length = 0;
        _reorderToSlot.length = 0;
        _dragGrabOffset = PointF.init;
        _dragPointerPosition = PointF.init;
        releaseMouse();
        setCursor(CursorKind.arrow);
        invalidate();
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || _pressed == -2) return false;
        const pressed = _pressed;
        const pressedEntryId = _pressedEntryId;
        const wasReordering = _reordering;
        const originalIndex = _dragOriginIndex;
        const draggedId = _dragEntryId;
        int finalIndex = -1;
        bool orderChanged;
        if (wasReordering)
        {
            updateTaskReorder(pointerPosition(event), true);
            finalIndex = _dragCurrentIndex;
            if (originalIndex >= 0 && finalIndex >= 0 &&
                originalIndex != finalIndex)
                orderChanged = moveEntryInternal(originalIndex, finalIndex, false);
            finalIndex = indexOfEntry(draggedId);
        }
        destroyDragProxy();
        _pressed = -2;
        _pressedEntryId = invalidTaskEntryId;
        _reordering = false;
        _dragEntryId = invalidTaskEntryId;
        _dragOriginIndex = -1;
        _dragCurrentIndex = -1;
        _reorderAnim = 1.0;
        _reorderAnimActive = false;
        _reorderFromSlot.length = 0;
        _reorderToSlot.length = 0;
        _dragGrabOffset = PointF.init;
        _dragPointerPosition = PointF.init;
        releaseMouse();
        setCursor(CursorKind.arrow);
        invalidate();
        if (wasReordering)
        {
            if (orderChanged)
            {
                if (onEntryMoved !is null) onEntryMoved(originalIndex, finalIndex);
                notifyEntryOrderChanged();
            }
            debug assert(taskOrderValid());
            return true;
        }
        if (pressed == -1)
        {
            if (startRect().contains(event.position) && onStart !is null) onStart();
            return true;
        }
        if (pressed == -4)
        {
            if (showDesktopRect().contains(event.position)) toggleShowDesktop();
            return true;
        }
        if (pressed == -3)
        {
            if (clockRect().contains(event.position) && onDateTimeSettings !is null)
                onDateTimeSettings();
            return true;
        }
        if (pressed == -5)
        {
            if (searchRect().contains(event.position) && onSearchClick !is null)
                onSearchClick();
            return true;
        }
        if (pressed >= 200)
        {
            const notifOrder = pressed - 200;
            if (notificationHit(event.position) == notifOrder)
                activateNotification(notifOrder);
            return true;
        }
        if (pressed >= 100)
        {
            const trayIcon = pressed - 100;
            if (trayIconHit(event.position) == trayIcon)
            {
                switch (trayIcon)
                {
                    case 0:
                        if (onWifiClick !is null) onWifiClick();
                        break;
                    case 1:
                        if (onVolumeClick !is null) onVolumeClick();
                        else if (onVolumeToggle !is null) onVolumeToggle();
                        break;
                    case 2:
                        if (onBatteryClick !is null) onBatteryClick();
                        else if (onVolumeChanged !is null) onVolumeChanged();
                        break;
                    case 3:
                        if (onHiddenIconsClick !is null) onHiddenIconsClick();
                        break;
                    default:
                        break;
                }
            }
            return true;
        }
        if (pressed >= 0)
        {
            const current = indexOfEntry(pressedEntryId);
            if (current >= 0 && entryRect(current).contains(event.position))
            {
                _keyboardIndex = current;
                activateEntry(current);
            }
        }
        return true;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (_entries.length == 0 || event.wheelY == 0) return false;
        int start = _activeWindow is null ? -1 : indexOfWindow(_activeWindow);
        const direction = event.wheelY > 0 ? -1 : 1;
        foreach (_; 0 .. _entries.length)
        {
            start += direction;
            if (start < 0) start = cast(int) _entries.length - 1;
            if (start >= cast(int) _entries.length) start = 0;
            if (_entries[cast(size_t) start].window !is null)
            {
                _keyboardIndex = start;
                activateEntry(start);
                return true;
            }
        }
        return false;
    }

    override bool onKeyDown(ref Event event)
    {
        if (_reordering && event.key == Key.escape)
        {
            cancelTaskReorder();
            return true;
        }
        if (_entries.length == 0)
        {
            if (event.key == Key.enter && onStart !is null)
            {
                onStart();
                return true;
            }
            return false;
        }
        switch (event.key)
        {
            case Key.left:
                _keyboardIndex = _keyboardIndex <= 0 ? cast(int) _entries.length - 1 :
                    _keyboardIndex - 1;
                invalidate();
                return true;
            case Key.right:
                _keyboardIndex = _keyboardIndex < 0 ||
                    _keyboardIndex + 1 >= cast(int) _entries.length ? 0 :
                    _keyboardIndex + 1;
                invalidate();
                return true;
            case Key.enter:
            case Key.space:
                if (_keyboardIndex >= 0) activateEntry(_keyboardIndex);
                else if (onStart !is null) onStart();
                return true;
            case Key.f10:
                if (event.shift())
                {
                    if (_keyboardIndex >= 0)
                    {
                        const rect = entryRect(_keyboardIndex);
                        showEntryContextMenu(_keyboardIndex,
                            localToGlobal(Point(rect.x + rect.width / 2, rect.y)));
                    }
                    else
                        showTaskbarContextMenu(localToGlobal(Point(60, 0)));
                    return true;
                }
                return false;
            default:
                return false;
        }
    }

    /// Right-click a visible notification icon: open it / hide it. The app
    /// provides per-icon custom menus via `showMenu` when present.
    private void showNotificationContextMenu(int visibleOrder, Point globalPosition)
    {
        int seen;
        foreach (icon; _notifications)
        {
            if (icon.hidden) continue;
            if (seen == visibleOrder)
            {
                if (icon.showMenu !is null)
                {
                    icon.showMenu();
                    return;
                }
                ContextMenuItem[] items;
                items ~= ContextMenuItem.command(toUTF8(icon.label.length > 0 ?
                    icon.label : "Open"), icon.icon, delegate() { activateNotification(visibleOrder); });
                items ~= ContextMenuItem.separatorItem();
                items ~= ContextMenuItem.command("Hide icon", IconKind.minimize,
                    delegate() { setNotificationHidden(icon.id, true); });
                showContextMenu(this, globalPosition, items);
                return;
            }
            ++seen;
        }
    }

    private void showEntryContextMenu(int index, Point globalPosition)
    {
        if (index < 0 || index >= cast(int) _entries.length) return;
        const id = _entries[cast(size_t) index].id;
        auto entry = _entries[cast(size_t) index];
        ContextMenuItem[] items;
        if (entry.hostHwnd != 0)
        {
            // External OS window: route actions to the host (activate/minimize/
            // close). The host reports live visibility.
            const hwnd = entry.hostHwnd;
            const visible = onExternalVisible is null ? true :
                onExternalVisible(hwnd);
            items ~= ContextMenuItem.command("Open", IconKind.open,
                delegate()
                {
                    if (onExternalActivate !is null)
                        onExternalActivate(hwnd, false);
                });
            items ~= ContextMenuItem.command("Minimize", IconKind.minimize,
                delegate()
                {
                    if (onExternalMinimize !is null)
                        onExternalMinimize(hwnd);
                }, "", visible);
            items ~= ContextMenuItem.separatorItem();
            items ~= ContextMenuItem.command("Close window", IconKind.close,
                delegate()
                {
                    if (onExternalClose !is null) onExternalClose(hwnd);
                }, "Alt+F4");
        }
        else if (entry.window !is null)
        {
            auto window = entry.window;
            items ~= ContextMenuItem.command("Restore", IconKind.open,
                delegate()
                {
                    window.restore();
                    setActiveWindow(window);
                }, "", !window.visible());
            items ~= ContextMenuItem.command("Minimize", IconKind.minimize,
                delegate()
                {
                    window.minimize();
                    if (_activeWindow is window) setActiveWindow(null);
                }, "", window.visible());
            items ~= ContextMenuItem.command(window.maximized() ? "Restore down" : "Maximize",
                IconKind.maximize, delegate()
                {
                    window.toggleMaximize();
                    setActiveWindow(window);
                });
            items ~= ContextMenuItem.separatorItem();
            items ~= ContextMenuItem.command("Close window", IconKind.close,
                delegate() { window.closeWindow(); }, "Alt+F4");
        }
        else
        {
            items ~= ContextMenuItem.command("Open", entry.icon,
                delegate()
                {
                    const current = indexOfEntry(id);
                    if (current >= 0) activateEntry(current);
                });
            items ~= ContextMenuItem.separatorItem();
        }
        items ~= ContextMenuItem.command("Move left", IconKind.none,
            delegate()
            {
                const current = indexOfEntry(id);
                if (current > 0) moveEntryInternal(current, current - 1, true);
            }, "", index > 0);
        items ~= ContextMenuItem.command("Move right", IconKind.chevronRight,
            delegate()
            {
                const current = indexOfEntry(id);
                if (current >= 0 && current + 1 < cast(int) _entries.length)
                    moveEntryInternal(current, current + 1, true);
            }, "", index + 1 < cast(int) _entries.length);
        if (entry.window is null && entry.hostHwnd == 0)
        {
            items ~= ContextMenuItem.separatorItem();
            items ~= ContextMenuItem.command("Remove from taskbar", IconKind.close,
                delegate() { removeEntry(id); });
        }
        showContextMenu(this, globalPosition, items);
    }

    private void showStartContextMenu(Point globalPosition)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Open Start", IconKind.start,
            delegate() { if (onStart !is null) onStart(); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Taskbar settings", IconKind.settings,
            delegate()
            {
                if (onTaskbarSettings !is null) onTaskbarSettings();
            }, "", onTaskbarSettings !is null);
        showContextMenu(this, globalPosition, items);
    }

    private void showClockContextMenu(Point globalPosition)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("Adjust date and time", IconKind.clock,
            delegate()
            {
                if (onDateTimeSettings !is null) onDateTimeSettings();
            }, "", onDateTimeSettings !is null);
        showContextMenu(this, globalPosition, items);
    }

    private void showTaskbarContextMenu(Point globalPosition)
    {
        ContextMenuItem[] items;
        items ~= ContextMenuItem.command(_showDesktopWindows.length == 0 ?
                "Show desktop" : "Restore windows", IconKind.computer,
            delegate() { toggleShowDesktop(); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Full screen", IconKind.maximize,
            delegate()
            {
                if (onToggleFullscreen !is null) onToggleFullscreen();
            }, "F11", onToggleFullscreen !is null);
        items ~= ContextMenuItem.command("Taskbar settings", IconKind.settings,
            delegate()
            {
                if (onTaskbarSettings !is null) onTaskbarSettings();
            }, "", onTaskbarSettings !is null);
        showContextMenu(this, globalPosition, items);
    }

    protected override void onTick(double deltaSeconds)
    {
        _clockAccumulator += deltaSeconds;
        if (_clockAccumulator >= 1.0)
        {
            _clockAccumulator = 0.0;
            updateClock();
        }
        if (_reorderAnimActive)
        {
            _reorderAnim += deltaSeconds / reorderAnimSeconds;
            if (_reorderAnim >= 1.0)
            {
                _reorderAnim = 1.0;
                _reorderAnimActive = false;
                _reorderFromSlot.length = 0;
                _reorderToSlot.length = 0;
            }
            invalidate();
        }
        advanceTooltip(deltaSeconds);
    }

    private void updateClock()
    {
        time_t raw;
        time(&raw);
        auto info = localtime(&raw);
        if (info !is null)
        {
            if (_clockHour == info.tm_hour && _clockMinute == info.tm_min &&
                _clockDay == info.tm_mday && _clockMonth == info.tm_mon &&
                _clockYear == info.tm_year)
            {
                return;
            }
            _clockHour = info.tm_hour;
            _clockMinute = info.tm_min;
            _clockDay = info.tm_mday;
            _clockMonth = info.tm_mon;
            _clockYear = info.tm_year;
            _clock = toUTF32(format("%02d:%02d", info.tm_hour, info.tm_min));
            _date = formatDate(info);
        }
        else
        {
            if (_clock == "--:--"d) return;
            _clockHour = -1;
            _clockMinute = -1;
            _clockDay = -1;
            _clockMonth = -1;
            _clockYear = -1;
            _clock = "--:--"d;
            _date = "--"d;
        }
        invalidate();
    }

    // Produces a Windows-11 style "M/D/YYYY" date line from a localtime struct.
    private static dstring formatDate(const tm* info) @safe
    {
        // tm_mon is 0-based; tm_year is years since 1900.
        return toUTF32(format("%d/%d/%d", info.tm_mon + 1, info.tm_mday,
            info.tm_year + 1900));
    }

    private static PointF pointerPosition(ref Event event)
        @safe pure nothrow @nogc
    {
        return event.hasPrecisePosition ? event.preciseGlobalPosition :
            PointF(event.globalPosition);
    }
}

unittest
{
    auto desktop = new DesktopSurface();
    desktop.setBounds(Rect(0, 0, 800, 600));

    auto firstIcon = desktop.addIcon("One", IconKind.file);
    auto secondIcon = desktop.addIcon("Two", IconKind.folder);
    desktop.setAlignToGrid(false);
    Event iconDown;
    iconDown.button = MouseButton.left;
    iconDown.position = Point(20, 20);
    iconDown.globalPosition = firstIcon.localToGlobal(iconDown.position);
    assert(firstIcon.onMouseDown(iconDown));
    Event iconMove;
    iconMove.position = Point(40, 40);
    iconMove.globalPosition = Point(iconDown.globalPosition.x + 140,
        iconDown.globalPosition.y + 80);
    assert(firstIcon.onMouseMove(iconMove));
    assert(firstIcon.dragging());
    Event iconUp;
    iconUp.button = MouseButton.left;
    iconUp.position = Point(40, 40);
    iconUp.globalPosition = iconMove.globalPosition;
    assert(firstIcon.onMouseUp(iconUp));
    assert(firstIcon.bounds().x > 100 && firstIcon.bounds().y > 60);
    assert(secondIcon.parent() is desktop);

    auto floating = desktop.addWindow(
        new FloatingWindow("Test", IconKind.file, new WidgetTestPanel()));
    const original = Rect(40, 50, 320, 220);
    floating.setBounds(original);

    Event down;
    down.button = MouseButton.left;
    down.position = Point(24, 12);
    down.globalPosition = Point(64, 62);
    assert(floating.onMouseDown(down));
    Event move;
    move.globalPosition = Point(104, 92);
    assert(floating.onMouseMove(move));
    assert(floating.bounds() == Rect(80, 80, 320, 220));
    Event up;
    up.button = MouseButton.left;
    assert(floating.onMouseUp(up));
    floating.setBounds(original);

    bool minimized;
    bool restored;
    bool closed;
    floating.onMinimized = delegate(FloatingWindow) { minimized = true; };
    floating.onRestored = delegate(FloatingWindow) { restored = true; };
    floating.onClosed = delegate(FloatingWindow) { closed = true; };

    floating.toggleMaximize();
    assert(floating.maximized());
    assert(floating.bounds() == Rect(0, 0, 800, 600));
    floating.toggleMaximize();
    assert(!floating.maximized());
    assert(floating.bounds() == original);

    floating.minimize();
    assert(minimized && !floating.visible());
    floating.restore();
    assert(restored && floating.visible());

    auto taskbar = new Taskbar();
    taskbar.setBounds(Rect(0, 0, 800, 52));
    taskbar.addCommand("One", IconKind.file, delegate() {});
    taskbar.addCommand("Two", IconKind.folder, delegate() {});
    taskbar.addCommand("Three", IconKind.terminal, delegate() {});
    assert(taskbar.moveEntry(0, 2));
    assert(taskbar.entryTitle(2) == "One"d);
    assert(taskbar.moveEntry(2, 0));
    assert(taskbar.entryTitle(0) == "One"d);

    taskbar.addWindow(floating, "Test", IconKind.file);
    const trackedCount = taskbar.entryCount();
    taskbar.addWindow(floating, "Renamed", IconKind.notepad);
    assert(taskbar.entryCount() == trackedCount);
    const floatingIndex = taskbar.indexOfWindow(floating);
    assert(floatingIndex >= 0);
    assert(taskbar.entryTitle(cast(size_t) floatingIndex) == "Renamed"d);
    assert(taskbar.entryWindow(cast(size_t) floatingIndex) is floating);
    assert(taskbar.entryIcon(cast(size_t) floatingIndex) == IconKind.notepad);
    taskbar.setActiveWindow(floating);
    taskbar.showDesktop();
    assert(!floating.visible() && taskbar.activeWindow() is null);
    taskbar.restoreDesktop();
    assert(floating.visible() && taskbar.activeWindow() is floating);
    assert(taskbar.removeWindow(floating));
    assert(taskbar.indexOfWindow(floating) < 0);

    floating.closeWindow();
    assert(closed && floating.parent() is null);
}

private final class WidgetTestPanel : Widget
{
}
