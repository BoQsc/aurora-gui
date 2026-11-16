module aurora.widgets.filedialog;

import aurora.canvas : Canvas;
import aurora.color : Color;
import aurora.event : Event, Key, MouseButton;
import aurora.icons : IconKind;
import aurora.layout : HBox, VBox;
import aurora.platform.base : WindowOptions;
import aurora.theme : Theme;
import aurora.types : HorizontalAlign, Insets, Orientation, Point, Rect, Size,
    VerticalAlign, maxInt;
import aurora.widget : Widget;
import aurora.widgets.button : Button, IconButton;
import aurora.widgets.label : Label;
import aurora.widgets.listview : ListItem, ListView;
import aurora.widgets.popup : PopupOverlay, PopupPlacement,
    dismissTransientPopups, popupRoot;
import aurora.widgets.splitpane : SplitPane;
import aurora.widgets.texteditor : TextField;
import aurora.window : GuiWindow;
import std.algorithm.sorting : sort;
import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, isDir;
import std.format : format;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, extension,
    isAbsolute, rootName;
import std.process : environment;
import std.string : icmp;
import std.utf : toUTF8;

version (Windows)
{
    pragma(lib, "shell32");
    import core.sys.windows.shlobj : CSIDL_DESKTOPDIRECTORY, CSIDL_PERSONAL,
        SHGetFolderPathW;
    import core.sys.windows.windef : MAX_PATH;
}

enum FileDialogMode : ubyte
{
    open,
    save
}

struct FileDialogOptions
{
    FileDialogMode mode = FileDialogMode.open;
    string title;
    string initialPath;
    string defaultFileName;
    string acceptLabel;
    // When set, the dialog picks a folder instead of a file: the file-name
    // field is hidden and accepting returns the highlighted folder (or the
    // folder currently open) rather than a file path.
    bool selectFolders = false;
    Size preferredSize = Size(760, 540);
}

private struct FileDialogEntry
{
    string name;
    string path;
    bool directory;
    ulong size;
}

class FileDialogOverlay : PopupOverlay
{
    this(Widget content, Widget focusReturn = null)
    {
        super(content, focusReturn);
    }

    override bool dismissPopupForPointer(Point globalPoint, MouseButton button)
    {
        return true;
    }
}

class FileDialogPanel : VBox
{
    private FileDialogOptions _options;
    private HBox _header;
    private Label _titleLabel;
    private TextField _pathField;
    private TextField _nameField;
    private ListView _shortcuts;
    private ListView _files;
    private Label _status;
    private FileDialogEntry[] _entries;
    private string[] _shortcutPaths;
    private string _currentDirectory;
    private string _selectedPath;
    private bool _allowPanelDrag;
    private bool _draggingDialog;
    private Point _lastDragPosition;

    void delegate(string path) onAccepted;
    void delegate() onCanceled;
    bool delegate() onWindowMoveRequested;

