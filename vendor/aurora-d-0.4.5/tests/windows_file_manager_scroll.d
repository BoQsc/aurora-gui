module tests.windows_file_manager_scroll;

import aurora;
import std.file : exists, getcwd, mkdirRecurse, write;
import std.path : buildPath;
import std.stdio : writeln;
import std.string : format;

import demos.windows_file_manager : WindowsFileManagerRoot;

private void createScrollDirectory(string path, int count)
{
    mkdirRecurse(path);
    foreach (index; 0 .. count)
        write(buildPath(path, format("scroll-item-%03d.txt", index)),
            "Aurora file manager scroll test item.\n");
}

private int settleScrollY(WindowsFileManagerRoot fm, GuiWindow window)
{
    // Let any in-flight smooth-scroll animation reach its target.
    foreach (_; 0 .. 200)
    {
        window.onNativeTick(0.016);
        window.onNativePaint();
    }
    return fm.testListScrollY();
}

private void testStandardMouseWheel(GuiWindow window, WindowsFileManagerRoot fm,
    UiTestDriver driver)
{
    const initial = settleScrollY(fm, window);
    const maxScroll = fm.testMaxListScroll();
    if (maxScroll <= 0)
    {
        writeln("SKIP: list not scrollable (max scroll 0)");
        return;
    }

    // Direct handler probe (bypasses the window dispatch layer).
    // Positive wheelY = wheel away from the user = scroll toward the top;
    // the list starts at the top, so a down-notch is the negative direction.
    Event direct;
    direct.type = EventType.mouseWheel;
    direct.wheelY = -3;
    direct.wheelX = 0;
    direct.position = Point(600, 400);
    direct.globalPosition = Point(600, 400);
    direct.precisePosition = PointF(600, 400);
    direct.preciseGlobalPosition = PointF(600, 400);
    direct.hasPrecisePosition = true;
    const directHandled = fm.onMouseWheel(direct);
    const directActive = fm.testListSmoothScrollActive();
    if (!directHandled || !directActive)
        throw new Exception("Direct wheel handler did not start a list scroll");

    // One physical wheel notch = wheelY 3 units (WM_MOUSEWHEEL 120 delta).
    driver.wheel(Point(600, 400), -3);
    const afterFirst = settleScrollY(fm, window);
    if (afterFirst <= initial)
        throw new Exception("Standard mouse wheel did not scroll the file list");
    if (afterFirst > maxScroll)
        throw new Exception("Wheel scrolled past the list maximum");

    // Reverse direction (up) must scroll back toward the top.
    driver.wheel(Point(600, 400), 3);
    const afterUp = settleScrollY(fm, window);
    if (afterUp >= afterFirst)
        throw new Exception("Reverse wheel did not scroll the file list back up");
}

private void testTouchpadFineGrainWheel(GuiWindow window, WindowsFileManagerRoot fm,
    UiTestDriver driver)
{
    const initial = settleScrollY(fm, window);
    const maxScroll = fm.testMaxListScroll();
    if (maxScroll <= 0)
    {
        writeln("SKIP: list not scrollable (max scroll 0)");
        return;
    }

    // Precision touchpads deliver many small deltas per gesture. Each win32
    // message accumulates into at most one wheel unit, so wheelY stays small
    // (0/1) while the remainder field is carried over. Negative = scroll down.
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    driver.wheel(Point(600, 400), -1);
    const afterGesture = settleScrollY(fm, window);
    if (afterGesture <= initial)
        throw new Exception("Fine-grain touchpad wheel did not scroll the file list");
}

private void testNativeVerticalScrollCommand(GuiWindow window,
    WindowsFileManagerRoot fm)
{
    const maximum = fm.testMaxListScroll();
    if (maximum <= 0) return;
    const target = maximum / 2;
    Event nativeScroll;
    nativeScroll.type = EventType.mouseWheel;
    nativeScroll.position = Point(600, 400);
    nativeScroll.globalPosition = nativeScroll.position;
    nativeScroll.verticalScrollPosition = target;
    nativeScroll.hasVerticalScrollPosition = true;
    if (!fm.onMouseWheel(nativeScroll))
        throw new Exception("Native vertical scroll command was not handled");
    if (fm.testListScrollY() != target)
        throw new Exception("Native vertical scroll command did not set the exact position");
    settleScrollY(fm, window);
}

