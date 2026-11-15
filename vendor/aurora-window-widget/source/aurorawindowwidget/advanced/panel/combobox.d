// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.panel.combobox;

import aurora.layout : HBox, VBox;
import aurora.types : Insets;
import aurora.widgets.button : Button;
import aurora.widgets.texteditor : TextField;
import aurorawindowwidget.advanced.panel.dropdownlist : DropdownList;
import std.utf : toUTF8;

/// Editable text field with an attached collapsible choice list.
class ComboBox : VBox
{
    private HBox _fieldRow;
    private TextField _field;
    private Button _arrow;
    private DropdownList _list;

    void delegate(int index, string value) onSelectionChanged;

    this(string[] items = null)
    {
        super(0, Insets(0));
        _fieldRow = add(new HBox(0));
        _fieldRow.layoutHints().preferredHeight = 32;
        _field = _fieldRow.add(new TextField());
        _field.layoutHints().flex = 1.0;
        _arrow = _fieldRow.add(new Button("\u25BE"));
        _arrow.setFlat(true);
        _arrow.layoutHints().preferredWidth = 32;
        _arrow.onClick = delegate() { toggle(); };
        _list = add(new DropdownList());
        _list.layoutHints().flex = 0.0;
        _list.onSelected = delegate(int index) { acceptSelection(index); };
        if (items !is null && items.length > 0) setItems(items);
        layoutHints().minWidth = 140;
    }

    bool isOpen() const @safe pure nothrow @nogc { return _list.isOpen; }
    int selectedIndex() const @safe pure nothrow @nogc
    {
        return _list.selectedIndex;
    }
    string text() const { return _field.textUtf8(); }

    void setText(string value) { _field.setText(value); }
    void setItems(string[] items) { _list.setStrings(items); }
    void open() { _list.open(); }
    void close() { _list.close(); }
    void toggle() { _list.toggle(); }

    private void acceptSelection(int index)
    {
        const all = _list.items();
        if (index < 0 || index >= cast(int) all.length) return;
        const value = toUTF8(all[index].text);
        _field.setText(value);
        if (onSelectionChanged !is null) onSelectionChanged(index, value);
    }
}