    this(FileDialogOptions options)
    {
        super(8, Insets(12));
        _options = options;
        layoutHints().preferredWidth = options.preferredSize.width;
        layoutHints().preferredHeight = options.preferredSize.height;
        layoutHints().minWidth = 520;
        layoutHints().minHeight = 380;

        _header = add(new HBox(8));
        _header.layoutHints().preferredHeight = 40;
        _titleLabel = _header.add(new Label(dialogTitle()));
        _titleLabel.setScale(2);
        _titleLabel.layoutHints().flex = 1.0;
        auto closeButton = _header.add(new IconButton(IconKind.close));
        closeButton.onClick = delegate() { cancel(); };

        auto navigation = add(new HBox(6));
        navigation.layoutHints().preferredHeight = 40;
        auto upButton = navigation.add(new Button("Up", IconKind.up));
        upButton.onClick = delegate() { goUp(); };
        auto homeButton = navigation.add(new Button("Home", IconKind.home));
        homeButton.onClick = delegate() { goHome(); };
        auto refreshButton = navigation.add(new Button("Refresh", IconKind.refresh));
        refreshButton.onClick = delegate() { refresh(); };
        _pathField = navigation.add(new TextField());
        _pathField.layoutHints().flex = 1.0;
        _pathField.onSubmitted = delegate() { submitPath(); };

        auto shortcutsPanel = new VBox(5, Insets(6));
        auto placesLabel = shortcutsPanel.add(new Label("Places"));
        placesLabel.setScale(1);
        placesLabel.layoutHints().preferredHeight = 26;
        _shortcuts = shortcutsPanel.add(new ListView());
        _shortcuts.setShowBorder(false);
        // A place is opened by a single click, not a double click: picking a
        // location should feel like a button, not a file act.
        _shortcuts.setActivateOnSingleClick(true);
        _shortcuts.onActivated = delegate(int index)
        {
            if (index >= 0 && index < cast(int) _shortcutPaths.length)
                navigate(_shortcutPaths[cast(size_t) index]);
        };

        auto filesPanel = new VBox(6);
        _files = filesPanel.add(new ListView());
        _files.setRowHeight(44);
        _files.onSelectionChanged = delegate(int index) { updateSelection(index); };
        _files.onActivated = delegate(int index) { activateEntry(index); };

        auto split = add(new SplitPane(shortcutsPanel, filesPanel,
            Orientation.horizontal));
        split.setRatio(0.24, false);
        split.layoutHints().flex = 1.0;

        auto footer = add(new HBox(8));
        footer.layoutHints().preferredHeight = 40;
        auto nameLabel = footer.add(new Label("File"));
        nameLabel.setScale(1);
        nameLabel.setAlignment(HorizontalAlign.left, VerticalAlign.middle);
        nameLabel.layoutHints().preferredWidth = 48;
        _nameField = footer.add(new TextField(defaultFileName()));
        _nameField.layoutHints().flex = 1.0;
        _nameField.onSubmitted = delegate() { accept(); };
        auto cancelButton = footer.add(new Button("Cancel"));
        cancelButton.onClick = delegate() { cancel(); };
        auto acceptButton = footer.add(new Button(acceptLabel(), acceptIcon()));
        acceptButton.setAccent(true);
        acceptButton.onClick = delegate() { accept(); };

        if (_options.selectFolders)
        {
            // Folder mode has nothing to type: the highlighted row is the
            // choice, so the file-name field would only mislead.
            nameLabel.setVisible(false);
            _nameField.setVisible(false);
        }

        _status = add(new Label("Ready"));
        _status.setScale(1);
        _status.layoutHints().preferredHeight = 24;

        rebuildShortcuts();
        // The default place is Desktop, so highlight it as the current place.
        if (_shortcutPaths.length > 0) _shortcuts.setSelectedIndex(0, false);
        initializeLocation();
    }

    void setPanelDragging(bool value)
    {
        if (_allowPanelDrag == value) return;
        _allowPanelDrag = value;
    }

