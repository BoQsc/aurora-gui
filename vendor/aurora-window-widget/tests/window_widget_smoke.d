// SPDX-License-Identifier: 0BSD
module window_widget_smoke;

import aurorawindowwidget;
import aurora.types : Insets, Point, Rect, Size;
import std.stdio : writeln;

private void check(bool condition, string message)
{
    if (!condition) throw new Exception("window widget smoke failed: " ~ message);
}

int main()
{
    auto label = new Label("heading");
    check(label.measure(Size(200, 60)).width > 0, "label measures");

    auto panel = new Panel();
    panel.add(label);
    panel.setBounds(Rect(0, 0, 320, 200));
    panel.layoutTree();
    check(panel.children().length == 1, "panel hosts a child");
    check(panel.bounds().width == 320, "panel bounds");

    auto tabs = new Tabs();
    tabs.addTab("One", new Label("first"));
    tabs.addTab("Two", new Label("second"));
    tabs.setBounds(Rect(0, 0, 400, 240));
    tabs.layoutTree();
    check(tabs.tabCount == 2, "two tabs");
    check(tabs.selectedIndex == 0, "first tab selected");
    int activeTab = -1;
    tabs.onSelectionChanged = delegate(int index) { activeTab = index; };
    tabs.select(1);
    check(tabs.selectedIndex == 1 && activeTab == 1, "tab selection");

    auto sidebar = new Sidebar("Files");
    sidebar.addItem("Open");
    sidebar.addItem("Save");
    sidebar.setBounds(Rect(0, 0, 200, 300));
    sidebar.layoutTree();
    check(sidebar.itemCount == 2, "two sidebar items");
    check(sidebar.selectedIndex == 0, "first sidebar item selected");

    auto table = new Table(["Name", "Size"], [160, 90]);
    table.addRow(["a.d", "33"]);
    table.addRow(["b.d", "34"]);
    table.setBounds(Rect(0, 0, 340, 160));
    table.layoutTree();
    check(table.rowCount == 2, "two table rows");
    int selectedRow = -1;
    table.onSelectionChanged = delegate(int index) { selectedRow = index; };
    table.select(1);
    check(selectedRow == 1, "row selection");

    auto combo = new ComboBox(["alpha", "beta"]);
    combo.setBounds(Rect(0, 0, 240, 260));
    combo.layoutTree();
    check(!combo.isOpen, "combo starts closed");
    combo.open();
    check(combo.isOpen, "combo opens");
    combo.close();
    check(!combo.isOpen, "combo closes");

    auto dropdown = new DropdownList(["a", "b"]);
    check(!dropdown.isOpen, "dropdown starts closed");
    dropdown.open();
    check(dropdown.isOpen, "dropdown opens");

    auto list = new ListBox(["x", "y"]);
    list.addItem("z");
    check(list.itemCount == 3, "listbox item count");
    check(list.itemText(2) == "z", "listbox item text");

    auto option = new Option("choice", true);
    check(option.selected, "option starts selected");
    option.setSelected(false, false);
    check(!option.selected, "option clears");
    check(option.text == "choice"d, "option text");

    auto tooltip = new Tooltip("hint");
    tooltip.setBounds(Rect(0, 0, 90, 26));
    check(tooltip.text == "hint"d, "tooltip text");
    check(tooltip.measure(Size(200, 200)).height == 26, "tooltip height");

    auto image = new ImageView();
    check(image.image is null, "image view starts empty");
    check(image.measure(Size(100, 100)) == Size(16, 16),
        "empty image keeps its minimum size");

    auto dialog = new Dialog("Confirm");
    dialog.addContent(new Label("Continue?"));
    bool accepted;
    dialog.addAction("OK", delegate() { accepted = true; });
    dialog.setBounds(Rect(0, 0, 360, 200));
    dialog.layoutTree();
    check(dialog.children().length == 3, "dialog has three sections");
    check(!accepted, "dialog action not fired yet");

    auto textbox = new TextBox("hello");
    check(textbox.textUtf8() == "hello", "text box text");
    auto tickbox = new TickBox("agree", true);
    check(tickbox.checked, "tick box checked");
    auto progress = new ProgressBar();
    progress.setValue(0.5);
    check(progress.value == 0.5, "progress value");
    auto split = new SplitPane(new Label("left"), new Label("right"));
    split.setBounds(Rect(0, 0, 400, 200));
    split.layoutTree();
    check(split.ratio > 0 && split.ratio < 1, "split ratio");

    writeln("window_widget_smoke: ALL PASSED");
    return 0;
}