module tests.desktop_shell;

import aurora;
import std.algorithm : reverse;
import std.stdio : writeln;

private final class ClickProbe : Widget
{
    int presses;
    int releases;

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        ++presses;
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        ++releases;
        return true;
    }
}

private final class ShellRoot : Widget
{
    ClickProbe probe;
    Taskbar taskbar;

    this()
    {
        probe = add(new ClickProbe());
        taskbar = add(new Taskbar());
    }

    protected override void onLayout()
    {
        const barHeight = 52;
        probe.setBounds(Rect(0, 0, bounds().width,
            maxInt(0, bounds().height - barHeight)));
        taskbar.setBounds(Rect(0, maxInt(0, bounds().height - barHeight),
            bounds().width, barHeight));
    }
}

private Point center(Rect value)
{
    return Point(value.x + value.width / 2, value.y + value.height / 2);
}

private Point taskCenter(Taskbar taskbar, size_t index)
{
    const local = center(taskbar.entryBounds(index));
    return taskbar.localToGlobal(local);
}

private Rect taskGlobalBounds(Taskbar taskbar, size_t index)
{
    const local = taskbar.entryBounds(index);
    const origin = taskbar.globalOrigin();
    return local.translated(origin.x, origin.y);
}

private void moveExpected(ref TaskEntryId[] order, int from, int to)
{
    const value = order[cast(size_t) from];
    if (from < to)
    {
        foreach (index; from .. to)
            order[cast(size_t) index] = order[cast(size_t) index + 1];
    }
    else
    {
        for (int index = from; index > to; --index)
            order[cast(size_t) index] = order[cast(size_t) index - 1];
    }
    order[cast(size_t) to] = value;
}

private void assertOrder(Taskbar taskbar, const(TaskEntryId)[] expected)
{
    assert(taskbar.taskOrderValid());
    assert(taskbar.entryOrder() == expected);
    foreach (index, id; expected)
        assert(taskbar.entryId(index) == id);
}

private StartMenu buildStartMenu(Taskbar taskbar, ref int applicationLaunches,
    ref int shutdowns)
{
    auto menu = new StartMenu(taskbar);
    foreach (index; 0 .. 12)
    {
        const captured = index;
        menu.addApplication("Application", IconKind.file, delegate()
        {
            applicationLaunches += cast(int) captured + 1;
        }, "Pinned desktop application");
    }
    menu.addSystemCommand("Full screen", IconKind.maximize, delegate() {});
    menu.addSystemCommand("Taskbar settings", IconKind.settings, delegate() {});
    menu.addSystemCommand("Shut down", IconKind.close,
        delegate() { ++shutdowns; }, true);
    return menu;
}

private void testStartMenuAndPopupContracts()
{
    WindowOptions options;
    options.width = 900;
    options.height = 640;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new ShellRoot();
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(900, 640));

    int applicationLaunches;
    int shutdowns;
    auto menu = buildStartMenu(root.taskbar, applicationLaunches, shutdowns);
    menu.onOpenChanged = delegate(bool open)
    {
        root.taskbar.setStartMenuOpen(open);
    };
    root.taskbar.onStart = delegate()
    {
        menu.toggle(root.taskbar, root.taskbar.startButtonGlobalBounds());
    };

    // Every supported shell size must keep the fixed footer and all visible
    // interactive geometry wholly inside the panel.
    foreach (size; [Size(640, 480), Size(800, 600), Size(1280, 760)])
    {
        driver.resize(size);
        const start = center(root.taskbar.startButtonGlobalBounds());
        driver.click(start);
        assert(menu.open());
        assert(currentTransientPopup(root) is menu);
        assert(root.taskbar.startMenuOpen());
        assert(menu.layoutValid());
        assert(menu.bounds() == Rect(0, 0, size.width, size.height));
        const last = menu.entryRect(StartMenuEntryKind.systemCommand,
            menu.systemCommands().length - 1);
        assert(last.height == 48);
        assert(last.intersection(menu.panelRect()) == last);
        assert(last.bottom() <= menu.panelRect().bottom() - 12);
        assertLayoutClean(root);

        // Clicking Start while open closes it and consumes the anchor press so
        // mouse-up cannot immediately reopen it.
        driver.click(start);
        assert(!menu.open());
        assert(currentTransientPopup(root) is null);
        assert(!root.taskbar.startMenuOpen());
    }

    driver.resize(Size(900, 640));
    const start = center(root.taskbar.startButtonGlobalBounds());
    driver.click(start);
    assert(menu.open());

    // Click-away occurs before normal hit testing; the same press reaches the
    // application underneath after the popup has detached.
    const beforePresses = root.probe.presses;
    driver.click(Point(700, 300));
    assert(!menu.open());
    assert(root.probe.presses == beforePresses + 1);
    assert(window.focusedWidget() !is menu);

    // Escape and native host deactivation close transient UI consistently.
    driver.click(start);
    assert(menu.open());
    driver.pressKey(Key.escape);
    assert(!menu.open());
    driver.click(start);
    assert(menu.open());
    driver.setHostFocus(false);
    assert(!menu.open());
    driver.setHostFocus(true);

    // Search is keyboard-driven, filtered rows remain inside the scrollable
    // viewport, and clearing the query restores the complete application set.
    driver.click(start);
    driver.text("app"d);
    assert(menu.query() == "app"d);
    assert(menu.layoutValid());
    driver.pressKey(Key.backspace);
    driver.pressKey(Key.backspace);
    driver.pressKey(Key.backspace);
    assert(menu.query().length == 0);
    driver.pressKey(Key.escape);

    // Context menus use the same root-level popup contract and also allow the
    // closing click to continue to the application underneath.
    auto context = showContextMenu(root.probe, Point(120, 120), [
        ContextMenuItem.command("Open", delegate() {})
    ]);
    assert(context !is null);
    const beforeContextPresses = root.probe.presses;
    driver.click(Point(700, 300));
    assert(currentTransientPopup(root) is null);
    assert(root.probe.presses == beforeContextPresses + 1);
}

