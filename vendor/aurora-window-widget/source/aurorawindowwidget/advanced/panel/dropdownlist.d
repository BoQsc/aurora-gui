// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.panel.dropdownlist;

import aurora.event : Event;
import aurora.widgets.listview : ListView;

/// Single-choice list that expands inline under its owning field.
class DropdownList : ListView
{
    private bool _open;

    void delegate(int index) onSelected;

    this(string[] items = null)
    {
        super();
        setActivateOnSingleClick(true);
        if (items.length > 0) setStrings(items);
        setVisible(false);
    }

    bool isOpen() const @safe pure nothrow @nogc { return _open; }

    void open()
    {
        if (_open) return;
        _open = true;
        setVisible(true);
        reflow();
    }

    void close()
    {
        if (!_open) return;
        _open = false;
        setVisible(false);
        reflow();
    }

    void setOpen(bool value)
    {
        if (value) open();
        else close();
    }

    void toggle()
    {
        setOpen(!_open);
    }

    override bool onMouseUp(ref Event event)
    {
        const handled = super.onMouseUp(event);
        if (handled && _open)
        {
            close();
            if (onSelected !is null) onSelected(selectedIndex);
        }
        return handled;
    }

    private void reflow()
    {
        if (parent !is null) parent.layoutTree();
        invalidate();
    }
}