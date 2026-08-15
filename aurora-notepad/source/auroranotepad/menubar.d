module auroranotepad.menubar;

import aurora;

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
        layoutHints().preferredHeight = 30;
        const dtext = text();
        if (dtext.length == 0)
        {
            layoutHints().preferredWidth = 30;
            return;
        }
        TextLayoutOptions options;
        options.role = FontRole.ui;
        options.overrideFace = cast() theme().uiFont;
        options.pixelSize = fontPixelSize(theme().fontScale);
        options.wrap = false;
        const measured = fontSystem().textEngine.layout(dtext, options).measuredSize();
        layoutHints().preferredWidth = maxInt(30, cast(int) measured.width + 20);
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
    private int _barHeight = 30;

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
        int x = 8;
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
        // The Win32 menu bar is separated from the content by a hairline.
        canvas.fillRect(Rect(0, bounds().height - 1, bounds().width, 1),
            theme().border);
    }
}
