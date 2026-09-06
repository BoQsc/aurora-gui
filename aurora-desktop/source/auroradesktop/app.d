module auroradesktop.app;

import aurora;
import aurora.widgets.desktop : SystemTrayState;
import auroradesktop.settings : DesktopSettings, loadDesktopSettings,
    saveDesktopSettings;
import auroradesktop.system;
import auroradesktop.tray;
import auroradesktop.wlan : connectWifiNetwork, disconnectWifi, kickWifiScan,
    queryWifi;
import std.conv : to;
import std.utf : toUTF8;

/**
 * A Windows-11-style Aurora desktop environment session: wallpaper with
 * draggable shortcuts and windows, a taskbar with a live system tray, and a
 * Start menu that can really shut down, sleep, restart, or open Settings.
 *
 * The shell itself is pure Aurora widgets. Only the system/helper module
 * touches Win32 (battery, volume, network, power actions, the Settings app).
 */
final class DesktopRoot : Widget
{
    private DesktopSurface _desktop;
    private Taskbar _taskbar;
    private StartMenu _startMenu;
    private FloatingWindow _notepadWindow;
    private FloatingWindow _systemWindow;
    private int _newDocumentCount;
    private SystemTrayState _tray;
    private int _volume;
    private bool _muted;
    private DesktopSettings _settings;

    void delegate() onToggleFullscreen;

    this()
    {
        _desktop = add(new DesktopSurface());
        _taskbar = add(new Taskbar());

        // Previously persisted shell choice (modern Windows shell vs the
        // previous classic taskbar). Defaults to the new shell.
        _settings = loadDesktopSettings();
        _taskbar.setModernShell(_settings.modernShell);

        // The Start menu is created on demand (see toggleStartMenu/showStartMenu).
        _startMenu = null;

        // Populate shortcuts and system windows.
        auto notepadIcon = _desktop.addIcon("Notepad", IconKind.notepad,
            delegate() { showWindow(_notepadWindow); });
        auto computerIcon = _desktop.addIcon("Computer", IconKind.computer,
            delegate() { showWindow(_systemWindow); });
        auto trashIcon = _desktop.addIcon("Trash", IconKind.trash,
            delegate() { showMessage("Trash is empty."); });
        configureDesktopIcon(notepadIcon);
        configureDesktopIcon(computerIcon);
        configureDesktopIcon(trashIcon, false);
        _desktop.onRefresh = delegate() { showMessage("Desktop refreshed."); };
        _desktop.onNewItem = delegate() { createDocumentShortcut(); };
        _desktop.onDisplaySettings = delegate() { showWindow(_systemWindow); };
        _desktop.onPersonalize = delegate()
        {
            showMessage("Wallpaper and theme settings are available in Settings.");
        };

        buildNotepadWindow();
        buildSystemWindow();

        _taskbar.onStart = delegate() { toggleStartMenu(); };
        _taskbar.onShowDesktop = delegate() { };
        _taskbar.onToggleFullscreen = delegate()
        {
            if (onToggleFullscreen !is null) onToggleFullscreen();
        };
        _taskbar.onTaskbarSettings = delegate()
        {
            showMessage("Taskbar buttons can be dragged left or right and opened with right click.");
        };
        _taskbar.onDateTimeSettings = delegate()
        {
            showMessage("Date and time settings requested.");
        };
        _taskbar.onVolumeClick = delegate() { openVolumePanel(); };
        _taskbar.onBatteryClick = delegate() { openBatteryPanel(); };
        _taskbar.onWifiClick = delegate() { openWifiPanel(); };
        _taskbar.onHiddenIconsClick = delegate() { openHiddenIconsPanel(); };
        _taskbar.onSearchClick = delegate() { toggleStartMenu(); };

        _taskbar.addWindow(_notepadWindow, "Notepad", IconKind.notepad);
        _taskbar.addWindow(_systemWindow, "System", IconKind.computer);
        _taskbar.addCommand("Full screen", IconKind.maximize, delegate()
        {
            if (onToggleFullscreen !is null) onToggleFullscreen();
        });
        _taskbar.setActiveWindow(_notepadWindow);

        _volume = systemVolume();

        refreshTray();
    }

