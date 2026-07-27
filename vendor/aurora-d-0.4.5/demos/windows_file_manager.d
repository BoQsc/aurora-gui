module demos.windows_file_manager;

import aurora;
import std.algorithm.sorting : sort;
import std.file : DirEntry, SpanMode, copy, dirEntries, exists, getcwd, isDir,
    mkdir, removeFile = remove, renameFile = rename, rmdirRecurse, thisExePath,
    writeFile = write;
import std.format : format;
import std.path : baseName, buildNormalizedPath, dirName, extension, isAbsolute,
    rootName;
import std.process : Config, environment, spawnProcess;
import std.string : icmp, toLower;
import std.utf : toUTF16, toUTF16z, toUTF32;

version (Windows)
{
    import core.sys.windows.shellapi : ShellExecuteW;
    import core.sys.windows.windows : CF_UNICODETEXT, CloseClipboard,
        EmptyClipboard, GlobalAlloc, GlobalFree, GlobalLock, GlobalUnlock,
        GMEM_MOVEABLE, OpenClipboard, SetClipboardData;
    import core.sys.windows.winuser : SW_SHOWNORMAL;
}

private enum CommandButton
{
    none = -1,
    back,
    forward,
    up,
    refresh,
    newFolder,
    newTextFile,
    openSelected,
    copyPath
}

private enum SortColumn
{
    name,
    modified,
    type,
    size
}

private enum NavigationKind
{
    folder,
    thisPc,
    network
}

private struct ExplorerEntry
{
    string name;
    string path;
    bool directory;
    ulong size;
    string modified;
    string type;
}

private struct NavigationItem
{
    string label;
    string path;
    IconKind icon;
    NavigationKind kind;
    bool enabled = true;
    bool pinned;
}

final class WindowsFileManagerRoot : Widget
{
    private enum defaultUiZoomPercent = 80;
    private enum minimumUiZoomPercent = 80;
    private enum maximumUiZoomPercent = 125;
    private enum ribbonHeight = 66;
    private enum addressHeight = 40;
    private enum statusHeight = 26;
    private enum sidebarMinimumWidth = 228;
    private enum sidebarMaximumWidth = 330;
    private enum rowHeight = 25;
    private enum sidebarRowHeight = 27;
    private enum headerHeight = 34;
    private enum scrollbarWidth = 12;

    private GuiWindow _window;
    private TextField _addressField;
    private TextField _searchField;
    private ExplorerEntry[] _entries;
    private int[] _visibleEntries;
    private NavigationItem[] _navigation;
    private string _currentPath;
    private string _searchQuery;
    private string _statusText = "Ready";
    private string[] _history;
    private int _historyIndex = -1;
    private int _uiZoomPercent = defaultUiZoomPercent;
    private int _selectedVisibleIndex = -1;
    private SortColumn _sortColumn = SortColumn.name;
    private bool _sortAscending = true;
    private int _scrollY;
    private int _sidebarScrollY;
    private CommandButton _pressedCommand = CommandButton.none;
    private bool _draggingListScrollbar;
    private int _listScrollbarGrabY;
    private int _listScrollbarGrabScrollY;
    private bool _draggingSidebarScrollbar;
    private int _sidebarScrollbarGrabY;
    private int _sidebarScrollbarGrabScrollY;
    private bool _pendingEntryDrag;
    private bool _draggingEntry;
    private int _dragSourceVisibleIndex = -1;
    private int _dropTargetVisibleIndex = -1;
    private int _dropTargetNavigationIndex = -1;
    private Point _dragStart;
    private Point _dragCurrent;

    private Rect _addressRect;
    private Rect _addressTextRect;
    private Rect _searchRect;
    private Rect _searchTextRect;
    private Rect _newFolderRect;
    private Rect _newTextFileRect;
    private Rect _openSelectedRect;
    private Rect _copyPathRect;
    private Rect _sidebarRect;
    private Rect _sidebarRowsRect;
    private Rect _mainRect;
    private Rect _headerRect;
    private Rect _rowsRect;
    private Rect _statusRect;
    private Rect _backRect;
    private Rect _forwardRect;
    private Rect _upRect;
    private Rect _refreshRect;
    private Rect _listScrollbarRect;
    private Rect _listScrollbarThumbRect;
    private Rect _sidebarScrollbarRect;
    private Rect _sidebarScrollbarThumbRect;
    private Rect _nameHeaderRect;
    private Rect _dateHeaderRect;
    private Rect _typeHeaderRect;
    private Rect _sizeHeaderRect;
    private int _usableListWidth;
    private int _dateX;
    private int _typeX;
    private int _sizeX;
    private int _sizeWidth;

    void delegate(string title) onTitleChanged;

    this(GuiWindow window, string initialPath = "")
    {
        _window = window;
        setFocusable(true);
        layoutHints().minWidth = scaled(820);
        layoutHints().minHeight = scaled(500);

        _addressField = add(new TextField());
        _addressField.setTransparentBackground(true);
        _addressField.setShowBorder(false);
        _addressField.setPadding(scaled(4));
        _addressField.setTextColor(explorerText);
        _addressField.onSubmitted = delegate() { submitAddress(); };

        _searchField = add(new TextField());
        _searchField.setTransparentBackground(true);
        _searchField.setShowBorder(false);
        _searchField.setPadding(scaled(5));
        _searchField.setTextColor(explorerText);
        _searchField.onChanged = delegate()
        {
            _searchQuery = _searchField.textUtf8();
            rebuildVisibleEntries();
        };
        _searchField.onSubmitted = delegate()
        {
            requestFocus();
        };

        rebuildNavigation();
        navigate(initialPath.length > 0 ? initialPath : getcwd(), true, true);
    }

    protected override Size onMeasure(Size available)
    {
        return Size(scaled(1180), scaled(720));
    }

    protected override void onLayout()
    {
        updateGeometry();
        layoutTextFields();
    }

    protected override void onPaint(ref Canvas canvas)
    {
        updateGeometry();
        canvas.fillRect(Rect(0, 0, bounds().width, bounds().height), explorerContent);
        drawRibbon(canvas);
        drawAddressBar(canvas);
        drawSidebar(canvas);
        drawDetailsView(canvas);
        drawStatusBar(canvas);
        drawDragPreview(canvas);
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button == MouseButton.right)
        {
            requestFocus();
            showContextMenuFor(event.position);
            return true;
        }
        if (event.button != MouseButton.left) return false;
        requestFocus();

        const command = commandAt(event.position);
        if (command != CommandButton.none && commandEnabled(command))
        {
            _pressedCommand = command;
            captureMouse();
            invalidate();
            return true;
        }

        if (_addressRect.contains(event.position))
        {
            _addressField.requestFocus();
            _addressField.selectAll();
            return true;
        }

        const sortColumn = sortColumnAt(event.position);
        if (sortColumn >= 0)
        {
            setSortColumn(cast(SortColumn) sortColumn);
            return true;
        }

        if (_listScrollbarThumbRect.contains(event.position))
        {
            _draggingListScrollbar = true;
            _listScrollbarGrabY = event.position.y;
            _listScrollbarGrabScrollY = _scrollY;
            captureMouse();
            return true;
        }
        if (_listScrollbarRect.contains(event.position) && maxListScroll() > 0)
        {
            pageListScroll(event.position.y < _listScrollbarThumbRect.y ? -1 : 1);
            return true;
        }
        if (_sidebarScrollbarThumbRect.contains(event.position))
        {
            _draggingSidebarScrollbar = true;
            _sidebarScrollbarGrabY = event.position.y;
            _sidebarScrollbarGrabScrollY = _sidebarScrollY;
            captureMouse();
            return true;
        }
        if (_sidebarScrollbarRect.contains(event.position) && maxSidebarScroll() > 0)
        {
            pageSidebarScroll(event.position.y < _sidebarScrollbarThumbRect.y ? -1 : 1);
            return true;
        }

        const navIndex = navigationIndexAt(event.position);
        if (navIndex >= 0)
        {
            activateNavigation(navIndex);
            return true;
        }

        const visibleIndex = entryIndexAt(event.position);
        if (visibleIndex >= 0)
        {
            _selectedVisibleIndex = visibleIndex;
            updateSelectedStatus();
            if (event.clickCount >= 2)
            {
                activateEntry(visibleIndex);
            }
            else
            {
                beginEntryDrag(visibleIndex, event.position);
            }
            invalidate();
            return true;
        }

        if (_rowsRect.contains(event.position))
        {
            _selectedVisibleIndex = -1;
            updateStatus();
            invalidate();
            return true;
        }