    void focusDefault()
    {
        if (_options.selectFolders)
        {
            _files.requestFocus();
            return;
        }
        if (_options.mode == FileDialogMode.save)
        {
            _nameField.requestFocus();
            _nameField.selectAll();
        }
        else
            _files.requestFocus();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        canvas.drawRoundedRect(Rect(0, 0, bounds().width, bounds().height),
            maxInt(6, palette.cornerRadius), palette.panelElevated,
            palette.border, 1);
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.escape)
        {
            cancel();
            return true;
        }
        if (event.alt() && event.key == Key.up)
        {
            goUp();
            return true;
        }
        if (event.key == Key.f5)
        {
            refresh();
            return true;
        }
        if (event.control() || event.meta())
        {
            if (event.key == Key.l)
            {
                _pathField.requestFocus();
                _pathField.selectAll();
            }
            return true;
        }
        return false;
    }

    override bool onMouseDown(ref Event event)
    {
        if (!_allowPanelDrag || event.button != MouseButton.left ||
            _header is null ||
            !topDragRegionContains(event.position))
            return false;
        auto overlay = cast(FileDialogOverlay) parent();
        if (overlay is null)
            return onWindowMoveRequested !is null && onWindowMoveRequested();
        _draggingDialog = true;
        _lastDragPosition = event.globalPosition;
        captureMouse();
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (!_draggingDialog) return false;
        const dx = event.globalPosition.x - _lastDragPosition.x;
        const dy = event.globalPosition.y - _lastDragPosition.y;
        _lastDragPosition = event.globalPosition;
        auto overlay = cast(FileDialogOverlay) parent();
        if (overlay !is null)
            overlay.movePanelBy(dx, dy);
        return true;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left || !_draggingDialog) return false;
        _draggingDialog = false;
        releaseMouse();
        return true;
    }

    protected override void onFocusChanged(bool focused)
    {
        if (!focused && _draggingDialog)
        {
            _draggingDialog = false;
            releaseMouse();
        }
    }

    private bool topDragRegionContains(Point point) const
    {
        if (_header is null || point.x < 0 || point.x >= bounds().width)
            return false;
        return point.y >= 0 && point.y < _header.bounds().bottom();
    }

    private string dialogTitle() const
    {
        if (_options.title.length > 0) return _options.title;
        if (_options.selectFolders) return "Select Folder";
        return _options.mode == FileDialogMode.open ? "Open File" : "Save File";
    }

    private string acceptLabel() const
    {
        if (_options.acceptLabel.length > 0) return _options.acceptLabel;
        if (_options.selectFolders) return "Select Folder";
        return _options.mode == FileDialogMode.open ? "Open" : "Save";
    }

    private IconKind acceptIcon() const
    {
        if (_options.selectFolders) return IconKind.folder;
        return _options.mode == FileDialogMode.open ? IconKind.open :
            IconKind.save;
    }

    private string defaultFileName() const
    {
        if (_options.defaultFileName.length > 0) return _options.defaultFileName;
        if (_options.mode == FileDialogMode.save) return "Untitled.txt";
        return "";
    }

    private void initializeLocation()
    {
        string initial = _options.initialPath;
        if (initial.length == 0)
            initial = _options.defaultFileName.length > 0 ?
                _options.defaultFileName : desktopDirectory();

        const resolved = resolveAgainst(getcwd(), initial);
        string directory = getcwd();
        string filename = _nameField.textUtf8();

        if (directoryExists(resolved))
            directory = resolved;
        else
        {
            const parent = dirName(resolved);
            if (parent.length > 0 && directoryExists(parent))
                directory = parent;
            const name = baseName(resolved);
            if (name.length > 0)
                filename = name;
        }

        if (filename.length > 0)
            _nameField.setText(filename, false);
        navigate(directory);
    }

    private void rebuildShortcuts()
    {
        const desktop = desktopDirectory();
        const documents = documentsDirectory();
        const downloads = downloadsDirectory();
        const thisPc = thisPcPath();
        _shortcutPaths = [desktop, documents, downloads, thisPc];

        ListItem[] items;
        items ~= ListItem("Desktop", IconKind.folder, desktop);
        items ~= ListItem("Documents", IconKind.notepad, documents);
        items ~= ListItem("Downloads", IconKind.folder, downloads);
        items ~= ListItem("This PC", IconKind.computer, thisPc);
        _shortcuts.setItems(items);
    }

    private void navigate(string candidate)
    {
        const path = resolvePath(candidate);
        try
        {
            if (!directoryExists(path))
            {
                _status.setText("Not a directory: " ~ path);
                return;
            }

            FileDialogEntry[] entries;
            foreach (DirEntry item; dirEntries(path, SpanMode.shallow))
            {
                FileDialogEntry entry;
                entry.path = item.name;
                entry.name = baseName(item.name);
                if (entry.name.length == 0) entry.name = item.name;
                try
                {
                    entry.directory = item.isDir;
                    if (!entry.directory) entry.size = item.size;
                }
                catch (Exception)
                {
                    continue;
                }
                entries ~= entry;
            }
            sort!entryLess(entries);
            _entries = entries;
            _currentDirectory = path;
            _selectedPath = "";
            _pathField.setText(path, false);
            if (_options.mode == FileDialogMode.open)
                _nameField.setText("", false);
            rebuildFileList();
            _status.setText(format("%d items", _entries.length));
        }
        catch (Exception error)
        {
            _status.setText("Cannot open directory: " ~ error.msg);
        }
    }

    private void rebuildFileList()
    {
        ListItem[] items;
        items.reserve(_entries.length);
        foreach (entry; _entries)
        {
            const icon = entry.directory ? IconKind.folder : iconForFile(entry.name);
            const secondary = entry.directory ? "Folder" : humanSize(entry.size);
            items ~= ListItem(entry.name, icon, secondary);
        }
        _files.setItems(items);
        _files.setSelectedIndex(-1, false);
    }

    private void updateSelection(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length)
        {
            _selectedPath = "";
            return;
        }

        const entry = _entries[cast(size_t) index];
        _selectedPath = entry.path;
        if (entry.directory)
            _status.setText("Folder: " ~ entry.path);
        else
        {
            _nameField.setText(entry.name, false);
            _status.setText(humanSize(entry.size) ~ " - " ~ entry.path);
        }
    }

    private void activateEntry(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length) return;
        const entry = _entries[cast(size_t) index];
        if (entry.directory)
        {
            navigate(entry.path);
            return;
        }
        _nameField.setText(entry.name, false);
        accept();
    }

    private void submitPath()
    {
        const path = resolvePath(_pathField.textUtf8());
        if (directoryExists(path))
        {
            navigate(path);
            return;
        }
        if (fileExists(path))
        {
            const parent = dirName(path);
            const name = baseName(path);
            if (_options.mode == FileDialogMode.open)
            {
                if (onAccepted !is null) onAccepted(path);
                return;
            }
            if (parent.length > 0 && directoryExists(parent))
                navigate(parent);
            if (name.length > 0) _nameField.setText(name, false);
            return;
        }
        _status.setText("Path not found: " ~ path);
    }

    private void accept()
    {
        if (_options.selectFolders)
        {
            // A highlighted folder wins; otherwise the folder we are inside is
            // the choice, which makes "navigate then confirm" work naturally.
            string folder = _selectedPath;
            if (folder.length == 0 || !directoryExists(folder))
                folder = _currentDirectory;
            if (folder.length == 0 || !directoryExists(folder))
            {
                _status.setText("Choose a folder.");
                return;
            }
            if (onAccepted !is null) onAccepted(folder);
            return;
        }
        string candidate = _nameField.textUtf8();
        string path = candidate.length > 0 ? resolvePath(candidate) : _selectedPath;
        if (path.length == 0)
        {
            _status.setText("Choose a file.");
            return;
        }
        path = resolvePath(path);
        if (directoryExists(path))
        {
            navigate(path);
            return;
        }
        if (_options.mode == FileDialogMode.open && !fileExists(path))
        {
            _status.setText("File does not exist: " ~ path);
            return;
        }
        if (_options.mode == FileDialogMode.save)
        {
            const parent = dirName(path);
            if (parent.length == 0 || !directoryExists(parent))
            {
                _status.setText("Folder does not exist: " ~ parent);
                return;
            }
        }
        if (onAccepted !is null) onAccepted(path);
    }

    private void cancel()
    {
        if (onCanceled !is null) onCanceled();
    }

    private void refresh()
    {
        navigate(_currentDirectory);
    }

    private void goHome()
    {
        navigate(environment.get("HOME", environment.get("USERPROFILE", getcwd())));
    }

    private void goUp()
    {
        const parent = dirName(_currentDirectory);
        if (parent.length > 0 && parent != _currentDirectory)
            navigate(parent);
    }

    private string resolvePath(string candidate) const
    {
        if (candidate.length == 0) return _currentDirectory;
        return resolveAgainst(_currentDirectory.length > 0 ? _currentDirectory :
            getcwd(), candidate);
    }

    private static string resolveAgainst(string directory, string candidate)
    {
        if (candidate.length == 0) return directory;
        if (isAbsolute(candidate)) return buildNormalizedPath(candidate);
        return buildNormalizedPath(directory, candidate);
    }

    private static bool directoryExists(string path)
    {
        try return exists(path) && isDir(path);
        catch (Exception) return false;
    }

    private static bool fileExists(string path)
    {
        try return exists(path) && !isDir(path);
        catch (Exception) return false;
    }

    private static string userHome()
    {
        return environment.get("USERPROFILE", environment.get("HOME", getcwd()));
    }

    // A child of `parent` that exists, or "" when it does not. Used so a
    // missing Downloads/Desktop folder degrades to the user profile rather than
    // navigating somewhere invalid.
    private static string existingChild(string parent, string name)
    {
        if (parent.length == 0) return "";
        const candidate = buildPath(parent, name);
        return directoryExists(candidate) ? candidate : "";
    }

    private static string desktopDirectory()
    {
        version (Windows)
        {
            const resolved = knownFolderPath(CSIDL_DESKTOPDIRECTORY);
            if (resolved.length > 0) return resolved;
        }
        const fallback = existingChild(userHome(), "Desktop");
        return fallback.length > 0 ? fallback : userHome();
    }

    private static string documentsDirectory()
    {
        version (Windows)
        {
            const resolved = knownFolderPath(CSIDL_PERSONAL);
            if (resolved.length > 0) return resolved;
        }
        const fallback = existingChild(userHome(), "Documents");
        return fallback.length > 0 ? fallback : userHome();
    }

    private static string downloadsDirectory()
    {
        const resolved = existingChild(userHome(), "Downloads");
        return resolved.length > 0 ? resolved : userHome();
    }

    private static string thisPcPath()
    {
        const root = rootName(getcwd());
        return root.length > 0 ? root : "/";
    }

    version (Windows)
    private static string knownFolderPath(int csidl)
    {
        wchar[MAX_PATH] buffer;
        if (SHGetFolderPathW(null, csidl, null, 0, buffer.ptr) != 0) return "";
        size_t length = 0;
        while (length < MAX_PATH && buffer[length] != 0) ++length;
        return toUTF8(buffer[0 .. length]);
    }

    private static bool entryLess(FileDialogEntry a, FileDialogEntry b)
    {
        if (a.directory != b.directory) return a.directory;
        return icmp(a.name, b.name) < 0;
    }

    private static string humanSize(ulong bytes)
    {
        if (bytes < 1024) return format("%d B", bytes);
        if (bytes < 1024UL * 1024UL)
            return format("%.1f KiB", cast(double) bytes / 1024.0);
        if (bytes < 1024UL * 1024UL * 1024UL)
            return format("%.1f MiB", cast(double) bytes / (1024.0 * 1024.0));
        return format("%.1f GiB", cast(double) bytes /
            (1024.0 * 1024.0 * 1024.0));
    }

    private static IconKind iconForFile(string name)
    {
        const ext = extension(name);
        if (icmp(ext, ".txt") == 0 || icmp(ext, ".md") == 0 ||
            icmp(ext, ".d") == 0)
            return IconKind.notepad;
        if (icmp(ext, ".png") == 0 || icmp(ext, ".jpg") == 0 ||
            icmp(ext, ".jpeg") == 0 || icmp(ext, ".gif") == 0 ||
            icmp(ext, ".bmp") == 0)
            return IconKind.image;
        if (icmp(ext, ".mp3") == 0 || icmp(ext, ".wav") == 0 ||
            icmp(ext, ".flac") == 0)
            return IconKind.music;
        return IconKind.file;
    }
}