    private void buildNotepadWindow()
    {
        auto content = new VBox(6, Insets(7));
        auto toolbar = content.add(new HBox(5));
        toolbar.layoutHints().preferredHeight = 40;
        auto newButton = toolbar.add(new Button("New", IconKind.newDocument));
        auto saveButton = toolbar.add(new Button("Save", IconKind.save));
        saveButton.setAccent(true);
        auto editor = content.add(new TextArea(
            "Aurora Desktop\n\nThis Notepad runs inside Aurora's retained GPU-composited desktop environment.\n"
            ~ "Drag the title bar, use the caption controls, and switch apps from the taskbar."));
        editor.setCursorIndex(0);
        editor.setWordWrap(true);
        editor.layoutHints().flex = 1.0;
        newButton.onClick = delegate() { editor.setText(""); };
        saveButton.onClick = delegate() { showMessage("Demo document saved in memory."); };

        _notepadWindow = _desktop.addWindow(
            new FloatingWindow("Notepad", IconKind.notepad, content));
        _notepadWindow.setBounds(Rect(120, 60, 460, 380));
        connectWindow(_notepadWindow);
    }

    private void buildSystemWindow()
    {
        auto content = new VBox(10, Insets(12));
        auto heading = content.add(new Label("System Overview"));
        heading.setScale(3);
        heading.layoutHints().preferredHeight = 36;
        content.add(new Label("Battery"));
        auto battery = content.add(new ProgressBar(0.5));
        battery.setLabel("50%");
        content.add(new Label("Volume"));
        auto slider = content.add(new Slider(0, 100, 50));
        slider.onChanged = delegate(double value)
        {
            const rounded = cast(int) (value + 0.5);
            setVolume(rounded);
        };
        auto shellToggle = content.add(new CheckBox(
            "Windows shell taskbar (search, tray, date)",
            _taskbar.modernShell()));
        shellToggle.onChanged = delegate(bool checked)
        {
            _taskbar.setModernShell(checked);
            _settings.modernShell = checked;
            saveDesktopSettings(_settings);
        };
        content.add(new Spacer());

        _systemWindow = _desktop.addWindow(
            new FloatingWindow("System Settings", IconKind.settings, content));
        _systemWindow.setBounds(Rect(560, 120, 340, 320));
        _systemWindow.minimize();
        connectWindow(_systemWindow);
    }

    private void configureDesktopIcon(DesktopIcon icon, bool removable = true)
    {
        if (icon is null) return;
        icon.onRenameRequested = delegate(DesktopIcon target)
        {
            target.setText(toUTF8(target.text()) ~ " (renamed)");
        };
        if (removable)
        {
            icon.onDeleteRequested = delegate(DesktopIcon target)
            {
                const name = toUTF8(target.text());
                if (_desktop.removeIcon(target))
                    showMessage(name ~ " was moved to Trash.");
            };
        }
        icon.onPropertiesRequested = delegate(DesktopIcon target)
        {
            showMessage(toUTF8(target.text()) ~ "\nPosition: " ~
                to!string(target.bounds().x) ~ ", " ~ to!string(target.bounds().y));
        };
    }

    private void connectWindow(FloatingWindow window)
    {
        window.onActivated = delegate(FloatingWindow active)
        {
            _taskbar.setActiveWindow(active);
        };
        window.onMinimized = delegate(FloatingWindow minimized)
        {
            if (_taskbar.activeWindow() is minimized)
                _taskbar.setActiveWindow(null);
        };
        window.onRestored = delegate(FloatingWindow restored)
        {
            _taskbar.setActiveWindow(restored);
        };
        window.onClosed = delegate(FloatingWindow closed)
        {
            _taskbar.removeWindow(closed);
        };
    }

    private void showWindow(FloatingWindow window)
    {
        if (window is null) return;
        dismissStartMenu();
        window.restore();
        _taskbar.setActiveWindow(window);
    }

