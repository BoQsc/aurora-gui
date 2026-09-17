module tests.headless_smoke;

import aurora;
import aurora.widgets.desktop : SystemTrayState, NotificationIcon;
import aurora.widgets.contextmenu : ContextMenu;
import aurora.widgets.popup : currentTransientPopup;
import auroradesktop.app : DesktopRoot;
import auroradesktop.search : SearchPopup;
import auroradesktop.taskpreview : TaskPreview;
import std.stdio : writeln, stdout;
import std.algorithm : canFind;
import std.conv : to;
import std.utf : toUTF32;

private Point center(Rect value)
{
    return Point(value.x + value.width / 2, value.y + value.height / 2);
}

// Drive the taskbar tick enough times to cross the tooltip delay (0.6 s).
private void placeTooltipForTest(GuiWindow window)
{
    foreach (_; 0 .. 6)
    {
        window.onNativeTick(0.2);
    }
}

// Count root-level taskbar tooltip widgets (root children whose class name
// contains "Tooltip").
private int countTooltipWidgets(Widget root)
{
    int count;
    foreach (child; root.children())
    {
        const name = child.classinfo.name;
        if (canFind(name, "Tooltip")) ++count;
    }
    return count;
}

// True if a CalendarPopup is currently attached to the root.
private bool calendarOpen(Widget root)
{
    foreach (child; root.children())
    {
        if (canFind(child.classinfo.name, "CalendarPopup")) return true;
    }
    return false;
}

private Rect globalBounds(Widget widget)
{
    // NB: globalOrigin already includes the widget's own position, so only
    // the size comes from bounds().
    const origin = widget.globalOrigin();
    const local = widget.bounds();
    return Rect(origin.x, origin.y, local.width, local.height);
}

private Button findButton(Widget subtree, string text)
{
    foreach (child; subtree.children())
    {
        auto button = cast(Button) child;
        if (button !is null && button.text() == toUTF32(text))
            return button;
        auto nested = findButton(child, text);
        if (nested !is null) return nested;
    }
    return null;
}

private Slider findSlider(Widget subtree)
{
    foreach (child; subtree.children())
    {
        auto slider = cast(Slider) child;
        if (slider !is null) return slider;
        auto nested = findSlider(child);
        if (nested !is null) return nested;
    }
    return null;
}

// True if the subtree contains a CheckBox control.
private bool hasCheckBox(Widget subtree)
{
    foreach (child; subtree.children())
    {
        if (cast(CheckBox) child !is null) return true;
        if (hasCheckBox(child)) return true;
    }
    return false;
}

// Minimal root hosting only a Taskbar, for pointer-driven drag tests.
private final class TaskbarRoot : Widget
{
    Taskbar taskbar;
    this()
    {
        taskbar = add(new Taskbar());
    }
    protected override void onLayout()
    {
        taskbar.setBounds(Rect(0, maxInt(0, bounds().height - 52),
            bounds().width, 52));
    }
}

