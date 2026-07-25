module demos.desktop_environment;

import aurora;
import std.conv : to;
import std.utf : toUTF8;

final class DesktopEnvironmentRoot : Widget
{
    private DesktopSurface _desktop;
    private Taskbar _taskbar;
    private StartMenu _startMenu;
    private FloatingWindow _notepadWindow;
    private FloatingWindow _filesWindow;
    private FloatingWindow _systemWindow;
    private FloatingWindow _terminalWindow;
    private DesktopIcon _trashIcon;
    private int _newDocumentCount;

    void delegate() onToggleFullscreen;

    this()
    {
        _desktop = add(new DesktopSurface());
        _taskbar = add(new Taskbar());

        auto notepadIcon = _desktop.addIcon("Notepad", IconKind.notepad,
            delegate() { showWindow(_notepadWindow); });
        auto filesIcon = _desktop.addIcon("Files", IconKind.folder,
            delegate() { showWindow(_filesWindow); });
        auto computerIcon = _desktop.addIcon("Computer", IconKind.computer,
            delegate() { showWindow(_systemWindow); });
        auto terminalIcon = _desktop.addIcon("Terminal", IconKind.terminal,
            delegate() { showWindow(_terminalWindow); });
        _trashIcon = _desktop.addIcon("Trash", IconKind.trash,
            delegate() { showMessage("Trash is empty."); });
        configureDesktopIcon(notepadIcon);
        configureDesktopIcon(filesIcon);
        configureDesktopIcon(computerIcon);
        configureDesktopIcon(terminalIcon);
        configureDesktopIcon(_trashIcon, false);
        _desktop.onIconDropped = &handleIconDrop;
        _desktop.onRefresh = delegate() { showMessage("Desktop refreshed."); };
        _desktop.onNewItem = delegate() { createDocumentShortcut(); };
        _desktop.onDisplaySettings = delegate() { showWindow(_systemWindow); };
        _desktop.onPersonalize = delegate()
        {
            showMessage("Wallpaper and theme settings are available in System Settings.");
        };

        buildNotepadWindow();
        buildFilesWindow();
        buildSystemWindow();
        buildTerminalWindow();

        _taskbar.onStart = delegate() { toggleStartMenu(); };
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
        _taskbar.addWindow(_notepadWindow, "Notepad", IconKind.notepad);
        _taskbar.addWindow(_filesWindow, "Files", IconKind.folder);
        _taskbar.addWindow(_systemWindow, "System", IconKind.computer);
        _taskbar.addWindow(_terminalWindow, "Terminal", IconKind.terminal);
        _taskbar.addCommand("Full screen", IconKind.maximize, delegate()
        {
            if (onToggleFullscreen !is null) onToggleFullscreen();
        });
        _taskbar.setActiveWindow(_filesWindow);
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
        _notepadWindow.setBounds(Rect(155, 58, 520, 410));
        connectWindow(_notepadWindow);
    }

    private void buildFilesWindow()
    {
        auto content = new VBox(6, Insets(7));
        auto toolbar = content.add(new HBox(5));
        toolbar.layoutHints().preferredHeight = 40;
        toolbar.add(new Button("Up", IconKind.up));
        toolbar.add(new Button("Refresh", IconKind.refresh));
        auto path = toolbar.add(new TextField("/home/demo"));
        path.layoutHints().flex = 1.0;

        auto files = content.add(new ListView());
        files.setItems([
            ListItem("Documents", IconKind.folder, "Folder"),
            ListItem("Pictures", IconKind.folder, "Folder"),
            ListItem("Music", IconKind.folder, "Folder"),
            ListItem("project-notes.txt", IconKind.notepad, "4.2 KiB"),
            ListItem("wallpaper.png", IconKind.image, "1.8 MiB"),
            ListItem("theme.d", IconKind.file, "12.7 KiB")
        ]);
        files.onActivated = delegate(int index)
        {
            if (index >= 0)
                showMessage("Opened " ~ toUTF8(files.items()[cast(size_t) index].text));
        };

        _filesWindow = _desktop.addWindow(
            new FloatingWindow("File Explorer", IconKind.folder, content));
        _filesWindow.setBounds(Rect(540, 125, 590, 430));
        connectWindow(_filesWindow);
    }

    private void buildSystemWindow()
    {
        auto content = new VBox(10, Insets(12));
        auto heading = content.add(new Label("System Overview"));
        heading.setScale(3);
        heading.layoutHints().preferredHeight = 36;
        content.add(new Label("CPU usage"));
        auto cpu = content.add(new ProgressBar(0.42));
        cpu.setLabel("42%" );
        content.add(new Label("Memory usage"));
        auto memory = content.add(new ProgressBar(0.68));
        memory.setLabel("68%" );
        content.add(new Label("Display brightness"));
        auto slider = content.add(new Slider(0, 100, 75));
        slider.onChanged = delegate(double value)
        {
            memory.setLabel("Brightness " ~ to!string(cast(int) value) ~ "%");
            memory.setValue(value / 100.0);
        };
        content.add(new CheckBox("Enable desktop animations", true));
        content.add(new CheckBox("Show seconds in taskbar", false));
        content.add(new Spacer());

        _systemWindow = _desktop.addWindow(
            new FloatingWindow("System Settings", IconKind.settings, content));
        _systemWindow.setBounds(Rect(320, 190, 430, 390));
        _systemWindow.minimize();
        connectWindow(_systemWindow);
    }

