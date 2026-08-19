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
    this(string label, ContextMenuItem[] items)
    {
        super(label);
        setFlat(true);
        setTextPixelSize(NotepadMenuFontPixelSize);
        applyMenuSizing();
        onClick = delegate() { showContextMenuBelow(this, items); };
    }

    override void setText(string value)
    {
        super.setText(value);
        applyMenuSizing();
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
        // the text is centered horizontally within the item.
        const palette = theme();
        const background = pressed() ? palette.buttonPressed :
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
        auto item = new MenuBarItem(label, items);
        add(item);
        invalidate();
        return item;
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
