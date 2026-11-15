// SPDX-License-Identifier: 0BSD
module aurorawindowwidget.advanced.panel.listbox;

import aurora.widgets.listview : ListItem, ListView;
import std.utf : toUTF8;

/// String-item list with single-click activation.
class ListBox : ListView
{
    this(string[] items = null)
    {
        super();
        setActivateOnSingleClick(true);
        if (items.length > 0) setStrings(items);
    }

    int itemCount()
    {
        return cast(int) items().length;
    }

    void addItem(string text)
    {
        ListItem[] next;
        foreach (item; items()) next ~= item;
        next ~= ListItem(text);
        setItems(next);
    }

    string itemText(int index)
    {
        const all = items();
        if (index < 0 || index >= cast(int) all.length) return "";
        return toUTF8(all[index].text);
    }
}