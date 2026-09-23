module auroraspace.scout;

import aurora;
import aurora.canvas : Canvas;
import aurora.event : Event, MouseButton;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.algorithm.sorting : sort;
import std.algorithm : filter;
import std.algorithm.comparison : max, min;
import std.algorithm.searching : startsWith;
import std.array : array;
import std.datetime : Clock, SysTime, dur;
import std.file : SpanMode, dirEntries, getcwd, isDir;
import std.format : format;
import std.path : baseName, rootName;
import std.string : strip;
import std.utf : toUTF16, toUTF16z, toUTF32;

version (Windows)
{
    import core.sys.windows.windows : GetFileAttributesW,
        INVALID_FILE_ATTRIBUTES;
    import core.sys.windows.shellapi : FO_DELETE, FOF_ALLOWUNDO,
        SHFILEOPSTRUCTW, SHFileOperationW, ShellExecuteW;
}

enum ItemKind { file, folder }

struct ScoutItem
{
    string path;
    string name;
    ulong bytes;
    SysTime modified;
    ItemKind kind;
}

struct ScanSnapshot
{
    ScoutItem[] files;
    ScoutItem[] folders;
    ulong totalBytes;
    ulong fileCount;
    ulong errors;
    ulong visitedFolders;
    string currentPath;
    bool complete;
}

private class ScanJob
{
    Mutex mutex;
    ScanSnapshot snapshot;
    this() { mutex = new Mutex; }
}

private final class FolderCheckList : Widget
{
    private ScoutItem[] _items;
    private bool[] _checked;
    private int _rowHeight = 58;
    private int _scrollOffset;
    private int _hovered = -1;
    private int _selected = -1;

    void delegate(int index) onSelectionChanged;
    void delegate() onChecksChanged;

    this()
    {
        layoutHints().minWidth = 200;
        layoutHints().minHeight = 100;
        layoutHints().flex = 1.0;
        setFocusable(true);
    }

    void setItems(ScoutItem[] items)
    {
        _items = items.dup;
        _checked.length = _items.length;
        _selected = _items.length == 0 ? -1 : 0;
        clampScroll();
        invalidate();
    }

    const(ScoutItem)[] items() const { return _items; }
    int selectedIndex() const { return _selected; }
    bool checked(size_t index) const { return index < _checked.length && _checked[index]; }
    size_t checkedCount() const
    {
        size_t count;
        foreach (value; _checked) if (value) ++count;
        return count;
    }

    void setAllChecked(bool value)
    {
        foreach (i; 0 .. _checked.length) _checked[i] = value;
        invalidate();
        if (onChecksChanged !is null) onChecksChanged();
    }

    void setChecked(size_t index, bool value)
    {
        if (index >= _checked.length || _checked[index] == value) return;
        _checked[index] = value;
        invalidate();
        if (onChecksChanged !is null) onChecksChanged();
    }

    void removePath(string path)
    {
        size_t writeIndex;
        foreach (i, item; _items)
        {
            if (item.path == path) continue;
            _items[writeIndex] = item;
            _checked[writeIndex] = _checked[i];
            ++writeIndex;
        }
        _items.length = writeIndex;
        _checked.length = writeIndex;
        _selected = _items.length == 0 ? -1 : cast(int) min(
            cast(size_t) max(0, _selected), _items.length - 1);
        clampScroll();
        invalidate();
        if (onChecksChanged !is null) onChecksChanged();
    }

    private int rowAt(Point point) const
    {
        const index = (point.y + _scrollOffset) / _rowHeight;
        return index >= 0 && index < cast(int) _items.length ? index : -1;
    }

    private void clampScroll()
    {
        _scrollOffset = clampInt(_scrollOffset, 0,
            maxInt(0, cast(int) _items.length * _rowHeight - bounds().height));
    }

    protected override void onBoundsChanged() { clampScroll(); }

