module tests.wifipanel;

import aurora;
import auroradesktop.app : DesktopRoot;
import aurora.widgets.popup : currentTransientPopup;
import std.stdio : writeln, stdout;
import std.utf : toUTF32;

private Point center(Rect r)
{
    return Point(r.x + r.width / 2, r.y + r.height / 2);
}

private Button findButton(Widget subtree, string text)
{
    foreach (child; subtree.children())
    {
        if (auto b = cast(Button) child)
            if (b.text() == toUTF32(text)) return b;
        if (auto n = findButton(child, text)) return n;
    }
    return null;
}

void main()
{
    WindowOptions o;
    o.width = 1280; o.height = 760;
    o.renderer = RendererPreference.software;
    auto w = new GuiWindow(o, Theme.dark());
    auto root = new DesktopRoot();
    w.setRoot(root);
    auto d = new UiTestDriver(w);
    d.resize(Size(1280, 760));
    d.paint();
    auto taskbar = root.taskbarForTesting();

    // Time the open (it should be near-instant: no Thread.sleep).
    import std.datetime.stopwatch : StopWatch, AutoStart;
    auto sw = StopWatch(AutoStart.yes);
    d.click(center(taskbar.trayIconGlobalBounds(0)));
    d.paint();
    sw.stop();
    auto popup = currentTransientPopup(root);
    assert(popup !is null, "wifi panel did not open");
    writeln("panel OPEN time = ", sw.peek.total!"usecs", " usec");
    stdout.flush();

    // Drive the background poll (onTick) - must NOT block (no sleep) and the
    // panel content should refresh as the scan populates.
    foreach (i; 0 .. 8)
    {
        w.onNativeTick(0.2);
        d.paint();
    }
    writeln("after background poll, panel still open = ", popup.parent() !is null);
    stdout.flush();
    writeln("DONE");
}