FileDialogOverlay showFileDialog(Widget owner, FileDialogOptions options,
    void delegate(string path) onAccepted, void delegate() onCanceled = null)
{
    auto root = popupRoot(owner);
    if (root is null) return null;
    dismissTransientPopups(root);

    auto panel = new FileDialogPanel(options);
    panel.setPanelDragging(true);
    FileDialogOverlay popup;
    bool completed;
    panel.onAccepted = delegate(string path)
    {
        completed = true;
        if (popup !is null) popup.dismiss();
        if (onAccepted !is null) onAccepted(path);
    };
    panel.onCanceled = delegate()
    {
        completed = true;
        if (popup !is null) popup.dismiss();
        if (onCanceled !is null) onCanceled();
    };

    popup = new FileDialogOverlay(panel, owner);
    popup.onDismissed = delegate()
    {
        if (!completed && onCanceled !is null) onCanceled();
    };
    popup.setBackdrop(Color.rgba(0, 0, 0, 92));
    popup.setRequestedSize(options.preferredSize.empty() ? Size(760, 540) :
        options.preferredSize);
    root.add(popup);
    popup.setBounds(Rect(0, 0, root.bounds().width, root.bounds().height));
    root.bringChildToFront(popup);
    popup.setAnchor(Rect(0, 0, 1, 1), PopupPlacement.centered);
    popup.layoutTree();
    panel.focusDefault();
    return popup;
}