    protected override void onPaint(ref Canvas canvas)
    {
        const palette = theme();
        canvas.fillRect(Rect(0, 0, bounds().width, bounds().height),
            palette.fieldBackground);
        const first = _scrollOffset / _rowHeight;
        const last = min(cast(int) _items.length,
            first + bounds().height / _rowHeight + 2);
        for (int i = first; i < last; ++i)
        {
            const y = i * _rowHeight - _scrollOffset;
            const row = Rect(0, y, bounds().width, _rowHeight);
            if (i == _selected) canvas.fillRect(row, palette.selection);
            else if (i == _hovered) canvas.fillRect(row, palette.buttonHover);
            const box = Rect(12, y + (_rowHeight - 18) / 2, 18, 18);
            canvas.drawRoundedRect(box, 3,
                _checked[i] ? palette.accent : palette.fieldBackground,
                _checked[i] ? palette.accent : palette.border, 1);
            if (_checked[i])
            {
                canvas.drawLine(Point(box.x + 4, box.y + 9),
                    Point(box.x + 8, box.y + 13), Color.rgb(255, 255, 255), 2);
                canvas.drawLine(Point(box.x + 8, box.y + 13),
                    Point(box.x + 15, box.y + 5), Color.rgb(255, 255, 255), 2);
            }
            const text = _items[i].name ~ "   ·   " ~ formatSize(_items[i].bytes) ~
                "   ·   " ~ dateText(_items[i].modified);
            canvas.drawTextInRect(Rect(42, y, maxInt(0, bounds().width - 52),
                _rowHeight), toUTF32(text),
                i == _selected ? palette.selectionText : palette.text,
                1, HorizontalAlign.left, VerticalAlign.middle, true);
            canvas.drawLine(Point(8, y + _rowHeight - 1),
                Point(bounds().width - 8, y + _rowHeight - 1), palette.border);
        }
        if (_items.length == 0)
            canvas.drawTextInRect(Rect(16, 0, maxInt(0, bounds().width - 32),
                bounds().height), "No large folders found for these filters"d,
                palette.textMuted, 1, HorizontalAlign.center, VerticalAlign.middle);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        const index = rowAt(event.position);
        if (index < 0) return false;
        _selected = index;
        if (event.position.x < 38) _checked[index] = !_checked[index];
        invalidate();
        if (onSelectionChanged !is null) onSelectionChanged(index);
        if (onChecksChanged !is null && event.position.x < 38) onChecksChanged();
        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        const next = rowAt(event.position);
        if (_hovered != next)
        {
            _hovered = next;
            invalidate();
        }
        return false;
    }

    override bool onMouseWheel(ref Event event)
    {
        _scrollOffset = clampInt(_scrollOffset - (event.wheelY / 120) * _rowHeight,
            0, maxInt(0, cast(int) _items.length * _rowHeight - bounds().height));
        invalidate();
        return true;
    }
}

private ulong thresholdBytes(int index)
{
    if (index == 0) return 1024UL * 1024 * 1024;
    if (index == 1) return 100UL * 1024 * 1024;
    return 500UL * 1024 * 1024;
}

private string formatSize(ulong bytes)
{
    if (bytes >= 1024UL * 1024 * 1024)
        return format("%.1f GB", bytes / cast(double)(1024UL * 1024 * 1024));
    if (bytes >= 1024UL * 1024)
        return format("%.1f MB", bytes / cast(double)(1024UL * 1024));
    if (bytes >= 1024UL)
        return format("%.0f KB", bytes / cast(double)1024);
    return format("%d B", bytes);
}

private string dateText(SysTime time)
{
    return format("%04d-%02d-%02d", time.year, time.month, time.day);
}

private string pathTimeText(SysTime time)
{
    return format("%04d-%02d-%02d %02d:%02d", time.year, time.month,
        time.day, time.hour, time.minute);
}

