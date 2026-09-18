module auroradesktop.app;

import aurora;
import aurora.widgets.desktop : SystemTrayState, NotificationIcon, TaskEntryId;
import auroradesktop.calendar : CalendarPopup;
import auroradesktop.desktopfiles : enumerateDesktopEntries;
import auroradesktop.search : SearchPopup;
import auroradesktop.settings : DesktopSettings, loadDesktopSettings,
    saveDesktopSettings;
import auroradesktop.store : DesktopState, IconState, PinnedAppState, TaskState,
    WindowState, iconKindFromName, iconKindName, loadDesktopState,
    saveDesktopState;
import auroradesktop.taskpreview : TaskPreview;
import auroradesktop.tasks : ExternalTask, TrayIconInfo, activateExternalTask,
    captureExternalThumbnail, closeExternalTask, enumerateExternalTasks,
    enumerateTrayIcons, excludeWindow, externalTaskAlive, externalTaskFocused,
    executableIcon, externalTaskGroupKey, externalTaskIcon,
    externalTaskMinimized, externalTaskSize, externalTaskTitle, fileIcon,
    minimizeExternalTask, postTrayContextMenu, postTrayDoubleClick,
    postTrayPrimaryClick, restoreExternalTask;
import auroradesktop.inputlang : InputLanguage, activateInputLanguage,
    activeInputLanguage, inputLanguageAbbrev, inputLanguageName,
    inputLanguages;
import auroradesktop.system;
import auroradesktop.tray;
import auroradesktop.wallpaper : chooseWallpaperFile, currentWallpaperPath,
    loadWallpaperImage, setWallpaper;
import auroradesktop.wlan : connectWifiNetwork, disconnectWifi, kickWifiScan,
    queryWifi;
