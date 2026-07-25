module demos.file_explorer;

import aurora;
import std.algorithm.sorting : sort;
import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, isDir;
import std.format : format;
import std.path : baseName, buildNormalizedPath, dirName, extension, isAbsolute, rootName;
import std.process : environment;
import std.string : icmp;

private struct EntryInfo
{
    string name;
    string path;
    bool directory;
    ulong size;
}

final class ExplorerRoot : VBox
{
    private GuiWindow _window;
    private TextField _pathField;
    private ListView _shortcuts;
    private ListView _files;
    private Label _details;
    private Label _status;
    private EntryInfo[] _entries;
    private string[] _shortcutPaths;
    private string _currentPath;
    private bool _dark;

    this(GuiWindow window, string initialPath = "")
    {
        super(7, Insets(8));
        _window = window;
        _currentPath = initialPath.length > 0 ? initialPath : getcwd();

        auto toolbar = add(new HBox(6));
        toolbar.layoutHints().preferredHeight = 42;
        auto upButton = toolbar.add(new Button("Up", IconKind.up));
        upButton.onClick = delegate() { goUp(); };
        auto homeButton = toolbar.add(new Button("Home", IconKind.home));
        homeButton.onClick = delegate() { goHome(); };
        auto refreshButton = toolbar.add(new Button("Refresh", IconKind.refresh));
        refreshButton.onClick = delegate() { refresh(); };

        _pathField = toolbar.add(new TextField(_currentPath));
        _pathField.layoutHints().flex = 1.0;
        _pathField.layoutHints().preferredWidth = 400;
        _pathField.onSubmitted = delegate() { navigate(_pathField.textUtf8()); };

        auto themeButton = toolbar.add(new Button("Theme", IconKind.settings));
        themeButton.onClick = delegate()
        {
            _dark = !_dark;
            _window.setTheme(_dark ? Theme.dark() : Theme.light());
        };

        auto shortcutsPanel = new VBox(5, Insets(5));
        shortcutsPanel.setBackground(Color.rgba(255, 255, 255, 18));
        shortcutsPanel.setBorder(Color.rgba(255, 255, 255, 35), 5);
        auto placesLabel = shortcutsPanel.add(new Label("Places"));
        placesLabel.layoutHints().preferredHeight = 30;
        _shortcuts = shortcutsPanel.add(new ListView());
        _shortcuts.setShowBorder(false);
        _shortcuts.onActivated = delegate(int index)
        {
            if (index >= 0 && index < cast(int) _shortcutPaths.length)
                navigate(_shortcutPaths[cast(size_t) index]);
        };

        auto filesPanel = new VBox(5);
        _files = filesPanel.add(new ListView());
        _files.setRowHeight(46);
        _files.onSelectionChanged = delegate(int index) { updateDetails(index); };
        _files.onActivated = delegate(int index) { activateEntry(index); };
        _details = filesPanel.add(new Label("Select an item to see details."));
        _details.layoutHints().preferredHeight = 30;
        _details.setScale(1);

        auto split = add(new SplitPane(shortcutsPanel, filesPanel, Orientation.horizontal));
        split.setRatio(0.22, false);
        split.layoutHints().flex = 1.0;

        _status = add(new Label("Ready"));
        _status.layoutHints().preferredHeight = 28;
        _status.setScale(1);

        rebuildShortcuts();
        navigate(_currentPath);
    }

    private void rebuildShortcuts()
    {
        const current = getcwd();
        const home = environment.get("HOME", environment.get("USERPROFILE", current));
        auto root = rootName(current);
        if (root.length == 0) root = "/";
        _shortcutPaths = [home, current, root];
        ListItem[] items;
        items ~= ListItem("Home", IconKind.home, home);
        items ~= ListItem("Working directory", IconKind.folder, current);
        items ~= ListItem("Filesystem", IconKind.drive, root);
        _shortcuts.setItems(items);
    }

    private string resolvePath(string candidate) const
    {
        if (candidate.length == 0) return _currentPath;
        if (isAbsolute(candidate)) return buildNormalizedPath(candidate);
        return buildNormalizedPath(_currentPath, candidate);
    }