private void performScan(ScanJob job, string root, SysTime newerThan,
    ulong minimumBytes)
{
    ScanSnapshot result;
    struct Frame { string path; size_t parent; ulong bytes; SysTime modified; }
    Frame[] frames;
    frames ~= Frame(root, size_t.max, 0, SysTime.min);
    size_t cursor;
    while (cursor < frames.length)
    {
        const frameIndex = cursor++;
        auto frame = frames[frameIndex];
        synchronized (job.mutex)
        {
            result.visitedFolders = cursor;
            result.currentPath = frame.path;
            job.snapshot.visitedFolders = result.visitedFolders;
            job.snapshot.fileCount = result.fileCount;
            job.snapshot.totalBytes = result.totalBytes;
            job.snapshot.errors = result.errors;
            job.snapshot.currentPath = result.currentPath;
        }
        try
        {
            foreach (entry; dirEntries(frame.path, SpanMode.shallow))
            {
                try
                {
                    const path = entry.name;
                    if (entry.isDir)
                    {
                        version (Windows)
                        {
                            const attrs = GetFileAttributesW(toUTF16z(path));
                            // Reparse points can lead outside the chosen root or loop.
                            if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & 0x400) != 0)
                                continue;
                        }
                        frames ~= Frame(path, frameIndex, 0,
                            entry.timeLastModified);
                    }
                    else
                    {
                        const modified = entry.timeLastModified;
                        const bytes = entry.size;
                        result.totalBytes += bytes;
                        ++result.fileCount;
                        frame.bytes += bytes;
                        if (bytes >= minimumBytes && modified >= newerThan)
                        {
                            result.files ~= ScoutItem(path, baseName(path),
                                bytes, modified, ItemKind.file);
                            synchronized (job.mutex)
                                job.snapshot.files ~= result.files[$ - 1];
                        }
                    }
                }
                catch (Exception) { ++result.errors; }
            }
        }
        catch (Exception) { ++result.errors; }
        frames[frameIndex].bytes = frame.bytes;
        synchronized (job.mutex)
        {
            job.snapshot.fileCount = result.fileCount;
            job.snapshot.totalBytes = result.totalBytes;
            job.snapshot.errors = result.errors;
        }
    }
    // Children appear after their parent in the work queue, so accumulate
    // their total sizes from leaves toward the root before creating results.
    foreach_reverse (i; 0 .. frames.length)
        if (frames[i].parent != size_t.max)
            frames[frames[i].parent].bytes += frames[i].bytes;
    foreach (i, frame; frames)
    {
        if (frame.path == root || frame.bytes < minimumBytes) continue;
        bool nestedInLargeFolder;
        for (auto parentIndex = frame.parent; parentIndex != size_t.max;
            parentIndex = frames[parentIndex].parent)
        {
            if (frames[parentIndex].bytes >= minimumBytes)
            {
                nestedInLargeFolder = true;
                break;
            }
        }
        if (nestedInLargeFolder) continue;
        if (frame.modified >= newerThan)
            result.folders ~= ScoutItem(frame.path, baseName(frame.path),
                frame.bytes, frame.modified, ItemKind.folder);
    }
    result.files.sort!((a, b) => a.bytes > b.bytes);
    result.folders.sort!((a, b) => a.bytes > b.bytes);
    result.complete = true;
    synchronized (job.mutex) job.snapshot = result;
}

private string userProfilePath()
{
    version (Windows)
    {
        import core.sys.windows.windows : MAX_PATH;
        import core.sys.windows.shlobj : CSIDL_PROFILE, SHGetFolderPathW;
        import std.utf : toUTF8;
        wchar[MAX_PATH] buffer;
        if (SHGetFolderPathW(null, CSIDL_PROFILE, null, 0, buffer.ptr) == 0)
        {
            size_t length;
            while (length < buffer.length && buffer[length] != 0) ++length;
            return toUTF8(buffer[0 .. length]);
        }
    }
    return getcwd();
}

private bool recyclePath(string path, out bool aborted)
{
    aborted = false;
    version (Windows)
    {
        wchar[] from = toUTF16(path).dup;
        from ~= 0;
        from ~= 0;
        SHFILEOPSTRUCTW operation;
        operation.wFunc = FO_DELETE;
        operation.pFrom = from.ptr;
        operation.fFlags = FOF_ALLOWUNDO | 0x0010;
        const result = SHFileOperationW(&operation);
        aborted = operation.fAnyOperationsAborted != 0;
        return result == 0 && !aborted;
    }
    else return false;
}

