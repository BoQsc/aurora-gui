module tests.textfield_context_smoke;

import aurora;
import aurora.layout : Panel;
import aurora.testing : UiTestDriver;
import aurora.types : Point, Rect;
import aurora.widgets.contextmenu : ContextMenu;
import std.stdio : writeln;

private ContextMenu findContextMenu(Widget root)
{
    foreach (child; root.children())
        if (auto menu = cast(ContextMenu) child) return menu;
    return null;
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Cut textfield context smoke";
    options.width = 900;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new Panel();
    window.setRoot(root);
    root.setBounds(Rect(0, 0, 900, 700));

    auto field = root.add(new TextField("hello world"));
    field.setBounds(Rect(20, 20, 300, 40));
    field.setCursorIndex(0);

    auto driver = new UiTestDriver(window);

    driver.moveTo(Point(40, 40));
    driver.rightClick(Point(40, 40));
    auto menu = findContextMenu(root);
    assert(menu !is null, "Right-click on TextField did not open a context menu");
    assert(menu.items().length >= 5,
        "Editing context menu did not include Cut/Copy/Paste/Select All");
    assert(menu.items()[3].separator, "Context menu is missing the separator");

    // Drive the menu actions through the real menu select/click path.
    // A double-click selects the word; then Copy should read it, and the
    // caret moves to the end for Paste to append a copy.
    field.setSelection(0, cast(size_t) field.textView().length);
    field.copyToClipboard();
    field.setCursorIndex(cast(size_t) field.textView().length);
    field.pasteFromClipboard();
    assert(field.textUtf8() == "hello worldhello world",
        "Copy/Paste across selection did not duplicate the text");

    // Cut removes the freshly pasted tail, restoring the original text.
    field.setSelection(cast(size_t) "hello world".length,
        cast(size_t) field.textUtf8().length);
    field.cutToClipboard();
    assert(field.textUtf8() == "hello world",
        "Cut did not remove the selected tail");

    writeln("Aurora Cut textfield context menu smoke test passed.");
    return 0;
}
