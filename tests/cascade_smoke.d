module tests.cascade_smoke;

import aurora;
import aurora.layout : Panel;
import aurora.testing : UiTestDriver;
import aurora.types : Point, Rect;
import aurora.widgets.contextmenu : ContextMenu, ContextMenuItem, showContextMenu;
import std.stdio : writeln;

/// Local-space centre of row `index` (non-separator rows) in a menu.
private Point rowCentre(ContextMenu menu, int index)
{
    const r = menu.menuRect();
    int y = r.y + 3;
    for (int i = 0; i < index; ++i) y += menu.rowHeightForTesting();
    return Point(r.x + 40, y + menu.rowHeightForTesting() / 2);
}

/// Regression: a cascade sub-menu is a front-most full-window popup, so the
/// framework routes pointer moves over the parent to the child first. The child
/// must forward such moves back to the parent so the parent tracks its hover
/// (item highlights follow the cursor) and retracts the cascade when the cursor
/// moves back onto the parent away from the owning cascade item.
int main()
{
    WindowOptions options;
    options.title = "Aurora Cut cascade smoke";
    options.width = 900;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new Panel();
    window.setRoot(root);
    root.setBounds(Rect(0, 0, 900, 700));

    ContextMenuItem[] views;
    views ~= ContextMenuItem.command("Details", delegate() {});
    ContextMenuItem[] items;
    items ~= ContextMenuItem.command("Open", delegate() {});
    items ~= ContextMenuItem.submenuItem("Audio track", IconKind.music, views);
    items ~= ContextMenuItem.command("Refresh", delegate() {});

    auto menu = showContextMenu(root, Point(120, 60), items);
    assert(menu !is null);
    auto driver = new UiTestDriver(window);

    // Hover the cascade row: the child opens out to the right.
    const cascadePoint = rowCentre(menu, 1);
    driver.moveTo(cascadePoint);
    auto child = menu.childMenu();
    assert(child !is null,
        "Hovering the cascade item did not open the child menu");

    // Hover the child item: the child reacts to its own items (cursor tracking).
    const detailsPoint = rowCentre(child, 0);
    driver.moveTo(detailsPoint);
    assert(menu.childMenu() !is null,
        "Hovering a child item retracted the child menu");
    assert(child !is null);

    // Hover back onto the parent's plain first row: the child retracts.
    const openPoint = rowCentre(menu, 0);
    driver.moveTo(openPoint);
    assert(menu.childMenu() is null,
        "Moving back onto the parent did not retract the child menu");

    // Re-hover the cascade and re-enter the child, then move right past the
    // child onto empty parent area: the child must retract.
    driver.moveTo(cascadePoint);
    child = menu.childMenu();
    assert(child !is null, "Re-hovering the cascade did not reopen the child");
    const farPoint = Point(menu.menuRect().right() + child.menuRect().width + 80,
        menu.menuRect().y + 4);
    driver.moveTo(farPoint);
    assert(menu.childMenu() is null,
        "Moving away from the cascade did not retract the child menu");

    writeln("Aurora Cut cascade sub-menu smoke test passed.");
    return 0;
}