public final class SpaceScoutRoot : VBox
{
    private GuiWindow _window;
    private TextField _rootField;
    private ListView _fileList;
    private ListView _folderList;
    private Label _status;
    private Label _summary;
    private Label _detail;
    private Label _listTitle;
    private CheckBox _filesTab;
    private CheckBox _foldersTab;
    private Button _deleteButton;
    private Button _scanButton;
    private Button _recentButton;
    private Button _thresholdButton;
    private Button _selectAllButton;
    private int _selectedTab;
    private int _thresholdIndex = 1;
    private int _days = 90;
    private string _scanRoot;
    private ScoutItem[] _shownItems;
    private FolderCheckList _folderChecks;
    private ScanJob _job;
    private Thread _worker;
    private bool _workerRunning;
    private double _pollSeconds = 0.0;

    this(GuiWindow window)
    {
        super(10, Insets(18));
        _window = window;
        _job = new ScanJob;
        buildUi();
        startScan();
    }

    private void buildUi()
    {
        auto heading = add(new HBox(12));
        auto title = heading.add(new Label("Aurora Space Scout"));
        title.setScale(3);
        title.layoutHints().flex = 1.0;
        _summary = heading.add(new Label("Find recent installs taking up space"));
        _summary.setScale(1);

        auto controls = add(new HBox(8));
        controls.layoutHints().preferredHeight = 40;
        _rootField = controls.add(new TextField());
        _rootField.layoutHints().flex = 1.0;
        _rootField.setText(userProfilePath());
        auto browse = controls.add(new Button("Choose folder", IconKind.folder));
        browse.onClick = delegate() { chooseRoot(); };
        _scanButton = controls.add(new Button("Scan", IconKind.refresh));
        _scanButton.onClick = delegate() { startScan(); };

        auto filters = add(new HBox(12));
        filters.layoutHints().preferredHeight = 38;
        _recentButton = filters.add(new Button("Recent: 90 days"));
        _recentButton.setEnabled(false);
        _recentButton.onClick = delegate()
        {
            _days = _days == 90 ? 30 : _days == 30 ? 7 : 90;
            _recentButton.setText(format("Recent: %d days", _days));
            startScan();
        };
        _thresholdButton = filters.add(new Button("Minimum: 100 MB"));
        _thresholdButton.setEnabled(false);
        _thresholdButton.onClick = delegate()
        {
            _thresholdIndex = (_thresholdIndex + 1) % 3;
            const label = _thresholdIndex == 0 ? "1 GB" :
                _thresholdIndex == 1 ? "100 MB" : "500 MB";
            _thresholdButton.setText("Minimum: " ~ label);
            startScan();
        };
        filters.add(new Spacer());
        _filesTab = filters.add(new CheckBox("Large files", true));
        _foldersTab = filters.add(new CheckBox("Large folders", false));
        _filesTab.setEnabled(false);
        _foldersTab.setEnabled(false);
        _filesTab.onChanged = delegate(bool value) { if (value) selectTab(0); };
        _foldersTab.onChanged = delegate(bool value) { if (value) selectTab(1); };

        auto content = add(new HBox(12));
        content.layoutHints().flex = 1.0;
        auto results = new VBox(8);
        results.layoutHints().flex = 1.0;
        auto caption = results.add(new HBox(10));
        _listTitle = caption.add(new Label("Large files"));
        _listTitle.setScale(2);
        _listTitle.layoutHints().flex = 1.0;
        caption.add(new Label("Sorted by size"));
        _fileList = new ListView();
        _fileList.setRowHeight(58);
        _fileList.onSelectionChanged = delegate(int index) { selectItem(index); };
        _fileList.onActivated = delegate(int index) { openSelected(); };
        _fileList.onContextMenuRequested = delegate(int index, Point globalPosition)
        {
            if (index < 0 || index >= cast(int) _shownItems.length) return;
            _fileList.setSelectedIndex(index, false);
            selectItem(index);
            showContextMenu(_fileList, globalPosition, [
                ContextMenuItem.command("Open containing folder", IconKind.folder,
                    delegate() { openContainingFolder(index); })
            ]);
        };
        _folderChecks = new FolderCheckList();
        _folderChecks.setVisible(false);
        _folderChecks.onSelectionChanged = delegate(int index) { selectFolderItem(index); };
        _folderChecks.onChecksChanged = delegate() { updateDeleteLabel(); };
        _selectAllButton = new Button("Select all");
        _selectAllButton.setVisible(false);
        _selectAllButton.onClick = delegate()
        {
            const allChecked = _folderChecks.checkedCount() ==
                _folderChecks.items.length;
            _folderChecks.setAllChecked(!allChecked);
            _selectAllButton.setText(allChecked ? "Select all" : "Clear selection");
        };
        caption.add(_selectAllButton);
        results.add(_fileList);
        results.add(_folderChecks);
        content.add(results);

        auto side = new VBox(12, Insets(16));
        side.layoutHints().preferredWidth = 310;
        side.layoutHints().minWidth = 280;
        side.layoutHints().flex = 0.0;
        side.setBorder(theme().border, 1);
        auto sideTitle = side.add(new Label("Selection details"));
        sideTitle.setScale(2);
        _detail = side.add(new Label("Select a result to review its full path and size."));
        _detail.setScale(1);
        _detail.setEllipsis(false);
        _deleteButton = side.add(new Button("Move selected to Recycle Bin", IconKind.trash));
        _deleteButton.setDanger(true);
        _deleteButton.setEnabled(false);
        _deleteButton.onClick = delegate() { deleteSelected(); };
        auto hint = side.add(new Label("Items are never removed automatically. Selected items go to the Windows Recycle Bin so you can restore them."));
        hint.setScale(1);
        hint.setEllipsis(false);
        content.add(side);

        _status = add(new Label("Ready to scan"));
        _status.setScale(1);
    }