        return true;
    }

    override bool onMouseMove(ref Event event)
    {
        if (_draggingListScrollbar)
        {
            dragListScrollbar(event.position.y);
            return true;
        }
        if (_draggingSidebarScrollbar)
        {
            dragSidebarScrollbar(event.position.y);
            return true;
        }
        if (_pendingEntryDrag || _draggingEntry)
        {
            updateEntryDrag(event.position);
            return true;
        }
        return false;
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        if (_draggingListScrollbar || _draggingSidebarScrollbar)
        {
            _draggingListScrollbar = false;
            _draggingSidebarScrollbar = false;
            releaseMouse();
            invalidate();
            return true;
        }
        if (_pressedCommand != CommandButton.none)
        {
            const pressed = _pressedCommand;
            _pressedCommand = CommandButton.none;
            releaseMouse();
            if (commandAt(event.position) == pressed && commandEnabled(pressed))
                activateCommand(pressed);
            invalidate();
            return true;
        }
        if (_pendingEntryDrag || _draggingEntry)
        {
            const completed = _draggingEntry;
            releaseMouse();
            if (completed)
                completeEntryDrop(event.position);
            else
                invalidate();
            resetEntryDrag(false);
            return true;
        }
        return false;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (event.control() || event.meta())
        {
            if (event.wheelY != 0)
                setUiZoomPercent(_uiZoomPercent + (event.wheelY > 0 ? 10 : -10));
            return true;
        }
        const sideRow = sidebarRowHeightPx();
        const row = rowHeightPx();
        if (_sidebarRect.contains(event.position))
        {
            setSidebarScroll(_sidebarScrollY - event.wheelY * sideRow / 3);
            return true;
        }
        if (_mainRect.contains(event.position))
        {
            setListScroll(_scrollY - event.wheelY * row / 3);
            return true;
        }
        return false;
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
        if (event.alt() && event.key == Key.left)
        {
            goBack();
            return true;
        }
        if (event.alt() && event.key == Key.right)
        {
            goForward();
            return true;
        }
        if (event.key == Key.backspace)
        {
            goUp();
            return true;
        }
        if (event.key == Key.enter && _selectedVisibleIndex >= 0)
        {
            activateEntry(_selectedVisibleIndex);
            return true;
        }
        if (event.key == Key.escape && _searchQuery.length > 0)
        {
            _searchField.setText("", false);
            _searchQuery = "";
            rebuildVisibleEntries();
            return true;
        }
        if (event.control() || event.meta())
        {
            if (event.key == Key.equal)
            {
                setUiZoomPercent(_uiZoomPercent + 10);
                return true;
            }
            if (event.key == Key.minus)
            {
                setUiZoomPercent(_uiZoomPercent - 10);
                return true;
            }
            if (event.key == Key.digit0)
            {
                setUiZoomPercent(defaultUiZoomPercent);
                return true;
            }
            if (event.key == Key.l)
            {
                _addressField.requestFocus();
                _addressField.selectAll();
                return true;
            }
            if (event.key == Key.f)
            {
                _searchField.requestFocus();
                _searchField.selectAll();
                return true;
            }
            if (event.key == Key.n)
            {
                createNewFolder();
                return true;
            }
            if (event.key == Key.c && _selectedVisibleIndex >= 0)
            {
                copySelectedPath();
                return true;
            }
        }
        return false;
    }

    override bool onFilesDropped(ref Event event)
    {
        if (event.paths.length == 0) return false;
        const targetDirectory = dropTargetDirectoryAt(event.position, "", true);
        if (targetDirectory.length > 0)
        {
            moveDroppedPaths(event.paths, targetDirectory);
            return true;
        }

        const path = event.paths[0];
        try
        {
            if (exists(path) && isDir(path))
            {
                navigate(path, true, true);
                return true;
            }
            if (exists(path))
            {
                navigate(dirName(path), true, true);
                selectPath(path);
                return true;
            }
        }
        catch (Exception error)
        {
            _statusText = "Cannot open dropped item: " ~ error.msg;
            invalidate();
            return true;
        }
        return false;
    }

    private void beginEntryDrag(int visibleIndex, Point position)
    {
        _pendingEntryDrag = true;
        _draggingEntry = false;
        _dragSourceVisibleIndex = visibleIndex;
        _dropTargetVisibleIndex = -1;
        _dropTargetNavigationIndex = -1;
        _dragStart = position;
        _dragCurrent = position;
        captureMouse();
    }

    private void updateEntryDrag(Point position)
    {
        _dragCurrent = position;
        if (_pendingEntryDrag && dragThresholdExceeded(position))
        {
            _pendingEntryDrag = false;
            _draggingEntry = true;
        }
        if (_draggingEntry)
            updateDropTargets(position);
        invalidate();
    }

    private void updateDropTargets(Point position)
    {
        _dropTargetVisibleIndex = -1;
        _dropTargetNavigationIndex = -1;
        if (!hasDragSource()) return;

        const sourcePath = dragSourceEntry().path;
        const navIndex = navigationIndexAt(position);
        if (isNavigationDropTarget(navIndex, sourcePath))
        {
            _dropTargetNavigationIndex = navIndex;
            return;
        }

        const visibleIndex = entryIndexAt(position);
        if (isEntryDropTarget(visibleIndex, sourcePath))
            _dropTargetVisibleIndex = visibleIndex;
    }

    private void completeEntryDrop(Point position)
    {
        if (!hasDragSource())
        {
            invalidate();
            return;
        }

        const entry = dragSourceEntry();
        const targetDirectory = dropTargetDirectoryAt(position, entry.path, false);
        if (targetDirectory.length == 0)
        {
            _statusText = "Move canceled.";
            invalidate();
            return;
        }

        const movedPath = movePathIntoDirectory(entry.path, targetDirectory);
        if (movedPath.length > 0)
        {
            navigate(_currentPath, false, false);
            if (pathsEqual(dirName(movedPath), _currentPath))
                selectPath(movedPath);
            _statusText = "Moved " ~ entry.name ~ " to " ~ folderDisplayName(targetDirectory) ~ ".";
        }
        invalidate();
    }

    private void resetEntryDrag(bool redraw)
    {
        _pendingEntryDrag = false;
        _draggingEntry = false;
        _dragSourceVisibleIndex = -1;
        _dropTargetVisibleIndex = -1;
        _dropTargetNavigationIndex = -1;
        if (redraw) invalidate();
    }

    private bool hasDragSource() const
    {
        return _dragSourceVisibleIndex >= 0 &&
            _dragSourceVisibleIndex < cast(int) _visibleEntries.length;
    }

    private ExplorerEntry dragSourceEntry() const
    {
        if (!hasDragSource()) return ExplorerEntry.init;
        return _entries[cast(size_t) _visibleEntries[cast(size_t) _dragSourceVisibleIndex]];
    }

    private bool dragThresholdExceeded(Point position) const
    {
        return absInt(position.x - _dragStart.x) >= 4 ||
            absInt(position.y - _dragStart.y) >= 4;
    }

    private string dropTargetDirectoryAt(Point point, string sourcePath,
        bool allowCurrentFolder) const
    {
        const navIndex = navigationIndexAt(point);
        if (isNavigationDropTarget(navIndex, sourcePath))
            return _navigation[cast(size_t) navIndex].path;

        const visibleIndex = entryIndexAt(point);
        if (isEntryDropTarget(visibleIndex, sourcePath))
        {
            const entry = _entries[cast(size_t) _visibleEntries[cast(size_t) visibleIndex]];
            return entry.path;
        }

        if (allowCurrentFolder && _rowsRect.contains(point) && _currentPath.length > 0 &&
            exists(_currentPath) && isDir(_currentPath))
            return _currentPath;
        return "";
    }

    private bool isNavigationDropTarget(int index, string sourcePath) const
    {
        if (index < 0 || index >= cast(int) _navigation.length) return false;
        const item = _navigation[cast(size_t) index];
        if (!item.enabled) return false;
        if (item.kind != NavigationKind.folder && item.kind != NavigationKind.thisPc)
            return false;
        return isDirectoryDropTarget(item.path, sourcePath);
    }

    private bool isEntryDropTarget(int visibleIndex, string sourcePath) const
    {
        if (visibleIndex < 0 || visibleIndex >= cast(int) _visibleEntries.length) return false;
        const entry = _entries[cast(size_t) _visibleEntries[cast(size_t) visibleIndex]];
        if (!entry.directory) return false;
        return isDirectoryDropTarget(entry.path, sourcePath);
    }

    private bool isDirectoryDropTarget(string targetDirectory, string sourcePath) const
    {
        if (targetDirectory.length == 0 || !exists(targetDirectory) || !isDir(targetDirectory))
            return false;
        if (sourcePath.length == 0) return true;
        if (!exists(sourcePath)) return false;
        if (pathsEqual(targetDirectory, sourcePath)) return false;
        if (pathsEqual(targetDirectory, dirName(sourcePath))) return false;
        if (isDir(sourcePath) && isSameOrDescendantPath(targetDirectory, sourcePath))
            return false;
        return true;
    }

    private void moveDroppedPaths(string[] paths, string targetDirectory)
    {
        int moved;
        string lastMovedPath;
        foreach (path; paths)
        {
            const movedPath = movePathIntoDirectory(path, targetDirectory);
            if (movedPath.length > 0)
            {
                ++moved;
                lastMovedPath = movedPath;
            }
        }

        if (moved > 0)
        {
            navigate(_currentPath, false, false);
            if (moved == 1 && pathsEqual(dirName(lastMovedPath), _currentPath))
                selectPath(lastMovedPath);
            _statusText = moved == 1 ? "Moved " ~ baseName(lastMovedPath) ~ "." :
                format("Moved %d items.", moved);
        }
        else if (_statusText.length == 0)
            _statusText = "No items moved.";
        invalidate();
    }

    private string movePathIntoDirectory(string sourcePath, string targetDirectory)
    {
        try
        {
            const source = buildNormalizedPath(sourcePath);
            const target = buildNormalizedPath(targetDirectory);
            if (!exists(source))
            {
                _statusText = "Cannot move missing item: " ~ source;
                return "";
            }
            if (!exists(target) || !isDir(target))
            {
                _statusText = "Cannot move to unavailable folder: " ~ target;
                return "";
            }
            if (pathsEqual(source, target))
            {
                _statusText = "Cannot move a folder into itself.";
                return "";
            }
            if (pathsEqual(dirName(source), target))
            {
                _statusText = baseName(source) ~ " is already in " ~ folderDisplayName(target) ~ ".";
                return "";
            }
            if (isDir(source) && isSameOrDescendantPath(target, source))
            {
                _statusText = "Cannot move a folder into itself.";
                return "";
            }

            const name = baseName(source);
            if (name.length == 0)
            {
                _statusText = "Cannot move a drive root.";
                return "";
            }

            const destination = uniqueDestinationPath(target, name);
            movePath(source, destination);
            return destination;
        }
        catch (Exception error)
        {
            _statusText = "Cannot move item: " ~ error.msg;
            return "";
        }
    }

    int uiZoomPercent() const @safe pure nothrow @nogc
    {
        return _uiZoomPercent;
    }

    void setUiZoomPercent(int percent)
    {
        const next = clampInt(percent, minimumUiZoomPercent, maximumUiZoomPercent);
        if (next == _uiZoomPercent) return;
        const previousRow = rowHeightPx();
        const previousSidebarRow = sidebarRowHeightPx();
        _uiZoomPercent = next;
        applyZoomMetrics();
        updateGeometry();
        if (previousRow > 0)
            _scrollY = _scrollY * rowHeightPx() / previousRow;
        if (previousSidebarRow > 0)
            _sidebarScrollY = _sidebarScrollY * sidebarRowHeightPx() / previousSidebarRow;
        setListScroll(_scrollY);
        setSidebarScroll(_sidebarScrollY);
        layoutTextFields();
        _statusText = format("Zoom %d%%", _uiZoomPercent);
        invalidate();
    }

    private void applyZoomMetrics()
    {
        layoutHints().minWidth = scaled(820);
        layoutHints().minHeight = scaled(500);
        if (_addressField !is null)
            _addressField.setPadding(scaled(4));
        if (_searchField !is null)
            _searchField.setPadding(scaled(5));
    }

    private void layoutTextFields()
    {
        if (_addressField !is null)
            _addressField.setBounds(_addressTextRect);
        if (_searchField !is null)
            _searchField.setBounds(_searchTextRect);
    }

    private int scaled(int value) const @safe pure nothrow @nogc
    {
        if (value == 0) return 0;
        const sign = value < 0 ? -1 : 1;
        const magnitude = value < 0 ? -value : value;
        return sign * maxInt(1, (magnitude * _uiZoomPercent + 50) / 100);
    }

    private int ribbonHeightPx() const @safe pure nothrow @nogc
    {
        return scaled(ribbonHeight);
    }

    private int addressHeightPx() const @safe pure nothrow @nogc
    {
        return scaled(addressHeight);
    }

    private int statusHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(22, scaled(statusHeight));
    }

    private int rowHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(22, scaled(rowHeight));
    }

    private int sidebarRowHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(23, scaled(sidebarRowHeight));
    }

    private int headerHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(29, scaled(headerHeight));
    }

    private int scrollbarWidthPx() const @safe pure nothrow @nogc
    {
        return maxInt(10, scaled(scrollbarWidth));
    }

    private int textScale() const @safe pure nothrow @nogc
    {
        const pixels = maxInt(10, (UiFontSizeCaption * _uiZoomPercent + 50) / 100);
        return fontScaleForPixelSize(pixels);
    }

    private void updateGeometry()
    {
        const w = bounds().width;
        const h = bounds().height;
        const sidebarWidth = clampInt(w / 4, scaled(sidebarMinimumWidth),
            scaled(sidebarMaximumWidth));
        const ribbon = ribbonHeightPx();
        const address = addressHeightPx();
        const status = statusHeightPx();
        const header = headerHeightPx();
        const contentTop = ribbon + address;
        const contentHeight = maxInt(0, h - contentTop - status);
        _statusRect = Rect(0, maxInt(contentTop, h - status), w, status);
        _sidebarRect = Rect(0, contentTop, sidebarWidth, contentHeight);
        _sidebarRowsRect = _sidebarRect.inset(0, scaled(4), 0, scaled(4));
        _mainRect = Rect(sidebarWidth, contentTop, maxInt(0, w - sidebarWidth), contentHeight);
        _headerRect = Rect(_mainRect.x, _mainRect.y, _mainRect.width, header);
        _rowsRect = Rect(_mainRect.x, _mainRect.y + header, _mainRect.width,
            maxInt(0, _mainRect.height - header));

        _backRect = Rect(scaled(10), ribbon + scaled(6), scaled(26), scaled(28));
        _forwardRect = Rect(scaled(39), ribbon + scaled(6), scaled(26), scaled(28));
        _upRect = Rect(scaled(76), ribbon + scaled(6), scaled(26), scaled(28));
        const searchWidth = clampInt(w / 5, scaled(160), scaled(250));
        _searchRect = Rect(maxInt(0, w - searchWidth - scaled(12)),
            ribbon + scaled(6), searchWidth, scaled(28));
        _refreshRect = Rect(maxInt(scaled(112), _searchRect.x - scaled(32)),
            ribbon + scaled(6), scaled(28), scaled(28));
        _addressRect = Rect(scaled(116), ribbon + scaled(6),
            maxInt(scaled(110), _refreshRect.x - scaled(122)), scaled(28));
        _addressTextRect = Rect(_addressRect.x + scaled(31), _addressRect.y + scaled(2),
            maxInt(0, _addressRect.width - scaled(39)),
            maxInt(0, _addressRect.height - scaled(4)));
        _searchTextRect = Rect(_searchRect.x + scaled(32), _searchRect.y + scaled(2),
            maxInt(0, _searchRect.width - scaled(38)),
            maxInt(0, _searchRect.height - scaled(4)));
        _newFolderRect = Rect(scaled(84), scaled(38), scaled(92), scaled(24));
        _newTextFileRect = Rect(scaled(182), scaled(38), scaled(86), scaled(24));
        _openSelectedRect = Rect(scaled(274), scaled(38), scaled(70), scaled(24));
        _copyPathRect = Rect(scaled(350), scaled(38), scaled(88), scaled(24));

        updateColumnGeometry();
        rebuildScrollbars();
    }

    private void updateColumnGeometry()
    {
        const scrollbar = scrollbarWidthPx();
        _usableListWidth = maxInt(scaled(120), _mainRect.width - scrollbar);
        const nameWidth = clampInt(_usableListWidth - scaled(415), scaled(240),
            maxInt(scaled(240), _usableListWidth - scaled(250)));
        const dateWidth = scaled(165);
        const typeWidth = scaled(150);
        _sizeWidth = scaled(100);
        const nameX = _mainRect.x + scaled(20);
        _dateX = _mainRect.x + nameWidth;
        _typeX = _dateX + dateWidth;
        _sizeX = _typeX + typeWidth;

        _nameHeaderRect = Rect(nameX, _headerRect.y, maxInt(0, _dateX - nameX),
            _headerRect.height);
        _dateHeaderRect = Rect(_dateX + scaled(8), _headerRect.y,
            maxInt(0, _typeX - _dateX - scaled(8)), _headerRect.height);
        _typeHeaderRect = Rect(_typeX + scaled(8), _headerRect.y,
            maxInt(0, _sizeX - _typeX - scaled(8)), _headerRect.height);
        _sizeHeaderRect = Rect(_sizeX + scaled(8), _headerRect.y,
            maxInt(0, _sizeWidth - scaled(8)), _headerRect.height);
    }

    private void rebuildNavigation()
    {
        _navigation.length = 0;
        const current = getcwd();
        const home = environment.get("USERPROFILE", environment.get("HOME", current));
        const documents = buildNormalizedPath(home, "Documents");

        addNavigation("Personal", home, IconKind.folder, true);
        addNavigation("Desktop", buildNormalizedPath(home, "Desktop"), IconKind.computer, true);
        addNavigation("Downloads", buildNormalizedPath(home, "Downloads"), IconKind.open, true);
        addNavigation("Documents", documents, IconKind.notepad, true);
        addNavigation("Pictures", buildNormalizedPath(home, "Pictures"), IconKind.image, true);
        addNavigation("Videos", buildNormalizedPath(home, "Videos"), IconKind.music, true);
        addDocumentFolders(documents, 12);
        addNavigation("OneDrive - Personal", buildNormalizedPath(home, "OneDrive"), IconKind.drive, false);
        addNavigation("This PC", rootPathFor(home), IconKind.computer, false,
            NavigationKind.thisPc, true);
        addNavigation("Network", "", IconKind.drive, false, NavigationKind.network, true);
    }

    private void addNavigation(string label, string path, IconKind icon, bool pinned,
        NavigationKind kind = NavigationKind.folder, bool forceEnabled = false)
    {
        NavigationItem item;
        item.label = label;
        item.path = path;
        item.icon = icon;
        item.kind = kind;
        item.pinned = pinned;
        item.enabled = forceEnabled || (path.length > 0 && exists(path) && isDir(path));
        _navigation ~= item;
    }

    private void addDocumentFolders(string documents, int limit)
    {
        if (!exists(documents) || !isDir(documents)) return;
        NavigationItem[] added;
        try
        {
            foreach (DirEntry item; dirEntries(documents, SpanMode.shallow))
            {
                if (cast(int) added.length >= limit) break;
                try
                {
                    if (!item.isDir) continue;
                    const name = baseName(item.name);
                    if (name.length == 0) continue;
                    NavigationItem nav;
                    nav.label = name;
                    nav.path = item.name;
                    nav.icon = IconKind.folder;
                    nav.kind = NavigationKind.folder;
                    nav.enabled = true;
                    nav.pinned = true;
                    added ~= nav;
                }
                catch (Exception)
                {
                    continue;
                }
            }
        }
        catch (Exception)
        {
            return;
        }
        sort!((a, b) => a.label < b.label)(added);
        foreach (item; added)
            _navigation ~= item;
    }

    private void navigate(string candidate, bool addHistory, bool clearSearch)
    {
        const path = resolvePath(candidate);
        try
        {
            if (!exists(path) || !isDir(path))
            {
                _statusText = "Not a folder: " ~ path;
                invalidate();
                return;
            }

            ExplorerEntry[] entries;
            foreach (DirEntry item; dirEntries(path, SpanMode.shallow))
            {
                ExplorerEntry entry;
                entry.path = item.name;
                entry.name = baseName(item.name);
                if (entry.name.length == 0) entry.name = item.name;
                try
                {
                    entry.directory = item.isDir;
                    if (!entry.directory) entry.size = item.size;
                    entry.modified = modifiedText(item);
                    entry.type = typeText(entry.name, entry.directory);
                }
                catch (Exception)
                {
                    continue;
                }
                entries ~= entry;
            }
            sortEntries(entries);
            _entries = entries;
            _currentPath = path;
            _selectedVisibleIndex = -1;
            _scrollY = 0;

            if (clearSearch)
            {
                _searchQuery = "";
                _searchField.setText("", false);
            }
            _addressField.setText(path, false);
            _searchField.setPlaceholder(searchPlaceholder());

            if (addHistory)
                pushHistory(path);
            rebuildVisibleEntries();
            updateWindowTitle();
        }
        catch (Exception error)
        {
            _statusText = "Cannot open folder: " ~ error.msg;
            invalidate();
        }
    }

    private string resolvePath(string candidate) const
    {
        if (candidate.length == 0) return _currentPath.length > 0 ? _currentPath : getcwd();
        if (isAbsolute(candidate)) return buildNormalizedPath(candidate);
        return buildNormalizedPath(_currentPath.length > 0 ? _currentPath : getcwd(), candidate);
    }

    private void pushHistory(string path)
    {
        if (_historyIndex >= 0 && _historyIndex < cast(int) _history.length &&
            pathsEqual(_history[cast(size_t) _historyIndex], path))
            return;
        if (_historyIndex + 1 < cast(int) _history.length)
            _history = _history[0 .. cast(size_t) (_historyIndex + 1)];
        _history ~= path;
        _historyIndex = cast(int) _history.length - 1;
    }

    private void rebuildVisibleEntries()
    {
        _visibleEntries.length = 0;
        const query = _searchQuery.toLower();
        foreach (index, entry; _entries)
        {
            if (query.length == 0 || containsInsensitive(entry.name, query))
                _visibleEntries ~= cast(int) index;
        }
        if (_selectedVisibleIndex >= cast(int) _visibleEntries.length)
            _selectedVisibleIndex = -1;
        setListScroll(_scrollY);
        updateStatus();
        invalidate();
    }

    private void sortEntries(ref ExplorerEntry[] entries)
    {
        sort!((a, b) => compareEntries(a, b) < 0)(entries);
    }

    private int compareEntries(ExplorerEntry a, ExplorerEntry b) const
    {
        if (a.directory != b.directory) return a.directory ? -1 : 1;

        int result;
        final switch (_sortColumn)
        {
            case SortColumn.name:
                result = icmp(a.name, b.name);
                break;
            case SortColumn.modified:
                result = icmp(a.modified, b.modified);
                break;
            case SortColumn.type:
                result = icmp(a.type, b.type);
                break;
            case SortColumn.size:
                if (a.size < b.size) result = -1;
                else if (a.size > b.size) result = 1;
                else result = 0;
                break;
        }
        if (result == 0) result = icmp(a.name, b.name);
        return _sortAscending ? result : -result;
    }

    private int sortColumnAt(Point point) const
    {
        if (_nameHeaderRect.contains(point)) return cast(int) SortColumn.name;
        if (_dateHeaderRect.contains(point)) return cast(int) SortColumn.modified;
        if (_typeHeaderRect.contains(point)) return cast(int) SortColumn.type;
        if (_sizeHeaderRect.contains(point)) return cast(int) SortColumn.size;
        return -1;
    }

    private void setSortColumn(SortColumn column)
    {
        const selectedPath = hasSelection() ? selectedEntry().path : "";
        if (_sortColumn == column)
            _sortAscending = !_sortAscending;
        else
        {
            _sortColumn = column;
            _sortAscending = true;
        }
        sortEntries(_entries);
        rebuildVisibleEntries();
        if (selectedPath.length > 0)
            selectPath(selectedPath);
    }

    private void activateNavigation(int index)
    {
        if (index < 0 || index >= cast(int) _navigation.length) return;
        const item = _navigation[cast(size_t) index];
        if (item.kind == NavigationKind.network)
        {
            openNetworkLocation();
            return;
        }
        if (!item.enabled)
        {
            _statusText = item.label ~ " is not available.";
            invalidate();
            return;
        }
        navigate(item.path, true, true);
    }

    private bool navigationItemSelected(const NavigationItem item) const
    {
        if (!item.enabled) return false;
        if (item.kind == NavigationKind.network) return false;
        return item.path.length > 0 && pathsEqual(item.path, _currentPath);
    }

    private void activateEntry(int visibleIndex)
    {
        if (visibleIndex < 0 || visibleIndex >= cast(int) _visibleEntries.length) return;
        const entry = _entries[cast(size_t) _visibleEntries[cast(size_t) visibleIndex]];
        if (entry.directory)
            navigate(entry.path, true, true);
        else
            openPath(entry.path);
    }

    private void activateCommand(CommandButton command)
    {
        final switch (command)
        {
            case CommandButton.none:
                break;
            case CommandButton.back:
                goBack();
                break;
            case CommandButton.forward:
                goForward();
                break;
            case CommandButton.up:
                goUp();
                break;
            case CommandButton.refresh:
                refresh();
                break;
            case CommandButton.newFolder:
                createNewFolder();
                break;
            case CommandButton.newTextFile:
                createNewTextFile();
                break;
            case CommandButton.openSelected:
                if (_selectedVisibleIndex >= 0) activateEntry(_selectedVisibleIndex);
                break;
            case CommandButton.copyPath:
                copySelectedPath();
                break;
        }
    }

    private void goBack()
    {
        if (_historyIndex <= 0) return;
        --_historyIndex;
        navigate(_history[cast(size_t) _historyIndex], false, true);
    }

    private void goForward()
    {
        if (_historyIndex + 1 >= cast(int) _history.length) return;
        ++_historyIndex;
        navigate(_history[cast(size_t) _historyIndex], false, true);
    }

    private void goUp()
    {
        const parent = dirName(_currentPath);
        if (parent.length > 0 && !pathsEqual(parent, _currentPath))
            navigate(parent, true, true);
    }

    private void refresh()
    {
        navigate(_currentPath, false, false);
    }

    private void submitAddress()
    {
        const requested = _addressField.textUtf8();
        navigate(requested, true, true);
        _addressField.setText(_currentPath, false);
        requestFocus();
    }

    private bool hasSelection() const
    {
        return _selectedVisibleIndex >= 0 &&
            _selectedVisibleIndex < cast(int) _visibleEntries.length;
    }

    private ExplorerEntry selectedEntry() const
    {
        if (!hasSelection()) return ExplorerEntry.init;
        return _entries[cast(size_t) _visibleEntries[cast(size_t) _selectedVisibleIndex]];
    }

    private void createNewFolder()
    {
        createDirectoryItem(uniqueChildPath("New folder", ""));
    }

    private void createNewTextFile()
    {
        createFileItem(uniqueChildPath("New Text Document", ".txt"));
    }

    private void createDirectoryItem(string path)
    {
        try
        {
            mkdir(path);
            navigate(_currentPath, false, true);
            selectPath(path);
            _statusText = "Created " ~ baseName(path);
            invalidate();
        }
        catch (Exception error)
        {
            _statusText = "Cannot create folder: " ~ error.msg;
            invalidate();
        }
    }

    private void createFileItem(string path)
    {
        try
        {
            writeFile(path, "");
            navigate(_currentPath, false, true);
            selectPath(path);
            _statusText = "Created " ~ baseName(path);
            invalidate();
        }
        catch (Exception error)
        {
            _statusText = "Cannot create file: " ~ error.msg;
            invalidate();
        }
    }

    private string uniqueChildPath(string stem, string suffix) const
    {
        auto candidate = buildNormalizedPath(_currentPath, stem ~ suffix);
        if (!exists(candidate)) return candidate;
        foreach (index; 2 .. 1000)
        {
            candidate = buildNormalizedPath(_currentPath,
                stem ~ " (" ~ format("%d", index) ~ ")" ~ suffix);
            if (!exists(candidate)) return candidate;
        }
        return buildNormalizedPath(_currentPath, stem ~ " " ~ format("%d", _entries.length) ~ suffix);
    }

    private static string uniqueDestinationPath(string targetDirectory, string name)
    {
        auto candidate = buildNormalizedPath(targetDirectory, name);
        if (!exists(candidate)) return candidate;
        foreach (index; 2 .. 1000)
        {
            candidate = buildNormalizedPath(targetDirectory,
                collisionName(name, cast(int) index));
            if (!exists(candidate)) return candidate;
        }
        return buildNormalizedPath(targetDirectory,
            collisionName(name, 1000));
    }

    private static string collisionName(string name, int index)
    {
        const ext = extension(name);
        if (ext.length > 0 && ext.length < name.length)
            return name[0 .. $ - ext.length] ~ " (" ~ format("%d", index) ~ ")" ~ ext;
        return name ~ " (" ~ format("%d", index) ~ ")";
    }

    private static void movePath(string source, string destination)
    {
        try
        {
            renameFile(source, destination);
        }
        catch (Exception)
        {
            copyPathRecursive(source, destination);
            removePathRecursive(source);
        }
    }

    private static void copyPathRecursive(string source, string destination)
    {
        if (isDir(source))
        {
            mkdir(destination);
            foreach (DirEntry item; dirEntries(source, SpanMode.shallow))
                copyPathRecursive(item.name,
                    buildNormalizedPath(destination, baseName(item.name)));
        }
        else
            copy(source, destination);
    }

    private static void removePathRecursive(string path)
    {
        if (isDir(path))
            rmdirRecurse(path);
        else
            removeFile(path);
    }

    private void selectPath(string path)
    {
        foreach (visibleIndex, entryIndex; _visibleEntries)
        {
            if (pathsEqual(_entries[cast(size_t) entryIndex].path, path))
            {
                _selectedVisibleIndex = cast(int) visibleIndex;
                ensureSelectionVisible();
                updateSelectedStatus();
                invalidate();
                return;
            }
        }
    }

    private void ensureSelectionVisible()
    {
        if (!hasSelection()) return;
        const row = rowHeightPx();
        const top = _selectedVisibleIndex * row;
        const bottom = top + row;
        if (top < _scrollY)
            setListScroll(top);
        else if (bottom > _scrollY + _rowsRect.height)
            setListScroll(bottom - _rowsRect.height);
    }

    private void openPath(string path)
    {
        try
        {
            if (openPathWithSystem(path))
                _statusText = "Opened " ~ baseName(path);
            else
                _statusText = "No system opener is available for " ~ baseName(path);
        }
        catch (Exception error)
        {
            _statusText = "Cannot open item: " ~ error.msg;
        }
        invalidate();
    }

    private void openNetworkLocation()
    {
        version (Windows)
        {
            if (openPathWithSystem("shell:NetworkPlacesFolder"))
                _statusText = "Opened Network.";
            else
                _statusText = "Cannot open Network.";
        }
        else
            _statusText = "Network browsing is not available in this build.";
        invalidate();
    }

    private void copySelectedPath()
    {
        if (!hasSelection()) return;
        const entry = selectedEntry();
        if (writeClipboardText(entry.path))
            _statusText = "Copied path for " ~ entry.name;
        else
            _statusText = "Clipboard is not available.";
        invalidate();
    }

    private void copyCurrentPath()
    {
        if (writeClipboardText(_currentPath))
            _statusText = "Copied current folder path.";
        else
            _statusText = "Clipboard is not available.";
        invalidate();
    }

    private void showContextMenuFor(Point localPosition)
    {
        const visibleIndex = entryIndexAt(localPosition);
        if (visibleIndex >= 0)
        {
            _selectedVisibleIndex = visibleIndex;
            updateSelectedStatus();
            invalidate();
        }

        ContextMenuItem[] items;
        if (hasSelection())
        {
            const entry = selectedEntry();
            items ~= ContextMenuItem.command("Open", IconKind.open,
                delegate() { activateEntry(_selectedVisibleIndex); }, "Enter");
            if (!entry.directory)
                items ~= ContextMenuItem.command("Open with system", IconKind.open,
                    delegate() { openPath(entry.path); });
            items ~= ContextMenuItem.command("Copy path", IconKind.file,
                delegate() { copySelectedPath(); }, "Ctrl+C");
            items ~= ContextMenuItem.separatorItem();
        }
        items ~= ContextMenuItem.command("New folder", IconKind.folder,
            delegate() { createNewFolder(); }, "Ctrl+N");
        items ~= ContextMenuItem.command("New text file", IconKind.newDocument,
            delegate() { createNewTextFile(); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Copy current path", IconKind.file,
            delegate() { copyCurrentPath(); });
        items ~= ContextMenuItem.command("Refresh", IconKind.refresh,
            delegate() { refresh(); }, "F5");
        showContextMenu(this, localToGlobal(localPosition), items);
    }

    private void updateStatus()
    {
        if (_searchQuery.length > 0)
            _statusText = format("%d matches in %d items",
                _visibleEntries.length, _entries.length);
        else
            _statusText = format("%d items", _entries.length);
    }

    private void updateSelectedStatus()
    {
        if (_selectedVisibleIndex < 0 ||
            _selectedVisibleIndex >= cast(int) _visibleEntries.length)
        {
            updateStatus();
            return;
        }
        const entry = _entries[cast(size_t) _visibleEntries[cast(size_t) _selectedVisibleIndex]];
        _statusText = entry.directory ? entry.name ~ " folder" :
            entry.name ~ "  " ~ humanSize(entry.size);
    }

    private void updateWindowTitle()
    {
        string title = baseName(_currentPath);
        if (title.length == 0) title = displayRoot(_currentPath);
        if (title.length == 0) title = "File Manager";
        const fullTitle = title ~ " - Aurora Windows File Manager";
        if (_window !is null)
            _window.setTitle(fullTitle);
        if (onTitleChanged !is null)
            onTitleChanged(fullTitle);
    }

    void publishTitle()
    {
        updateWindowTitle();
    }

    private CommandButton commandAt(Point point) const
    {
        if (_backRect.contains(point)) return CommandButton.back;
        if (_forwardRect.contains(point)) return CommandButton.forward;
        if (_upRect.contains(point)) return CommandButton.up;
        if (_refreshRect.contains(point)) return CommandButton.refresh;
        if (_newFolderRect.contains(point)) return CommandButton.newFolder;
        if (_newTextFileRect.contains(point)) return CommandButton.newTextFile;
        if (_openSelectedRect.contains(point)) return CommandButton.openSelected;
        if (_copyPathRect.contains(point)) return CommandButton.copyPath;
        return CommandButton.none;
    }

    private bool commandEnabled(CommandButton command) const
    {
        final switch (command)
        {
            case CommandButton.none:
                return false;
            case CommandButton.back:
                return canGoBack();
            case CommandButton.forward:
                return canGoForward();
            case CommandButton.up:
            case CommandButton.refresh:
            case CommandButton.newFolder:
            case CommandButton.newTextFile:
                return _currentPath.length > 0 && exists(_currentPath) && isDir(_currentPath);
            case CommandButton.openSelected:
            case CommandButton.copyPath:
                return hasSelection();
        }
    }

    private int navigationIndexAt(Point point) const
    {
        if (!_sidebarRowsRect.contains(point)) return -1;
        const row = sidebarRowHeightPx();
        const y = point.y - _sidebarRowsRect.y + _sidebarScrollY;
        const index = y / row;
        return index >= 0 && index < cast(int) _navigation.length ? index : -1;
    }

    private int entryIndexAt(Point point) const
    {
        if (!_rowsRect.contains(point)) return -1;
        const row = rowHeightPx();
        const y = point.y - _rowsRect.y + _scrollY;
        const index = y / row;
        return index >= 0 && index < cast(int) _visibleEntries.length ? index : -1;
    }

    private void setListScroll(int value)
    {
        _scrollY = clampInt(value, 0, maxListScroll());
        rebuildScrollbars();
        invalidate();
    }

    private void setSidebarScroll(int value)
    {
        _sidebarScrollY = clampInt(value, 0, maxSidebarScroll());
        rebuildScrollbars();
        invalidate();
    }

    private int maxListScroll() const
    {
        return maxInt(0, cast(int) _visibleEntries.length * rowHeightPx() -
            _rowsRect.height);
    }

    private int maxSidebarScroll() const
    {
        return maxInt(0, cast(int) _navigation.length * sidebarRowHeightPx() -
            _sidebarRowsRect.height);
    }

    private void pageListScroll(int direction)
    {
        const row = rowHeightPx();
        setListScroll(_scrollY + direction * maxInt(row, _rowsRect.height - row));
    }

    private void pageSidebarScroll(int direction)
    {
        const row = sidebarRowHeightPx();
        setSidebarScroll(_sidebarScrollY +
            direction * maxInt(row, _sidebarRowsRect.height - row));
    }

    private void dragListScrollbar(int pointerY)
    {
        const maxScroll = maxListScroll();
        const travel = maxInt(1, _listScrollbarRect.height - _listScrollbarThumbRect.height);
        const delta = pointerY - _listScrollbarGrabY;
        setListScroll(_listScrollbarGrabScrollY + delta * maxScroll / travel);
    }

    private void dragSidebarScrollbar(int pointerY)
    {
        const maxScroll = maxSidebarScroll();
        const travel = maxInt(1, _sidebarScrollbarRect.height - _sidebarScrollbarThumbRect.height);
        const delta = pointerY - _sidebarScrollbarGrabY;
        setSidebarScroll(_sidebarScrollbarGrabScrollY + delta * maxScroll / travel);
    }

    private void rebuildScrollbars()
    {
        const listMax = maxListScroll();
        const scrollbar = scrollbarWidthPx();
        _listScrollbarRect = Rect(_rowsRect.right() - scrollbar, _rowsRect.y,
            scrollbar, _rowsRect.height);
        if (listMax > 0)
        {
            const contentHeight = cast(int) _visibleEntries.length * rowHeightPx();
            const thumbHeight = clampInt(_rowsRect.height * _rowsRect.height /
                maxInt(1, contentHeight), scaled(34), maxInt(scaled(34), _rowsRect.height));
            const travel = maxInt(1, _rowsRect.height - thumbHeight);
            const thumbY = _rowsRect.y + _scrollY * travel / listMax;
            _listScrollbarThumbRect = Rect(_listScrollbarRect.x + scaled(2), thumbY,
                maxInt(1, scrollbar - scaled(4)), thumbHeight);
        }
        else
            _listScrollbarThumbRect = Rect.init;

        const navMax = maxSidebarScroll();
        _sidebarScrollbarRect = Rect(_sidebarRowsRect.right() - scrollbar,
            _sidebarRowsRect.y, scrollbar, _sidebarRowsRect.height);
        if (navMax > 0)
        {
            const contentHeight = cast(int) _navigation.length * sidebarRowHeightPx();
            const thumbHeight = clampInt(_sidebarRowsRect.height * _sidebarRowsRect.height /
                maxInt(1, contentHeight), scaled(34),
                maxInt(scaled(34), _sidebarRowsRect.height));
            const travel = maxInt(1, _sidebarRowsRect.height - thumbHeight);
            const thumbY = _sidebarRowsRect.y + _sidebarScrollY * travel / navMax;
            _sidebarScrollbarThumbRect = Rect(_sidebarScrollbarRect.x + scaled(2), thumbY,
                maxInt(1, scrollbar - scaled(4)), thumbHeight);
        }
        else
            _sidebarScrollbarThumbRect = Rect.init;
    }

    private void drawRibbon(ref Canvas canvas)
    {
        const ribbon = ribbonHeightPx();
        const tabHeight = scaled(34);
        canvas.fillRect(Rect(0, 0, bounds().width, ribbon), explorerBlack);
        canvas.fillRect(Rect(0, tabHeight, bounds().width, 1), explorerLine);
        canvas.fillRect(Rect(0, ribbon - 1, bounds().width, 1), explorerLine);

        canvas.fillRect(Rect(0, 0, scaled(70), tabHeight), explorerBlue);
        drawText(canvas, Rect(0, 0, scaled(70), tabHeight), "File", explorerText,
            HorizontalAlign.center);

        drawText(canvas, Rect(scaled(82), 0, scaled(62), tabHeight), "Home", explorerText,
            HorizontalAlign.left);
        drawText(canvas, Rect(scaled(150), 0, scaled(62), tabHeight), "Share", explorerText,
            HorizontalAlign.left);
        drawText(canvas, Rect(scaled(218), 0, scaled(62), tabHeight), "View", explorerText,
            HorizontalAlign.left);

        canvas.fillRect(Rect(0, scaled(35), bounds().width, maxInt(0, ribbon - scaled(35))),
            explorerBlack);
        drawCommandButton(canvas, _newFolderRect, CommandButton.newFolder,
            IconKind.folder, "New folder", true);
        drawCommandButton(canvas, _newTextFileRect, CommandButton.newTextFile,
            IconKind.newDocument, "New file", true);
        drawCommandButton(canvas, _openSelectedRect, CommandButton.openSelected,
            IconKind.open, "Open", hasSelection());
        drawCommandButton(canvas, _copyPathRect, CommandButton.copyPath,
            IconKind.file, "Copy path", hasSelection());
    }

    private void drawAddressBar(ref Canvas canvas)
    {
        const ribbon = ribbonHeightPx();
        canvas.fillRect(Rect(0, ribbon, bounds().width, addressHeightPx()),
            explorerAddressBackground);

        drawNavButton(canvas, _backRect, CommandButton.back, canGoBack());
        drawNavButton(canvas, _forwardRect, CommandButton.forward, canGoForward());
        drawUpButton(canvas, _upRect);

        canvas.drawRoundedRect(_addressRect, 0, explorerField, explorerFieldBorder, 1);
        drawIcon(canvas, IconKind.folder, Rect(_addressRect.x + scaled(8),
            _addressRect.y + scaled(6), scaled(16), scaled(16)),
            explorerText, folderAccent);

        drawRefreshButton(canvas, _refreshRect);

        canvas.drawRoundedRect(_searchRect, 0, explorerField, explorerFieldBorder, 1);
        drawIcon(canvas, IconKind.search, Rect(_searchRect.x + scaled(9),
            _searchRect.y + scaled(7), scaled(15), scaled(15)),
            explorerMuted, explorerMuted);
    }

    private void drawSidebar(ref Canvas canvas)
    {
        canvas.fillRect(_sidebarRect, explorerSidebar);
        canvas.fillRect(Rect(_sidebarRect.right() - 1, _sidebarRect.y, 1,
            _sidebarRect.height), explorerLine);

        auto content = canvas.clipped(_sidebarRowsRect);
        const sideRow = sidebarRowHeightPx();
        const scrollbar = scrollbarWidthPx();
        foreach (index, item; _navigation)
        {
            const rowY = _sidebarRowsRect.y + cast(int) index * sideRow -
                _sidebarScrollY;
            const row = Rect(_sidebarRowsRect.x, rowY,
                maxInt(0, _sidebarRowsRect.width - scrollbar), sideRow);
            if (row.bottom() < _sidebarRowsRect.y || row.y > _sidebarRowsRect.bottom())
                continue;

            if (_draggingEntry && cast(int) index == _dropTargetNavigationIndex)
            {
                content.fillRect(row, explorerDropTarget);
                content.strokeRect(row, explorerBlue, 1);
            }
            else if (navigationItemSelected(item))
                content.fillRect(row, explorerSelection);
            else if (!item.enabled)
                content.fillRect(row, Color.rgba(0, 0, 0, 20));

            const textColor = item.enabled ? explorerText : explorerDisabled;
            drawIcon(content, item.icon, Rect(row.x + scaled(36), row.y + scaled(5),
                scaled(17), scaled(17)),
                textColor, folderAccent);
            drawText(content, Rect(row.x + scaled(60), row.y,
                maxInt(0, row.width - scaled(86)), row.height), item.label, textColor,
                HorizontalAlign.left);

            if (item.pinned)
                drawPin(content, Rect(row.right() - scaled(22), row.y + scaled(7),
                    scaled(11), scaled(11)),
                    explorerMuted);
        }

        drawScrollbar(canvas, _sidebarScrollbarRect, _sidebarScrollbarThumbRect);
    }

    private void drawDetailsView(ref Canvas canvas)
    {
        canvas.fillRect(_mainRect, explorerContent);
        canvas.fillRect(_headerRect, explorerHeader);
        canvas.fillRect(Rect(_headerRect.x, _headerRect.bottom() - 1,
            _headerRect.width, 1), explorerLine);

        drawHeaderCell(canvas, _nameHeaderRect, "Name", SortColumn.name);
        drawHeaderCell(canvas, _dateHeaderRect, "Date modified", SortColumn.modified);
        drawHeaderCell(canvas, _typeHeaderRect, "Type", SortColumn.type);
        drawHeaderCell(canvas, _sizeHeaderRect, "Size", SortColumn.size);
        canvas.fillRect(Rect(_dateX, _headerRect.y, 1, _headerRect.height), explorerLine);
        canvas.fillRect(Rect(_typeX, _headerRect.y, 1, _headerRect.height), explorerLine);
        canvas.fillRect(Rect(_sizeX, _headerRect.y, 1, _headerRect.height), explorerLine);
        canvas.fillRect(Rect(_sizeX + _sizeWidth, _headerRect.y, 1, _headerRect.height),
            explorerLine);

        auto rows = canvas.clipped(_rowsRect);
        const rowHeightScaled = rowHeightPx();
        const first = maxInt(0, _scrollY / rowHeightScaled);
        const last = minInt(cast(int) _visibleEntries.length,
            (_scrollY + _rowsRect.height) / rowHeightScaled + 2);
        foreach (visibleIndex; first .. last)
        {
            const entry = _entries[cast(size_t) _visibleEntries[cast(size_t) visibleIndex]];
            const y = _rowsRect.y + visibleIndex * rowHeightScaled - _scrollY;
            const row = Rect(_rowsRect.x + scaled(20), y,
                maxInt(0, _usableListWidth - scaled(24)), rowHeightScaled);
            if (_draggingEntry && visibleIndex == _dropTargetVisibleIndex)
            {
                rows.fillRect(row, explorerDropTarget);
                rows.strokeRect(row, explorerBlue, 1);
            }
            else if (visibleIndex == _selectedVisibleIndex)
            {
                rows.fillRect(row, explorerSelection);
                rows.strokeRect(row, explorerSelectionBorder, 1);
            }

            const icon = entry.directory ? IconKind.folder : iconForFile(entry.name);
            drawIcon(rows, icon, Rect(row.x + scaled(6), row.y + scaled(4),
                scaled(17), scaled(17)), explorerText,
                entry.directory ? folderAccent : fileAccent);
            drawText(rows, Rect(row.x + scaled(28), row.y,
                maxInt(0, _dateX - row.x - scaled(35)), row.height), entry.name,
                explorerText, HorizontalAlign.left);
            drawText(rows, Rect(_dateX + scaled(8), row.y,
                maxInt(0, _typeX - _dateX - scaled(14)), row.height), entry.modified,
                explorerText, HorizontalAlign.left);
            drawText(rows, Rect(_typeX + scaled(8), row.y,
                maxInt(0, _sizeX - _typeX - scaled(14)), row.height), entry.type,
                explorerText, HorizontalAlign.left);
            drawText(rows, Rect(_sizeX + scaled(8), row.y, maxInt(0, _sizeWidth - scaled(16)),
                row.height), entry.directory ? "" : humanSize(entry.size),
                explorerText, HorizontalAlign.right);
        }

        drawScrollbar(canvas, _listScrollbarRect, _listScrollbarThumbRect);
    }

    private void drawDragPreview(ref Canvas canvas)
    {
        if (!_draggingEntry || !hasDragSource()) return;
        const entry = dragSourceEntry();
        const previewWidth = clampInt(scaled(52) + cast(int) entry.name.length * scaled(7),
            scaled(150), scaled(320));
        const preview = Rect(_dragCurrent.x + scaled(12), _dragCurrent.y + scaled(12),
            previewWidth, scaled(30));
        canvas.drawRoundedRect(preview, scaled(2), explorerDragPreview, explorerSelectionBorder, 1);
        const icon = entry.directory ? IconKind.folder : iconForFile(entry.name);
        drawIcon(canvas, icon, Rect(preview.x + scaled(8), preview.y + scaled(6),
            scaled(17), scaled(17)),
            explorerText, entry.directory ? folderAccent : fileAccent);
        drawText(canvas, Rect(preview.x + scaled(32), preview.y,
            maxInt(0, preview.width - scaled(42)), preview.height), entry.name,
            explorerText, HorizontalAlign.left);
    }

    private void drawStatusBar(ref Canvas canvas)
    {
        canvas.fillRect(_statusRect, explorerStatus);
        canvas.fillRect(Rect(_statusRect.x, _statusRect.y, _statusRect.width, 1),
            explorerLine);
        drawText(canvas, Rect(_statusRect.x + scaled(20), _statusRect.y,
            maxInt(0, _statusRect.width - scaled(40)), _statusRect.height), _statusText,
            explorerText, HorizontalAlign.left);
    }

    private void drawNavButton(ref Canvas canvas, Rect rect, CommandButton command,
        bool enabled)
    {
        const pressed = _pressedCommand == command;
        if (pressed)
            canvas.fillRect(rect, explorerPressed);
        const color = enabled ? explorerText : explorerDisabled;
        const midY = rect.y + rect.height / 2;
        const midX = rect.x + rect.width / 2;
        const dir = command == CommandButton.back ? -1 : 1;
        canvas.drawLine(Point(midX + dir * scaled(5), midY - scaled(6)),
            Point(midX - dir * scaled(3), midY),
            color, 2);
        canvas.drawLine(Point(midX - dir * scaled(3), midY),
            Point(midX + dir * scaled(5), midY + scaled(6)),
            color, 2);
    }

    private void drawUpButton(ref Canvas canvas, Rect rect)
    {
        if (_pressedCommand == CommandButton.up)
            canvas.fillRect(rect, explorerPressed);
        drawIcon(canvas, IconKind.up, Rect(rect.x + scaled(5), rect.y + scaled(5),
            scaled(18), scaled(18)),
            explorerText, explorerText);
    }

    private void drawRefreshButton(ref Canvas canvas, Rect rect)
    {
        if (_pressedCommand == CommandButton.refresh)
            canvas.fillRect(rect, explorerPressed);
        canvas.drawRoundedRect(rect, 0, explorerField, explorerFieldBorder, 1);
        drawIcon(canvas, IconKind.refresh, Rect(rect.x + scaled(6), rect.y + scaled(6),
            scaled(16), scaled(16)),
            explorerMuted, explorerText);
    }

    private void drawCommandButton(ref Canvas canvas, Rect rect, CommandButton command,
        IconKind icon, string label, bool enabled)
    {
        const pressed = _pressedCommand == command;
        if (pressed)
            canvas.fillRect(rect, explorerPressed);
        else
            canvas.fillRect(rect, Color.rgba(255, 255, 255, 10));
        canvas.strokeRect(rect, enabled ? explorerFieldBorder.withAlpha(150) :
            explorerFieldBorder.withAlpha(70), 1);
        const foreground = enabled ? explorerText : explorerDisabled;
        drawIcon(canvas, icon, Rect(rect.x + scaled(5), rect.y + scaled(4),
            scaled(16), scaled(16)),
            foreground, folderAccent);
        drawText(canvas, Rect(rect.x + scaled(25), rect.y,
            maxInt(0, rect.width - scaled(29)), rect.height), label, foreground,
            HorizontalAlign.left);
    }

    private void drawHeaderCell(ref Canvas canvas, Rect rect, string text,
        SortColumn column)
    {
        const label = _sortColumn == column
            ? text ~ (_sortAscending ? " ^" : " v")
            : text;
        drawText(canvas, rect.inset(scaled(4), 0, scaled(4), 0), label, explorerText,
            HorizontalAlign.left);
    }

    private void drawText(ref Canvas canvas, Rect rect, string text, Color color,
        HorizontalAlign horizontal)
    {
        canvas.drawTextInRect(rect, toUTF32(text), color, textScale(),
            horizontal, VerticalAlign.middle, true);
    }

    private void drawPin(ref Canvas canvas, Rect rect, Color color)
    {
        const cx = rect.x + rect.width / 2;
        const cy = rect.y + rect.height / 2;
        canvas.drawLine(Point(cx - scaled(3), cy - scaled(3)),
            Point(cx + scaled(3), cy + scaled(3)), color, 2);
        canvas.fillRect(Rect(cx - scaled(4), cy - scaled(5), scaled(8), scaled(3)), color);
        canvas.drawLine(Point(cx, cy + scaled(3)), Point(cx - scaled(3), cy + scaled(6)),
            color, 1);
    }

    private void drawScrollbar(ref Canvas canvas, Rect track, Rect thumb)
    {
        if (track.empty() || thumb.empty()) return;
        canvas.fillRect(track, explorerScrollbarTrack);
        canvas.fillRoundedRect(thumb, scaled(2), explorerScrollbarThumb);
    }

    private bool canGoBack() const
    {
        return _historyIndex > 0;
    }

    private bool canGoForward() const
    {
        return _historyIndex + 1 < cast(int) _history.length;
    }

    private string searchPlaceholder() const
    {
        string title = baseName(_currentPath);
        if (title.length == 0) title = displayRoot(_currentPath);
        if (title.length == 0) title = "folder";
        return "Search " ~ title;
    }

    private static string breadcrumbText(string path)
    {
        string[] parts;
        const root = rootName(path);
        if (root.length > 0)
        {
            parts ~= "This PC";
            parts ~= displayRoot(root);
            foreach (part; splitPathParts(path[root.length .. $]))
                parts ~= part;
        }
        else
        {
            parts ~= path.length > 0 && path[0] == '/' ? "/" : "This PC";
            foreach (part; splitPathParts(path))
                parts ~= part;
        }

        string result;
        foreach (index, part; parts)
        {
            if (index > 0) result ~= " > ";
            result ~= part;
        }
        return result;
    }

    private static string[] splitPathParts(string path)
    {
        string[] result;
        size_t start;
        foreach (index, ch; path)
        {
            if (ch == '/' || ch == '\\')
            {
                if (index > start)
                    result ~= path[start .. index];
                start = index + 1;
            }
        }
        if (start < path.length)
            result ~= path[start .. $];
        return result;
    }

    private static string rootPathFor(string path)
    {
        const root = rootName(path);
        return root.length > 0 ? root : "/";
    }

    private static string displayRoot(string path)
    {
        const root = rootName(path);
        if (root.length >= 2 && root[1] == ':')
            return "Operating System (" ~ root[0 .. 2] ~ ")";
        if (path.length >= 2 && path[1] == ':')
            return "Operating System (" ~ path[0 .. 2] ~ ")";
        return root.length > 0 ? root : path;
    }

    private static string folderDisplayName(string path)
    {
        const name = baseName(path);
        return name.length > 0 ? name : displayRoot(path);
    }

    private static bool pathsEqual(string a, string b)
    {
        version (Windows)
            return icmp(buildNormalizedPath(a), buildNormalizedPath(b)) == 0;
        else
            return buildNormalizedPath(a) == buildNormalizedPath(b);
    }

    private static bool isSameOrDescendantPath(string candidate, string parent)
    {
        if (pathsEqual(candidate, parent)) return true;
        const normalizedCandidate = ensureTrailingSeparator(buildNormalizedPath(candidate));
        const normalizedParent = ensureTrailingSeparator(buildNormalizedPath(parent));
        if (normalizedCandidate.length < normalizedParent.length) return false;
        version (Windows)
            return icmp(normalizedCandidate[0 .. normalizedParent.length],
                normalizedParent) == 0;
        else
            return normalizedCandidate[0 .. normalizedParent.length] == normalizedParent;
    }

    private static string ensureTrailingSeparator(string path)
    {
        if (path.length == 0) return pathSeparator();
        const last = path[$ - 1];
        if (last == '/' || last == '\\') return path;
        return path ~ pathSeparator();
    }

    private static string pathSeparator()
    {
        version (Windows)
            return "\\";
        else
            return "/";
    }

    private static int absInt(int value)
    {
        return value < 0 ? -value : value;
    }

    private static bool containsInsensitive(string value, string loweredNeedle)
    {
        if (loweredNeedle.length == 0) return true;
        const haystack = value.toLower();
        if (loweredNeedle.length > haystack.length) return false;
        foreach (index; 0 .. haystack.length - loweredNeedle.length + 1)
            if (haystack[index .. index + loweredNeedle.length] == loweredNeedle)
                return true;
        return false;
    }

    private static string modifiedText(DirEntry item)
    {
        try
        {
            auto text = format("%s", item.timeLastModified);
            return text.length > 16 ? text[0 .. 16] : text;
        }
        catch (Exception)
        {
            return "";
        }
    }

    private static string typeText(string name, bool directory)
    {
        if (directory) return "File folder";
        const ext = extension(name);
        if (icmp(ext, ".exe") == 0) return "Application";
        if (icmp(ext, ".json") == 0) return "JSON File";
        if (icmp(ext, ".md") == 0) return "MD File";
        if (icmp(ext, ".d") == 0) return "D Source File";
        if (icmp(ext, ".txt") == 0) return "Text Document";
        if (icmp(ext, ".pdb") == 0) return "Program Debug D...";
        if (icmp(ext, ".lib") == 0) return "Object File Library";
        if (ext.length > 1) return ext[1 .. $].toUpperAscii() ~ " File";
        return "File";
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

    private static string humanSize(ulong bytes)
    {
        if (bytes == 0) return "0 KB";
        const kb = (bytes + 1023) / 1024;
        return groupedNumber(kb) ~ " KB";
    }

    private static string groupedNumber(ulong value)
    {
        auto text = format("%d", value);
        string result;
        int group;
        for (int index = cast(int) text.length - 1; index >= 0; --index)
        {
            if (group == 3)
            {
                result = " " ~ result;
                group = 0;
            }
            result = text[cast(size_t) index .. cast(size_t) index + 1] ~ result;
            ++group;
        }
        return result;
    }
}

private string toUpperAscii(string value)
{
    char[] result = value.dup;
    foreach (ref ch; result)
        if (ch >= 'a' && ch <= 'z')
            ch = cast(char) (ch - ('a' - 'A'));
    return cast(string) result;
}

private string processClipboardText;

private bool writeClipboardText(string value)
{
    processClipboardText = value;
    version (Windows)
        return writeSystemClipboardText(value);
    else
        return true;
}

version (Windows)
private bool writeSystemClipboardText(string value)
{
    if (!OpenClipboard(null)) return false;
    scope (exit) CloseClipboard();
    if (!EmptyClipboard()) return false;

    auto encoded = toUTF16(value);
    const bytes = (encoded.length + 1) * wchar.sizeof;
    auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (memory is null) return false;
    auto text = cast(wchar*) GlobalLock(memory);
    if (text is null)
    {
        GlobalFree(memory);
        return false;
    }
    foreach (index, ch; encoded)
        text[index] = ch;
    text[encoded.length] = 0;
    GlobalUnlock(memory);

    if (SetClipboardData(CF_UNICODETEXT, memory) is null)
    {
        GlobalFree(memory);
        return false;
    }
    return true;
}

private bool openPathWithSystem(string path)
{
    version (Windows)
    {
        auto result = ShellExecuteW(null, "open".toUTF16z, path.toUTF16z,
            null, null, SW_SHOWNORMAL);
        return cast(size_t) result > 32;
    }
    else version (OSX)
    {
        spawnProcess(["open", path], null, Config.detached);
        return true;
    }
    else
    {
        spawnProcess(["xdg-open", path], null, Config.detached);
        return true;
    }
}

private Theme explorerTheme()
{
    auto theme = Theme.dark();
    theme.windowBackground = explorerContent;
    theme.panelBackground = explorerContent;
    theme.panelElevated = explorerHeader;
    theme.text = explorerText;
    theme.textMuted = explorerMuted;
    theme.border = explorerFieldBorder;
    theme.accent = explorerBlue;
    theme.selection = explorerSelection;
    theme.selectionText = explorerText;
    theme.fieldBackground = explorerField;
    theme.buttonBackground = explorerField;
    theme.buttonHover = explorerSelection;
    theme.buttonPressed = explorerPressed;
    theme.cornerRadius = 0;
    theme.controlHeight = 30;
    theme.fontScale = cast(int) TextScale.caption;
    return theme;
}

private immutable Color explorerBlack = Color.fromHex(0x000000);
private immutable Color explorerContent = Color.fromHex(0x202020);
private immutable Color explorerSidebar = Color.fromHex(0x191919);
private immutable Color explorerHeader = Color.fromHex(0x202020);
private immutable Color explorerAddressBackground = Color.fromHex(0x151515);
private immutable Color explorerField = Color.fromHex(0x202020);
private immutable Color explorerFieldBorder = Color.fromHex(0x434343);
private immutable Color explorerLine = Color.fromHex(0x474747);
private immutable Color explorerText = Color.fromHex(0xf2f2f2);
private immutable Color explorerMuted = Color.fromHex(0xa7a7a7);
private immutable Color explorerDisabled = Color.fromHex(0x676767);
private immutable Color explorerBlue = Color.fromHex(0x005a9e);
private immutable Color explorerPressed = Color.fromHex(0x303030);
private immutable Color explorerSelection = Color.fromHex(0x353535);
private immutable Color explorerSelectionBorder = Color.fromHex(0x5a5a5a);
private immutable Color explorerDropTarget = Color.fromHex(0x24445f);
private immutable Color explorerDragPreview = Color.rgba(32, 32, 32, 225);
private immutable Color explorerStatus = Color.fromHex(0x303030);
private immutable Color explorerScrollbarTrack = Color.fromHex(0x242424);
private immutable Color explorerScrollbarThumb = Color.fromHex(0x6a6a6a);
private immutable Color folderAccent = Color.fromHex(0xf4d35e);
private immutable Color fileAccent = Color.fromHex(0x78aee8);

private string windowsFileManagerIconPath()
{
    string[] basePaths = [getcwd()];

    try
    {
        const exePath = thisExePath();
        if (exePath.length)
            basePaths ~= dirName(exePath);
    }
    catch (Exception)
    {
    }

    foreach (basePath; basePaths)
    {
        foreach (relativePath; [
            "resources/windows/windows_file_manager.ico",
            "../resources/windows/windows_file_manager.ico",
            "../../resources/windows/windows_file_manager.ico"
        ])
        {
            const candidate = buildNormalizedPath(basePath, relativePath);
            if (exists(candidate))
                return candidate;
        }
    }

    return "";
}

version (AuroraWindowsFileManagerApp)
int main(string[] args)
{
    WindowOptions options;
    options.title = "Aurora Windows File Manager";
    options.width = 1280;
    options.height = 760;
    options.darkTitleBar = true;
    options.iconPath = windowsFileManagerIconPath();
    auto window = new GuiWindow(options, explorerTheme());
    const initial = args.length > 1 ? args[1] : "";
    window.setRoot(new WindowsFileManagerRoot(window, initial));
    return window.run();
}
