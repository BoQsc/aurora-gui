module tests.headless_smoke;

import aurora;
import aurora.widgets.desktop : SystemTrayState, NotificationIcon;
import aurora.widgets.popup : currentTransientPopup;
import auroradesktop.app : DesktopRoot;
import auroradesktop.search : SearchPopup;
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

    // The shell registers three notification icons; each visible icon has
    // global bounds and a hover code in the -10.. block (never a task index).
    assert(taskbar.notifications().length >= 3,
        "shell notifications were not registered");
    int notifSeen;
    foreach (i, icon; taskbar.notifications())
    {
        if (icon.hidden) continue;
        const nB = taskbar.notificationIconGlobalBounds(i);
        assert(!nB.empty(), "visible notification has no bounds");
        driver.moveTo(center(nB));
        driver.paint();
        const nHot = taskbar.hotRegion();
        assert(nHot == -(10 + notifSeen),
            "notification hover code was " ~ to!string(nHot) ~
            ", expected " ~ to!string(-(10 + notifSeen)));
        ++notifSeen;
    }
    // Hiding a notification moves it into the overflow and updates the tray.
    const firstNotif = taskbar.notifications()[0];
    taskbar.setNotificationHidden(firstNotif.id, true);
    assert(taskbar.trayState().hiddenIconCount >= 1,
        "hiding a notification did not update hiddenIconCount");

    // Drag-triggered hide: dragging a visible notification far left hides it.
    // Find a currently visible notification and drag it left by 80 px.
    NotificationIcon dragTarget;
    bool haveTarget;
    foreach (icon; taskbar.notifications())
    {
        if (!icon.hidden)
        {
            dragTarget = icon;
            haveTarget = true;
            break;
        }
    }
    if (haveTarget)
    {
        const before = taskbar.trayState().hiddenIconCount;
        driver.drag(center(taskbar.notificationIconGlobalBounds(0)),
            Point(center(taskbar.notificationIconGlobalBounds(0)).x - 80,
                center(taskbar.notificationIconGlobalBounds(0)).y), 8);
        driver.paint();
        assert(taskbar.trayState().hiddenIconCount == before + 1,
            "dragging a notification left did not hide it");
    }

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
    // hitEntry returns -1 for empty space, which is also the start code, so
    // an empty hover used to light the start button. It must now be -2.
    driver.moveTo(Point(400, 720));
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
    driver.moveTo(center(entry0));
    driver.paint();
    auto preview = currentTransientPopup(root);
    assert(preview !is null, "task hover did not open a preview");
    assert(canFind(preview.classinfo.name, "TaskPreview"),
        "task hover opened the wrong popup: " ~ preview.classinfo.name);
    // Moving to empty taskbar space dismisses the preview.
    driver.moveTo(Point(400, 30));
    driver.paint();
    assert(currentTransientPopup(root) is null,
        "task preview did not dismiss when pointer left the entry");

    window.saveScreenshot("build/headless-desktop.ppm");
    writeln("aurora-desktop headless smoke: ALL PASSED");
    return 0;
}