    private void selectTab(int index)
    {
        _selectedTab = index;
        _filesTab.setChecked(index == 0, false);
        _foldersTab.setChecked(index == 1, false);
        _fileList.setVisible(index == 0);
        _folderChecks.setVisible(index == 1);
        _selectAllButton.setVisible(index == 1);
        _listTitle.setText(index == 0 ? "Large files" : "Large folders");
        _detail.setText("Select a result to review its full path and size.");
        _deleteButton.setEnabled(false);
        refreshLists();
    }

    private void chooseRoot()
    {
        FileDialogOptions options;
        options.mode = FileDialogMode.open;
        options.title = "Choose a folder to scan";
        options.initialPath = _rootField.textUtf8();
        string path;
        if (runFileDialogWindow(_window, options, path) && isDir(path))
        {
            _rootField.setText(path);
            startScan();
        }
    }

    private void startScan()
    {
        if (_workerRunning)
        {
            _status.setText("A scan is already running");
            return;
        }
        auto root = strip(_rootField.textUtf8());
        if (root.length == 0 || !isDir(root))
        {
            _status.setText("Choose a folder that exists before scanning.");
            return;
        }
        _workerRunning = true;
        _scanRoot = root;
        _scanButton.setEnabled(false);
        _recentButton.setEnabled(false);
        _thresholdButton.setEnabled(false);
        _filesTab.setEnabled(false);
        _foldersTab.setEnabled(false);
        _status.setText("Scanning " ~ root ~ " … large folders may take a while");
        _fileList.clear();
        _folderChecks.setItems(null);
        _shownItems = null;
        _deleteButton.setEnabled(false);
        synchronized (_job.mutex) _job.snapshot = ScanSnapshot.init;
        const cutoff = Clock.currTime() - dur!"days"(_days);
        const minimum = thresholdBytes(_thresholdIndex);
        _worker = new Thread(delegate() { performScan(_job, root, cutoff, minimum); });
        _worker.start();
    }

    private void refreshLists()
    {
        ScanSnapshot snapshot;
        synchronized (_job.mutex) snapshot = _job.snapshot;
        foreach (item; snapshot.folders)
            if (item.kind != ItemKind.folder)
                assert(false, "Folder result has the wrong kind");
        foreach (item; snapshot.files)
            if (item.kind != ItemKind.file)
                assert(false, "File result has the wrong kind");
        auto items = _selectedTab == 0 ? snapshot.files : snapshot.folders;
        string[] rows;
        foreach (item; items)
            rows ~= format("%s   ·   %s   ·   %s", item.name,
                formatSize(item.bytes), dateText(item.modified));
        if (_selectedTab == 0)
        {
            _fileList.setStrings(rows);
            _shownItems = items.dup;
        }
        else
        {
            _folderChecks.setItems(items.dup);
            _shownItems = items.dup;
            updateDeleteLabel();
        }
        _summary.setText(format("%s files · %s scanned · %d folders",
            snapshot.fileCount, formatSize(snapshot.totalBytes), snapshot.folders.length));
    }

