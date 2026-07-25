module auroracut.filedialog;

import aurora;
import auroracut.util : ensureExtension, isSupportedMediaPath;
import std.algorithm.sorting : sort;
import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, isDir;
import std.path : baseName, buildNormalizedPath, dirName, extension, isAbsolute;
import std.string : toLower;

private enum FileDialogMode : ubyte
{
    open,
    save
}

private struct DialogEntry
{
    string name;
    string path;
    bool directory;
}

/** Aurora-rendered open/save picker. No platform toolkit is required. */
final class FileDialogController
{
    private Widget _owner;
    private PopupOverlay _popup;
    private TextField _pathField;
    private TextField _nameField;
    private ListView _files;
    private Label _error;
    private Label _title;
    private DialogEntry[] _entries;
    private string _currentPath;
    private string _requiredExtension;
    private string _openExtension;
    private string _dialogTitle;
    private string _acceptLabel;
    private FileDialogMode _mode;
    private void delegate(string path) _accepted;

    this(Widget owner)
    {
        _owner = owner;
    }

    void showOpen(void delegate(string path) accepted)
    {
        show(FileDialogMode.open, "", "", accepted, "", "Import media", "Import");
    }

    void showOpenProject(void delegate(string path) accepted)
    {
        show(FileDialogMode.open, "", "", accepted, ".auroracut",
            "Open Aurora Cut project", "Open");
    }

    void showSave(string requiredExtension, string suggestedName,
        void delegate(string path) accepted)
    {
        const project = requiredExtension.toLower() == ".auroracut";
        show(FileDialogMode.save, requiredExtension, suggestedName, accepted, "",
            project ? "Save Aurora Cut project" : "Export file",
            project ? "Save" : "Export");
    }

    bool visible()
    {
        return _popup !is null && _popup.parent() !is null;
    }

    void dismiss()
    {
        if (_popup !is null) _popup.dismiss();
    }

    private void show(FileDialogMode mode, string requiredExtension,
        string suggestedName, void delegate(string path) accepted,
        string openExtension, string dialogTitle, string acceptLabel)
    {
        dismiss();
        _mode = mode;
        _requiredExtension = requiredExtension;
        _openExtension = openExtension;
        _dialogTitle = dialogTitle;
        _acceptLabel = acceptLabel;
        _accepted = accepted;
        _currentPath = getcwd();

        auto content = new VBox(8, Insets(14));
        content.setBackground(Color.fromHex(0x242a32));
        content.setBorder(Color.fromHex(0x4a5562), 8);

        auto header = content.add(new HBox(8));
        header.layoutHints().preferredHeight = 38;
        _title = header.add(new Label(_dialogTitle));
        _title.setScale(2);
        _title.layoutHints().flex = 1.0;
        auto closeButton = header.add(new IconButton(IconKind.close));
        closeButton.setFlat(true);
        closeButton.onClick = delegate() { dismiss(); };

        auto pathRow = content.add(new HBox(7));
        pathRow.layoutHints().preferredHeight = 40;
        auto upButton = pathRow.add(new Button("Up", IconKind.up));
        upButton.onClick = delegate() { navigate(dirName(_currentPath)); };
        _pathField = pathRow.add(new TextField(_currentPath));
        _pathField.layoutHints().flex = 1.0;
        _pathField.onSubmitted = delegate() { navigate(_pathField.textUtf8()); };
        auto refreshButton = pathRow.add(new IconButton(IconKind.refresh));
        refreshButton.onClick = delegate() { navigate(_currentPath); };

        _files = content.add(new ListView());
        _files.setRowHeight(48);
        _files.layoutHints().flex = 1.0;
        _files.onSelectionChanged = delegate(int index) { selectEntry(index); };
        _files.onActivated = delegate(int index) { activateEntry(index); };

        auto nameRow = content.add(new HBox(8));
        nameRow.layoutHints().preferredHeight = 40;
        auto nameLabel = nameRow.add(new Label(mode == FileDialogMode.open ? "File" : "Name"));
        nameLabel.layoutHints().preferredWidth = 64;
        nameLabel.setScale(1);
        _nameField = nameRow.add(new TextField(suggestedName));
        _nameField.layoutHints().flex = 1.0;
        _nameField.onSubmitted = delegate() { acceptCurrent(); };

        _error = content.add(new Label(""));
        _error.setScale(1);
        _error.setColor(Color.fromHex(0xff8b8b));
        _error.layoutHints().preferredHeight = 24;

        auto footer = content.add(new HBox(8));
        footer.layoutHints().preferredHeight = 42;
        footer.add(new Spacer());
        auto cancelButton = footer.add(new Button("Cancel"));
        cancelButton.onClick = delegate() { dismiss(); };
        auto acceptButton = footer.add(new Button(_acceptLabel,
            mode == FileDialogMode.open ? IconKind.open : IconKind.save));
        acceptButton.setAccent(true);
        acceptButton.onClick = delegate() { acceptCurrent(); };

        _popup = new PopupOverlay(content, _owner);
        _popup.setRequestedSize(Size(780, 590));
        _popup.setAnchor(Rect.init, PopupPlacement.centered);
        _popup.setBackdrop(Color.rgba(0, 0, 0, 150));
        _popup.onDismissed = delegate() { _popup = null; };
        auto root = popupRoot(_owner);
        if (root is null) throw new Exception("The file dialog has no root widget.");
        root.add(_popup);
        navigate(_currentPath);
        _popup.focusFirst();
    }