    private void createDocumentShortcut()
    {
        ++_newDocumentCount;
        const title = "New document " ~ to!string(_newDocumentCount);
        auto icon = _desktop.addIcon(title, IconKind.newDocument,
            delegate() { showMessage(title ~ " opened."); });
        configureDesktopIcon(icon);
        _desktop.alignIconsToGrid();
    }

    private StartMenu createStartMenu()
    {
        auto menu = new StartMenu(_taskbar);
        menu.addApplication("Notepad", IconKind.notepad,
            delegate() { showWindow(_notepadWindow); }, "Text editor");
        menu.addApplication("System Settings", IconKind.settings,
            delegate() { showWindow(_systemWindow); }, "Display and preferences");
        menu.addSystemCommand("Settings", IconKind.settings,
            delegate() { systemOpenSettings(); }, false, "Open Windows Settings");
        menu.addSystemCommand("Restart", IconKind.refresh,
            delegate() { systemRestart(); }, false, "Restart this computer");
        menu.addSystemCommand("Sleep", IconKind.power,
            delegate() { systemSleep(); }, false, "Put this computer to sleep");
        menu.addSystemCommand("Shut down", IconKind.power,
            delegate() { systemShutdown(); }, true, "Shut down this computer");
        menu.addSystemCommand("Full screen (F11)", IconKind.maximize,
            delegate()
            {
                if (onToggleFullscreen !is null) onToggleFullscreen();
            }, false, "Use the entire display");
        menu.onDismissed = delegate()
        {
            if (_startMenu is menu) _startMenu = null;
            _taskbar.setStartMenuOpen(false);
        };
        return menu;
    }

    private void toggleStartMenu()
    {
        if (_startMenu !is null && !_startMenu.dismissed())
        {
            dismissStartMenu();
            return;
        }
        auto menu = createStartMenu();
        _startMenu = menu.show(_taskbar, _taskbar.startButtonGlobalBounds()) ?
            menu : null;
        _taskbar.setStartMenuOpen(_startMenu !is null);
    }

    private void dismissStartMenu()
    {
        auto menu = _startMenu;
        if (menu !is null && !menu.dismissed()) menu.dismiss();
        _taskbar.setStartMenuOpen(false);
    }

    // --- Volume / tray control ---
    //
    // `_volume` is the last non-muted level (the restore level). `_muted` is
    // an explicit flag: muting writes 0 to the mixer but remembers `_volume`
    // so unmute restores it. External mixer changes are picked up on refresh.

    private void toggleMute()
    {
        _muted = !_muted;
        setSystemMuted(_muted);
        pushTrayVolume();
        if (_volumePanel !is null && !_volumePanel.dismissed())
            _volumePanelContent.update(_volume, _muted);
    }

    private void setVolume(int percent)
    {
        const clamped = percent < 0 ? 0 : (percent > 100 ? 100 : percent);
        _volume = clamped;
        // The tray paints only the muted speaker glyph, never the numeric
        // level, so only a mute flip needs a taskbar repaint - not every
        // drag sample. The cached level still flows to refreshTray().
        const wasMuted = _muted;
        if (clamped > 0)
        {
            // Skip the mixer write when already unmuted: a slider drag would
            // otherwise pay a full control round-trip on every sample.
            if (_muted) setSystemMuted(false);
            _muted = false;
        }
        setSystemVolume(clamped);
        _tray.volumePercent = clamped;
        if (_muted != wasMuted)
            pushTrayVolume();
        if (_volumePanel !is null && !_volumePanel.dismissed())
            _volumePanelContent.update(clamped, _muted);
    }

    private void pushTrayVolume()
    {
        _tray.volumePercent = _muted ? 0 : _volume;
        _tray.volumeMuted = _muted;
        _taskbar.setTrayState(_tray);
    }