    private void selectItem(int index)
    {
        if (index < 0 || index >= cast(int) _shownItems.length) return;
        const item = _shownItems[index];
        _detail.setText(format("%s\n\n%s\n\n%s\nModified %s\n\n%s",
            item.kind == ItemKind.file ? "Large file" : "Large folder",
            item.name, formatSize(item.bytes), pathTimeText(item.modified), item.path));
        _deleteButton.setEnabled(true);
    }

    private void selectFolderItem(int index)
    {
        if (index < 0 || index >= cast(int) _shownItems.length) return;
        const item = _shownItems[index];
        _detail.setText(format("Large folder\n\n%s\n\n%s\nModified %s\n\n%s",
            item.name, formatSize(item.bytes), pathTimeText(item.modified), item.path));
        _deleteButton.setEnabled(_folderChecks.checkedCount() > 0);
    }

    private void updateDeleteLabel()
    {
        const count = _folderChecks.checkedCount();
        _deleteButton.setText(count == 0 ? "Move selected to Recycle Bin" :
            format("Move %d selected to Recycle Bin", count));
        _deleteButton.setEnabled(count > 0);
        _selectAllButton.setText(count == _folderChecks.items.length && count > 0 ?
            "Clear selection" : "Select all");
    }

    private void openSelected()
    {
        const index = _selectedTab == 0 ? _fileList.selectedIndex() :
            _folderChecks.selectedIndex();
        if (index < 0 || index >= cast(int) _shownItems.length) return;
        version (Windows)
            ShellExecuteW(null, toUTF16z("open"), toUTF16z(_shownItems[index].path),
                null, null, 1);
    }

    private void openContainingFolder(int index)
    {
        if (index < 0 || index >= cast(int) _shownItems.length ||
            _shownItems[index].kind != ItemKind.file) return;
        version (Windows)
        {
            import std.path : dirName;
            const path = _shownItems[index].path;
            ShellExecuteW(null, toUTF16z("open"), toUTF16z("explorer.exe"),
                toUTF16z("/select,\"" ~ path ~ "\""),
                toUTF16z(dirName(path)), 1);
        }
    }

    private void deleteSelected()
    {
        if (_selectedTab == 1)
        {
            deleteCheckedFolders();
            return;
        }
        const index = _fileList.selectedIndex();
        if (index < 0 || index >= cast(int) _shownItems.length) return;
        const item = _shownItems[index];
        if (item.path == _scanRoot || item.path == rootName(item.path))
        {
            _status.setText("Refusing to move the scan root or a drive root.");
            return;
        }
        const message = format("Move this %s to the Recycle Bin?\n\n%s\n%s",
            item.kind == ItemKind.file ? "file" : "folder", item.path,
            formatSize(item.bytes));
        version (Windows)
        {
            import core.sys.windows.windows : MB_ICONWARNING, MB_YESNO, IDYES,
                MessageBoxW;
            if (MessageBoxW(null, toUTF16z(message),
                toUTF16z("Confirm Recycle Bin move"), MB_YESNO | MB_ICONWARNING) != IDYES)
                return;
        }
        bool aborted;
        if (recyclePath(item.path, aborted))
        {
            removeDeletedResults([item]);
            _status.setText("Moved to the Recycle Bin. Current results updated without rescanning.");
        }
        else
            _status.setText(aborted ? "Recycle Bin move was canceled." :
                "Could not move the item. It may be in use or access is denied.");
    }