import std.algorithm : canFind, endsWith;
import std.conv : to;
import std.format : format;
import std.path : baseName;
import std.process : spawnShell;
import std.string : toLower;
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
    // Hover-intent state for task previews (see onTaskHover/onTaskHoverLeave).
    private int _previewWantedIndex = -1;
    private double _previewWantedDelay = 0.0;
    private bool _previewHidePending;
    private double _previewHideDelay = 0.0;
    private int _previewIndex = -1;
    private bool _taskHovered;
    private enum double previewShowDelaySeconds = 0.3;
    private enum double previewHideGraceSeconds = 0.35;

    /// Called once the host GuiWindow is known (see run()); applies the system
    /// cursor visibility so startup honors a persisted "hide cursor" choice.
    void setShellWindow(GuiWindow window)
    {
        _window = window;
        _window.setSystemCursorVisible(!_hideSystemCursor);
        // Minimize is left enabled on purpose: this is a normal desktop window
        // the user must be able to minimize/restore. The platform still exposes
        // the opt-in prevent-minimize policy, but the shell does not use it.
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
        _taskbar.setTaskGrouping(_settings.groupTasks);
        // The shell shows rich thumbnail previews on task hover; the taskbar's
        // own delayed label tooltip would collide with them.
        _taskbar.setTaskEntryTooltips(false);
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
        // Show the real Windows Desktop contents (files, shortcuts, folders)
        // so the shell matches the user's actual desktop; double-click opens the
        // item through the shell.
        foreach (entry; enumerateDesktopEntries())
        {
            const path = entry.path;
            const iconKind = entry.directory ? IconKind.folder :
                iconKindForFile(entry.name);
            auto item = _desktop.addIcon(entry.name, iconKind,
                delegate() { openDesktopEntry(path); });
            auto shellIcon = fileIcon(path);
            if (shellIcon !is null) item.setIconImage(shellIcon);
            configureDesktopIcon(item);
        }
        _desktop.onRefresh = delegate()
        {
            reloadDesktopEntries();
            showMessage("Desktop refreshed.");
        };
        _desktop.onNewItem = delegate() { createDocumentShortcut(); };
        _desktop.onDisplaySettings = delegate() { showWindow(_systemWindow); };
        _desktop.onPersonalize = delegate() { chooseAndApplyWallpaper(); };

        buildNotepadWindow();
        buildSystemWindow();
        restoreWindowState();
        restoreIconPositions();
        // Paint the user's real Windows wallpaper behind the desktop icons.
        auto wallpaperImage = loadWallpaperImage(currentWallpaperPath());
        if (wallpaperImage !is null) _desktop.setWallpaper(wallpaperImage);

        _taskbar.onStart = delegate() { toggleStartMenu(); };
        // Show Desktop must affect the real running programs, not just the
        // in-shell windows: minimize every visible external window and restore
        // exactly those when toggled back.
        _taskbar.onShowDesktop = delegate()
        {
            _desktopMinimizedHwnds.length = 0;
            foreach (t; enumerateExternalTasks())
            {
                if (externalTaskMinimized(t.hwnd)) continue;
                minimizeExternalTask(t.hwnd);
                _desktopMinimizedHwnds ~= t.hwnd;
            }
        };
        _taskbar.onRestoreDesktop = delegate()
        {
            foreach (hwnd; _desktopMinimizedHwnds)
                if (externalTaskAlive(hwnd)) restoreExternalTask(hwnd);
            _desktopMinimizedHwnds.length = 0;
        };
        _taskbar.onToggleFullscreen = delegate()
        {
            if (onToggleFullscreen !is null) onToggleFullscreen();
        };
        _taskbar.onTaskbarSettings = delegate() { openTaskbarSettings(); };
        _taskbar.onTaskManager = delegate()
        {
            version (Windows)
            {
                try
                {
                    spawnShell("taskmgr.exe");
                }
                catch (Exception)
                {
                }
            }
        };
        _taskbar.onDateTimeSettings = delegate()
        {
            openCalendar();
        };
        _taskbar.onVolumeClick = delegate() { openVolumePanel(); };
        _taskbar.onBatteryClick = delegate() { openBatteryPanel(); };
        _taskbar.onWifiClick = delegate() { openWifiPanel(); };
        _taskbar.onHiddenIconsClick = delegate() { openHiddenIconsPanel(); };
        _taskbar.onLanguageClick = delegate() { openLanguagePanel(); };
        _taskbar.onSearchClick = delegate() { openSearch(); };
        // Hover intent: a short stable-hover delay before the preview appears,
        // then a grace window when the pointer leaves so it can travel from the
        // task button (or the gap above it) onto the preview without it
        // flickering. While the pointer is over the preview it never hides.
        _taskbar.onTaskHover = delegate(int index)
        {
            _taskHovered = true;
            _previewHidePending = false;
            _previewHideDelay = 0;
            _previewWantedIndex = index;
            _previewWantedDelay = 0;
        };
        _taskbar.onTaskHoverLeave = delegate()
        {
            _taskHovered = false;
            _previewWantedIndex = -1;
            _previewWantedDelay = 0;
            _previewHidePending = true;
            _previewHideDelay = 0;
        };
        _taskbar.onEntryOrderChanged = delegate(TaskEntryId[] order)
        {
            persistState();
        };
        // External OS window tasks live in the taskbar. Activation/minimize and
        // live visibility/focus are routed to the OS on the app's behalf.
        _taskbar.onExternalActivate = delegate(ulong hwnd, bool minimized)
        {
            activateExternalTask(hwnd);
            _activeExternalHwnd = hwnd;
        };
        _taskbar.onExternalMinimize = delegate(ulong hwnd)
        {
            minimizeExternalTask(hwnd);
            // The window is no longer the active one, so the next click on its
            // task should restore rather than minimize again.
            if (_activeExternalHwnd == hwnd) _activeExternalHwnd = 0;
        };
        _taskbar.onExternalClose = delegate(ulong hwnd)
        {
            closeExternalTask(hwnd);
        };
        _taskbar.onExternalVisible = delegate(ulong hwnd)
        {
            return externalTaskVisibleNow(hwnd);
        };
        // A taskbar click makes Aurora the foreground window, so the clicked
        // external window is not GetForegroundWindow at that moment. Treat the
        // window the shell most recently activated as active so a second click
        // on its task minimizes it (Windows behavior) instead of re-activating.
        _taskbar.onExternalFocused = delegate(ulong hwnd)
        {
            return externalTaskFocused(hwnd) ||
                (hwnd != 0 && hwnd == _activeExternalHwnd);
        };

        _taskbar.addWindow(_notepadWindow, "Notepad", IconKind.notepad);
        _taskbar.addWindow(_systemWindow, "System", IconKind.computer);
        // "Full screen" lives in the Start menu (small system command) rather
        // than taking a permanent taskbar button.
        restorePinnedTasks();
        restorePinnedApps();
        _taskbar.setActiveWindow(_notepadWindow);

        _volume = systemVolume();

        refreshTray();
        _taskbar.onNotificationHidden = delegate(size_t id, bool hidden)
        {
            foreach (key, value; _notificationIds)
                if (value == id)
                {
                    _notificationHiddenOverride[key] = hidden;
                    break;
                }
        };
        // Ask the owning application to show its own tray menu.
        _taskbar.onNotificationMenu = delegate(size_t id)
        {
            return postNotificationAppMenu(id);
        };
        _taskbar.onPinChanged = delegate(TaskEntryId id, bool pinned)
        {
            const index = _taskbar.indexOfEntry(id);
            if (index < 0) return;
            const exePath = _taskbar.entryGroupKey(cast(size_t) index);
            if (exePath.length == 0) return;
            if (pinned)
                addPinnedApp(exePath,
                    toUTF8(_taskbar.entryTitle(cast(size_t) index)));
            else
            {
                removePinnedApp(exePath);
                _taskbar.removeEntry(id);
            }
        };
        refreshNotifications();
        syncExternalTasks();
    }

    // --- pinned taskbar apps ---------------------------------------------
    private void restorePinnedApps()
    {
        foreach (a; _state.pinnedApps)
        {
            if (a.exePath.length == 0) continue;
            const title = a.title.length > 0 ? a.title : baseName(a.exePath);
            const exePath = a.exePath;
            _taskbar.addPinnedTask(title, executableIcon(exePath),
                delegate() { activateOrLaunchApp(exePath); }, exePath);
        }
    }

    private bool isPinnedExe(string exePath)
    {
        if (exePath.length == 0) return false;
        foreach (a; _state.pinnedApps)
            if (a.exePath == exePath) return true;
        return false;
    }

    private void addPinnedApp(string exePath, string title)
    {
        if (isPinnedExe(exePath)) return;
        PinnedAppState app;
        app.exePath = exePath;
        app.title = title.length > 0 ? title : baseName(exePath);
        _state.pinnedApps ~= app;
        _taskbar.addPinnedTask(app.title, executableIcon(exePath),
            delegate() { activateOrLaunchApp(exePath); }, exePath);
        persistState();
        syncExternalTasks();
    }

    private void removePinnedApp(string exePath)
    {
        PinnedAppState[] kept;
        foreach (a; _state.pinnedApps)
            if (a.exePath != exePath) kept ~= a;
        _state.pinnedApps = kept;
        persistState();
        syncExternalTasks();
    }

    /// Activate a running window of the app, or launch it when none is open.
    private void activateOrLaunchApp(string exePath)
    {
        version (Windows)
        {
            foreach (t; enumerateExternalTasks())
            {
                auto cached = t.hwnd in _externalGroupKeys;
                const key = cached !is null ? *cached :
                    externalTaskGroupKey(t.hwnd);
                if (key == exePath)
                {
                    activateExternalTask(t.hwnd);
                    return;
                }
            }
            try
            {
                spawnShell(exePath);
            }
            catch (Exception)
            {
            }
        }
    }

    // --- real notification-area (tray) icons -----------------------------
    // The shell enumerates the live Windows tray icons (visible + overflow),
    // preserves the user's drag order across refreshes, and keeps hide/show
    // overrides. State is keyed by a stable per-icon string.
    private string[] _notificationOrder;
    private size_t[string] _notificationIds;
    private size_t _nextNotificationId = 1;
    private bool[string] _notificationHiddenOverride;
    private ulong[string] _notificationHwnd;
    private uint[string] _notificationCallback;
    private uint[string] _notificationOsId;
    // True for Windows-provided icons (network/battery/security/...): they have
    // no reachable application handler, so a left-click opens Settings instead.
    private bool[string] _notificationSystem;
    // NB: D floating-point fields default to NaN, which makes every
    // `accumulator >= threshold` check permanently false (no tick updates).
    // Every timer field must be explicitly initialised.
    private double _notificationRefreshAccumulator = 0.0;
    // Poll fast enough that animating tray icons (e.g. Task Manager's CPU
    // graph) visibly update.
    private enum double notificationRefreshSeconds = 1.0;

    /// Stable identity for a tray icon: owner + window handle + notification id.
    /// The tooltip is deliberately excluded because it changes constantly (CPU
    /// %, battery %), which would otherwise look like a brand-new icon.
    private static string notificationKey(const ref TrayIconInfo info)
    {
        return info.exePath ~ "\t" ~ to!string(info.hwnd) ~ "\t" ~
            to!string(info.id);
    }

    /// Map a stable notification id back to its key ("" when unknown).
    private string notificationKeyForId(size_t id)
    {
        foreach (key, value; _notificationIds)
            if (value == id) return key;
        return "";
    }

    /// Owning executable path of a notification id (from its stable key).
    private string notificationExeForId(size_t id)
    {
        const key = notificationKeyForId(id);
        foreach (i, c; key)
            if (c == '\t') return key[0 .. i];
        return "";
    }

    /// Ask the owning app to open its tray context menu; false when there is no
    /// usable callback (the caller then keeps its own menu).
    private bool postNotificationAppMenu(size_t id)
    {
        const key = notificationKeyForId(id);
        if (key.length == 0) return false;
        auto hwndPtr = key in _notificationHwnd;
        auto callbackPtr = key in _notificationCallback;
        auto osIdPtr = key in _notificationOsId;
        if (hwndPtr is null || callbackPtr is null || osIdPtr is null)
            return false;
        return postTrayContextMenu(*hwndPtr, *callbackPtr, *osIdPtr);
    }

    /// Ask the owning app to run its primary (left-click) tray action; false
    /// for Windows system icons or when there is no usable callback.
    private bool postNotificationPrimaryClick(size_t id)
    {
        const key = notificationKeyForId(id);
        if (key.length == 0) return false;
        auto systemPtr = key in _notificationSystem;
        if (systemPtr !is null && *systemPtr) return false;
        auto hwndPtr = key in _notificationHwnd;
        auto callbackPtr = key in _notificationCallback;
        auto osIdPtr = key in _notificationOsId;
        if (hwndPtr is null || callbackPtr is null || osIdPtr is null)
            return false;
        return postTrayPrimaryClick(*hwndPtr, *callbackPtr, *osIdPtr);
    }

    /// Ask the owning app to run its tray double-click action (Task Manager,
    /// etc. open only on a native double-click).
    private bool postNotificationDoubleClick(size_t id)
    {
        const key = notificationKeyForId(id);
        if (key.length == 0) return false;
        auto systemPtr = key in _notificationSystem;
        if (systemPtr !is null && *systemPtr) return false;
        auto hwndPtr = key in _notificationHwnd;
        auto callbackPtr = key in _notificationCallback;
        auto osIdPtr = key in _notificationOsId;
        if (hwndPtr is null || callbackPtr is null || osIdPtr is null)
            return false;
        return postTrayDoubleClick(*hwndPtr, *callbackPtr, *osIdPtr);
    }

    /// Double-clicking a tray icon opens the owning application, exactly like
    /// double-clicking its icon in the Windows notification area. Replaying the
    /// owner's raw tray callback is unreliable: the message packing depends on
    /// the NOTIFYICON_VERSION the app registered, and a mis-packed message can
    /// wake an unrelated handler (observed: Task Manager's icon opening the
    /// ELAN touchpad app). Activating the owner's own window cannot reach a
    /// different app.
    private void invokeTrayDoubleClick(size_t id, string label)
    {
        version (Windows)
        {
            const exePath = notificationExeForId(id);
            if (exePath.length > 0)
            {
                activateOrLaunchApp(exePath);
                return;
            }
        }
        invokeTrayIcon(id, label);
    }

    /// Left-clicking a tray icon the way Windows does: ask the owning
    /// application to perform its own primary action (restore/open the app,
    /// toggle its flyout, ...) by posting its tray callback. Windows-owned
    /// system icons have no reachable handler, so they keep opening the
    /// matching Settings page.
    private void invokeTrayIcon(size_t id, string label)
    {
        version (Windows)
        {
            if (postNotificationPrimaryClick(id)) return;
        }
        activateTrayIcon(notificationExeForId(id), label);
    }

    /// Enumerate the real tray icons and publish them to the taskbar.
    private void refreshNotifications()
    {
        version (Windows)
        {
            ++_notificationRefreshCount;
            auto icons = enumerateTrayIcons();

            bool[string] present;
            TrayIconInfo[string] byKey;
            string[] newKeys;
            foreach (icon; icons)
            {
                if (_settings.hideSystemTrayIcons && icon.isSystem) continue;
                string key = notificationKey(icon);
                if (key !in present) newKeys ~= key;
                present[key] = true;
                byKey[key] = icon;
            }

            // Preserve the user's drag order: start from what the taskbar shows
            // right now, then any still-present saved keys, then new icons.
            string[] order;
            bool[string] seen;
            foreach (current; _taskbar.notifications())
            {
                const key = notificationKeyForId(current.id);
                if (key.length == 0 || key in seen || key !in present) continue;
                seen[key] = true;
                order ~= key;
            }
            foreach (key; _notificationOrder)
            {
                if (key in seen || key !in present) continue;
                seen[key] = true;
                order ~= key;
            }
            foreach (key; newKeys)
            {
                if (key in seen) continue;
                seen[key] = true;
                order ~= key;
            }
            _notificationOrder = order;

            // Build the desired model, assigning stable ids.
            NotificationIcon[] desired;
            foreach (key; order)
            {
                auto found = key in byKey;
                if (found is null) continue;
                auto info = *found;
                auto idPtr = key in _notificationIds;
                if (idPtr is null)
                {
                    _notificationIds[key] = _nextNotificationId++;
                    idPtr = key in _notificationIds;
                }
                auto hiddenPtr = key in _notificationHiddenOverride;
                _notificationHwnd[key] = info.hwnd;
                _notificationCallback[key] = info.callbackMessage;
                _notificationOsId[key] = info.id;
                _notificationSystem[key] = info.isSystem;

                NotificationIcon icon;
                icon.id = *idPtr;
                icon.label = toUTF32(info.label.length > 0 ?
                    info.label : "Notification");
                icon.icon = IconKind.settings;
                icon.iconImage = info.icon;
                icon.hidden = hiddenPtr !is null ? *hiddenPtr : info.hidden;
                icon.system = info.isSystem;
                const label = info.label;
                const stableId = icon.id;
                icon.action = delegate() { invokeTrayIcon(stableId, label); };
                icon.doubleClickAction =
                    delegate() { invokeTrayDoubleClick(stableId, label); };
                desired ~= icon;
            }

            // A structural change (icon added/removed/reordered/hidden) rebuilds
            // the model; otherwise update labels/icons in place so periodically
            // changing tray icons keep animating without disturbing the order.
            auto current = _taskbar.notifications();
            bool structural = current.length != desired.length;
            if (!structural)
            {
                foreach (i; 0 .. desired.length)
                {
                    if (current[i].id != desired[i].id ||
                        current[i].hidden != desired[i].hidden)
                    {
                        structural = true;
                        break;
                    }
                }
            }
            if (structural)
            {
                _taskbar.clearNotifications();
                foreach (icon; desired) _taskbar.addNotification(icon);
            }
            else
            {
                foreach (icon; desired)
                    _taskbar.updateNotification(icon.id, icon.label,
                        icon.iconImage);
            }
            refreshTray();
            // Keep an open overflow flyout live too (its model is a snapshot).
            refreshHiddenPanel();
        }
    }

    /// Best-effort activation of a tray icon when the owning app has no usable
    /// tray callback: focus its running window (or launch it), or open the
    /// matching Settings page for Windows-owned components.
    private void activateTrayIcon(string exePath, string label)
    {
        version (Windows)
        {
            if (isSystemExecutable(exePath))
            {
                // Windows-owned system icon: open the matching Aurora flyout
                // (network/battery/volume/input language), like Windows. Fall
                // back to the matching Settings page for anything not modeled.
                const lower = toLower(label);
                if (canFind(lower, "network") || canFind(lower, "wi-fi") ||
                    canFind(lower, "wifi") || canFind(lower, "internet") ||
                    canFind(lower, "access"))
                {
                    openWifiPanel();
                    return;
                }
                if (canFind(lower, "volume") || canFind(lower, "speaker") ||
                    canFind(lower, "sound") || canFind(lower, "audio") ||
                    canFind(lower, "headphone"))
                {
                    openVolumePanel();
                    return;
                }
                if (canFind(lower, "battery") || canFind(lower, "charged") ||
                    canFind(lower, "power"))
                {
                    openBatteryPanel();
                    return;
                }
                if (canFind(lower, "language") || canFind(lower, "input") ||
                    canFind(lower, "keyboard") || canFind(lower, "english") ||
                    canFind(lower, "lithuanian"))
                {
                    openLanguagePanel();
                    return;
                }
                const uri = systemSettingsUri(label);
                if (uri.length > 0)
                {
                    systemOpenSettings(uri);
                    return;
                }
            }
            else if (exePath.length > 0)
            {
                // The owning app registered the icon, so it is already running:
                // focus its window instead of starting a second instance
                // (activateOrLaunchApp launches only when no window is open).
                activateOrLaunchApp(exePath);
                return;
            }
        }
        showMessage(label.length > 0 ? label : "Notification");
    }

    /// Best-effort Settings page for a Windows system tray icon's label.
    private static string systemSettingsUri(string label)
    {
import std.string : toLower;
        const text = toLower(label);
        if (text.length == 0) return "";
        if (canFind(text, "bluetooth")) return "ms-settings:bluetooth";
        if (canFind(text, "security")) return "windowsdefender:";
        if (canFind(text, "headphone") || canFind(text, "volume") ||
            canFind(text, "audio") || canFind(text, "speaker") ||
            canFind(text, "sound"))
            return "ms-settings:sound";
        if (canFind(text, "battery") || canFind(text, "charged"))
            return "ms-settings:batterysaver";
        if (canFind(text, "wi-fi") || canFind(text, "wifi") ||
            canFind(text, "internet") || canFind(text, "network") ||
            canFind(text, "access"))
            return "ms-settings:network";
        return "";
    }

    private static bool isSystemExecutable(string path)
    {
        if (path.length < 12) return false;
        return toLower(path[0 .. 12]) == "c:\\windows\\";
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
        auto groupToggle = content.add(new CheckBox(
            "Group taskbar buttons by app",
            _taskbar.taskGrouping()));
        groupToggle.onChanged = delegate(bool checked)
        {
            _taskbar.setTaskGrouping(checked);
            _settings.groupTasks = checked;
            saveDesktopSettings(_settings);
        };
        auto systemTrayToggle = content.add(new CheckBox(
            "Hide Windows system tray icons",
            _settings.hideSystemTrayIcons));
        systemTrayToggle.onChanged = delegate(bool checked)
        {
            _settings.hideSystemTrayIcons = checked;
            saveDesktopSettings(_settings);
            _notificationOrder.length = 0;
            refreshNotifications();
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
        state.schema = 2;
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
            // Drop pins an older build leaked from live OS windows: they are
            // recreated by syncExternalTasks and must not become permanent
            // icon-less command buttons. Schema < 2 is the build that captured
            // every live window as a "command" pin with no icon, so those are
            // discarded on the first launch after the upgrade.
            if (t.kind == "external") continue;
            if (_state.schema < 2 && t.kind == "command" && t.iconName == "none")
                continue;
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
        next.schema = 2;
        next.taskbarModernShell = _taskbar.modernShell();
        next.hideSystemCursor = _hideSystemCursor;
        next.windows = captureWindows();
        next.icons = captureIcons();
        next.pinnedTasks = capturePinnedTasks();
        next.pinnedTasks = canonicalPinnedOrder(next.pinnedTasks);
        next.pinnedApps = _state.pinnedApps;
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
            // Live external OS windows are NOT user pins: they come and go with
            // the OS, so persisting them would resurrect them as permanent
            // (icon-less) command entries on every launch. Pinned apps are
            // persisted separately in `pinnedApps`.
            if (_taskbar.entryHostHwnd(i) != 0) continue;
            if (_taskbar.entryPinned(i)) continue;
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
        _previewIndex = index;
        if (hwnd != 0)
        {
            // External OS window: capture a real thumbnail with PrintWindow.
            version (Windows)
            {
                // A grouped app shows one tile per window so the user can pick
                // the window instead of cycling blindly. Dead members can linger
                // for up to one sync tick, so filter to live windows first.
                auto members = _taskbar.entryHostHwnds(cast(size_t) index);
                ulong target = hwnd;
                if (members.length > 1)
                {
                    RgbaImage[] images;
                    ulong[] live;
                    string[] captions;
                    foreach (memberHwnd; members)
                    {
                        if (!externalTaskAlive(memberHwnd)) continue;
                        images ~= captureThumbnailCached(memberHwnd);
                        live ~= memberHwnd;
                        captions ~= cleanTaskTitle(externalTaskTitle(memberHwnd));
                    }
                    if (live.length > 1)
                    {
                        auto preview = new TaskPreview(title, images, live,
                            captions);
                        preview.onCloseRequested = delegate()
                        {
                            closeExternalTask(hwnd);
                        };
                        preview.onActivateHwnd = delegate(ulong memberHwnd)
                        {
                            activateExternalTask(memberHwnd);
                        };
                        if (preview.show(_taskbar,
                                _taskbar.entryGlobalBounds(cast(size_t) index)))
                            _preview = preview;
                        return;
                    }
                    if (live.length == 1) target = live[0];
                }
                auto image = captureThumbnailCached(target);
                if (image is null)
                {
                    // Fall back to an icon-only preview (no thumbnail).
                    return;
                }
                auto preview = new TaskPreview(title, image);
                preview.onCloseRequested = delegate()
                {
                    closeExternalTask(target);
                };
                preview.onActivate = delegate() { activateExternalTask(target); };
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
        _previewIndex = -1;
    }

    /**
     * Advance the hover-intent timers. The preview appears once the pointer
     * rests on a task for a moment and only hides after a grace window that the
     * pointer can cancel by moving onto the preview.
     */
    private void updateTaskPreviewHover(double deltaSeconds)
    {
        if (_previewWantedIndex >= 0)
        {
            _previewWantedDelay += deltaSeconds;
            if (_previewWantedDelay >= previewShowDelaySeconds)
            {
                const index = _previewWantedIndex;
                _previewWantedIndex = -1;
                if (_previewIndex != index || _preview is null ||
                    _preview.dismissed())
                    showTaskPreview(index);
            }
        }
        const preview = _preview;
        if (preview is null || preview.dismissed())
        {
            _previewHidePending = false;
            _previewHideDelay = 0;
            return;
        }
        // Keep the preview while the pointer is on a task entry, still waiting
        // to show one, or over the preview panel itself.
        const keepOpen = _taskHovered || _previewWantedIndex >= 0 ||
            preview.pointerInside();
        if (keepOpen)
        {
            _previewHidePending = false;
            _previewHideDelay = 0;
            return;
        }
        _previewHidePending = true;
        _previewHideDelay += deltaSeconds;
        if (_previewHideDelay >= previewHideGraceSeconds)
        {
            hideTaskPreview();
            _previewHidePending = false;
            _previewHideDelay = 0;
        }
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

    /// Open a real desktop item (file/folder/shortcut) with the shell.
    private void openDesktopEntry(string path)
    {
        try
        {
            spawnShell(path);
        }
        catch (Exception)
        {
            showMessage("Could not open " ~ baseName(path));
        }
    }

    /// Pick a glyph for a file by its extension.
    private static IconKind iconKindForFile(string name)
    {
        const lower = name.toLower;
        foreach (extension; [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp",
            ".ico", ".tif", ".tiff"])
            if (lower.endsWith(extension)) return IconKind.image;
        foreach (extension; [".mp3", ".wav", ".flac", ".m4a", ".ogg", ".wma"])
            if (lower.endsWith(extension)) return IconKind.music;
        foreach (extension; [".txt", ".md", ".log", ".ini", ".json", ".xml",
            ".csv", ".rtf"])
            if (lower.endsWith(extension)) return IconKind.newDocument;
        return IconKind.file;
    }

    /// Let the user pick an image and use it as the wallpaper (also applied to
    /// the Windows desktop so the choice persists outside Aurora).
    private void chooseAndApplyWallpaper()
    {
        version (Windows)
        {
            import aurora.platform.select : PlatformWindow;
            import core.sys.windows.windef : HWND;
            HWND owner;
            if (_window !is null)
            {
                auto native = cast(PlatformWindow) _window.nativeWindow();
                if (native !is null) owner = cast(HWND) native.hwnd();
            }
            const chosen = chooseWallpaperFile(owner);
            if (chosen.length == 0) return;
            const applied = setWallpaper(chosen);
            auto image = loadWallpaperImage(chosen);
            if (image !is null) _desktop.setWallpaper(image);
            showMessage(applied ? "Wallpaper updated." :
                "Could not set the Windows wallpaper.");
        }
        else
        {
            showMessage("Wallpaper is only supported on Windows.");
        }
    }

    /// Re-scan the real Desktop folders and add any items not already shown.
    private void reloadDesktopEntries()
    {
        bool[string] present;
        for (size_t i = 0; i < _desktop.iconCount(); ++i)
        {
            auto existing = _desktop.iconAt(i);
            if (existing !is null) present[toUTF8(existing.text())] = true;
        }
        foreach (entry; enumerateDesktopEntries())
        {
            if (entry.name in present) continue;
            const path = entry.path;
            const iconKind = entry.directory ? IconKind.folder :
                iconKindForFile(entry.name);
            auto item = _desktop.addIcon(entry.name, iconKind,
                delegate() { openDesktopEntry(path); });
            auto shellIcon = fileIcon(path);
            if (shellIcon !is null) item.setIconImage(shellIcon);
            configureDesktopIcon(item);
        }
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
        // Input-language indicator ("ENG"), like the Windows 11 tray. Enumerate
        // the installed layouts once and reuse the result for the indicator and
        // the open flyout (each enumeration runs GetKeyboardLayoutList plus a
        // GetLocaleInfoW per layout, so calling it three times was the main
        // per-tick cost behind the laggy language flyout).
        auto languages = inputLanguages();
        string abbrev = "ENG";
        string name;
        foreach (language; languages)
            if (language.active)
            {
                abbrev = language.abbrev;
                name = language.name;
                break;
            }
        next.languageLabel = toUTF32(abbrev);
        next.languageName = toUTF32(name);
        _tray = next;
        _taskbar.setTrayState(next);
        if (_volumePanel !is null && !_volumePanel.dismissed())
            _volumePanelContent.update(_tray.volumePercent, _muted);
        if (_languagePanel !is null && !_languagePanel.dismissed() &&
            _languagePanelContent !is null)
            _languagePanelContent.update(languages);
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
        panel.onOpenBatterySettings = delegate()
        {
            dismissPanel();
            systemOpenSettings("ms-settings:batterysaver");
        };
        showPanel(PanelKind.battery, panel, _taskbar.trayIconGlobalBounds(2));
    }

    /// Windows-style input-language flyout: pick an installed keyboard layout.
    private void openLanguagePanel()
    {
        auto panel = new LanguagePanel(inputLanguages());
        panel.onOpenSettings = delegate()
        {
            dismissPanel();
            systemOpenSettings("ms-settings:regionlanguage");
        };
        panel.onSelect = delegate(size_t hkl)
        {
            if (hkl == 0 || hkl == activeInputLanguage()) return;
            activateInputLanguage(hkl);
            // Publishes the new indicator and refreshes the open panel.
            refreshTray();
        };
        showPanel(PanelKind.language, panel,
            _taskbar.trayIconGlobalBounds(4));
        _languagePanel = _panelPopup;
        _languagePanelContent = panel;
    }

    private void openWifiPanel()
    {
        // Instant open: build the panel with a fast, non-blocking query so the
        // button never freezes the UI. Then kick an active scan and poll it on
        // the background tick so the surrounding networks appear without a
        // synchronous sleep on the UI thread.
        auto panel = new WifiPanel(queryWifi());
        panel.onOpenNetworkSettings = delegate()
        {
            dismissPanel();
            systemOpenSettings("ms-settings:network");
        };
        panel.onRefresh = delegate() { startWifiScan(); };
        panel.onAirplaneMode = delegate()
        {
            dismissPanel();
            systemOpenSettings("ms-settings:network-airplanemode");
        };
        panel.onMobileHotspot = delegate()
        {
            dismissPanel();
            systemOpenSettings("ms-settings:network-mobilehotspot");
        };
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
        // NB: showPanel() calls dismissPanel(), which clears the cached panel
        // references, so re-bind them AFTER showing or refreshes no-op.
        _wifiPanel = _panelPopup;
        _wifiPanelContent = panel;
        startWifiScan();
    }

    /// Kick an active scan and start polling the cached list, showing a clear
    /// "scanning" status until the surrounding networks have settled.
    private void startWifiScan()
    {
        kickWifiScan();
        _wifiScanning = true;
        _wifiScanElapsed = 0.0;
        _wifiScanStable = 0.0;
        _wifiPollElapsed = 0.0;
        _wifiPollActive = true;
        _wifiPollMax = 8.0;   // give the driver up to ~8 s to finish
        _wifiLastCount = -1;  // force the first poll to count as growth
        if (_wifiPanelContent !is null)
            _wifiPanelContent.refresh(queryWifi(), scanningText(), true);
    }

    private string scanningText() const
    {
        const remaining = _wifiPollMax - _wifiScanElapsed;
        const seconds = remaining > 0 ? cast(int) (remaining + 0.5) : 0;
        return format("Scanning for networks... %ds", seconds);
    }

    // Pull the latest scan into the panel without blocking. Asks Windows to
    // rescan when the list is still sparse, so the surrounding networks rotate
    // in over the poll window.
    private void refreshWifiPanel(string feedback)
    {
        if (_wifiPanel is null || _wifiPanel.dismissed() ||
            _wifiPanelContent is null)
            return;
        _wifiPanelContent.refresh(queryWifi(), feedback, _wifiScanning);
    }

    private void pollWifiPanel(double deltaSeconds)
    {
        if (!_wifiPollActive) return;
        _wifiPollElapsed += deltaSeconds;
        if (_wifiScanning) _wifiScanElapsed += deltaSeconds;
        if (_wifiPollElapsed < 0.25) return;
        const step = _wifiPollElapsed;
        _wifiPollElapsed = 0.0;

        auto state = queryWifi();
        if (_wifiPanelContent !is null && !_wifiPanel.dismissed())
            _wifiPanelContent.refresh(state, _wifiScanning ? scanningText() : "",
                _wifiScanning);

        if (!_wifiScanning)
        {
            _wifiPollActive = false;
            return;
        }

        const count = cast(int) state.networks.length;
        if (count > _wifiLastCount)
        {
            _wifiLastCount = count;
            _wifiScanStable = 0.0;
        }
        else
            _wifiScanStable += step;

        // Once a non-empty list has stopped growing for ~2 s, or the scan
        // window runs out, stop and clear the scanning status.
        const settled = count > 0 && _wifiScanStable >= 2.0;
        if (settled || _wifiScanElapsed >= _wifiPollMax)
        {
            _wifiScanning = false;
            _wifiPollActive = false;
            if (_wifiPanelContent !is null && !_wifiPanel.dismissed())
                _wifiPanelContent.refresh(state, "", false);
        }
    }

    /// The "Taskbar settings" flyout opened from the taskbar context menu.
    private void openTaskbarSettings()
    {
        dismissStartMenu();
        auto content = new VBox(8, Insets(12));
        auto heading = content.add(new Label("Taskbar settings"));
        heading.setScale(2);
        heading.layoutHints().preferredHeight = 28;

        auto modern = content.add(new CheckBox(
            "Windows shell taskbar (search, tray, date)",
            _taskbar.modernShell()));
        modern.onChanged = delegate(bool checked)
        {
            _taskbar.setModernShell(checked);
            _settings.modernShell = checked;
            saveDesktopSettings(_settings);
        };
        auto group = content.add(new CheckBox(
            "Group taskbar buttons by app", _taskbar.taskGrouping()));
        group.onChanged = delegate(bool checked)
        {
            _taskbar.setTaskGrouping(checked);
            _settings.groupTasks = checked;
            saveDesktopSettings(_settings);
        };
        auto systemTray = content.add(new CheckBox(
            "Hide Windows system tray icons", _settings.hideSystemTrayIcons));
        systemTray.onChanged = delegate(bool checked)
        {
            _settings.hideSystemTrayIcons = checked;
            saveDesktopSettings(_settings);
            _notificationOrder.length = 0;
            refreshNotifications();
        };
        auto locked = content.add(new CheckBox(
            "Lock the taskbar", _taskbar.taskbarLocked()));
        locked.onChanged = delegate(bool checked)
        {
            _taskbar.setTaskbarLocked(checked);
        };
        content.add(new Spacer());
        content.layoutHints().preferredWidth = 340;
        showPanel(PanelKind.taskbarSettings, content, _taskbar.clockBounds());
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
            // Same as clicking the visible icon: run the owning app's own tray
            // action, falling back to launch/Settings.
            invokeTrayIcon(id, label);
        };
        panel.onIconMenu = delegate(size_t id)
        {
            return postNotificationAppMenu(id);
        };
        panel.onIconHidden = delegate(size_t id, bool hidden)
        {
            _taskbar.setNotificationHidden(id, hidden);
            _tray.hiddenIconCount = hiddenCount();
            _taskbar.setTrayState(_tray);
            // Show-in-tray / drag-out changes the visible cluster: close the
            // overflow flyout so the tray update is immediately visible.
            dismissPanel();
        };
        showPanel(PanelKind.hidden, panel, _taskbar.trayIconGlobalBounds(3));
        _hiddenPanel = panel;
    }

    /// Rebuild the open overflow panel from the live model so hidden icons keep
    /// animating while the flyout is open.
    private void refreshHiddenPanel()
    {
        if (_hiddenPanel is null || _panelKind != PanelKind.hidden ||
            _panelPopup is null || _panelPopup.dismissed() ||
            _hiddenPanel.dragging())
            return;
        NotificationIcon[] hidden;
        foreach (icon; _taskbar.notifications())
            if (icon.hidden) hidden ~= icon;
        _hiddenPanel.refresh(hidden);
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
    // Last external window the shell activated (or that was foreground), so a
    // second taskbar click on it minimizes instead of re-activating.
    private ulong _activeExternalHwnd;
    // Real windows hidden by Show Desktop, restored when it is toggled back.
    private ulong[] _desktopMinimizedHwnds;
    // Bounded per-window icon-resolution attempts (see syncExternalTasks).
    private ubyte[ulong] _externalIconAttempts;
    // Resolved grouping key per hwnd (owning executable path), so grouping only
    // pays the OpenProcess/query cost once per window.
    private string[ulong] _externalGroupKeys;
    // Last good thumbnail per window. PrintWindow cannot capture a minimized
    // window, so hovering a minimized task reuses the last frame captured while
    // it was visible instead of showing black.
    private RgbaImage[ulong] _thumbnailCache;

    private static bool bitmapHasContent(RgbaImage image)
    {
        if (image is null) return false;
        const px = image.pixels();
        // A failed capture is uniformly black; sample to stay cheap.
        for (size_t i = 0; i + 3 < px.length; i += 4 * 7)
            if (px[i] > 16 || px[i + 1] > 16 || px[i + 2] > 16) return true;
        return false;
    }

    /// Capture a window thumbnail, falling back to the last good frame when the
    /// window is minimized (or the capture failed).
    private RgbaImage captureThumbnailCached(ulong hwnd)
    {
        // Return an already-captured frame immediately so showing a preview on
        // hover is instant (Windows-like); the periodic sync keeps it fresh.
        // Only pay for a synchronous capture when we have nothing to show.
        auto cached = hwnd in _thumbnailCache;
        if (cached !is null) return *cached;
        auto size = externalTaskSize(hwnd);
        auto image = captureExternalThumbnail(hwnd, size.width, size.height);
        if (image !is null && bitmapHasContent(image))
        {
            _thumbnailCache[hwnd] = image;
            return image;
        }
        return null;
    }

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
                auto cachedKey = t.hwnd in _externalGroupKeys;
                _externalGroupKeys[t.hwnd] = cachedKey !is null ? *cachedKey :
                    externalTaskGroupKey(t.hwnd);
            }

            // Keep "active external window" fresh: while an external window is
            // foreground it is the active one; if it closed or was minimized,
            // forget it so the next task click restores instead of minimizing.
            if (_activeExternalHwnd != 0 && (_activeExternalHwnd !in live ||
                externalTaskMinimized(_activeExternalHwnd)))
                _activeExternalHwnd = 0;
            if (_activeExternalHwnd == 0)
                foreach (t; tasks)
                    if (externalTaskFocused(t.hwnd))
                    {
                        _activeExternalHwnd = t.hwnd;
                        break;
                    }

            // Feed each pinned app its live windows so it keeps a running
            // indicator and a multi-window hover preview. Any separate external
            // entry for those windows is removed so there is one button per app.
            if (_state.pinnedApps.length > 0)
            {
                foreach (a; _state.pinnedApps)
                {
                    if (a.exePath.length == 0) continue;
                    ulong[] members;
                    string[] titles;
                    foreach (t; tasks)
                    {
                        auto g = t.hwnd in _externalGroupKeys;
                        if (g is null || *g != a.exePath) continue;
                        members ~= t.hwnd;
                        titles ~= cleanTaskTitle(t.title);
                        const index = _taskbar.indexOfExternal(t.hwnd);
                        if (index >= 0 && !_taskbar.entryPinned(cast(size_t) index))
                            _taskbar.removeExternal(t.hwnd);
                    }
                    _taskbar.setPinnedAppRunning(a.exePath, members, titles);
                }
            }

            foreach (t; tasks)
            {
                auto cachedKey = t.hwnd in _externalGroupKeys;
                const groupKey = cachedKey !is null ? *cachedKey : "";
                if (isPinnedExe(groupKey)) continue;
                if (_taskbar.indexOfExternal(t.hwnd) < 0)
                {
                    // `computer` is only a last-resort glyph for a window whose
                    // real icon cannot be resolved; the raster icon normally
                    // replaces it (see below).
                    _taskbar.addExternalTask(t.hwnd, cleanTaskTitle(t.title),
                        IconKind.computer, groupKey);
                    _externalIconAttempts[t.hwnd] = 0;
                }
                // Resolve the real OS icon and hand it to the taskbar so the
                // entry paints it instead of an IconKind placeholder. Some apps
                // publish WM_SETICON a moment after the window appears, so a
                // null result is retried a few times (iconHasInk/executable
                // fallback make a permanent null rare).
                if (_taskbar.externalTaskIconImage(t.hwnd) is null)
                {
                    auto attempted = t.hwnd in _externalIconAttempts;
                    const tries = attempted is null ? cast(ubyte) 0 : *attempted;
                    if (tries < 3)
                    {
                        _taskbar.setExternalTaskIcon(t.hwnd,
                            externalTaskIcon(t.hwnd));
                        _externalIconAttempts[t.hwnd] = cast(ubyte) (tries + 1);
                    }
                }
                // Refresh a thumbnail while the window is visible so previews
                // are near-live and a minimized task can still show its last
                // frame (PrintWindow cannot capture a minimized window).
                if (!externalTaskMinimized(t.hwnd))
                {
                    auto size = externalTaskSize(t.hwnd);
                    auto image = captureExternalThumbnail(t.hwnd, size.width,
                        size.height);
                    if (image !is null && bitmapHasContent(image))
                        _thumbnailCache[t.hwnd] = image;
                }
            }
            // Remove entries whose window is gone.
            foreach (hwnd; _externalHwnds)
            {
                if (hwnd in live) continue;
                _taskbar.removeExternal(hwnd);
                if (hwnd in _externalIconAttempts) _externalIconAttempts.remove(hwnd);
                if (hwnd in _externalGroupKeys) _externalGroupKeys.remove(hwnd);
                if (hwnd in _thumbnailCache) _thumbnailCache.remove(hwnd);
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
    // Live overflow panel (needs refreshing because its model is a snapshot).
    private HiddenIconsPanel _hiddenPanel;
    private PopupOverlay _volumePanel;
    private VolumePanel _volumePanelContent;
    private PopupOverlay _wifiPanel;
    private WifiPanel _wifiPanelContent;
    private PopupOverlay _languagePanel;
    private LanguagePanel _languagePanelContent;
    // Identifies which tray popup is open so re-clicking its taskbar icon
    // toggles it closed instead of re-opening (Windows tray behavior).
    private enum PanelKind : ubyte { none, volume, battery, wifi, hidden, language, taskbarSettings }
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
        _languagePanel = null;
        _languagePanelContent = null;
        _hiddenPanel = null;
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
        updateTaskPreviewHover(deltaSeconds);
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
        // Refresh the real tray icons periodically (apps add/remove them).
        _notificationRefreshAccumulator += deltaSeconds;
        if (_notificationRefreshAccumulator >= notificationRefreshSeconds)
        {
            _notificationRefreshAccumulator = 0.0;
            refreshNotifications();
        }
    }

    private double _externalTaskAccumulator = 0.0;
    private double _stateSaveAccumulator = 0.0;
    private double _clockAccumulator = 0.0;
    private double _wifiPollElapsed = 0.0;
    private double _wifiPollMax = 0.0;
    private bool _wifiPollActive;
    private bool _wifiScanning;
    private double _wifiScanElapsed = 0.0;
    private double _wifiScanStable = 0.0;
    private int _wifiLastCount;

    // Test-only accessors. Kept on the class (not free functions) so the
    // headless smoke can inspect shell state without a running window loop.
    Taskbar taskbarForTesting() @safe pure nothrow @nogc { return _taskbar; }

    // Guards the "D double fields default to NaN" class of bug: the periodic
    // notification refresh must actually run when ticked.
    private size_t _notificationRefreshCount;
    size_t notificationRefreshCountForTesting() const @safe pure nothrow @nogc
    {
        return _notificationRefreshCount;
    }

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
    // Never hide the native cursor during a drag: this shell relies on the
    // OS cursor, and any gap between hiding it and drawing a replacement makes
    // the mouse vanish for the whole gesture (dragging taskbar icons/windows).
    options.synchronizedDragPointer = false;
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
