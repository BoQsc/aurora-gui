module tests.titlebar_smoke;

import aurora;
import aurora.testing : UiTestDriver;
import std.stdio : writeln;

private final class TestRoot : Widget
{
}

private TitleBar requireTitleBar(Widget root)
{
    assert(root !is null && root.children().length == 1);
    auto bar = cast(TitleBar) root.children()[0];
    assert(bar !is null, "Expected a TitleBar as the root child");
    return bar;
}

private Point captionCenter(TitleBar bar, TitleBarControl control)
{
    const rect = bar.captionRect(control);
    return bar.localToGlobal(Point(rect.x + rect.width / 2,
        rect.y + rect.height / 2));
}

private Point titleCenter(TitleBar bar)
{
    const rect = bar.titleRect();
    return bar.localToGlobal(Point(rect.x + rect.width / 2,
        rect.y + rect.height / 2));
}

/// A click on the window background resets GuiWindow's click-count state so
/// back-to-back doubleClicks in the test start from a clean clickCount.
private void resetClickState(UiTestDriver driver)
{
    driver.click(Point(20, 350));
}

int main()
{
    WindowOptions options;
    options.title = "Aurora TitleBar smoke";
    options.width = 800;
    options.height = 400;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, Theme.dark());
    auto root = new TestRoot();
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));

    auto bar = new TitleBar();
    bar.setTitle("My Custom Window");
    bar.setIcon(IconKind.computer);
    root.add(bar);
    bar.setBounds(Rect(20, 20, 760, 40));
    assert(driver.paint(), "TitleBar paint failed");

    // --- Caption buttons fire their callbacks through real dispatch. ---
    bool minimized;
    bool maximized;
    bool closed;
    bool doubleClicked;
    bool systemMenuRequested;
    bar.onMinimize = delegate() { minimized = true; };
    bar.onMaximizeToggle = delegate()
    {
        maximized = !maximized;
        bar.setMaximized(maximized);
    };
    bar.onClose = delegate() { closed = true; };
    bar.onDoubleClick = delegate() { doubleClicked = true; };
    bar.onSystemMenu = delegate(Point position) { systemMenuRequested = true; };

    driver.click(captionCenter(bar, TitleBarControl.minimize));
    assert(minimized, "Minimize callback not fired");

    driver.click(captionCenter(bar, TitleBarControl.maximize));
    assert(maximized && bar.maximized(), "Maximize callback/state not updated");
    driver.click(captionCenter(bar, TitleBarControl.maximize));
    assert(!maximized && !bar.maximized(), "Restore did not revert maximize state");

    driver.click(captionCenter(bar, TitleBarControl.close));
    assert(closed, "Close callback not fired");

    // --- Double-click on the title toggles maximize. ---
    // Reset the host click counter (a click on empty background) so each
    // doubleClick below starts from a clean clickCount.
    resetClickState(driver);
    driver.doubleClick(titleCenter(bar));
    assert(maximized && bar.maximized(),
        "Double-click did not toggle maximize");
    resetClickState(driver);
    driver.doubleClick(titleCenter(bar));
    assert(!maximized, "Double-click did not restore");
    assert(doubleClicked, "onDoubleClick observer not fired");

    // --- Double-click still maximizes when native system move is enabled. ---
    // Regression: the second press of the double-click used to enter the
    // system-move branch again instead of the maximize branch.
    bar.setSystemMoveOnDrag(true);
    resetClickState(driver);
    driver.doubleClick(titleCenter(bar));
    assert(maximized && bar.maximized(),
        "Double-click did not maximize with systemMoveOnDrag");
    resetClickState(driver);
    driver.doubleClick(titleCenter(bar));
    assert(!maximized, "Double-click did not restore with systemMoveOnDrag");
    bar.setSystemMoveOnDrag(false);

    // --- A native double-click (WM_LBUTTONDBLCLK) also maximizes. ---
    bar.setMaximized(false);
    maximized = false;
    const nativePoint = titleCenter(bar);
    Event nativeDbl;
    nativeDbl.type = EventType.mouseDown;
    nativeDbl.nativeDoubleClick = true;
    nativeDbl.button = MouseButton.left;
    nativeDbl.position = nativePoint;
    nativeDbl.globalPosition = nativePoint;
    nativeDbl.precisePosition = PointF(nativePoint);
    nativeDbl.preciseGlobalPosition = PointF(nativePoint);
    nativeDbl.hasPrecisePosition = true;
    window.onNativeEvent(nativeDbl);
    assert(maximized && bar.maximized(),
        "Native double-click did not maximize");

    // --- Drag down while maximized restores, then continues the drag. ---
    // In-canvas self-move: restore fires on drag, the bar leaves maximize and
    // keeps moving from the re-anchored pointer.
    bool restoredRequested;
    PointF restorePointer;
    PointF restorePress;
    bar.onRestoreRequested = delegate(PointF pointer, PointF pressPointer)
    {
        restoredRequested = true;
        restorePointer = pointer;
        restorePress = pressPointer;
        maximized = false;
        bar.setMaximized(false);
    };
    resetClickState(driver);
    bar.setBounds(Rect(20, 20, 760, 40));
    bar.setMaximized(true);
    maximized = true;
    const maximizedStart = bar.bounds();
    driver.drag(Point(300, 40), Point(300, 120));
    assert(restoredRequested, "Restore-on-drag was not requested");
    assert(restorePress == PointF(300, 40),
        "Restore-on-drag press pointer mismatch");
    assert(!bar.maximized() && !maximized,
        "Bar did not leave the maximized state on drag");
    assert(bar.bounds().y > maximizedStart.y,
        "Drag did not continue after restore");
    assert(bar.bounds().y == maximizedStart.y + 70,
        "Drag did not re-anchor after restore");
    assert(!bar.dragging(), "Drag did not end after restore-on-drag");

    // System-move mode: restore is requested too, then the native move loop is
    // started (returns false headlessly) and the state is cleared.
    bar.setSystemMoveOnDrag(true);
    resetClickState(driver);
    restoredRequested = false;
    bar.setBounds(Rect(20, 20, 760, 40));
    bar.setMaximized(true);
    maximized = true;
    driver.drag(Point(300, 40), Point(300, 120));
    assert(restoredRequested,
        "System-move restore-on-drag was not requested");
    assert(!bar.maximized() && !maximized,
        "System-move restore did not clear maximize state");
    bar.setSystemMoveOnDrag(false);
    bar.onRestoreRequested = null;
    bar.setMaximized(false);
    maximized = false;

    // --- Hover visuals freeze while dragging (no cursor flicker). ---
    bar.setBounds(Rect(20, 20, 760, 40));
    resetClickState(driver);
    driver.moveTo(Point(300, 40));
    driver.mouseDown(MouseButton.left);
    driver.moveTo(Point(300, 45)); // cross the drag threshold
    assert(bar.dragging(), "Drag did not start for hover-freeze test");
    driver.moveTo(captionCenter(bar, TitleBarControl.close)); // over the button
    assert(bar.hotControl() != TitleBarControl.close,
        "Hover cursor changed while dragging");
    driver.moveTo(Point(300, 110));
    driver.mouseUp(MouseButton.left);
    assert(!bar.dragging(), "Drag did not end for hover-freeze test");

    // --- Right-click on the title requests the system menu. ---
    driver.rightClick(titleCenter(bar));
    assert(systemMenuRequested, "System menu request not fired");

    // --- Drag moves the bar itself by the exact pointer delta. ---
    bar.setBounds(Rect(20, 20, 760, 40));
    resetClickState(driver);
    const start = bar.bounds();
    driver.drag(Point(120, 40), Point(220, 90));
    assert(bar.bounds() == Rect(start.x + 100, start.y + 50,
        start.width, start.height),
        "Self-move drag relocated the bar incorrectly");
    assert(!bar.dragging(), "Drag did not end on release");

    // --- Owner-driven drag through onDragMoved. ---
    bool dragEnded;
    bar.onDragEnded = delegate() { dragEnded = true; };
    const ownerStart = Point(30, 80);
    bar.setBounds(Rect(ownerStart.x, ownerStart.y, 760, 40));
    bar.onDragMoved = delegate(PointF pointer, bool requestFrame)
    {
        const dx = pointer.x - 140.0;
        const dy = pointer.y - 100.0;
        bar.setBounds(Rect(ownerStart.x + cast(int) dx,
            ownerStart.y + cast(int) dy, 760, 40));
        return true;
    };
    driver.drag(Point(140, 100), Point(190, 130));
    assert(bar.bounds().x == ownerStart.x + 50 &&
        bar.bounds().y == ownerStart.y + 30,
        "Owner-driven drag did not move the bar");
    assert(dragEnded, "onDragEnded not fired");

    // --- Customization: hide buttons, custom content, alignment. ---
    bar.setShowMinimize(false);
    bar.setShowMaximize(false);
    bar.setShowClose(true);
    bar.setBarHeight(48);
    assert(bar.captionRect(TitleBarControl.minimize).empty);
    assert(bar.captionRect(TitleBarControl.maximize).empty);
    assert(!bar.captionRect(TitleBarControl.close).empty);

    auto content = new Label("Tab strip content");
    content.setColor(Color.rgb(120, 200, 255));
    bar.setContent(content);
    driver.paint();
    const expectedContent = bar.contentRect();
    assert(content.bounds() == expectedContent,
        "Custom content was not laid into contentRect");

    bar.setTitleAlign(HorizontalAlign.center);
    bar.setTitleWidth(300);
    driver.paint();
    assert(bar.titleRect().width == 300,
        "Fixed title width not honored");
    assert(bar.contentRect().x == bar.titleRect().right() + 8,
        "Content does not follow the fixed title region");

    // A narrow centered content widget keeps the surrounding bar draggable.
    bar.setContentWidth(200);
    const fieldLeft = bar.contentRect().x;
    const fieldRight = bar.contentRect().right();
    assert(bar.controlAt(Point(fieldLeft - 20, 20)) == TitleBarControl.title,
        "Area left of the field is not draggable title surface");
    assert(bar.controlAt(Point(fieldRight + 20, 20)) == TitleBarControl.title,
        "Area right of the field is not draggable title surface");
    assert(bar.contentRect().width == 200,
        "Content width constraint not honored");
    bar.setContentWidth(0);
    assert(bar.contentRect().width > 200,
        "Content did not restore to full width after clearing contentWidth");

    // --- Active/inactive state and maximized glyph bookkeeping. ---
    bar.setActive(false);
    assert(!bar.active());
    bar.setActive(true);
    bar.setMaximized(true);
    assert(bar.maximized());
    bar.setMaximized(false);

    // --- Clicking a non-focusable area releases hosted-field focus. ---
    auto searchField = new TextField();
    searchField.setPlaceholder("Search clips, tracks, effects…");
    searchField.setContentCentered(true);
    bar.setContent(searchField);
    driver.paint();
    const fieldRect = searchField.bounds();
    const fieldCenter = searchField.localToGlobal(Point(
        fieldRect.width / 2, fieldRect.height / 2));
    driver.click(fieldCenter);
    assert(searchField.focused(), "Search field did not gain focus");
    driver.click(Point(60, 30)); // titlebar empty strip
    assert(!searchField.focused(),
        "Clicking the titlebar did not release field focus");
    driver.click(fieldCenter);
    assert(searchField.focused(), "Search field did not regain focus");
    driver.click(Point(20, 350)); // window background
    assert(!searchField.focused(),
        "Clicking the window background did not release field focus");
    bar.clearContent();

    // --- Reset to the default layout and capture a visual. ---
    bar.setTitle("My Custom Window");
    bar.setIcon(IconKind.computer);
    bar.setShowMinimize(true);
    bar.setShowMaximize(true);
    bar.setShowClose(true);
    bar.setBarHeight(40);
    bar.setTitleWidth(0);
    bar.setTitleMinWidth(0);
    bar.clearContent();
    bar.setBounds(Rect(20, 20, 760, 40));
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "TitleBar paint after reset failed");
    // Caption buttons stack right-to-left: close, maximize, minimize.
    assert(bar.captionRect(TitleBarControl.close).right() == 760 &&
        bar.captionRect(TitleBarControl.close).x >
        bar.captionRect(TitleBarControl.maximize).x &&
        bar.captionRect(TitleBarControl.maximize).x >
        bar.captionRect(TitleBarControl.minimize).x,
        "Caption button order is not right-to-left");
    window.saveScreenshot("build/headless-smoke/titlebar-smoke.ppm");

    // Hover the close button and capture the highlight state.
    driver.moveTo(captionCenter(bar, TitleBarControl.close));
    assert(driver.paint(), "TitleBar hover paint failed");
    window.saveScreenshot("build/headless-smoke/titlebar-smoke-hover.ppm");

    driver.resize(Size(640, 360));
    assert(driver.paint(), "TitleBar paint after resize failed");
    assert(bar.content() is null, "Unexpected content after reset");

    import std.stdio : writeln;
    writeln("Aurora TitleBar smoke test passed.");
    return 0;
}