    private void deleteCheckedFolders()
    {
        const checkedCount = _folderChecks.checkedCount();
        if (checkedCount == 0) return;
        string[] paths;
        ulong totalBytes;
        foreach (i, item; _folderChecks.items)
        {
            if (!_folderChecks.checked(i)) continue;
            if (item.path == _scanRoot || item.path == rootName(item.path))
            {
                _status.setText("Refusing to move the scan root or a drive root.");
                return;
            }
            paths ~= item.path;
            totalBytes += item.bytes;
        }
        const message = format("Move %d selected folders to the Recycle Bin?\n\nTotal size: %s\n\nFolders will be moved with Windows undo support.",
            paths.length, formatSize(totalBytes));
        version (Windows)
        {
            import core.sys.windows.windows : MB_ICONWARNING, MB_YESNO, IDYES,
                MessageBoxW;
            if (MessageBoxW(null, toUTF16z(message),
                toUTF16z("Confirm Recycle Bin move"), MB_YESNO | MB_ICONWARNING) != IDYES)
                return;
        }
        ScoutItem[] movedItems;
        foreach (path; paths)
        {
            bool aborted;
            if (recyclePath(path, aborted))
            {
                foreach (candidate; _folderChecks.items)
                    if (candidate.path == path)
                    {
                        movedItems ~= candidate;
                        break;
                    }
            }
            else if (aborted) break;
        }
        _status.setText(format("Moved %d of %d selected folders to the Recycle Bin.",
            movedItems.length, paths.length));
        if (movedItems.length > 0)
        {
            removeDeletedResults(movedItems);
            _status.setText(format("Moved %d folders to the Recycle Bin. Current results updated without rescanning.",
                movedItems.length));
        }
    }

    private void removeDeletedResults(ScoutItem[] removedItems)
    {
        synchronized (_job.mutex)
        {
            foreach (removed; removedItems)
            {
                const folderPrefix = removed.path ~ "\\";
                _job.snapshot.files = _job.snapshot.files.filter!(item =>
                    item.path != removed.path && (removed.kind != ItemKind.folder ||
                        !item.path.startsWith(folderPrefix))).array;
                _job.snapshot.folders = _job.snapshot.folders.filter!(item =>
                    item.path != removed.path && (removed.kind != ItemKind.folder ||
                        !item.path.startsWith(folderPrefix))).array;
            }
        }
        refreshLists();
        _detail.setText("Select a result to review its full path and size.");
        _deleteButton.setEnabled(false);
    }

    override void onTick(double deltaSeconds)
    {
        if (deltaSeconds != deltaSeconds || deltaSeconds < 0) deltaSeconds = 0;
        _pollSeconds += deltaSeconds;
        if (_pollSeconds < 0.25) return;
        _pollSeconds = 0;
        if (_workerRunning)
        {
            ScanSnapshot snapshot;
            synchronized (_job.mutex)
            {
                snapshot = _job.snapshot;
                snapshot.files = _job.snapshot.files.dup;
                snapshot.folders = _job.snapshot.folders.dup;
            }
            if (snapshot.complete)
            {
                _worker.join();
                _workerRunning = false;
                _scanButton.setEnabled(true);
                _recentButton.setEnabled(true);
                _thresholdButton.setEnabled(true);
                _filesTab.setEnabled(true);
                _foldersTab.setEnabled(true);
                refreshLists();
                _status.setText(format("Scan complete · %d files · %d results · %d access skips",
                    snapshot.fileCount, snapshot.files.length + snapshot.folders.length,
                    snapshot.errors));
            }
            else
            {
                _summary.setText(format("%d files · %s scanned · %d folders visited",
                    snapshot.fileCount, formatSize(snapshot.totalBytes),
                    snapshot.visitedFolders));
                _status.setText("Scanning: " ~ snapshot.currentPath ~ format(
                    "  ·  %d access skips", snapshot.errors));
                if (_selectedTab == 0)
                {
                    string[] rows;
                    foreach (item; snapshot.files)
                        rows ~= format("%s   ·   %s   ·   %s", item.name,
                            formatSize(item.bytes), dateText(item.modified));
                    _fileList.setStrings(rows);
                    _shownItems = snapshot.files.dup;
                }
                invalidate();
            }
        }
    }
}

private WindowOptions windowOptions()
{
    WindowOptions options;
    options.title = "Aurora Space Scout";
    options.width = 1220;
    options.height = 790;
    options.resizable = true;
    options.decorated = false;
    options.darkTitleBar = true;
    options.lowLatency = true;
    options.vsync = true;
    options.synchronizedDragPointer = false;
    return options;
}

int run(string[] args)
{
    auto window = new GuiWindow(windowOptions(), Theme.dark());
    window.setRoot(new SpaceScoutRoot(window));
    return window.run();
}
