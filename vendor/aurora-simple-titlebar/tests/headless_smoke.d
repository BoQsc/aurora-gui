module headless_smoke;

import aurora;
import aurorasimpletitlebar.titlebar;

private void check(bool condition, string message)
{
    if (!condition) throw new Exception("simple titlebar smoke failed: " ~ message);
}

int main()
{
    auto bar = new SimpleTitleBar();
    bar.setBounds(Rect(0, 0, 800, 23));
    check(bar.barHeight() == 23, "default height");
    check(bar.captionButtonWidth() == 36, "Windows caption width");
    check(bar.titleFontSize() == 12, "Windows caption font size");
    check(bar.iconSize() == 16, "application icon size");
    check(bar.captionRect(SimpleTitleBarControl.close) == Rect(764, 0, 36, 23),
        "close geometry");
    check(bar.controlAt(Point(777, 11)) == SimpleTitleBarControl.close,
        "close hit test");
    check(bar.controlAt(Point(100, 11)) == SimpleTitleBarControl.title,
        "title hit test");

    bool closed;
    bar.onClose = delegate() { closed = true; };
    Event closeDown;
    closeDown.button = MouseButton.left;
    closeDown.position = Point(777, 11);
    check(bar.onMouseDown(closeDown), "close press");
    Event closeUp;
    closeUp.button = MouseButton.left;
    closeUp.position = Point(777, 11);
    check(bar.onMouseUp(closeUp), "close release");
    check(closed, "close callback");

    bool maximized;
    bar.onMaximizeToggle = delegate() { maximized = true; };
    Event doubleClick;
    doubleClick.button = MouseButton.left;
    doubleClick.position = Point(100, 11);
    doubleClick.clickCount = 2;
    check(bar.onMouseDown(doubleClick), "double-click title");
    check(maximized, "double-click callback");

    bool menu;
    bar.onSystemMenu = delegate(Point) { menu = true; };
    Event rightClick;
    rightClick.button = MouseButton.right;
    rightClick.position = Point(100, 11);
    check(bar.onMouseDown(rightClick), "system menu press");
    check(menu, "system menu callback");

    bar.setMaximized(true);
    check(bar.maximized(), "maximized state");
    bar.setShowIcon(false);
    check(bar.iconRect().empty, "icon can be hidden");

    import std.stdio : writeln;
    writeln("simple_titlebar: ALL PASSED");
    return 0;
}
