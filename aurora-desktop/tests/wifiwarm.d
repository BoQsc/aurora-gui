module tests.wifiwarm;

import aurora;
import auroradesktop.app : DesktopRoot;
import aurora.widgets.popup : currentTransientPopup;
import std.stdio : writeln, stdout;
import std.utf : toUTF32;
import core.time : msecs;
import core.thread : Thread;

private Point center(Rect r) { return Point(r.x + r.width/2, r.y + r.height/2); }

private void countButtons(Widget subtree, ref int cnt)
{
    foreach (child; subtree.children())
    {
        if (cast(Button) child !is null) ++cnt;
        countButtons(child, cnt);
    }
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

    // Let the app live for ~3 s of ticks (the 2 s tray refresh kicks a scan).
    // onTick drives refreshTray -> kickWifiScan, so the cache warms up.
    foreach (_; 0 .. 15)
    {
        w.onNativeTick(0.2);
        Thread.sleep(msecs(200));
        d.paint();
    }
    writeln("warmed for ~3s of tick+real time");
    stdout.flush();

    // Now open the WiFi panel exactly like clicking the tray icon.
    d.click(center(taskbar.trayIconGlobalBounds(0)));
    d.paint();
    auto popup = currentTransientPopup(root);
    assert(popup !is null);
    // Buttons = network rows + footer(Refresh/Disconnect/settings). Network
    // rows are the ones with IconKind.wifi + a "signal%".
    int btnCount;
    countButtons(popup, btnCount);
    writeln("panel button count on open = ", btnCount,
        " (rows + footer: means >=4 => networks populated)");
    stdout.flush();

    // Also drive the post-open poll a bit.
    foreach (_; 0 .. 10) { w.onNativeTick(0.2); d.paint(); }
    int btnCount2;
    countButtons(popup, btnCount2);
    writeln("panel button count after poll = ", btnCount2);
    stdout.flush();
    writeln("DONE");
}
