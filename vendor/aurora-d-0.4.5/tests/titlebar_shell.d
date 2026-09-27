module aurora_titlebar_shell_test;

import aurora;
import aurora.platform.headless : PlatformWindow;
import std.stdio : writeln;

void main()
{
    WindowOptions options;
    options.width = 800;
    options.height = 600;
    options.decorated = false;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto native = cast(PlatformWindow) window.nativeWindow();
    assert(native !is null);

    const restored = Rect(100, 80, 800, 600);
    const workArea = Rect(0, 0, 1920, 1040);
    native.setWindowBounds(restored);
    native.setTestWorkArea(workArea);

    auto bar = new FramelessWindowTitleBar(window);
    auto preview = new TitleBarSnapPreview();
    bar.setSnapPreview(preview);

    // Caption maximize uses the monitor work area and restores exact bounds.
    bar.onMaximizeToggle();
    Rect actual;
    assert(native.lastWindowBounds(actual) && actual == workArea);
    assert(bar.maximizedState() && bar.maximized());
    assert(bar.restoredBounds() == restored);
    bar.onMaximizeToggle();
    assert(native.lastWindowBounds(actual) && actual == restored);
    assert(!bar.maximizedState() && !bar.maximized());

    // Restore-on-drag preserves the fractional horizontal grab and gives the
    // continuing owner-driven drag one stable screen-space anchor.
    bar.onMaximizeToggle();
    native.setTestScreenPointerPosition(PointF(960, 10));
    bar.onRestoreRequested(PointF(960, 10), PointF(960, 10));
    assert(native.lastWindowBounds(actual) && actual == Rect(560, 0, 800, 600));
    assert(!bar.maximizedState());
    bar.onDragStarted(PointF(960, 10), PointF(560, 0));
    native.setTestScreenPointerPosition(PointF(1060, 70));
    assert(bar.onDragMoved(PointF(1060, 70), true));
    assert(native.lastWindowBounds(actual) && actual == Rect(660, 60, 800, 600));

    // Snap preview coordinates are mapped from screen space into the window,
    // then hidden when the same target is committed.
    const left = Rect(0, 0, 960, 1040);
    bar.onSnapChanged(TitleBarSnapTarget.left, left);
    assert(preview.active());
    assert(preview.previewBounds() == Rect(-660, -60, 960, 1040));
    bar.onSnapApplied(TitleBarSnapTarget.left, left);
    assert(!preview.active());
    assert(native.lastWindowBounds(actual) && actual == left);
    assert(!bar.maximizedState());

    // Top snap is the shared maximized state and exposes the standard menu.
    bar.onSnapApplied(TitleBarSnapTarget.top, workArea);
    assert(bar.maximizedState() && bar.maximized());
    const menu = bar.systemMenuItems();
    assert(menu.length == 5);
    assert(menu[0].enabled);
    assert(menu[1].label == "Restore down"d);
    assert(menu[2].label == "Minimize"d);
    assert(menu[3].separator);
    assert(menu[4].label == "Close"d && menu[4].shortcut == "Alt+F4"d);

    // Product-specific tray/close policies remain injectable without copying
    // any window-shell orchestration into the application.
    bool minimized;
    bool closed;
    bar.setMinimizeAction(delegate() { minimized = true; });
    bar.setCloseAction(delegate() { closed = true; });
    bar.onMinimize();
    bar.onClose();
    assert(minimized && closed);

    window.close();
    writeln("Frameless titlebar shell regression passed.");
}