// Dragging a task must ease neighbors into their swapped slot instead of
// teleporting them: sample an entry's painted x mid-drag and assert it lies
// strictly between its start and settled positions.
private void testTaskDragAnimation()
{
    WindowOptions options;
    options.width = 640;
    options.height = 260;
    options.renderer = RendererPreference.software;
    auto dragWindow = new GuiWindow(options, Theme.dark());
    auto dragRoot = new TaskbarRoot();
    dragWindow.setRoot(dragRoot);
    auto driver = new UiTestDriver(dragWindow);
    driver.resize(Size(640, 260));
    driver.paint();
    auto taskbar = dragRoot.taskbar;
    foreach (i; 0 .. 5)
        taskbar.addCommand("T" ~ to!string(i), IconKind.file, delegate() {});
    driver.paint();

    const from = center(taskbar.entryGlobalBounds(0));
    const destination = center(taskbar.entryGlobalBounds(4));
    driver.moveTo(from);
    driver.mouseDown();
    driver.moveTo(Point(from.x + 8, from.y));
    assert(taskbar.reordering(), "drag did not start");
    driver.paint();
    // Dragging WITHIN a slot (no boundary crossing) must still rebuild the
    // taskbar layer so the task follows the pointer; it used to look stuck and
    // only jump when it swapped.
    const paintBefore = taskbar.paintGeneration();
    driver.moveTo(Point(from.x + 10, from.y));
    driver.paint();
    assert(taskbar.dragTargetIndex() == 0,
        "a 10px in-slot move should not have swapped yet");
    assert(taskbar.paintGeneration() > paintBefore,
        "taskbar did not repaint while dragging within a slot");
    foreach (step; 1 .. 6)
        driver.moveTo(Point(from.x + (destination.x - from.x) * step / 5,
            from.y));
    assert(taskbar.dragTargetIndex() == 4, "drag did not target slot 4");

    const startX = taskbar.entryPaintedX(1);
    dragWindow.onNativeTick(0.05);
    driver.paint();
    const midX = taskbar.entryPaintedX(1);
    dragWindow.onNativeTick(0.2);
    driver.paint();
    const endX = taskbar.entryPaintedX(1);

    assert(endX != startX, "neighbor never moved");
    assert(midX != startX && midX != endX,
        "neighbor snapped instead of animating (" ~
        to!string(startX) ~ " -> " ~ to!string(midX) ~ " -> " ~
        to!string(endX) ~ ")");
    const between = (midX > endX && midX < startX) ||
        (midX < endX && midX > startX);
    assert(between, "mid-drag neighbor position was not between start and end");
    driver.mouseUp();
}

// Notification behaviour: hover code, generic right-click menu, drag reorder,
// drag-out-to-overflow hide.
private void testNotificationBehavior()
{
    WindowOptions options;
    options.width = 640;
    options.height = 260;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new TaskbarRoot();
    window.setRoot(root);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(640, 260));
    driver.paint();
    auto taskbar = root.taskbar;
    foreach (i; 0 .. 3)
    {
        NotificationIcon icon;
        icon.id = i + 1;
        icon.label = toUTF32("Notif" ~ to!string(i));
        icon.icon = IconKind.file;
        taskbar.addNotification(icon);
    }
    driver.paint();
    assert(taskbar.notifications().length == 3);
    assert(taskbar.notifications()[0].id == 1);

    const first = center(taskbar.notificationIconGlobalBounds(0));
    const third = center(taskbar.notificationIconGlobalBounds(2));

    // Hover code for the first visible notification.
    driver.moveTo(first);
    driver.paint();
    assert(taskbar.hotRegion() == -10,
        "notification hover code was " ~ to!string(taskbar.hotRegion()));

    // Right-click opens a menu (label / Move / Hide) when no app menu is set.
    driver.rightClick(first);
    driver.paint();
    auto menu = cast(ContextMenu) currentTransientPopup(root);
    assert(menu !is null, "notification right-click did not open a menu");
    bool hasLabel, hasHide;
    foreach (item; menu.items())
    {
        const label = to!string(item.label);
        if (label == "Notif0") hasLabel = true;
        if (label == "Hide icon") hasHide = true;
    }
    assert(hasLabel && hasHide, "notification menu is missing items");
    menu.dismiss();

    // Drag the first notification onto the third slot.
    driver.moveTo(first);
    driver.mouseDown();
    driver.moveTo(Point(first.x + 8, first.y));
    driver.moveTo(Point((first.x + third.x) / 2, first.y));
    driver.moveTo(third);
    driver.mouseUp();
    driver.paint();

    const order = taskbar.notifications();
    assert(order.length == 3);
    assert(order[0].id == 2 && order[1].id == 3 && order[2].id == 1,
        "notification drag reorder produced " ~ to!string(order[0].id) ~ "," ~
        to!string(order[1].id) ~ "," ~ to!string(order[2].id));

    // In-place icon/label refresh (tray animation) must not reorder or reset.
    {
        import aurora.image : RgbaImage;
        ubyte[] a; a.length = 16 * 16 * 4;
        ubyte[] b; b.length = 16 * 16 * 4;
        foreach (i; 0 .. 16 * 16)
        {
            a[i * 4 + 3] = 255;
            b[i * 4 + 3] = 255;
            b[i * 4 + 0] = 255;
        }
        auto imageA = new RgbaImage(16, 16, a);
        auto imageB = new RgbaImage(16, 16, b);
        const id = taskbar.notifications()[0].id;
        taskbar.updateNotification(id, toUTF32("Anim"), imageA);
        assert(taskbar.notifications()[0].iconImage is imageA,
            "updateNotification did not set the icon");
        taskbar.updateNotification(id, toUTF32("Anim2"), imageB);
        assert(taskbar.notifications()[0].iconImage is imageB,
            "updateNotification did not replace the icon");
        assert(taskbar.notifications()[0].label == toUTF32("Anim2"));
        assert(taskbar.notifications().length == 3,
            "updateNotification changed the model size");
    }

    // Dragging a notification clear of the cluster hides it.
    size_t hiddenCount()
    {
        size_t count;
        foreach (icon; taskbar.notifications())
            if (icon.hidden) ++count;
        return count;
    }
    const before = hiddenCount();
    const target = center(taskbar.notificationIconGlobalBounds(0));
    driver.moveTo(target);
    driver.mouseDown();
    driver.moveTo(Point(target.x - 10, target.y));
    driver.moveTo(Point(target.x - 120, target.y));
    driver.mouseUp();
    driver.paint();
    assert(hiddenCount() == before + 1,
        "dragging a notification out of the cluster did not hide it");
}