    private void refreshTray()
    {
        SystemTrayState next;
        refreshSystemStatus(next);
        // Re-resolve the endpoint selection on the slow 2 s cadence so a
        // plug/unplug heals; the drag path in between rides the cache.
        refreshAudioEndpoints();
        const live = systemVolume();
        const liveMuted = systemMuted();
        // Track external mixer moves (Windows volume keys, another mixer app).
        if (live != _volume)
            _volume = live;
        if (liveMuted != _muted)
            _muted = liveMuted;
        next.volumePercent = _volume;
        next.volumeMuted = _muted;
        _tray = next;
        _taskbar.setTrayState(next);
        if (_volumePanel !is null && !_volumePanel.dismissed())
            _volumePanelContent.update(_tray.volumePercent, _muted);
    }

    private void openVolumePanel()
    {
        auto panel = new VolumePanel(_tray.volumePercent, _muted,
            audioOutputDevices(), selectedAudioDevice());
        panel.onVolumeSet = delegate(int percent) { setVolume(percent); };
        panel.onMuteToggle = delegate() { toggleMute(); };
        panel.onDeviceSelected = delegate(uint index)
        {
            selectAudioDevice(index);
            // The slider/mute now drive the newly selected device: re-read
            // its live level and mute flag instead of the old device's.
            _volume = systemVolume();
            _muted = systemMuted();
            pushTrayVolume();
            _volumePanelContent.update(_volume, _muted);
            _volumePanelContent.updateDevices(audioOutputDevices(),
                selectedAudioDevice());
        };
        showPanel(panel, _taskbar.trayIconGlobalBounds(1));
        // Assigned after showPanel: it dismisses any previous popup first,
        // which clears this tracking.
        _volumePanel = _panelPopup;
        _volumePanelContent = panel;
    }

    private void openBatteryPanel()
    {
        SystemTrayState snapshot;
        refreshSystemStatus(snapshot);
        auto panel = new BatteryPanel(snapshot.hasBattery,
            snapshot.batteryCharging, snapshot.batteryPercent);
        showPanel(panel, _taskbar.trayIconGlobalBounds(2));
    }

    private void openWifiPanel()
    {
        // Instant open: build the panel with a fast, non-blocking query so the
        // button never freezes the UI. Then kick an active scan and poll it on
        // the background tick so the surrounding networks appear without a
        // synchronous sleep on the UI thread.
        auto panel = new WifiPanel(queryWifi());
        _wifiPanelContent = panel;
        panel.onOpenNetworkSettings = delegate()
        {
            dismissPanel();
            systemOpenSettings("ms-settings:network");
        };
        panel.onRefresh = delegate() { refreshWifiPanel(""); };
        panel.onDisconnect = delegate()
        {
            refreshWifiPanel(disconnectWifi() ?
                "Disconnecting..." : "Disconnect failed.");
            refreshWifiPanel("");
        };
        panel.onConnect = delegate(string ssid, string profile, bool secured)
        {
            const result = connectWifiNetwork(ssid, profile, secured);
            refreshWifiPanel(result.message);
        };
        showPanel(panel, _taskbar.trayIconGlobalBounds(0));
        _wifiPanel = _panelPopup;

        kickWifiScan();
        _wifiPollElapsed = 0.0;
        _wifiPollActive = true;
        _wifiPollMax = 1.2; // ~6 polls @ 200 ms
    }

    // Pull the latest scan into the panel without blocking. Asks Windows to
    // rescan when the list is still sparse, so the surrounding networks rotate
    // in over the poll window.
    private void refreshWifiPanel(string feedback)
    {
        if (_wifiPanel is null || _wifiPanel.dismissed() ||
            _wifiPanelContent is null)
            return;
        _wifiPanelContent.refresh(queryWifi(), feedback);
    }

    private void pollWifiPanel(double deltaSeconds)
    {
        if (!_wifiPollActive) return;
        _wifiPollElapsed += deltaSeconds;
        if (_wifiPollElapsed < 0.2) return;
        auto state = queryWifi();
        if (_wifiPanelContent !is null && !_wifiPanel.dismissed())
            _wifiPanelContent.refresh(state, "");
        // Stop once the surrounding networks appear or the poll window runs out.
        if (state.networks.length > 1 || _wifiPollElapsed >= _wifiPollMax)
            _wifiPollActive = false;
        else
            _wifiPollElapsed = 0.0; // poll again next 0.2 s window
    }

