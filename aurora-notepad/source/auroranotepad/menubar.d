module auroranotepad.menubar;

import aurora;
import auroranotepad.notepadsize : NotepadMenuBarHeight,
    NotepadMenuFontPixelSize;

/**
 * A Windows-10-Notepad-style menu item: one flat text label that opens its
 * dropdown `ContextMenu` directly below itself.
 */
final class MenuBarItem : Button
{
    this(string label, ContextMenuItem[] items, MenuBar ownerBar = null)
    {
        super(label);
        setFlat(true);
        setTextPixelSize(NotepadMenuFontPixelSize);
        applyMenuSizing();
        _items = items;
        _ownerBar = ownerBar;
        // Native Windows 10 menu bar items keep the arrow cursor (no hand).
        setCursor(CursorKind.arrow);
    }

    private ContextMenuItem[] _items;
    private MenuBar _ownerBar;
    private bool _menuOpen;

    override void setText(string value)
    {
        super.setText(value);
        applyMenuSizing();
    }

    override bool onMouseDown(ref Event event)
    {
        if (!enabled() || event.button != MouseButton.left) return false;
        // Native Windows 10 menus open on PRESS, not release. Opening here
        // removes the perceived half-frame delay of firing onClick on mouse-up.
        // Keep a mild highlight on this item while its dropdown stays open.
        _menuOpen = true;
        invalidate();
        auto popup = showContextMenuBelow(this, _items);
        if (popup !is null)
        {
            // Forward hovers over the menu bar so moving to another item
            // switches the open dropdown (native Windows behavior).
            popup.onMouseMoveOutside = delegate(Point localPosition) {
                if (_ownerBar !is null)
                    _ownerBar.handleMenuHover(this, popup, localPosition);
                return true;
            };
            popup.onDismissed = delegate() { _menuOpen = false; invalidate(); };
        }
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        return true;
    }

    /** Called by the menu bar when another item's dropdown forwards a hover. */
    void openMenuOnHover()
    {
        if (_menuOpen) return;
        // Reuse the press-open path so the highlight and hover forwarding wire
        // up exactly as a real click.
        Event press;
        press.button = MouseButton.left;
        onMouseDown(press);
    }

    bool isMenuOpen() const @safe pure nothrow @nogc { return _menuOpen; }

    bool containsGlobal(Point globalPoint) const @safe pure nothrow @nogc
    {
        const origin = globalOrigin();
        const local = Point(globalPoint.x - origin.x, globalPoint.y - origin.y);
        return local.x >= 0 && local.y >= 0 &&
            local.x < bounds().width && local.y < bounds().height;
    }

    protected override void onMouseEnter()
    {
        // With a dropdown open elsewhere, hovering this item switches to its
        // menu (the popup forwards the move through onMouseMoveOutside).
        if (_ownerBar !is null && _ownerBar.anyMenuOpen())
            openMenuOnHover();
        super.onMouseEnter();
    }

    private void applyMenuSizing()
    {
        layoutHints().preferredHeight = NotepadMenuBarHeight;
        const dtext = text();
        if (dtext.length == 0)
        {
            layoutHints().preferredWidth = 30;
            return;
        }
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() theme().uiFont;
        options.pixelSize = NotepadMenuFontPixelSize;
        options.wrap = false;
        const measured = fontSystem().textEngine.layout(dtext, options).measuredSize();
        layoutHints().preferredWidth = maxInt(30, cast(int) measured.width + 20);
    }

    protected override void onPaint(ref Canvas canvas)
    {
        // Flat Win10 menu item: hover/pressed tint fills the whole bar, and
        // the text is centered horizontally within the item. While the item's
        // dropdown is open it keeps a milder highlight (softer than hover).
        const palette = theme();
        Color background;
        if (_menuOpen)
            background = palette.buttonHover.mixed(Color.rgb(255, 255, 255), 0.45);
        else
            background = pressed() ? palette.buttonPressed :
                (hovered() ? palette.buttonHover : Color.rgba(0, 0, 0, 0));
        if (background.a != 0)
            canvas.fillRect(Rect(0, 0, bounds().width, bounds().height), background);

        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() palette.uiFont;
        options.pixelSize = NotepadMenuFontPixelSize;
        options.wrap = false;
        auto layout = fontSystem().textEngine.layoutCached(text(), options);
        const measured = layout.measuredSize();
        const x = maxInt(0, (bounds().width - measured.width) / 2);
        const y = maxInt(0, (bounds().height - measured.height) / 2);
        canvas.drawLayout(Point(x, y), layout, palette.text);
    }
}

/**
 * The classic Windows-10 Notepad menu bar: a horizontal row of flat text items
 * (File, Edit, Format, View, Help) that open dropdown menus. The bar sits on
 * the window background and is separated from the content by a one-pixel
 * hairline, exactly like the Win32 menu bar.
 */
final class MenuBar : Widget
{
    private int _barHeight = NotepadMenuBarHeight;

    this()
    {
    }

    MenuBarItem addItem(string label, ContextMenuItem[] items)
    {
        auto item = new MenuBarItem(label, items, this);
        add(item);
        invalidate();
        return item;
    }

    /// True when any item's dropdown is currently open.
    bool anyMenuOpen()
    {
        foreach (child; children())
            if (auto item = cast(MenuBarItem) child)
                if (item.isMenuOpen()) return true;
        return false;
    }

    /**
     * Forwarded by the open dropdown's onMouseMoveOutside when the pointer is
     * over this menu bar. Hovering another top-level item switches the open
     * dropdown to that item, exactly like native Windows menus.
     */
    void handleMenuHover(MenuBarItem current, ContextMenu popup, Point localPosition)
    {
        // Convert the popup-local position to a root/window position, then
        // find which top-level item it lies over.
        const globalPoint = popup.localToGlobal(localPosition);
        foreach (child; children())
        {
            auto item = cast(MenuBarItem) child;
            if (item is null || item is current) continue;
            if (item.containsGlobal(globalPoint))
            {
                item.openMenuOnHover();
                return;
            }
        }
    }

    protected override Size onMeasure(Size available)
    {
        return Size(available.width, _barHeight);
    }

    protected override void onLayout()
    {
        int x = 0;
        const height = bounds().height;
        foreach (child; children())
        {
            const width = maxInt(1, child.layoutHints().preferredWidth);
            child.setBounds(Rect(x, 0, width, height));
            x += width;
        }
    }

    protected override void onPaint(ref Canvas canvas)
    {
        // Light-gray hairline separating the menu bar from the content,
        // matching the Win32 menu bar's bottom edge on Windows 10.
        canvas.fillRect(Rect(0, bounds().height - 1, bounds().width, 1),
            Color.fromHex(0xd6d6d6));
    }
}
