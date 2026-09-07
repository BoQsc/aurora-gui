module auroradesktop.app;

import aurora;
import aurora.widgets.desktop : SystemTrayState, NotificationIcon, TaskEntryId;
import auroradesktop.calendar : CalendarPopup;
import auroradesktop.search : SearchPopup;
import auroradesktop.settings : DesktopSettings, loadDesktopSettings,
    saveDesktopSettings;
import auroradesktop.store : DesktopState, IconState, TaskState, WindowState,
    iconKindFromName, iconKindName, loadDesktopState, saveDesktopState;
import auroradesktop.taskpreview : TaskPreview;
import auroradesktop.tasks : ExternalTask, activateExternalTask, captureExternalThumbnail,
    closeExternalTask, enumerateExternalTasks, excludeWindow, externalTaskAlive,
    externalTaskFocused, externalTaskMinimized, externalTaskSize, minimizeExternalTask;
import auroradesktop.system;
import auroradesktop.tray;
import auroradesktop.wlan : connectWifiNetwork, disconnectWifi, kickWifiScan,
    queryWifi;
import std.conv : to;
import std.utf : toUTF8, toUTF32;

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
    private bool _hideSystemCursor = true;
    private DesktopState _state;
    private TaskPreview _preview;

    /// Called once the host GuiWindow is known (see run()); applies the system
    /// cursor visibility so startup honors a persisted "hide cursor" choice.
    void setShellWindow(GuiWindow window)
    {
        _window = window;
        _window.setSystemCursorVisible(!_hideSystemCursor);
        version (Windows)
        {
            import aurora.platform.select : PlatformWindow;
            auto native = cast(PlatformWindow) window.nativeWindow();
            if (native !is null && native.hwnd() != 0)
                excludeWindow(native.hwnd());
        }
    }

    private GuiWindow _window;

    void delegate() onToggleFullscreen;

    this()
    {
        _desktop = add(new DesktopSurface());
        _taskbar = add(new Taskbar());

        // Previously persisted shell choice (modern Windows shell vs the
        // previous classic taskbar). Defaults to the new shell.
        _settings = loadDesktopSettings();
        _taskbar.setModernShell(_settings.modernShell);
        // Load the full session state (window bounds, icon positions, pinned
        // task order). The settings file is separate and kept small.
        _state = loadDesktopState();
        if (_state.windows.length == 0)
            _state = defaultState();
        // Hide the Aurora-rendered system cursor per the persisted preference.
        // The DesktopRoot has no direct window reference until run(); the app
        // re-applies this in setShellWindow (see below).
        _hideSystemCursor = _settings.hideSystemCursor;

        // The Start menu is created on demand (see toggleStartMenu/showStartMenu).
        _startMenu = null;

        // Populate shortcuts and system windows (positions restored where saved).
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
        restoreWindowState();
        restoreIconPositions();

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
            openCalendar();
        };
        _taskbar.onVolumeClick = delegate() { openVolumePanel(); };
        _taskbar.onBatteryClick = delegate() { openBatteryPanel(); };
        _taskbar.onWifiClick = delegate() { openWifiPanel(); };
        _taskbar.onHiddenIconsClick = delegate() { openHiddenIconsPanel(); };
        _taskbar.onSearchClick = delegate() { openSearch(); };
        _taskbar.onTaskHover = delegate(int index) { showTaskPreview(index); };
        _taskbar.onTaskHoverLeave = delegate() { hideTaskPreview(); };
        _taskbar.onEntryOrderChanged = delegate(TaskEntryId[] order)
        {
            persistState();
        };
        // External OS window tasks live in the taskbar. Activation/minimize and
        // live visibility/focus are routed to the OS on the app's behalf.
        _taskbar.onExternalActivate = delegate(ulong hwnd, bool minimized)
        {
            activateExternalTask(hwnd);
        };
        _taskbar.onExternalMinimize = delegate(ulong hwnd)
        {
            minimizeExternalTask(hwnd);
        };
        _taskbar.onExternalClose = delegate(ulong hwnd)
        {
            closeExternalTask(hwnd);
        };
        _taskbar.onExternalVisible = delegate(ulong hwnd)
        {
            return externalTaskVisibleNow(hwnd);
        };
        _taskbar.onExternalFocused = delegate(ulong hwnd)
        {
            return externalTaskFocused(hwnd);
        };

        _taskbar.addWindow(_notepadWindow, "Notepad", IconKind.notepad);
        _taskbar.addWindow(_systemWindow, "System", IconKind.computer);
        _taskbar.addCommand("Full screen", IconKind.maximize, delegate()
        {
            if (onToggleFullscreen !is null) onToggleFullscreen();
        });
        restorePinnedTasks();
        _taskbar.setActiveWindow(_notepadWindow);

        _volume = systemVolume();

        refreshTray();
        registerNotifications();
        syncExternalTasks();
    }

    /// Shell-owned notification icons for the tray cluster. Windows 11's XAML
    /// taskbar no longer exposes the classic Explorer overflow toolbar with real
    /// icon metadata (proven zero returns), so these are the shell's own.
    private void registerNotifications()
    {
        NotificationIcon icon;
        icon.id = 1;
        icon.label = toUTF32("OneDrive");
        icon.icon = IconKind.drive;
        icon.action = delegate() { showMessage("OneDrive is up to date."); };
        _taskbar.addNotification(icon);

        icon = NotificationIcon.init;
        icon.id = 2;
        icon.label = toUTF32("Antivirus");
        icon.icon = IconKind.computer;
        icon.action = delegate() { showMessage("Protection is on."); };
        _taskbar.addNotification(icon);

        icon = NotificationIcon.init;
        icon.id = 3;
        icon.label = toUTF32("Messenger");
        icon.icon = IconKind.terminal;
        icon.action = delegate() { showMessage("No new messages."); };
        _taskbar.addNotification(icon);
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
        auto cursorToggle = content.add(new CheckBox(
            "Hide system cursor",
            _hideSystemCursor));
        cursorToggle.onChanged = delegate(bool checked)
        {
            _hideSystemCursor = checked;
            _settings.hideSystemCursor = checked;
            if (_window !is null) _window.setSystemCursorVisible(!checked);
            saveDesktopSettings(_settings);
        };
        content.add(new Spacer());

        _systemWindow = _desktop.addWindow(
            new FloatingWindow("System Settings", IconKind.settings, content));
        _systemWindow.setBounds(Rect(560, 120, 340, 320));
        _systemWindow.minimize();
        connectWindow(_systemWindow);
    }

    // --- persistent session state ---------------------------------------
    // Windows, desktop icons, and pinned taskbar tasks are saved to
    // desktop_state.json so the shell resumes exactly where it left off.

    private static DesktopState defaultState()
    {
        DesktopState state;
        state.schema = 1;
        state.taskbarModernShell = true;
        state.hideSystemCursor = true;
        WindowState notepad;
        notepad.title = "Notepad";
        notepad.x = 120; notepad.y = 60;
        notepad.width = 460; notepad.height = 380;
        notepad.contentId = "notepad";
        state.windows ~= notepad;
        WindowState system;
        system.title = "System Settings";
        system.x = 560; system.y = 120;
        system.width = 340; system.height = 320;
        system.minimized = true;
        system.contentId = "system";
        state.windows ~= system;
        IconState ni; ni.label = "Notepad"; ni.x = 24; ni.y = 24; state.icons ~= ni;
        IconState ci; ci.label = "Computer"; ci.x = 24; ci.y = 96; state.icons ~= ci;
        IconState ti; ti.label = "Trash"; ti.x = 24; ti.y = 168; state.icons ~= ti;
        TaskState notepadTask; notepadTask.title = "Notepad";
        notepadTask.iconName = "notepad"; notepadTask.kind = "window";
        state.pinnedTasks ~= notepadTask;
        TaskState systemTask; systemTask.title = "System";
        systemTask.iconName = "computer"; systemTask.kind = "window";
        state.pinnedTasks ~= systemTask;
        TaskState fsTask; fsTask.title = "Full screen";
        fsTask.iconName = "maximize"; fsTask.kind = "command";
        state.pinnedTasks ~= fsTask;
        return state;
    }

    // Apply saved bounds/minimized state to the app-owned windows.
    private void restoreWindowState()
    {
        foreach (w; _state.windows)
        {
            if (w.contentId == "notepad" && _notepadWindow !is null)
            {
                if (w.width > 0 && w.height > 0)
                    _notepadWindow.setBounds(Rect(w.x, w.y, w.width, w.height));
                if (w.minimized) _notepadWindow.minimize();
                if (w.maximized) _notepadWindow.toggleMaximize();
            }
            else if (w.contentId == "system" && _systemWindow !is null)
            {
                if (w.width > 0 && w.height > 0)
                    _systemWindow.setBounds(Rect(w.x, w.y, w.width, w.height));
                if (w.minimized) _systemWindow.minimize();
                if (w.maximized) _systemWindow.toggleMaximize();
            }
        }
    }

    // Restore desktop icon positions by matching the stored label.
    private void restoreIconPositions()
    {
        foreach (saved; _state.icons)
        {
            for (size_t i = 0; i < _desktop.iconCount(); ++i)
            {
                auto icon = _desktop.iconAt(i);
                if (icon !is null && toUTF8(icon.text()) == saved.label)
                {
                    icon.setPosition(Point(saved.x, saved.y));
                    break;
                }
            }
        }
    }

    // Add the persisted pinned tasks after the built-in windows/commands. The
    // stored order (minus any task already present) is restored via setEntryOrder.
    private void restorePinnedTasks()
    {
        // Duplicates the built-in window titles; skip those.
        void[][string] seen;
        foreach (i; 0 .. _taskbar.entryCount())
            seen[toUTF8(_taskbar.entryTitle(i))] = null;
        foreach (t; _state.pinnedTasks)
        {
            if (t.title in seen) continue;
            if (t.kind == "command")
            {
                _taskbar.addCommand(t.title, iconKindFromName(t.iconName),
                    delegate() { if (onToggleFullscreen !is null) onToggleFullscreen(); });
                seen[t.title] = null;
            }
            else if (t.kind == "window")
            {
                // Not one of our built-in windows; add a draggable placeholder
                // command so the pin arrangement is visible.
                _taskbar.addCommand(t.title, iconKindFromName(t.iconName),
                    delegate() { showMessage(t.title ~ " is pinned."); });
                seen[t.title] = null;
            }
        }
    }

    // Capture the current session state and persist it.
    private void persistState()
    {
        DesktopState next;
        next.schema = 1;
        next.taskbarModernShell = _taskbar.modernShell();
        next.hideSystemCursor = _hideSystemCursor;
        next.windows = captureWindows();
        next.icons = captureIcons();
        next.pinnedTasks = capturePinnedTasks();
        next.pinnedTasks = canonicalPinnedOrder(next.pinnedTasks);
        _state = next;
        saveDesktopState(next);
    }

    private WindowState[] captureWindows()
    {
        WindowState[] result;
        foreach (name; ["notepad", "system"])
        {
            FloatingWindow window = name == "notepad" ? _notepadWindow :
                _systemWindow;
            if (window is null) continue;
            WindowState w;
            w.title = toUTF8(window.title());
            w.contentId = name;
            const b = window.bounds();
            w.x = b.x; w.y = b.y; w.width = b.width; w.height = b.height;
            w.maximized = window.maximized();
            w.minimized = !window.visible();
            result ~= w;
        }
        return result;
    }

    private IconState[] captureIcons()
    {
        IconState[] result;
        for (size_t i = 0; i < _desktop.iconCount(); ++i)
        {
            auto icon = _desktop.iconAt(i);
            if (icon is null) continue;
            IconState s;
            s.label = toUTF8(icon.text());
            const b = icon.bounds();
            s.x = b.x; s.y = b.y;
            result ~= s;
        }
        return result;
    }

    private TaskState[] capturePinnedTasks()
    {
        TaskState[] result;
        foreach (i; 0 .. _taskbar.entryCount())
        {
            TaskState t;
            t.title = toUTF8(_taskbar.entryTitle(i));
            t.iconName = iconKindName(_taskbar.entryIcon(i));
            t.kind = _taskbar.entryWindow(i) !is null ? "window" : "command";
            result ~= t;
        }
        return result;
    }

    // Reorder pinned tasks to a canonical, deduplicated form before saving so a
    // window entry that maps to a built-in window is recorded as a window task.
    private TaskState[] canonicalPinnedOrder(TaskState[] input)
    {
        TaskState[] result;
        bool[][string] seen;
        foreach (t; input)
        {
            const key = t.title;
            if (key in seen) continue;
            seen[key] = null;
            result ~= t;
        }
        return result;
    }

    private void showTaskPreview(int index)
    {
        if (index < 0 || index >= cast(int) _taskbar.entryCount()) return;
        const hwnd = _taskbar.entryHostHwnd(cast(size_t) index);
        string title = toUTF8(_taskbar.entryTitle(cast(size_t) index));
        const entryIcon = _taskbar.entryIcon(cast(size_t) index);
        hideTaskPreview();
        if (hwnd != 0)
        {
            // External OS window: capture a real thumbnail with PrintWindow.
            version (Windows)
            {
                auto size = externalTaskSize(hwnd);
                auto image = captureExternalThumbnail(hwnd, size.width, size.height);
                if (image is null)
                {
                    // Fall back to an icon-only preview (no thumbnail).
                    return;
                }
                auto preview = new TaskPreview(title, image);
                preview.onCloseRequested = delegate()
                {
                    closeExternalTask(hwnd);
                };
                preview.onActivate = delegate() { activateExternalTask(hwnd); };
                if (preview.show(_taskbar,
                        _taskbar.entryGlobalBounds(cast(size_t) index)))
                    _preview = preview;
            }
            return;
        }
        auto window = _taskbar.entryWindow(cast(size_t) index);
        if (window is null) return;
        auto preview = new TaskPreview(window, window.content(),
            title, entryIcon);
        preview.onCloseRequested = delegate() { window.closeWindow(); };
        preview.onActivate = delegate() { showWindow(window); };
        if (preview.show(_taskbar, _taskbar.entryGlobalBounds(cast(size_t) index)))
            _preview = preview;
    }

    private void hideTaskPreview()
    {
        if (_preview !is null && !_preview.dismissed())
            _preview.dismiss();
        _preview = null;
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
            persistState();
        };
        window.onRestored = delegate(FloatingWindow restored)
        {
            _taskbar.setActiveWindow(restored);
            persistState();
        };
        window.onClosed = delegate(FloatingWindow closed)
        {
            _taskbar.removeWindow(closed);
            hideTaskPreview();
            persistState();
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
        // Keep the WLAN scan cache warm in the background so that when the
        // tray WiFi button is clicked the surrounding networks are already
        // present (Windows only populates the available-network cache when a
        // scan runs). This is a cheap non-blocking request.
        kickWifiScan();
        const live = systemVolume();
        const liveMuted = systemMuted();
        // Track external mixer moves (Windows volume keys, another mixer app).
        if (live != _volume)
            _volume = live;
        if (liveMuted != _muted)
            _muted = liveMuted;
        next.volumePercent = _volume;
        next.volumeMuted = _muted;
        // Preserve the live hidden-icon count (the fresh snapshot's default of 5
        // would otherwise reset it on every 2s refresh).
        next.hiddenIconCount = hiddenCount();
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
        showPanel(PanelKind.volume, panel, _taskbar.trayIconGlobalBounds(1));
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
        showPanel(PanelKind.battery, panel, _taskbar.trayIconGlobalBounds(2));
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
        showPanel(PanelKind.wifi, panel, _taskbar.trayIconGlobalBounds(0));
        _wifiPanel = _panelPopup;

        kickWifiScan();
        _wifiPollElapsed = 0.0;
        _wifiPollActive = true;
        _wifiPollMax = 2.0;   // ~10 polls @ 0.2 s; let the scan finish
        _wifiLastCount = -1;  // force the first poll to count as growth
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
        // Keep polling the WHOLE window so the active scan can finish adding
        // every network (it grows 2 -> 3 -> 5 over ~1s). Stopping at ">1"
        // froze the list too early. Stop only when the count stops growing or
        // the poll window runs out.
        if (cast(int) state.networks.length <= _wifiLastCount ||
            _wifiPollElapsed >= _wifiPollMax)
        {
            _wifiPollActive = false;
        }
        else
        {
            _wifiLastCount = cast(int) state.networks.length;
            _wifiPollElapsed = 0.0;
        }
    }

    private void openHiddenIconsPanel()
    {
        // Collect the hidden notification icons and render a 3x3 grid overlay.
        NotificationIcon[] hidden;
        foreach (icon; _taskbar.notifications())
            if (icon.hidden) hidden ~= icon;
        auto panel = new HiddenIconsPanel(hidden);
        panel.onIconActivated = delegate(size_t id, string label)
        {
            showMessage(label ~ " (notification)");
        };
        panel.onIconHidden = delegate(size_t id, bool hidden)
        {
            _taskbar.setNotificationHidden(id, hidden);
            _tray.hiddenIconCount = hiddenCount();
            _taskbar.setTrayState(_tray);
        };
        showPanel(PanelKind.hidden, panel, _taskbar.trayIconGlobalBounds(3));
    }

    private size_t hiddenCount()
    {
        size_t count;
        foreach (icon; _taskbar.notifications())
            if (icon.hidden) ++count;
        return count;
    }

    /// Live visibility of an external OS window (true = not minimized).
    private bool externalTaskVisibleNow(ulong hwnd)
    {
        if (!externalTaskAlive(hwnd)) return false;
        return !externalTaskMinimized(hwnd);
    }

    // hwnds currently shown as external taskbar entries, for the poll diff.
    private ulong[] _externalHwnds;

    /// Diff the live OS task list against the taskbar: add new windows, remove
    /// closed ones. Existing external entries are kept in their pinned slot.
    private void syncExternalTasks()
    {
        version (Windows)
        {
            const tasks = enumerateExternalTasks();
            bool[ulong] live;
            foreach (t; tasks)
            {
                live[t.hwnd] = true;
                if (_taskbar.indexOfExternal(t.hwnd) < 0)
                    _taskbar.addExternalTask(t.hwnd, cleanTaskTitle(t.title));
            }
            // Remove entries whose window is gone.
            foreach (hwnd; _externalHwnds)
            {
                if (hwnd in live) continue;
                _taskbar.removeExternal(hwnd);
            }
            _externalHwnds.length = 0;
            foreach (t; tasks)
            {
                if (_taskbar.indexOfExternal(t.hwnd) >= 0)
                    _externalHwnds ~= t.hwnd;
            }
        }
    }

    private static string cleanTaskTitle(string title)
    {
        // Drop the leading full path for console windows so the task shows a
        // friendly label, and truncate ridiculous window titles.
        string result = title;
        if (result.length > 80) result = result[0 .. 80];
        return result;
    }

    private PopupOverlay _panelPopup;
    private PopupOverlay _volumePanel;
    private VolumePanel _volumePanelContent;
    private PopupOverlay _wifiPanel;
    private WifiPanel _wifiPanelContent;
    // Identifies which tray popup is open so re-clicking its taskbar icon
    // toggles it closed instead of re-opening (Windows tray behavior).
    private enum PanelKind : ubyte { none, volume, battery, wifi, hidden }
    private PanelKind _panelKind = PanelKind.none;

    private void showPanel(PanelKind kind, Widget content, Rect anchor)
    {
        // Toggle: re-clicking the same tray icon closes its open panel.
        if (_panelKind == kind && _panelPopup !is null &&
            !_panelPopup.dismissed())
        {
            dismissPanel();
            return;
        }
        dismissPanel();
        auto popup = showPopup(_taskbar, anchor, content,
            PopupPlacement.above);
        _panelPopup = popup;
        _panelKind = kind;
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
        _panelKind = PanelKind.none;
    }

    private void openCalendar()
    {
        dismissPanel();
        dismissStartMenu();
        auto calendar = new CalendarPopup();
        calendar.show(_taskbar, _taskbar.clockBounds());
    }

    private SearchPopup _searchPopup;

    private void openSearch()
    {
        if (_searchPopup !is null && !_searchPopup.dismissed())
        {
            _searchPopup.dismiss();
            _searchPopup = null;
            return;
        }
        dismissPanel();
        dismissStartMenu();
        auto search = new SearchPopup();
        search.add("Notepad", IconKind.notepad,
            delegate() { showWindow(_notepadWindow); }, "Text editor");
        search.add("System Settings", IconKind.settings,
            delegate() { showWindow(_systemWindow); }, "Display and preferences");
        search.add("Open Windows Settings", IconKind.settings,
            delegate() { systemOpenSettings(); }, "Settings");
        search.add("Restart", IconKind.power,
            delegate() { systemRestart(); }, "Restart this computer");
        search.add("Sleep", IconKind.power,
            delegate() { systemSleep(); }, "Put this computer to sleep");
        search.add("Shut down", IconKind.power,
            delegate() { systemShutdown(); }, "Shut down this computer");
        search.add("Full screen", IconKind.maximize,
            delegate()
            {
                if (onToggleFullscreen !is null) onToggleFullscreen();
            }, "Use the entire display");
        if (search.show(_taskbar, _taskbar.searchButtonGlobalBounds()))
            _searchPopup = search;
        else
            _searchPopup = null;
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
        _stateSaveAccumulator += deltaSeconds;
        if (_stateSaveAccumulator >= 10.0)
        {
            _stateSaveAccumulator = 0.0;
            persistState();
        }
        // Sync live external OS tasks into the taskbar every second.
        _externalTaskAccumulator += deltaSeconds;
        if (_externalTaskAccumulator >= 1.0)
        {
            _externalTaskAccumulator = 0.0;
            syncExternalTasks();
        }
    }

    private double _externalTaskAccumulator;

    private double _stateSaveAccumulator;
    private double _clockAccumulator;
    private double _wifiPollElapsed;
    private double _wifiPollMax;
    private bool _wifiPollActive;
    private int _wifiLastCount;

    // Test-only accessors. Kept on the class (not free functions) so the
    // headless smoke can inspect shell state without a running window loop.
    Taskbar taskbarForTesting() @safe pure nothrow @nogc { return _taskbar; }

    void refreshTrayForTesting()
    {
        refreshTray();
    }
}

/// The taskbar exposes a public tray-icon geometry accessor for app popups.
// __TIMESTAMP__ is the date+time (to the minute) this source was compiled; it
// is baked into the binary so the title always shows when this build was made.
enum string _buildTime = __TIMESTAMP__;

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
    root.setShellWindow(window);
    window.setTitle(options.title ~ " — " ~ window.rendererName() ~
        " — built " ~ _buildTime);

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
