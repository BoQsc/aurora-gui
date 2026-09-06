module tests.headless_smoke;

import aurora;
import aurora.widgets.desktop : SystemTrayState;
import aurora.widgets.popup : currentTransientPopup;
import auroradesktop.app : DesktopRoot;
import std.stdio : writeln, stdout;
import std.algorithm : canFind;
import std.conv : to;
import std.utf : toUTF32;

private Point center(Rect value)
{
    return Point(value.x + value.width / 2, value.y + value.height / 2);
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
    auto driver = new UiTestDriver(window);
    driver.resize(Size(1280, 760));
    driver.paint();

    // The taskbar must expose its start button, entries, and tray state.
    auto taskbar = root.taskbarForTesting();
    assert(root.bounds() == Rect(0, 0, 1280, 760));
    assert(taskbar.entryCount() >= 2);
    assert(!taskbar.startButtonGlobalBounds().empty());

    // Taskbar icon geometry must be non-empty (0=wifi, 1=volume, 2=battery, 3=hidden).
    foreach (index; 0 .. 4)
        assert(!taskbar.trayIconGlobalBounds(index).empty());

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

    // A live refresh must publish a valid tray snapshot without throwing.
    root.refreshTrayForTesting();
    const tray = taskbar.trayState();
    assert(tray.volumePercent >= 0 && tray.volumePercent <= 100);

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
                writeln("wifi: ", state.networks.length, " network(s), connected=",
                    state.connected);
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

    // The search pill opens the Start menu exactly like the Start button.
    // (searchRect sits 8 px right of the start button and is 150 px wide.)
    assert(!taskbar.startMenuOpen());
    const startBounds = taskbar.startButtonGlobalBounds();
    driver.click(Point(startBounds.right() + 8 + 75,
        startBounds.y + startBounds.height / 2));
    assert(taskbar.startMenuOpen());
    driver.pressKey(Key.escape);
    assert(!taskbar.startMenuOpen());

    window.saveScreenshot("build/headless-desktop.ppm");
    writeln("aurora-desktop headless smoke: ALL PASSED");
    return 0;
}