private void testPointerLockedTaskDrag()
{
    WindowOptions options;
    options.width = 1100;
    options.height = 260;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new ShellRoot();
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1100, 260));

    foreach (_; 0 .. 7)
        root.taskbar.addCommand("Task", IconKind.file, delegate() {});
    auto expected = root.taskbar.entryOrder();
    const from = 2;
    const to = 5;
    const source = taskGlobalBounds(root.taskbar, from);
    enum grabX = 17;
    enum grabY = 11;
    const press = Point(source.x + grabX, source.y + grabY);

    driver.moveTo(press);
    driver.mouseDown();
    const threshold = Point(press.x + 7, press.y + 2);
    driver.moveTo(threshold);
    assert(root.taskbar.reordering());
    assert(root.taskbar.dragAnchorGlobalPosition() == PointF(threshold));
    auto preview = root.taskbar.dragPreviewGlobalBounds();
    assert(preview.x == threshold.x - grabX);
    assert(preview.y == threshold.y - grabY);
    assert(root.taskbar.entryOrder() == expected);

    // The visible task follows every pointer sample by the original grab point,
    // including vertical movement. Reordering the model is deferred to release.
    foreach (position; [
        Point(520, 205), Point(710, 185), Point(860, 232), Point(640, 246)
    ])
    {
        driver.moveTo(position);
        assert(root.taskbar.dragAnchorGlobalPosition() == PointF(position));
        assert(root.taskbar.entryOrder() == expected);
        assert(root.taskbar.taskOrderValid());
    }

    // Late-latched fractional samples update only the retained proxy transform.
    const late = PointF(743.25, 219.75);
    assert(root.taskbar.onPointerLatch(late));
    assert(root.taskbar.dragAnchorGlobalPosition() == late);
    assert(root.taskbar.entryOrder() == expected);

    const destination = taskGlobalBounds(root.taskbar, to);
    const release = Point(destination.x + grabX, destination.y + grabY);
    driver.moveTo(release);
    assert(root.taskbar.dragTargetIndex() == to);
    assert(root.taskbar.entryOrder() == expected);
    driver.mouseUp();
    moveExpected(expected, from, to);
    assertOrder(root.taskbar, expected);
    assert(!root.taskbar.reordering());
    assert(root.taskbar.dragPreviewGlobalBounds().empty());

    // Losing host focus cancels a second drag without committing a partial order.
    const cancelSource = taskGlobalBounds(root.taskbar, 1);
    const cancelPress = Point(cancelSource.x + grabX, cancelSource.y + grabY);
    driver.moveTo(cancelPress);
    driver.mouseDown();
    driver.moveTo(Point(cancelPress.x + 12, cancelPress.y - 8));
    assert(root.taskbar.reordering());
    driver.setHostFocus(false);
    assert(!root.taskbar.reordering());
    assert(root.taskbar.dragPreviewGlobalBounds().empty());
    assertOrder(root.taskbar, expected);
    driver.setHostFocus(true);
}

