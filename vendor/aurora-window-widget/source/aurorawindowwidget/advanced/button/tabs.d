// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.button.tabs;

import aurora.layout : HBox, VBox;
import aurora.types : Insets;
import aurora.widget : Widget;
import aurora.widgets.button : Button;

/// Tab strip showing one content page at a time.
class Tabs : VBox
{
    private HBox _header;
    private VBox _content;
    private Widget[] _pages;
    private int _selected = -1;

    void delegate(int index) onSelectionChanged;

    this()
    {
        super(0, Insets(0));
        _header = add(new HBox(0));
        _header.layoutHints().preferredHeight = 34;
        _content = add(new VBox(0, Insets(12)));
        _content.layoutHints().flex = 1.0;
        layoutHints().minWidth = 160;
        layoutHints().minHeight = 80;
    }

    int selectedIndex() const @safe pure nothrow @nogc { return _selected; }
    int tabCount() const @safe pure nothrow @nogc { return cast(int) _pages.length; }

    /// Add a page and its header button. The first tab becomes selected.
    void addTab(string title, Widget page)
    {
        const index = cast(int) _pages.length;
        auto button = _header.add(new Button(title));
        button.setFlat(true);
        button.layoutHints().preferredHeight = 30;
        button.onClick = delegate() { select(index); };
        if (page !is null)
        {
            _content.add(page);
            page.setVisible(false);
        }
        _pages ~= page;
        if (_selected < 0) select(0);
    }

    Widget page(int index)
    {
        return index >= 0 && index < cast(int) _pages.length ?
            _pages[index] : null;
    }

    void select(int index, bool notify = true)
    {
        if (index < 0 || index >= cast(int) _pages.length) return;
        if (index == _selected) return;
        _selected = index;
        foreach (i, page; _pages)
            if (page !is null) page.setVisible(cast(int) i == index);
        layoutTree();
        invalidate();
        if (notify && onSelectionChanged !is null)
            onSelectionChanged(_selected);
    }
}