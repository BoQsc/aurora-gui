// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.sidebar;

import aurora.layout : VBox;
import aurora.types : Insets;
import aurora.widgets.button : Button;
import aurora.widgets.label : Label;

/// Navigation rail: a heading plus one flat button per destination.
class Sidebar : VBox
{
    private Label _title;
    private VBox _items;
    private Button[] _buttons;
    private int _selected = -1;

    void delegate(int index) onSelectionChanged;

    this(string title = "Navigation")
    {
        super(4, Insets(8));
        _title = add(new Label(title));
        _title.layoutHints().preferredHeight = 26;
        _items = add(new VBox(2, Insets(0)));
        _items.layoutHints().flex = 1.0;
        layoutHints().minWidth = 140;
        layoutHints().preferredWidth = 200;
    }

    void setTitle(string value)
    {
        _title.setText(value);
    }

    int selectedIndex() const @safe pure nothrow @nogc { return _selected; }

    int itemCount() const @safe pure nothrow @nogc
    {
        return cast(int) _buttons.length;
    }

    /// Add a destination. The first item becomes selected.
    Button addItem(string label)
    {
        const index = cast(int) _buttons.length;
        auto button = _items.add(new Button(label));
        button.setFlat(true);
        button.layoutHints().preferredHeight = 32;
        button.onClick = delegate() { select(index); };
        _buttons ~= button;
        if (_selected < 0) select(0);
        return button;
    }

    void select(int index, bool notify = true)
    {
        if (index < 0 || index >= cast(int) _buttons.length) return;
        if (index == _selected) return;
        _selected = index;
        invalidate();
        if (notify && onSelectionChanged !is null) onSelectionChanged(_selected);
    }
}