bool runFileDialogWindow(FileDialogOptions options, out string path)
{
    return runFileDialogWindow(null, options, path, Theme.light());
}

bool runFileDialogWindow(FileDialogOptions options, out string path, Theme theme)
{
    return runFileDialogWindow(null, options, path, theme);
}

bool runFileDialogWindow(GuiWindow owner, FileDialogOptions options, out string path)
{
    return runFileDialogWindow(owner, options, path, Theme.light());
}

bool runFileDialogWindow(GuiWindow owner, FileDialogOptions options, out string path,
    Theme theme)
{
    path = "";
    const size = options.preferredSize.empty() ? Size(760, 540) :
        options.preferredSize;

    WindowOptions windowOptions;
    windowOptions.title = dialogWindowTitle(options);
    windowOptions.width = maxInt(520, size.width);
    windowOptions.height = maxInt(380, size.height);
    windowOptions.decorated = false;
    windowOptions.enableFullscreenShortcut = false;
    centerDialogOverOwner(owner, windowOptions);

    auto window = new GuiWindow(windowOptions, theme);
    auto panel = new FileDialogPanel(options);
    panel.setPanelDragging(true);
    panel.onWindowMoveRequested = delegate()
    {
        return window.beginSystemMove();
    };
    bool accepted;
    panel.onAccepted = delegate(string selected)
    {
        path = selected;
        accepted = true;
        window.close();
    };
    panel.onCanceled = delegate()
    {
        window.close();
    };

    window.setRoot(panel);
    window.run();
    return accepted;
}

private void centerDialogOverOwner(GuiWindow owner, ref WindowOptions options)
{
    if (owner is null) return;
    Rect bounds;
    if (!owner.windowBounds(bounds) || bounds.empty()) return;
    options.x = bounds.x + (bounds.width - options.width) / 2;
    options.y = bounds.y + (bounds.height - options.height) / 2;
}

private string dialogWindowTitle(FileDialogOptions options)
{
    if (options.title.length > 0) return options.title;
    return options.mode == FileDialogMode.open ? "Open File" : "Save File";
}