private void testTaskbarOrderStress()
{
    WindowOptions options;
    options.width = 1100;
    options.height = 260;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new ShellRoot();
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1100, 260));

    foreach (index; 0 .. 7)
        root.taskbar.addCommand("Task", IconKind.file, delegate() {});
    TaskEntryId[] expected = root.taskbar.entryOrder();
    int moveCallbacks;
    int orderCallbacks;
    root.taskbar.onEntryMoved = delegate(int from, int to)
    {
        ++moveCallbacks;
        assert(from >= 0 && to >= 0 && from != to);
    };
    root.taskbar.onEntryOrderChanged = delegate(TaskEntryId[] order)
    {
        ++orderCallbacks;
        assert(order == root.taskbar.entryOrder());
    };

    // Exercise the real capture and bubbling path repeatedly. The expected
    // model is keyed by stable IDs, not by labels or transient indices.
    uint random = 0x6d2b79f5;
    foreach (iteration; 0 .. 320)
    {
        random = random * 1664525u + 1013904223u;
        const from = cast(int) (random % expected.length);
        random = random * 1664525u + 1013904223u;
        int to = cast(int) (random % expected.length);
        if (to == from) to = (to + 1) % cast(int) expected.length;

        const beforeMoveCallbacks = moveCallbacks;
        const beforeOrderCallbacks = orderCallbacks;
        driver.drag(taskCenter(root.taskbar, from), taskCenter(root.taskbar, to), 5);
        moveExpected(expected, from, to);
        assertOrder(root.taskbar, expected);
        assert(moveCallbacks == beforeMoveCallbacks + 1);
        assert(orderCallbacks == beforeOrderCallbacks + 1);
    }

    // Programmatic and persisted-order paths share the same invariant logic.
    auto reversed = expected.dup;
    reverse(reversed);
    const beforeRestoreCallbacks = orderCallbacks;
    assert(root.taskbar.setEntryOrder(reversed));
    expected = reversed;
    assertOrder(root.taskbar, expected);
    assert(orderCallbacks == beforeRestoreCallbacks + 1);
    auto invalid = expected.dup;
    invalid[$ - 1] = invalid[0];
    assert(!root.taskbar.setEntryOrder(invalid));
    assertOrder(root.taskbar, expected);

    // Context-menu actions resolve the task by stable identity even when the
    // order changes after the menu was opened.
    const chosenId = root.taskbar.entryId(2);
    driver.rightClick(taskCenter(root.taskbar, 2));
    auto context = cast(ContextMenu) currentTransientPopup(root);
    assert(context !is null);
    assert(root.taskbar.moveEntry(chosenId, 4));
    int moveRightItem = -1;
    foreach (index, item; context.items())
        if (item.label == "Move right"d) moveRightItem = cast(int) index;
    assert(moveRightItem >= 0);
    auto moveRightAction = context.items()[cast(size_t) moveRightItem].action;
    context.dismiss();
    const current = root.taskbar.indexOfEntry(chosenId);
    assert(current == 4);
    moveRightAction();
    assert(root.taskbar.indexOfEntry(chosenId) == 5);
    assert(root.taskbar.taskOrderValid());
}

private void testDesktopIconAndContextMenus()
{
    auto root = new ShellRoot();
    root.setBounds(Rect(0, 0, 900, 640));
    root.layoutTree();
    auto desktop = root.add(new DesktopSurface());
    desktop.setBounds(Rect(0, 0, 900, 588));
    root.bringChildToFront(root.taskbar);

    auto source = desktop.addIcon("Document", IconKind.file);
    auto target = desktop.addIcon("Folder", IconKind.folder);
    target.setBounds(Rect(320, 150, 96, 98));
    desktop.setAlignToGrid(false);
    int drops;
    desktop.onIconDropped = delegate(DesktopIcon dropped, DesktopIcon destination)
    {
        assert(dropped is source && destination is target);
        ++drops;
        return true;
    };

    const original = source.bounds();
    Event down;
    down.button = MouseButton.left;
    down.position = Point(20, 20);
    down.globalPosition = source.localToGlobal(down.position);
    assert(source.onMouseDown(down));
    Event move;
    move.position = Point(20, 20);
    move.globalPosition = target.localToGlobal(Point(48, 49));
    assert(source.onMouseMove(move));
    assert(source.dragging() && target.dropTarget());
    Event up;
    up.button = MouseButton.left;
    up.position = Point(20, 20);
    up.globalPosition = move.globalPosition;
    assert(source.onMouseUp(up));
    assert(drops == 1 && source.bounds() == original && !target.dropTarget());

    bool opened;
    source.onActivated = delegate() { opened = true; };
    Event menuEvent;
    menuEvent.button = MouseButton.right;
    menuEvent.position = Point(20, 20);
    menuEvent.globalPosition = source.localToGlobal(menuEvent.position);
    assert(source.onMouseDown(menuEvent));
    auto menu = cast(ContextMenu) currentTransientPopup(root);
    assert(menu !is null);
    Event enter;
    enter.key = Key.enter;
    assert(menu.onKeyDown(enter));
    assert(opened && currentTransientPopup(root) is null);
}

int main()
{
    testStartMenuAndPopupContracts();
    testPointerLockedTaskDrag();
    testTaskbarOrderStress();
    testDesktopIconAndContextMenus();
    writeln("Desktop shell popup, pointer-locked task drag, Start menu, icon, and stable task-order contracts passed.");
    return 0;
}
