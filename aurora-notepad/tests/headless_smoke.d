module auroranotepad_headless_smoke;

import aurora;
import aurora.testing : UiTestDriver;
import auroranotepad.appui : NotepadRoot, notepadTheme;
import std.stdio : writeln;

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
private void resetClickState(UiTestDriver driver, int windowWidth, int windowHeight)
{
    driver.click(Point(30, windowHeight - 10));
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Notepad";
    options.width = 1080;
    options.height = 680;
    options.renderer = RendererPreference.software;

    auto window = new GuiWindow(options, notepadTheme());
    auto root = new NotepadRoot(window);
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(options.width, options.height));
    assert(driver.paint(), "Initial Notepad paint failed");

    auto bar = root.titleBar();
    assert(bar !is null, "Notepad titlebar missing");
    assert(bar.barHeight() == 28, "Custom titlebar height not applied");
    assert(bar.iconKind() == IconKind.notepad, "Notepad icon not set");
    assert(bar.title() == "Untitled — Aurora Notepad", "Default title wrong");

    auto snapPreview = root.snapPreview();
    assert(snapPreview !is null);
    assert(!snapPreview.enabled(),
        "Snap preview must be created disabled (input-transparent)");

    // --- Menu bar: classic File/Edit/Format/View/Help row. ---
    auto menuBar = root.menuBar();
    assert(menuBar !is null, "Menu bar missing");
    assert(menuBar.children().length == 5,
        "Menu bar does not have the five Win10 menus");
    assert(menuBar.bounds().y == bar.barHeight(),
        "Menu bar is not directly below the titlebar");

    // --- Editor: borderless (no field focus ring). ---
    auto editor = root.editor();
    assert(editor !is null, "Editor missing");
    assert(editor.textView().length == 0, "Editor should start empty");
    // The editor must not paint an accent focus border: clicking into it then
    // painting must not crash and the editor remains the same widget.
    editor.requestFocus();
    assert(editor.focused(), "Editor did not take focus");
    assert(driver.paint(), "Editor focus paint failed");
    assert(editor is root.editor(), "Editor replaced unexpectedly");
    resetClickState(driver, options.width, options.height);
    assert(!editor.focused(), "Editor did not release focus");

    // --- Caption buttons fire through real dispatch. ---
    bool closed;
    bar.onClose = delegate() { closed = true; };
    driver.click(captionCenter(bar, TitleBarControl.close));
    assert(closed, "Close callback did not fire");

    // --- Work-area maximize through the caption button. ---
    driver.setTestWorkArea(Rect(0, 0, 1920, 1040));
    driver.click(captionCenter(bar, TitleBarControl.maximize));
    Rect snapped;
    assert(driver.lastWindowBounds(snapped), "Maximize did not set window bounds");
    assert(snapped == Rect(0, 0, 1920, 1040),
        "Maximize did not apply the work area");
    assert(bar.maximized(), "Titlebar did not track the maximized state");
    driver.click(captionCenter(bar, TitleBarControl.maximize));
    assert(!bar.maximized(), "Second maximize click did not restore");
    driver.setTestWorkArea(Rect.init);

    // --- Double-click on the title toggles maximize. ---
    resetClickState(driver, options.width, options.height);
    driver.doubleClick(titleCenter(bar));
    assert(bar.maximized(), "Double-click did not maximize");
    resetClickState(driver, options.width, options.height);
    driver.doubleClick(titleCenter(bar));
    assert(!bar.maximized(), "Double-click did not restore");

    // --- Drag down from maximized restores the initial window size. ---
    // Regression: the vendored TitleBar clears its own maximized flag BEFORE
    // firing onRestoreRequested, so restore-on-drag must use the notepad's own
    // state and always force the saved pre-maximize bounds. Without this the
    // restore bailed early and the window stayed at the maximized extent.
    driver.setTestWorkArea(Rect(0, 0, 1920, 1040));
    resetClickState(driver, options.width, options.height);
    driver.click(captionCenter(bar, TitleBarControl.maximize));
    assert(bar.maximized(), "Maximize did not engage for drag-restore test");
    assert(driver.lastWindowBounds(snapped) && snapped == Rect(0, 0, 1920, 1040),
        "Window was not maximized to the work area");
    driver.setTestScreenPointerPosition(PointF(500, 14));
    driver.moveTo(Point(300, 14));
    driver.mouseDown(MouseButton.left);
    driver.setTestScreenPointerPosition(PointF(500, 200));
    driver.moveTo(Point(300, 120)); // crosses the drag threshold: restore
    assert(!bar.maximized(), "Drag down did not leave the maximized state");
    assert(driver.lastWindowBounds(snapped) &&
        snapped == Rect(0, 0, options.width, options.height),
        "Drag down did not restore the initial window size");
    driver.mouseUp(MouseButton.left);
    driver.setTestWorkArea(Rect.init);
    driver.setTestScreenPointerPosition(PointF(0, 0));
    // Clear the click counter: the drag-restore press used the same titlebar
    // point as the snap test below, which would otherwise read as a
    // double-click (clickCount 2) and toggle maximize instead of dragging.
    resetClickState(driver, options.width, options.height);

    // --- Drag-snap to the left edge applies the work-area half. ---
    driver.setTestWorkArea(Rect(0, 0, 1920, 1040));
    driver.setTestScreenPointerPosition(PointF(500, 520));
    driver.moveTo(Point(300, 14)); // middle of the 28px titlebar
    driver.mouseDown(MouseButton.left);
    driver.setTestScreenPointerPosition(PointF(500, 520));
    driver.moveTo(Point(300, 40)); // crosses the drag threshold: drag starts
    assert(bar.dragging(), "Titlebar drag did not start for snap test");
    driver.setTestScreenPointerPosition(PointF(3, 520));
    driver.moveTo(Point(300, 60)); // now inside the left snap zone
    assert(bar.snapTarget() == TitleBarSnapTarget.left,
        "Left-edge snap target not detected");
    assert(snapPreview.active(), "Snap preview did not show over the left zone");
    driver.mouseUp(MouseButton.left);
    assert(driver.lastWindowBounds(snapped), "Snap release did not set bounds");
    assert(snapped == Rect(0, 0, 960, 1040),
        "Left snap applied wrong bounds");
    assert(!snapPreview.active(), "Snap preview did not hide after release");
    assert(!bar.dragging(), "Drag did not end after snap release");
    driver.setTestWorkArea(Rect.init);
    driver.setTestScreenPointerPosition(PointF(0, 0));

    // --- The full-size snap-preview overlay must NOT block titlebar input. ---
    snapPreview.show(Rect(0, 0, options.width, options.height));
    resetClickState(driver, options.width, options.height);
    closed = false;
    driver.click(captionCenter(bar, TitleBarControl.close));
    assert(closed, "Close button did not fire with the preview overlay present");
    snapPreview.hide();
    assert(!snapPreview.active(), "Snap preview did not hide");

    // --- Title reflects the document name and dirty marker. ---
    bar.setDocumentTitle("ideas.txt", true);
    assert(bar.title() == "*ideas.txt — Aurora Notepad", "Dirty title wrong");
    bar.setDocumentTitle("ideas.txt", false);
    assert(bar.title() == "ideas.txt — Aurora Notepad", "Clean title wrong");
    bar.setDocumentTitle("Untitled", false);
    assert(bar.title() == "Untitled — Aurora Notepad", "Untitled title wrong");

    // --- Hovering a flat menu item paints the Win10 highlight. ---
    const firstMenu = menuBar.children()[0];
    assert(firstMenu !is null, "Menu bar has no first item");
    const hoverCenter = firstMenu.localToGlobal(Point(
        firstMenu.bounds().width / 2, firstMenu.bounds().height / 2));
    driver.moveTo(Point(hoverCenter.x, hoverCenter.y));
    assert(driver.paint(), "Menu item hover paint failed");
    window.saveScreenshot("build/headless-smoke/notepad-smoke-toolbar-hover.ppm");
    resetClickState(driver, options.width, options.height);

    // --- File menu opens a dropdown below the item and its commands fire. ---
    driver.click(Point(hoverCenter.x, hoverCenter.y)); // open File menu
    assert(driver.paint(), "File menu open paint failed");
    window.saveScreenshot("build/headless-smoke/notepad-smoke-filemenu.ppm");
    resetClickState(driver, options.width, options.height);

    assert(driver.paint(), "Notepad paint after edits failed");

    import std.file : mkdirRecurse;
    mkdirRecurse("build/headless-smoke");
    window.saveScreenshot("build/headless-smoke/notepad-smoke.ppm");
    // The focused editor must not paint a field focus ring: save a focused
    // screenshot so the top edge of the editor area can be pixel-verified.
    editor.requestFocus();
    assert(driver.paint(), "Focused-editor paint failed");
    window.saveScreenshot("build/headless-smoke/notepad-smoke-focused.ppm");
    resetClickState(driver, options.width, options.height);
    assert(!editor.focused(), "Editor did not release focus");

    import std.stdio : writeln;
    writeln("Aurora Notepad headless smoke passed.");
    return 0;
}