int main()
{
    WindowOptions options;
    options.width = 1280;
    options.height = 760;
    options.renderer = RendererPreference.software;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new DesktopRoot();
    window.setRoot(root);
    root.setShellWindow(window);
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1280, 760));
    driver.paint();

    // Hide-cursor preference: the toggle must hide/show the Aurora system
    // cursor regardless of any persisted on-disk value (which can flip between
    // environments). Start visible, hide, then restore.
    window.setSystemCursorVisible(true);
    assert(window.systemCursorVisible() == true,
        "system cursor should be shown when enabled");
    window.setSystemCursorVisible(false);
    assert(window.systemCursorVisible() == false,
        "system cursor should be hidden when disabled");
    window.setSystemCursorVisible(true);

    // The taskbar must expose its start button, entries, and tray state.
    auto taskbar = root.taskbarForTesting();
    assert(root.bounds() == Rect(0, 0, 1280, 760));
    assert(taskbar.entryCount() >= 2);
    assert(!taskbar.startButtonGlobalBounds().empty());

    // Taskbar icon geometry must be non-empty (0=wifi, 1=volume, 2=battery, 3=hidden).
    foreach (index; 0 .. 4)
        assert(!taskbar.trayIconGlobalBounds(index).empty());

    // Notifications are OS-driven (real tray icons); their behavior is covered
    // deterministically in testNotificationBehavior(). Just ensure the model is
    // coherent here.
    foreach (icon; taskbar.notifications())
        assert(icon.label.length > 0, "notification with an empty label");

    // Hover must highlight ONLY the targeted item: a tray hover returns a
    // negative tray code (-6..-9), never a task-entry index (>= 0). Prior to
    // the fix, tray hover codes (0..3) collided with entry indices, so the
    // pointer over a tray icon also highlighted the first task entries.
    int[int] trayCode = [0: -6, 1: -7, 2: -8, 3: -9];
    foreach (index; 0 .. 4)
    {
        driver.moveTo(center(taskbar.trayIconGlobalBounds(index)));
        driver.paint();
        const hot = taskbar.hotRegion();
        assert(hot == trayCode[index],
            "tray icon " ~ to!string(index) ~ " hover code was " ~ to!string(hot) ~
            ", expected " ~ to!string(trayCode[index]));
    }
    // A task entry hover is a non-negative entry index (never a tray code).
    // entryBounds() is LOCAL, so translate to global before hovering.
    auto entryLocal = taskbar.entryBounds(0);
    auto entryGlobal = taskbar.localToGlobal(
        Point(entryLocal.x + entryLocal.width / 2,
            entryLocal.y + entryLocal.height / 2));
    driver.moveTo(entryGlobal);
    driver.paint();
    assert(taskbar.hotRegion() == 0,
        "first task entry hover should be entry index 0, got " ~
        to!string(taskbar.hotRegion()));

    // Empty taskbar space must NOT highlight the start button (or anything).
    // hitEntry returns -1 for empty space, which is also the start code, so an
    // empty hover used to light the start button. It must now be -2. Compute a
    // point right of the last task entry but left of the tray so the check does
    // not depend on how many OS windows are open.
    const lastEntry = taskbar.entryGlobalBounds(taskbar.entryCount() - 1);
    const trayStart = taskbar.trayIconGlobalBounds(0).x;
    const emptyPoint = Point(
        minInt(lastEntry.right() + 10, trayStart - 10),
        lastEntry.y + lastEntry.height / 2);
    driver.moveTo(emptyPoint);
    driver.paint();
    assert(taskbar.hotRegion() == -2,
        "empty taskbar space should be no-highlight (-2), got " ~
        to!string(taskbar.hotRegion()));

    // A live refresh must publish a valid tray snapshot without throwing.
    root.refreshTrayForTesting();
    const tray = taskbar.trayState();
    assert(tray.volumePercent >= 0 && tray.volumePercent <= 100);

    // Clock must be padded from the show-desktop button (gap >= 4 px).
    const clockB = taskbar.clockBounds();
    const showB = taskbar.showDesktopBounds();
    const clockGap = showB.x - (clockB.x + clockB.width);
    assert(clockGap >= 4, "date/time merged with show-desktop: gap " ~ clockGap.to!string);

    // Clicking the clock opens the calendar flyout; Escape/click-away closes it.
    driver.click(center(clockB));
    driver.paint();
    assert(calendarOpen(root), "clock click did not open the calendar");
    // Slide animation runs on ticks; then Escape dismisses.
    foreach (_; 0 .. 4) { window.onNativeTick(0.1); }
    driver.pressKey(Key.escape);
    driver.paint();
    assert(!calendarOpen(root), "escape did not close the calendar");

    // Hovering a tray icon for just past the delay shows a tooltip overlay.
    driver.moveTo(center(taskbar.trayIconGlobalBounds(0)));
    driver.paint();
    writeln("hovering wifi, ticking...");
    placeTooltipForTest(window);  // drive the tooltip timer via a tick
    driver.paint();
    const tooltipCount = countTooltipWidgets(root);
    writeln("tooltip widgets after wifi hover = ", tooltipCount);
    assert(tooltipCount == 1, "expected a tooltip for the wifi tray icon");
    // Moving to empty space hides it.
    driver.moveTo(Point(400, 720));
    driver.paint();
    window.onNativeTick(0.2);
    driver.paint();
    assert(countTooltipWidgets(root) == 0,
        "tooltip should hide when the pointer leaves the taskbar region");

    // The Start button opens the start menu; closing restores state.
    driver.click(center(taskbar.startButtonGlobalBounds()));
    assert(taskbar.startMenuOpen());
    driver.paint();
    window.saveScreenshot("build/headless-desktop-menu.ppm");
    driver.pressKey(Key.escape);
    assert(!taskbar.startMenuOpen());

    // Each tray icon opens its own popup panel (wifi, volume, battery, hidden).
    string[4] names = ["wifi", "volume", "battery", "hidden"];
    foreach (index; 0 .. 4)
    {
        driver.click(center(taskbar.trayIconGlobalBounds(index)));
        driver.paint();
        auto popup = currentTransientPopup(root);
        assert(popup !is null, "no popup opened for tray icon " ~ names[index]);
        window.saveScreenshot("build/headless-desktop-tray-" ~ names[index] ~ ".ppm");
        // The WiFi panel must offer a working Refresh control backed by the
        // real WLAN query path (which degrades gracefully without hardware).
        if (names[index] == "wifi")
        {
            import auroradesktop.wlan : queryWifi;
            const state = queryWifi(); // Must never throw.
            assert(findButton(popup, "Refresh") !is null);
            if (state.available)
            {
                writeln("wifi: ", state.networks.length, " network(s), connected=",
                    state.connected);
                // A connected interface MUST surface the network it is on with
                // its saved profile, or clicking it can never reconnect.
                if (state.connected)
                {
                    bool found;
                    foreach (n; state.networks)
                    {
                        if (n.ssid == state.ssid)
                        {
                            found = true;
                            assert(n.profile.length > 0,
                                "connected network lost its saved profile: " ~ n.ssid);
                        }
                    }
                    assert(found, "connected SSID not present in the scan: " ~
                        state.ssid);
                }
            }
            else
                writeln("wifi: adapter unavailable (graceful fallback)");
        }
        driver.pressKey(Key.escape);
        driver.paint();
        assert(currentTransientPopup(root) is null);
    }

    // Output-device enumeration exposes at least one device and the
    // selection round-trips.
    version (Windows)
    {
        import auroradesktop.system : audioOutputDevices, selectedAudioDevice,
            selectAudioDevice;
        const devices = audioOutputDevices();
        assert(devices.length >= 1, "no output devices enumerated");
        selectAudioDevice(0);
        assert(selectedAudioDevice() == 0);
    }

    // The volume slider and Mute button really drive the Windows mixer.
    version (Windows)
    {
        import auroradesktop.system : systemMuted,
            setSystemMuted, systemVolume, setSystemVolume;
        // Verified live on this machine: the mixer VOLUME + MUTE controls
        // round-trip (mute flips both ways, slider drives the level). The
        // WASAPI endpoint path cannot work here (MMDevAPI factory refuses
        // IMMDeviceEnumerator QI - proven), so no endpoint assertion.
        const original = systemVolume();
        const originalMuted = systemMuted();
        scope (exit)
        {
            setSystemVolume(original);
            setSystemMuted(originalMuted);
        }
        // The mixer is live shared machine state: force a known baseline
        // first so every assertion below is deterministic. Restored on exit.
        setSystemMuted(false);
        setSystemVolume(100);
        root.refreshTrayForTesting();
        driver.click(center(taskbar.trayIconGlobalBounds(1)));
        driver.paint();
        auto volumePopup = currentTransientPopup(root);
        assert(volumePopup !is null);
        // Drive the level through the UI slider: click at the 60% point.
        // (Slider maps x in [left+10, right-10] linearly to [min, max].)
        auto slider = findSlider(volumePopup);
        assert(slider !is null, "slider not found in volume panel");
        const sliderBounds = globalBounds(slider);
        const sliderAt = Point(sliderBounds.x + 10 +
            cast(int) (0.6 * (sliderBounds.width - 20)),
            sliderBounds.y + sliderBounds.height / 2);
        // The click must land on the slider itself, not an overlapping row.
        assert(root.hitTest(sliderAt) is slider);
        driver.click(sliderAt);
        driver.paint();
        const level = systemVolume();
        assert(level >= 55 && level <= 65,
            "slider did not drive the mixer to ~60");
        // Mute through the UI button, then restore through Unmute. Mute is
        // a real mixer flag now, so the level stays while muted bit flips.
        import auroradesktop.system : systemMuted;
        auto muteButton = findButton(volumePopup, "Mute");
        assert(muteButton !is null, "Mute button not found in volume panel");
        driver.click(center(globalBounds(muteButton)));
        driver.paint();
        assert(systemMuted(), "mixer was not muted");
        auto unmuteButton = findButton(volumePopup, "Unmute");
        assert(unmuteButton !is null, "Unmute button not found after mute");
        driver.click(center(globalBounds(unmuteButton)));
        driver.paint();
        // The button text flips back only if the click ran onClick+update.
        assert(findButton(volumePopup, "Mute") !is null,
            "unmute click missed the button");
        assert(!systemMuted(), "mixer was not unmuted");
        const restored = systemVolume();
        assert(restored >= 55 && restored <= 65,
            "mixer was not restored to the slider level");
        driver.pressKey(Key.escape);
        assert(currentTransientPopup(root) is null);
    }

    // The search pill opens the dedicated SearchPopup (a Windows-11-style
    // search flyout), NOT the Start menu. It anchors below the pill and
    // filters results live as the user types.
    const searchGlobal = taskbar.searchButtonGlobalBounds();
    assert(!searchGlobal.empty(), "search pill has no bounds in modern shell");
    driver.click(center(searchGlobal));
    driver.paint();
    auto searchPopup = currentTransientPopup(root);
    assert(searchPopup !is null, "search pill did not open a popup");
    assert(canFind(searchPopup.classinfo.name, "SearchPopup"),
        "search pill opened the wrong popup: " ~ searchPopup.classinfo.name);
    // All 7 registered results are shown before any typing.
    auto search = cast(SearchPopup) searchPopup;
    assert(search !is null, "search popup cast failed");
    assert(search.resultCount() == 7, "search popup did not list all results");

    // Live filtering: typing "sett" narrows to the two Settings entries.
    driver.text("sett");
    driver.paint();
    assert(search.resultCount() == 2,
        "search did not filter to Settings (count=" ~
        to!string(search.resultCount()) ~ ")");
    assert(to!string(search.query()) == "sett", "search query not captured");

    driver.pressKey(Key.escape);
    driver.paint();
    assert(currentTransientPopup(root) is null,
        "escape did not close the search popup");

    // Task thumbnail preview: hovering a window task entry opens a TaskPreview
    // popup anchored above it; moving away dismisses it.
    assert(taskbar.entryCount() >= 1);
    const entry0 = taskbar.entryGlobalBounds(0);
    assert(!entry0.empty(), "task entry has no global bounds");
    auto hoverWindow = taskbar.entryWindow(0);
    if (hoverWindow !is null) hoverWindow.restore();
    driver.paint();
    const entryCenter = center(entry0);
    driver.moveTo(entryCenter);
    // The preview appears only after a stable-hover delay.
    window.onNativeTick(0.29);
    driver.paint();
    assert(currentTransientPopup(root) is null,
        "preview appeared before the hover delay elapsed");
    // The tiny final tick crosses the delay, so the preview is created and
    // faded only a little in that same frame.
    window.onNativeTick(0.02);
    driver.paint();
    auto preview = currentTransientPopup(root);
    assert(preview !is null, "task hover did not open a preview");
    assert(canFind(preview.classinfo.name, "TaskPreview"),
        "task hover opened the wrong popup: " ~ preview.classinfo.name);
    auto hoverPreview = cast(TaskPreview) preview;
    assert(hoverPreview !is null, "preview cast failed");
    assert(hoverPreview.opacity() > 0.0 && hoverPreview.opacity() < 1.0,
        "preview did not fade in (opacity=" ~
        to!string(hoverPreview.opacity()) ~ ")");
    window.onNativeTick(0.2);
    driver.paint();
    assert(hoverPreview.opacity() == 1.0, "preview fade did not complete");
    // Regression: a tiny move within the SAME entry must not dismiss it. The
    // preview overlay used to steal hover and flicker the flyout closed/open.
    driver.moveTo(Point(entryCenter.x + 2, entryCenter.y));
    window.onNativeTick(0.05);
    driver.paint();
    assert(currentTransientPopup(root) is preview,
        "preview dismissed while still hovering the task");
    // Regression: moving onto the preview panel keeps it open and interactive.
    auto taskPreview = cast(TaskPreview) currentTransientPopup(root);
    assert(taskPreview !is null, "preview cast failed");
    const panel = taskPreview.panelRect();
    const panelOrigin = taskPreview.globalOrigin();
    const panelGlobal = Rect(panelOrigin.x + panel.x, panelOrigin.y + panel.y,
        panel.width, panel.height);
    driver.moveTo(center(panelGlobal));
    window.onNativeTick(0.05);
    driver.paint();
    assert(currentTransientPopup(root) is taskPreview,
        "preview did not stay open while the pointer was over its panel");
    assert(taskPreview.pointerInside(),
        "preview did not report the pointer inside");
    // Moving to empty taskbar space dismisses the preview after the grace
    // window (long enough for the pointer to travel onto the flyout).
    driver.moveTo(Point(400, 30));
    window.onNativeTick(0.4);
    driver.paint();
    assert(currentTransientPopup(root) is null,
        "task preview did not dismiss when pointer left the entry");

    // External OS task buttons must paint the window's real raster icon, not
    // an empty IconKind slot. Attach a synthetic magenta icon to a probe task
    // and assert the taskbar actually renders it.
    version (Windows)
    {
        import aurora.surface : Surface;
        import aurora.canvas : Canvas;
        import aurora.image : RgbaImage;

        auto probeBar = new Taskbar();
        probeBar.setBounds(Rect(0, 0, 640, 52));
        const probeHwnd = 0xDEADBEEF;
        probeBar.addExternalTask(probeHwnd, "Probe");
        const probeIndex = probeBar.indexOfExternal(probeHwnd);
        assert(probeIndex >= 0, "external probe entry was not added");
        enum int side = 26;
        ubyte[] pixels;
        pixels.length = side * side * 4;
        foreach (i; 0 .. side * side)
        {
            pixels[i * 4 + 0] = 255;
            pixels[i * 4 + 1] = 0;
            pixels[i * 4 + 2] = 255;
            pixels[i * 4 + 3] = 255;
        }
        assert(probeBar.setExternalTaskIcon(probeHwnd,
                new RgbaImage(side, side, pixels)),
            "external task icon was not attached");
        assert(probeBar.externalTaskIconResolved(probeHwnd));
        auto probeSurface = new Surface(640, 52);
        probeSurface.clear(Color.rgb(0, 0, 0));
        auto probeCanvas = Canvas(probeSurface);
        probeBar.paintTree(probeCanvas);
        bool foundIcon;
        foreach (y; 0 .. 52)
        {
            foreach (x; 0 .. 640)
            {
                const argb = probeSurface.pixel(x, y);
                const r = (argb >> 16) & 0xff;
                const g = (argb >> 8) & 0xff;
                const b = argb & 0xff;
                if (r > 200 && g < 80 && b > 200)
                {
                    foundIcon = true;
                    break;
                }
            }
            if (foundIcon) break;
        }
        assert(foundIcon, "external task raster icon was not painted");

        // Task grouping: same-app external windows collapse into one button and
        // the toggle splits/merges them without a host resync.
        auto groupBar = new Taskbar();
        groupBar.setBounds(Rect(0, 0, 640, 52));
        assert(groupBar.taskGrouping(), "task grouping should default to on");
        groupBar.addExternalTask(0x1111, "App A - 1", IconKind.computer, "appA");
        groupBar.addExternalTask(0x2222, "App A - 2", IconKind.computer, "appA");
        groupBar.addExternalTask(0x3333, "App B", IconKind.computer, "appB");
        const groupIndex = groupBar.indexOfExternal(0x1111);
        assert(groupIndex >= 0);
        assert(groupBar.indexOfExternal(0x2222) == groupIndex,
            "same-app window did not join its group");
        assert(groupBar.entryHostHwndCount(cast(size_t) groupIndex) == 2);
        assert(groupBar.entryCount() == 2, "expected one task button per app");
        groupBar.setTaskGrouping(false);
        assert(groupBar.entryCount() == 3, "disabling grouping must split tasks");
        assert(groupBar.indexOfExternal(0x1111) !=
            groupBar.indexOfExternal(0x2222));
        groupBar.setTaskGrouping(true);
        assert(groupBar.entryCount() == 2, "re-enabling grouping must merge tasks");
        assert(groupBar.removeExternal(0x2222));
        assert(groupBar.entryCount() == 2,
            "removing one member must keep the group alive");
        assert(groupBar.entryHostHwndCount(groupBar.indexOfExternal(0x1111)) == 1);
        assert(groupBar.removeExternal(0x1111));
        assert(groupBar.entryCount() == 1,
            "removing the last member must drop the group");
    }

    // The user's notification arrangement must survive the 2 s OS-tray refresh
    // (the shell reads the live taskbar order instead of snapping back).
    size_t[] visibleNotificationIds()
    {
        size_t[] ids;
        foreach (icon; taskbar.notifications())
            if (!icon.hidden) ids ~= icon.id;
        return ids;
    }
    auto visibleBefore = visibleNotificationIds();
    if (visibleBefore.length >= 3)
    {
        assert(taskbar.moveNotification(0, 2));
        auto visibleMoved = visibleNotificationIds();
        assert(visibleMoved.length == visibleBefore.length);
        assert(visibleMoved[2] == visibleBefore[0],
            "moveNotification did not move the first visible icon to the end");
        window.onNativeTick(2.1);
        driver.paint();
        assert(visibleNotificationIds()[2] == visibleBefore[0],
            "notification order was reset by the periodic refresh");
    }

    // Empty-taskbar right-click menu: Show the desktop / Task Manager /
    // Lock the taskbar (checkable) / Taskbar settings.
    {
        const menuLastEntry = taskbar.entryGlobalBounds(taskbar.entryCount() - 1);
        const menuPoint = Point(
            minInt(menuLastEntry.right() + 10,
                taskbar.trayIconGlobalBounds(0).x - 10),
            menuLastEntry.y + menuLastEntry.height / 2);
        driver.rightClick(menuPoint);
        driver.paint();
        auto menu = cast(ContextMenu) currentTransientPopup(root);
        assert(menu !is null, "taskbar right-click did not open a context menu");
        bool hasDesktop, hasTaskMgr, hasLock, hasSettings, lockChecked;
        void delegate() settingsAction;
        foreach (item; menu.items())
        {
            const label = to!string(item.label);
            if (label == "Show the desktop" || label == "Restore windows")
                hasDesktop = true;
            else if (label == "Task Manager") hasTaskMgr = true;
            else if (label == "Lock the taskbar")
            {
                hasLock = true;
                lockChecked = item.checked;
                if (item.action !is null) item.action();
            }
            else if (label == "Taskbar settings")
            {
                hasSettings = true;
                settingsAction = item.action;
            }
        }
        assert(hasDesktop, "menu is missing Show the desktop");
        assert(hasTaskMgr, "menu is missing Task Manager");
        assert(hasLock, "menu is missing Lock the taskbar");
        assert(hasSettings, "menu is missing Taskbar settings");
        assert(!lockChecked, "Lock the taskbar should start unchecked");
        assert(taskbar.taskbarLocked(), "activating Lock did not lock the taskbar");
        taskbar.setTaskbarLocked(false);

        // "Taskbar settings" must open a real settings UI with controls.
        assert(settingsAction !is null, "Taskbar settings has no action");
        settingsAction();
        driver.paint();
        auto settingsPanel = currentTransientPopup(root);
        assert(settingsPanel !is null, "Taskbar settings did not open a UI");
        assert(canFind(settingsPanel.classinfo.name, "PopupOverlay"),
            "Taskbar settings opened the wrong popup: " ~
            settingsPanel.classinfo.name);
        assert(hasCheckBox(settingsPanel),
            "Taskbar settings UI has no controls");
        settingsPanel.dismiss();
        driver.paint();
    }

    testTaskDragAnimation();
    testNotificationBehavior();

    window.saveScreenshot("build/headless-desktop.ppm");
    writeln("aurora-desktop headless smoke: ALL PASSED");
    return 0;
}