private void testStandaloneScrollbarWidget()
{
    auto scrollbar = new Scrollbar();
    scrollbar.setBounds(Rect(0, 0, 12, 200));
    scrollbar.setRange(0, 800, 200);
    if (!scrollbar.scrollable() || scrollbar.thumbRect().height != 40)
        throw new Exception("Standalone scrollbar computed incorrect thumb geometry");

    int notified = -1;
    scrollbar.onValueChanged = delegate(int value) { notified = value; };
    Event pageClick;
    pageClick.type = EventType.mouseDown;
    pageClick.button = MouseButton.left;
    pageClick.position = Point(6, 100);
    if (!scrollbar.onMouseDown(pageClick) || scrollbar.value() != 200 ||
        notified != 200)
        throw new Exception("Standalone scrollbar did not page its value");

    const thumb = scrollbar.thumbRect();
    Event dragStart;
    dragStart.type = EventType.mouseDown;
    dragStart.button = MouseButton.left;
    dragStart.position = Point(6, thumb.y + thumb.height / 2);
    if (!scrollbar.onMouseDown(dragStart) || !scrollbar.draggingThumb())
        throw new Exception("Standalone scrollbar did not capture its thumb");
    Event dragMove;
    dragMove.type = EventType.mouseMove;
    dragMove.position = Point(6, 170);
    scrollbar.onMouseMove(dragMove);
    Event dragEnd;
    dragEnd.type = EventType.mouseUp;
    dragEnd.button = MouseButton.left;
    dragEnd.position = dragMove.position;
    if (!scrollbar.onMouseUp(dragEnd) || scrollbar.draggingThumb() ||
        scrollbar.value() <= 200)
        throw new Exception("Standalone scrollbar thumb drag did not update its value");
}

private void testFileManagerScrollbarWidget(GuiWindow window,
    WindowsFileManagerRoot fm, UiTestDriver driver)
{
    auto scrollbar = fm.testListScrollbar();
    if (scrollbar is null || !scrollbar.visible() || !scrollbar.scrollable())
        throw new Exception("File manager did not install a real scrollbar widget");
    const initial = fm.testListScrollY();
    const bounds = scrollbar.bounds();
    const thumb = scrollbar.thumbRect();
    const from = Point(bounds.x + bounds.width / 2,
        bounds.y + thumb.y + thumb.height / 2);
    const to = Point(from.x, bounds.y + bounds.height - thumb.height / 2 - 1);
    driver.drag(from, to, 6);
    const after = fm.testListScrollY();
    if (after <= initial || after != scrollbar.value())
        throw new Exception("File manager scrollbar widget drag did not scroll the list");
}

private void testSidebarWheel(GuiWindow window, WindowsFileManagerRoot fm,
    UiTestDriver driver)
{
    if (fm.testMaxSidebarScroll() <= 0)
    {
        writeln("SKIP: sidebar not scrollable (few navigation items)");
        return;
    }
    const initial = fm.testSidebarScrollY();
    driver.wheel(Point(100, 400), -3);
    const after = settleScrollY(fm, window);
    const sidebarAfter = fm.testSidebarScrollY();
    if (sidebarAfter <= initial)
        throw new Exception("Wheel over sidebar did not scroll the navigation list");
}

private void testWheelOverEmptyAreas(GuiWindow window, WindowsFileManagerRoot fm,
    UiTestDriver driver)
{
    const listBefore = settleScrollY(fm, window);
    const sidebarBefore = fm.testSidebarScrollY();
    // Wheel over the status bar / ribbon must be ignored by the lists.
    driver.wheel(Point(600, 700), 3);
    driver.wheel(Point(600, 5), 3);
    const listAfter = settleScrollY(fm, window);
    const sidebarAfter = fm.testSidebarScrollY();
    if (listAfter != listBefore || sidebarAfter != sidebarBefore)
        throw new Exception("Wheel outside the lists scrolled a list");
}

int main()
{
    testStandaloneScrollbarWidget();
    const testRoot = buildPath(getcwd(), "build", "fm-scroll-test");
    const count = 80;
    createScrollDirectory(testRoot, count);

    WindowOptions options;
    options.width = 1100;
    options.height = 700;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto fm = new WindowsFileManagerRoot(window, testRoot);
    window.setRoot(fm);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1100, 700));
    window.onNativePaint();

    if (fm.testVisibleEntryCount() < count)
        throw new Exception("File manager did not list all test files");

    testStandardMouseWheel(window, fm, driver);
    testTouchpadFineGrainWheel(window, fm, driver);
    testNativeVerticalScrollCommand(window, fm);
    testFileManagerScrollbarWidget(window, fm, driver);
    testSidebarWheel(window, fm, driver);
    testWheelOverEmptyAreas(window, fm, driver);

    // A second, independent window must scroll the same way (fresh remainder state).
    auto window2 = new GuiWindow(options, Theme.dark());
    auto fm2 = new WindowsFileManagerRoot(window2, testRoot);
    window2.setRoot(fm2);
    auto driver2 = new UiTestDriver(window2);
    driver2.resize(Size(1100, 700));
    window2.onNativePaint();
    const initial2 = settleScrollY(fm2, window2);
    driver2.wheel(Point(600, 400), -3);
    const after2 = settleScrollY(fm2, window2);
    if (after2 <= initial2)
        throw new Exception("Second window did not scroll with the wheel");

    writeln("Windows file manager wheel/touchpad scroll contracts passed.");
    return 0;
}