    private void buildTerminalWindow()
    {
        auto terminal = new TextArea(
            "Aurora shell 0.1\n"
            ~ "$ uname -s\n"
            ~ "Aurora Desktop\n"
            ~ "$ help\n"
            ~ "Commands: demo, about, clear\n\n"
            ~ "$ ");
        terminal.setShowBorder(false);
        _terminalWindow = _desktop.addWindow(
            new FloatingWindow("Terminal", IconKind.terminal, terminal));
        _terminalWindow.setBounds(Rect(250, 115, 610, 360));
        _terminalWindow.minimize();
        connectWindow(_terminalWindow);
    }

    private StartMenu createStartMenu()
    {
        auto menu = new StartMenu(_taskbar);
        menu.addApplication("Notepad", IconKind.notepad,
            delegate() { showWindow(_notepadWindow); }, "Text editor");
        menu.addApplication("File Explorer", IconKind.folder,
            delegate() { showWindow(_filesWindow); }, "Browse files and folders");
        menu.addApplication("System Settings", IconKind.settings,
            delegate() { showWindow(_systemWindow); }, "Display and preferences");
        menu.addApplication("Terminal", IconKind.terminal,
            delegate() { showWindow(_terminalWindow); }, "Command shell");
        menu.addSystemCommand("Full screen (F11)", IconKind.maximize,
            delegate()
            {
                if (onToggleFullscreen !is null) onToggleFullscreen();
            }, false, "Use the entire display");
        menu.addSystemCommand("Taskbar settings", IconKind.settings,
            delegate()
            {
                showMessage("Taskbar buttons can be reordered and opened with right click.");
            });
        menu.addSystemCommand("Shut down", IconKind.close,
            delegate() { closeHostWindow(); }, true);
        menu.onDismissed = delegate()
        {
            if (_startMenu is menu) _startMenu = null;
            _taskbar.setStartMenuOpen(false);
        };
        return menu;
    }

    private void dismissStartMenu()
    {
        auto menu = _startMenu;
        if (menu !is null && !menu.dismissed()) menu.dismiss();
        _startMenu = null;
        _taskbar.setStartMenuOpen(false);
    }

    private void configureDesktopIcon(DesktopIcon icon, bool removable = true)
    {
        if (icon is null) return;
        icon.onRenameRequested = delegate(DesktopIcon target)
        {
            const current = toUTF8(target.text());
            target.setText(current ~ " (renamed)");
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
            const rect = target.bounds();
            showMessage(toUTF8(target.text()) ~ "\nPosition: " ~
                to!string(rect.x) ~ ", " ~ to!string(rect.y));
        };
    }

    private bool handleIconDrop(DesktopIcon source, DesktopIcon target)
    {
        if (source is null || target is null) return false;
        if (target is _trashIcon && source !is _trashIcon)
        {
            const name = toUTF8(source.text());
            _desktop.removeIcon(source);
            showMessage(name ~ " was moved to Trash.");
            return true;
        }
        showMessage("Dropped " ~ toUTF8(source.text()) ~ " on " ~
            toUTF8(target.text()) ~ ".");
        return true;
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
        window.onTitleChanged = delegate(FloatingWindow changed)
        {
            _taskbar.updateWindowTitle(changed);
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

    private void toggleStartMenu()
    {
        if (_startMenu !is null && !_startMenu.dismissed())
        {
            dismissStartMenu();
            return;
        }
        auto menu = createStartMenu();
        _startMenu = menu.show(_taskbar, _taskbar.startButtonGlobalBounds()) ? menu : null;
        _taskbar.setStartMenuOpen(_startMenu !is null);
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
        auto dialog = _desktop.addWindow(new FloatingWindow("Aurora", IconKind.start, content));
        dialog.setBounds(Rect(maxInt(20, (_desktop.bounds().width - 360) / 2),
            maxInt(20, (_desktop.bounds().height - 190) / 2), 360, 190));
        okay.onClick = delegate() { dialog.closeWindow(); };
        _desktop.bringChildToFront(dialog);
    }

    protected override void onLayout()
    {
        const barHeight = 52;
        _desktop.setBounds(Rect(0, 0, bounds().width, maxInt(0, bounds().height - barHeight)));
        _taskbar.setBounds(Rect(0, maxInt(0, bounds().height - barHeight), bounds().width, barHeight));
        foreach (window; [_notepadWindow, _filesWindow, _systemWindow, _terminalWindow])
        {
            if (window !is null && window.maximized())
                window.setBounds(Rect(0, 0, _desktop.bounds().width, _desktop.bounds().height));
        }
    }
}

int main()
{
    WindowOptions options;
    options.title = "Aurora Desktop Environment";
    options.width = 1280;
    options.height = 760;
    auto window = new GuiWindow(options, Theme.dark());
    auto root = new DesktopEnvironmentRoot();
    root.onToggleFullscreen = delegate() { window.toggleFullscreen(); };
    window.setRoot(root);
    window.setTitle(options.title ~ " — " ~ window.rendererName());
    return window.run();
}