    private void openHiddenIconsPanel()
    {
        auto panel = new HiddenIconsPanel(_tray.hiddenIconCount);
        showPanel(panel, _taskbar.trayIconGlobalBounds(3));
    }

    private PopupOverlay _panelPopup;
    private PopupOverlay _volumePanel;
    private VolumePanel _volumePanelContent;
    private PopupOverlay _wifiPanel;
    private WifiPanel _wifiPanelContent;

    private void showPanel(Widget content, Rect anchor)
    {
        dismissPanel();
        auto popup = showPopup(_taskbar, anchor, content,
            PopupPlacement.above);
        _panelPopup = popup;
    }

    private void dismissPanel()
    {
        if (_panelPopup !is null && !_panelPopup.dismissed())
            _panelPopup.dismiss();
        _panelPopup = null;
        _volumePanel = null;
        _volumePanelContent = null;
        _wifiPanel = null;
        _wifiPanelContent = null;
    }

    private void showMessage(string message)
    {
        dismissStartMenu();
        auto content = new VBox(8, Insets(12));
        auto label = content.add(new Label(message));
        label.setAlignment(HorizontalAlign.center, VerticalAlign.middle);
        label.layoutHints().flex = 1.0;
        auto okay = content.add(new Button("OK"));
        okay.setAccent(true);
        auto dialog = _desktop.addWindow(new FloatingWindow("Aurora",
            IconKind.start, content));
        dialog.setBounds(Rect(maxInt(20, (_desktop.bounds().width - 360) / 2),
            maxInt(20, (_desktop.bounds().height - 190) / 2), 360, 190));
        okay.onClick = delegate() { dialog.closeWindow(); };
        _desktop.bringChildToFront(dialog);
    }

    protected override void onLayout()
    {
        const barHeight = 52;
        _desktop.setBounds(Rect(0, 0, bounds().width,
            maxInt(0, bounds().height - barHeight)));
        _taskbar.setBounds(Rect(0, maxInt(0, bounds().height - barHeight),
            bounds().width, barHeight));
        foreach (window; [_notepadWindow, _systemWindow])
        {
            if (window !is null && window.maximized())
                window.setBounds(Rect(0, 0, _desktop.bounds().width,
                    _desktop.bounds().height));
        }
    }

    protected override void onTick(double deltaSeconds)
    {
        super.onTick(deltaSeconds);
        _clockAccumulator += deltaSeconds;
        if (_clockAccumulator >= 2.0)
        {
            _clockAccumulator = 0.0;
            refreshTray();
        }
        pollWifiPanel(deltaSeconds);
    }

    private double _clockAccumulator;
    private double _wifiPollElapsed;
    private double _wifiPollMax;
    private bool _wifiPollActive;

    // Test-only accessors. Kept on the class (not free functions) so the
    // headless smoke can inspect shell state without a running window loop.
    Taskbar taskbarForTesting() @safe pure nothrow @nogc { return _taskbar; }

    void refreshTrayForTesting()
    {
        refreshTray();
    }
}

/// The taskbar exposes a public tray-icon geometry accessor for app popups.
int run(string[] args)
{
    WindowOptions options;
    options.title = "Aurora Desktop";
    options.width = 1280;
    options.height = 760;
    bool screenshot;
    string screenshotPath;
    foreach (index, arg; args)
    {
        if (arg == "--screenshot" && index + 1 < args.length)
        {
            screenshot = true;
            screenshotPath = args[index + 1];
        }
    }

    auto window = new GuiWindow(options, Theme.dark());
    auto root = new DesktopRoot();
    root.onToggleFullscreen = delegate() { window.toggleFullscreen(); };
    window.setRoot(root);
    window.setTitle(options.title ~ " — " ~ window.rendererName());

    if (screenshot)
    {
        auto driver = new UiTestDriver(window);
        driver.resize(Size(options.width, options.height));
        driver.paint();
        window.saveScreenshot(screenshotPath);
        window.close();
        return 0;
    }

    return window.run();
}
