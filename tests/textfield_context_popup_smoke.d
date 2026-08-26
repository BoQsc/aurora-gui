module tests.textfield_context_popup_smoke;

import aurora;
import aurora.layout : Panel, VBox;
import aurora.types : Insets;
import aurora.testing : UiTestDriver;
import aurora.types : Point, Rect, Size;
import aurora.widgets.contextmenu : ContextMenu;
import aurora.widgets.popup : PopupPlacement, showPopup;
import std.stdio : writeln;

private ContextMenu findContextMenu(Widget root)
{
    foreach (child; root.children())
        if (auto menu = cast(ContextMenu) child) return menu;
    return null;
}

private bool hasPopupOverlay(Widget root)
{
    foreach (child; root.children())
        if (child.classinfo.name == "aurora.widgets.popup.PopupOverlay") return true;
    return false;
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Cut textfield in-popup context smoke";
    options.width = 900;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new Panel();
    window.setRoot(root);
    root.setBounds(Rect(0, 0, 900, 700));

    auto content = new VBox(8, Insets(12));
    content.setBackground(Color.fromHex(0x242a32));
    auto field = content.add(new TextField("some url here"));
    field.setId("yt-dlp-url");
    auto popup = showPopup(root, Rect(100, 100, 300, 100), content,
        PopupPlacement.below, Size(400, 200));
    assert(popup !is null, "Failed to open the simulated popup");

    auto driver = new UiTestDriver(window);

    // Right-click inside the TextField within the popup. The context menu must
    // appear WITHOUT dismissing the host popup.
    const fieldOrigin = field.localToGlobal(Point(0, 0));
    const fieldCentre = Point(fieldOrigin.x + field.bounds().width / 2,
        fieldOrigin.y + field.bounds().height / 2);
    driver.moveTo(fieldCentre);
    driver.rightClick(fieldCentre);

    auto menu = findContextMenu(root);
    assert(menu !is null, "Right-click inside popup TextField did not open context menu");
    assert(hasPopupOverlay(root), "Right-click in popup dismissed the host popup");
    assert(popup.focused() || popup.bounds().width > 0,
        "Host popup appears dismissed after context menu");

    writeln("Aurora Cut textfield in-popup context menu smoke test passed.");
    return 0;
}