    private void navigate(string candidate)
    {
        const path = resolvePath(candidate);
        try
        {
            if (!exists(path) || !isDir(path))
            {
                _status.setText("Not a directory: " ~ path);
                return;
            }

            EntryInfo[] entries;
            foreach (DirEntry item; dirEntries(path, SpanMode.shallow))
            {
                EntryInfo info;
                info.path = item.name;
                info.name = baseName(item.name);
                if (info.name.length == 0) info.name = item.name;
                try
                {
                    info.directory = item.isDir;
                    if (!info.directory) info.size = item.size;
                }
                catch (Exception)
                {
                    continue;
                }
                entries ~= info;
            }
            sort!entryLess(entries);
            _entries = entries;
            _currentPath = path;
            _pathField.setText(path, false);
            rebuildFileList();
            _window.setTitle(baseName(path) ~ " — Aurora File Explorer");
            _status.setText(format("%d items in %s", _entries.length, path));
        }
        catch (Exception error)
        {
            _status.setText("Cannot open directory: " ~ error.msg);
        }
    }

    private static bool entryLess(EntryInfo a, EntryInfo b)
    {
        if (a.directory != b.directory) return a.directory;
        return a.name < b.name;
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
        _details.setText("Select an item to see details.");
    }

    private void activateEntry(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length) return;
        const entry = _entries[cast(size_t) index];
        if (entry.directory)
            navigate(entry.path);
        else
            _status.setText("Selected file: " ~ entry.path);
    }

    private void updateDetails(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length)
        {
            _details.setText("Select an item to see details.");
            return;
        }
        const entry = _entries[cast(size_t) index];
        _details.setText(entry.directory
            ? "Folder  •  " ~ entry.path
            : humanSize(entry.size) ~ "  •  " ~ entry.path);
    }

    private void refresh()
    {
        navigate(_currentPath);
    }

    private void goHome()
    {
        navigate(environment.get("HOME", environment.get("USERPROFILE", getcwd())));
    }

    private void goUp()
    {
        const parent = dirName(_currentPath);
        if (parent.length > 0 && parent != _currentPath)
            navigate(parent);
    }

    private static string humanSize(ulong bytes)
    {
        if (bytes < 1024) return format("%d B", bytes);
        if (bytes < 1024UL * 1024UL) return format("%.1f KiB", cast(double) bytes / 1024.0);
        if (bytes < 1024UL * 1024UL * 1024UL)
            return format("%.1f MiB", cast(double) bytes / (1024.0 * 1024.0));
        return format("%.1f GiB", cast(double) bytes / (1024.0 * 1024.0 * 1024.0));
    }

    private static IconKind iconForFile(string name)
    {
        const ext = extension(name);
        if (icmp(ext, ".txt") == 0 || icmp(ext, ".md") == 0 || icmp(ext, ".d") == 0)
            return IconKind.notepad;
        if (icmp(ext, ".png") == 0 || icmp(ext, ".jpg") == 0 || icmp(ext, ".jpeg") == 0 ||
            icmp(ext, ".gif") == 0 || icmp(ext, ".bmp") == 0)
            return IconKind.image;
        if (icmp(ext, ".mp3") == 0 || icmp(ext, ".wav") == 0 || icmp(ext, ".flac") == 0)
            return IconKind.music;
        return IconKind.file;
    }

    override bool onKeyDown(ref Event event)
    {
        if (event.key == Key.f5)
        {
            refresh();
            return true;
        }
        if (event.alt() && event.key == Key.up)
        {
            goUp();
            return true;
        }
        if ((event.control() || event.meta()) && event.key == Key.l)
        {
            _pathField.requestFocus();
            _pathField.selectAll();
            return true;
        }
        return false;
    }
}

int main(string[] args)
{
    WindowOptions options;
    options.title = "Aurora File Explorer";
    options.width = 1080;
    options.height = 700;
    auto window = new GuiWindow(options, Theme.light());
    const initial = args.length > 1 ? args[1] : "";
    window.setRoot(new ExplorerRoot(window, initial));
    return window.run();
}