    private string resolve(string candidate) const
    {
        if (candidate.length == 0) return _currentPath;
        if (isAbsolute(candidate)) return buildNormalizedPath(candidate);
        return buildNormalizedPath(_currentPath, candidate);
    }

    private void navigate(string candidate)
    {
        const path = resolve(candidate);
        try
        {
            if (!exists(path) || !isDir(path))
            {
                showError("Not a directory: " ~ path);
                return;
            }

            DialogEntry[] entries;
            const parent = dirName(path);
            if (parent.length > 0 && parent != path)
            {
                DialogEntry up;
                up.name = "..";
                up.path = parent;
                up.directory = true;
                entries ~= up;
            }

            foreach (DirEntry item; dirEntries(path, SpanMode.shallow))
            {
                DialogEntry entry;
                entry.path = item.name;
                entry.name = baseName(item.name);
                if (entry.name.length == 0) entry.name = item.name;
                try entry.directory = item.isDir;
                catch (Exception) continue;

                if (!entry.directory)
                {
                    if (_mode == FileDialogMode.open)
                    {
                        if (_openExtension.length > 0)
                        {
                            if (extension(entry.path).toLower() != _openExtension.toLower())
                                continue;
                        }
                        else if (!isSupportedMediaPath(entry.path)) continue;
                    }
                    if (_mode == FileDialogMode.save)
                    {
                        const ext = extension(entry.path).toLower();
                        const wanted = _requiredExtension.toLower();
                        if (wanted.length > 0 && ext != wanted) continue;
                    }
                }
                entries ~= entry;
            }
            if (entries.length > 1)
                sort!entryLess(entries[1 .. $]);

            _entries = entries;
            _currentPath = path;
            _pathField.setText(path, false);
            rebuildList();
            showError("");
        }
        catch (Exception error)
        {
            showError("Cannot open directory: " ~ error.msg);
        }
    }

    private static bool entryLess(DialogEntry left, DialogEntry right)
    {
        if (left.directory != right.directory) return left.directory;
        return left.name.toLower() < right.name.toLower();
    }

    private void rebuildList()
    {
        ListItem[] items;
        foreach (entry; _entries)
        {
            const icon = entry.directory ? IconKind.folder :
                (_openExtension.length > 0 ? IconKind.file :
                    (isSupportedMediaPath(entry.path) ?
                        (extension(entry.path).toLower() == ".mp3" ? IconKind.music : IconKind.image) :
                        IconKind.file));
            items ~= ListItem(entry.name, icon, entry.directory ? "Folder" : entry.path);
        }
        _files.setItems(items);
        _files.setSelectedIndex(-1, false);
    }

    private void selectEntry(int index)
    {
        if (index < 0 || index >= cast(int) _entries.length) return;
        const entry = _entries[cast(size_t) index];
        if (!entry.directory) _nameField.setText(entry.name, false);
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
        acceptCurrent();
    }

    private void acceptCurrent()
    {
        string name = _nameField.textUtf8();
        if (name.length == 0)
        {
            showError(_mode == FileDialogMode.open ? "Select an MP4 or MP3 file." : "Enter an output name.");
            return;
        }
        if (_mode == FileDialogMode.save)
            name = ensureExtension(name, _requiredExtension);
        const path = buildNormalizedPath(_currentPath, name);

        if (_mode == FileDialogMode.open)
        {
            const extensionMatches = _openExtension.length == 0 ?
                isSupportedMediaPath(path) :
                extension(path).toLower() == _openExtension.toLower();
            if (!exists(path) || isDir(path) || !extensionMatches)
            {
                showError(_openExtension.length > 0 ?
                    "Select an existing Aurora Cut project file." :
                    "Select an existing MP4 or MP3 file.");
                return;
            }
        }
        else if (!exists(_currentPath) || !isDir(_currentPath))
        {
            showError("The destination folder does not exist.");
            return;
        }

        auto callback = _accepted;
        dismiss();
        if (callback !is null) callback(path);
    }

    private void showError(string message)
    {
        if (_error !is null) _error.setText(message);
    }
}
