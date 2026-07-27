module demos.windows_file_manager;

import aurora;
import std.algorithm.sorting : sort;
import std.file : DirEntry, SpanMode, dirEntries, exists, getcwd, isDir;
import std.format : format;
import std.path : baseName, buildNormalizedPath, dirName, extension, isAbsolute,
    rootName;
import std.process : environment;
import std.string : icmp, toLower;
import std.utf : toUTF32;

private enum CommandButton
{
    none = -1,
    back,
    forward,
    up,
    refresh
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
    bool enabled = true;
    bool pinned;
}

final class WindowsFileManagerRoot : Widget
{
    private enum ribbonHeight = 74;
    private enum addressHeight = 44;
    private enum statusHeight = 28;
    private enum sidebarMinimumWidth = 250;
    private enum sidebarMaximumWidth = 360;
    private enum rowHeight = 28;
    private enum sidebarRowHeight = 30;
    private enum headerHeight = 38;
    private enum scrollbarWidth = 13;

    private GuiWindow _window;
    private TextField _searchField;
    private ExplorerEntry[] _entries;
    private int[] _visibleEntries;
    private NavigationItem[] _navigation;
    private string _currentPath;
    private string _searchQuery;
    private string _statusText = "Ready";
    private string[] _history;
    private int _historyIndex = -1;
    private int _selectedVisibleIndex = -1;
    private int _scrollY;
    private int _sidebarScrollY;
    private CommandButton _pressedCommand = CommandButton.none;
    private bool _draggingListScrollbar;
    private int _listScrollbarGrabY;
    private int _listScrollbarGrabScrollY;
    private bool _draggingSidebarScrollbar;
    private int _sidebarScrollbarGrabY;
    private int _sidebarScrollbarGrabScrollY;

    private Rect _addressRect;
    private Rect _searchRect;
    private Rect _searchTextRect;
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

    this(GuiWindow window, string initialPath = "")
    {
        _window = window;
        setFocusable(true);
        layoutHints().minWidth = 820;
        layoutHints().minHeight = 500;

        _searchField = add(new TextField());
        _searchField.setTransparentBackground(true);
        _searchField.setShowBorder(false);
        _searchField.setPadding(5);
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
        return Size(1180, 720);
    }

    protected override void onLayout()
    {
        updateGeometry();
        if (_searchField !is null)
            _searchField.setBounds(_searchTextRect);
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
    }

    override bool onMouseDown(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
        requestFocus();

        const command = commandAt(event.position);
        if (command != CommandButton.none)
        {
            _pressedCommand = command;
            captureMouse();
            invalidate();
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
                activateEntry(visibleIndex);
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
            if (commandAt(event.position) == pressed)
                activateCommand(pressed);
            invalidate();
            return true;
        }
        return false;
    }

    override bool onMouseWheel(ref Event event)
    {
        if (_sidebarRect.contains(event.position))
        {
            setSidebarScroll(_sidebarScrollY - event.wheelY * sidebarRowHeight / 3);
            return true;
        }
        if (_mainRect.contains(event.position))
        {
            setListScroll(_scrollY - event.wheelY * rowHeight / 3);
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
            if (event.key == Key.f)
            {
                _searchField.requestFocus();
                _searchField.selectAll();
                return true;
            }
        }
        return false;
    }

    private void updateGeometry()
    {
        const w = bounds().width;
        const h = bounds().height;
        const sidebarWidth = clampInt(w / 4, sidebarMinimumWidth, sidebarMaximumWidth);
        const contentTop = ribbonHeight + addressHeight;
        const contentHeight = maxInt(0, h - contentTop - statusHeight);
        _statusRect = Rect(0, maxInt(contentTop, h - statusHeight), w, statusHeight);
        _sidebarRect = Rect(0, contentTop, sidebarWidth, contentHeight);
        _sidebarRowsRect = _sidebarRect.inset(0, 4, 0, 4);
        _mainRect = Rect(sidebarWidth, contentTop, maxInt(0, w - sidebarWidth), contentHeight);
        _headerRect = Rect(_mainRect.x, _mainRect.y, _mainRect.width, headerHeight);
        _rowsRect = Rect(_mainRect.x, _mainRect.y + headerHeight, _mainRect.width,
            maxInt(0, _mainRect.height - headerHeight));

        _backRect = Rect(12, ribbonHeight + 7, 28, 30);
        _forwardRect = Rect(44, ribbonHeight + 7, 28, 30);
        _upRect = Rect(84, ribbonHeight + 7, 28, 30);
        const searchWidth = clampInt(w / 5, 170, 270);
        _searchRect = Rect(maxInt(0, w - searchWidth - 14), ribbonHeight + 7,
            searchWidth, 30);
        _refreshRect = Rect(maxInt(120, _searchRect.x - 34), ribbonHeight + 7, 30, 30);
        _addressRect = Rect(126, ribbonHeight + 7,
            maxInt(120, _refreshRect.x - 132), 30);
        _searchTextRect = Rect(_searchRect.x + 32, _searchRect.y + 2,
            maxInt(0, _searchRect.width - 38), maxInt(0, _searchRect.height - 4));

        rebuildScrollbars();
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
        addNavigation("This PC", rootPathFor(home), IconKind.computer, false);
        addNavigation("Network", rootPathFor(home), IconKind.drive, false);
    }

    private void addNavigation(string label, string path, IconKind icon, bool pinned)
    {
        NavigationItem item;
        item.label = label;
        item.path = path;
        item.icon = icon;
        item.pinned = pinned;
        item.enabled = path.length > 0 && exists(path) && isDir(path);
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
            sort!entryLess(entries);
            _entries = entries;
            _currentPath = path;
            _selectedVisibleIndex = -1;
            _scrollY = 0;

            if (clearSearch)
            {
                _searchQuery = "";
                _searchField.setText("", false);
            }
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

    private static bool entryLess(ExplorerEntry a, ExplorerEntry b)
    {
        if (a.directory != b.directory) return a.directory;
        return icmp(a.name, b.name) < 0;
    }

    private void activateNavigation(int index)
    {
        if (index < 0 || index >= cast(int) _navigation.length) return;
        const item = _navigation[cast(size_t) index];
        if (!item.enabled)
        {
            _statusText = item.label ~ " is not available.";
            invalidate();
            return;
        }
        navigate(item.path, true, true);
    }

    private void activateEntry(int visibleIndex)
    {
        if (visibleIndex < 0 || visibleIndex >= cast(int) _visibleEntries.length) return;
        const entry = _entries[cast(size_t) _visibleEntries[cast(size_t) visibleIndex]];
        if (entry.directory)
            navigate(entry.path, true, true);
        else
        {
            _statusText = entry.name ~ " selected";
            invalidate();
        }
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
        _window.setTitle(title ~ " - Aurora Windows File Manager");
    }

    private CommandButton commandAt(Point point) const
    {
        if (_backRect.contains(point)) return CommandButton.back;
        if (_forwardRect.contains(point)) return CommandButton.forward;
        if (_upRect.contains(point)) return CommandButton.up;
        if (_refreshRect.contains(point)) return CommandButton.refresh;
        return CommandButton.none;
    }

    private int navigationIndexAt(Point point) const
    {
        if (!_sidebarRowsRect.contains(point)) return -1;
        const y = point.y - _sidebarRowsRect.y + _sidebarScrollY;
        const index = y / sidebarRowHeight;
        return index >= 0 && index < cast(int) _navigation.length ? index : -1;
    }

    private int entryIndexAt(Point point) const
    {
        if (!_rowsRect.contains(point)) return -1;
        const y = point.y - _rowsRect.y + _scrollY;
        const index = y / rowHeight;
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
        return maxInt(0, cast(int) _visibleEntries.length * rowHeight - _rowsRect.height);
    }

    private int maxSidebarScroll() const
    {
        return maxInt(0, cast(int) _navigation.length * sidebarRowHeight -
            _sidebarRowsRect.height);
    }

    private void pageListScroll(int direction)
    {
        setListScroll(_scrollY + direction * maxInt(rowHeight, _rowsRect.height - rowHeight));
    }

    private void pageSidebarScroll(int direction)
    {
        setSidebarScroll(_sidebarScrollY +
            direction * maxInt(sidebarRowHeight, _sidebarRowsRect.height - sidebarRowHeight));
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
        _listScrollbarRect = Rect(_rowsRect.right() - scrollbarWidth, _rowsRect.y,
            scrollbarWidth, _rowsRect.height);
        if (listMax > 0)
        {
            const contentHeight = cast(int) _visibleEntries.length * rowHeight;
            const thumbHeight = clampInt(_rowsRect.height * _rowsRect.height /
                maxInt(1, contentHeight), 34, maxInt(34, _rowsRect.height));
            const travel = maxInt(1, _rowsRect.height - thumbHeight);
            const thumbY = _rowsRect.y + _scrollY * travel / listMax;
            _listScrollbarThumbRect = Rect(_listScrollbarRect.x + 2, thumbY,
                maxInt(1, scrollbarWidth - 4), thumbHeight);
        }
        else
            _listScrollbarThumbRect = Rect.init;

        const navMax = maxSidebarScroll();
        _sidebarScrollbarRect = Rect(_sidebarRowsRect.right() - scrollbarWidth,
            _sidebarRowsRect.y, scrollbarWidth, _sidebarRowsRect.height);
        if (navMax > 0)
        {
            const contentHeight = cast(int) _navigation.length * sidebarRowHeight;
            const thumbHeight = clampInt(_sidebarRowsRect.height * _sidebarRowsRect.height /
                maxInt(1, contentHeight), 34, maxInt(34, _sidebarRowsRect.height));
            const travel = maxInt(1, _sidebarRowsRect.height - thumbHeight);
            const thumbY = _sidebarRowsRect.y + _sidebarScrollY * travel / navMax;
            _sidebarScrollbarThumbRect = Rect(_sidebarScrollbarRect.x + 2, thumbY,
                maxInt(1, scrollbarWidth - 4), thumbHeight);
        }
        else
            _sidebarScrollbarThumbRect = Rect.init;
    }

    private void drawRibbon(ref Canvas canvas)
    {
        canvas.fillRect(Rect(0, 0, bounds().width, ribbonHeight), explorerBlack);
        canvas.fillRect(Rect(0, 38, bounds().width, 1), explorerLine);
        canvas.fillRect(Rect(0, ribbonHeight - 1, bounds().width, 1), explorerLine);

        canvas.fillRect(Rect(0, 0, 72, 38), explorerBlue);
        drawText(canvas, Rect(0, 0, 72, 38), "File", explorerText,
            HorizontalAlign.center);

        drawText(canvas, Rect(84, 0, 70, 38), "Home", explorerText,
            HorizontalAlign.left);
        drawText(canvas, Rect(158, 0, 70, 38), "Share", explorerText,
            HorizontalAlign.left);
        drawText(canvas, Rect(232, 0, 70, 38), "View", explorerText,
            HorizontalAlign.left);

        canvas.fillRect(Rect(0, 39, bounds().width, 35), explorerBlack);
    }

    private void drawAddressBar(ref Canvas canvas)
    {
        canvas.fillRect(Rect(0, ribbonHeight, bounds().width, addressHeight),
            explorerAddressBackground);

        drawNavButton(canvas, _backRect, CommandButton.back, canGoBack());
        drawNavButton(canvas, _forwardRect, CommandButton.forward, canGoForward());
        drawUpButton(canvas, _upRect);

        canvas.drawRoundedRect(_addressRect, 0, explorerField, explorerFieldBorder, 1);
        drawIcon(canvas, IconKind.folder, Rect(_addressRect.x + 8, _addressRect.y + 6, 18, 18),
            explorerText, folderAccent);
        drawText(canvas, Rect(_addressRect.x + 34, _addressRect.y,
            maxInt(0, _addressRect.width - 42), _addressRect.height),
            breadcrumbText(_currentPath), explorerText, HorizontalAlign.left);

        drawRefreshButton(canvas, _refreshRect);

        canvas.drawRoundedRect(_searchRect, 0, explorerField, explorerFieldBorder, 1);
        drawIcon(canvas, IconKind.search, Rect(_searchRect.x + 9, _searchRect.y + 7, 16, 16),
            explorerMuted, explorerMuted);
    }

    private void drawSidebar(ref Canvas canvas)
    {
        canvas.fillRect(_sidebarRect, explorerSidebar);
        canvas.fillRect(Rect(_sidebarRect.right() - 1, _sidebarRect.y, 1,
            _sidebarRect.height), explorerLine);

        auto content = canvas.clipped(_sidebarRowsRect);
        foreach (index, item; _navigation)
        {
            const rowY = _sidebarRowsRect.y + cast(int) index * sidebarRowHeight -
                _sidebarScrollY;
            const row = Rect(_sidebarRowsRect.x, rowY,
                maxInt(0, _sidebarRowsRect.width - scrollbarWidth), sidebarRowHeight);
            if (row.bottom() < _sidebarRowsRect.y || row.y > _sidebarRowsRect.bottom())
                continue;

            if (item.enabled && pathsEqual(item.path, _currentPath))
                content.fillRect(row, explorerSelection);
            else if (!item.enabled)
                content.fillRect(row, Color.rgba(0, 0, 0, 20));

            const textColor = item.enabled ? explorerText : explorerDisabled;
            drawIcon(content, item.icon, Rect(row.x + 42, row.y + 6, 18, 18),
                textColor, folderAccent);
            drawText(content, Rect(row.x + 68, row.y, maxInt(0, row.width - 96),
                row.height), item.label, textColor, HorizontalAlign.left);

            if (item.pinned)
                drawPin(content, Rect(row.right() - 24, row.y + 8, 12, 12),
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

        const usableWidth = maxInt(120, _mainRect.width - scrollbarWidth);
        const nameWidth = clampInt(usableWidth - 460, 260, maxInt(260, usableWidth - 280));
        const dateWidth = 180;
        const typeWidth = 170;
        const sizeWidth = 110;
        const nameX = _mainRect.x + 24;
        const dateX = _mainRect.x + nameWidth;
        const typeX = dateX + dateWidth;
        const sizeX = typeX + typeWidth;

        drawHeaderCell(canvas, Rect(nameX, _headerRect.y, maxInt(0, dateX - nameX),
            _headerRect.height), "Name");
        drawHeaderCell(canvas, Rect(dateX + 8, _headerRect.y,
            maxInt(0, typeX - dateX - 8), _headerRect.height), "Date modified");
        drawHeaderCell(canvas, Rect(typeX + 8, _headerRect.y,
            maxInt(0, sizeX - typeX - 8), _headerRect.height), "Type");
        drawHeaderCell(canvas, Rect(sizeX + 8, _headerRect.y,
            maxInt(0, sizeWidth - 8), _headerRect.height), "Size");
        canvas.fillRect(Rect(dateX, _headerRect.y, 1, _headerRect.height), explorerLine);
        canvas.fillRect(Rect(typeX, _headerRect.y, 1, _headerRect.height), explorerLine);
        canvas.fillRect(Rect(sizeX, _headerRect.y, 1, _headerRect.height), explorerLine);
        canvas.fillRect(Rect(sizeX + sizeWidth, _headerRect.y, 1, _headerRect.height),
            explorerLine);

        auto rows = canvas.clipped(_rowsRect);
        const first = maxInt(0, _scrollY / rowHeight);
        const last = minInt(cast(int) _visibleEntries.length,
            (_scrollY + _rowsRect.height) / rowHeight + 2);
        foreach (visibleIndex; first .. last)
        {
            const entry = _entries[cast(size_t) _visibleEntries[cast(size_t) visibleIndex]];
            const y = _rowsRect.y + visibleIndex * rowHeight - _scrollY;
            const row = Rect(_rowsRect.x + 20, y, maxInt(0, usableWidth - 24), rowHeight);
            if (visibleIndex == _selectedVisibleIndex)
            {
                rows.fillRect(row, explorerSelection);
                rows.strokeRect(row, explorerSelectionBorder, 1);
            }

            const icon = entry.directory ? IconKind.folder : iconForFile(entry.name);
            drawIcon(rows, icon, Rect(row.x + 7, row.y + 5, 18, 18), explorerText,
                entry.directory ? folderAccent : fileAccent);
            drawText(rows, Rect(row.x + 31, row.y, maxInt(0, dateX - row.x - 39),
                row.height), entry.name, explorerText, HorizontalAlign.left);
            drawText(rows, Rect(dateX + 8, row.y, maxInt(0, typeX - dateX - 14),
                row.height), entry.modified, explorerText, HorizontalAlign.left);
            drawText(rows, Rect(typeX + 8, row.y, maxInt(0, sizeX - typeX - 14),
                row.height), entry.type, explorerText, HorizontalAlign.left);
            drawText(rows, Rect(sizeX + 8, row.y, maxInt(0, sizeWidth - 16),
                row.height), entry.directory ? "" : humanSize(entry.size),
                explorerText, HorizontalAlign.right);
        }

        drawScrollbar(canvas, _listScrollbarRect, _listScrollbarThumbRect);
    }

    private void drawStatusBar(ref Canvas canvas)
    {
        canvas.fillRect(_statusRect, explorerStatus);
        canvas.fillRect(Rect(_statusRect.x, _statusRect.y, _statusRect.width, 1),
            explorerLine);
        drawText(canvas, Rect(_statusRect.x + 20, _statusRect.y,
            maxInt(0, _statusRect.width - 40), _statusRect.height), _statusText,
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
        canvas.drawLine(Point(midX + dir * 5, midY - 6), Point(midX - dir * 3, midY),
            color, 2);
        canvas.drawLine(Point(midX - dir * 3, midY), Point(midX + dir * 5, midY + 6),
            color, 2);
    }

    private void drawUpButton(ref Canvas canvas, Rect rect)
    {
        if (_pressedCommand == CommandButton.up)
            canvas.fillRect(rect, explorerPressed);
        drawIcon(canvas, IconKind.up, Rect(rect.x + 5, rect.y + 5, 20, 20),
            explorerText, explorerText);
    }

    private void drawRefreshButton(ref Canvas canvas, Rect rect)
    {
        if (_pressedCommand == CommandButton.refresh)
            canvas.fillRect(rect, explorerPressed);
        canvas.drawRoundedRect(rect, 0, explorerField, explorerFieldBorder, 1);
        drawIcon(canvas, IconKind.refresh, Rect(rect.x + 6, rect.y + 6, 18, 18),
            explorerMuted, explorerText);
    }

    private void drawHeaderCell(ref Canvas canvas, Rect rect, string text)
    {
        drawText(canvas, rect.inset(4, 0, 4, 0), text, explorerText,
            HorizontalAlign.left);
    }

    private static void drawText(ref Canvas canvas, Rect rect, string text, Color color,
        HorizontalAlign horizontal)
    {
        canvas.drawTextInRect(rect, toUTF32(text), color, cast(int) TextScale.caption,
            horizontal, VerticalAlign.middle, true);
    }

    private static void drawPin(ref Canvas canvas, Rect rect, Color color)
    {
        const cx = rect.x + rect.width / 2;
        const cy = rect.y + rect.height / 2;
        canvas.drawLine(Point(cx - 3, cy - 3), Point(cx + 3, cy + 3), color, 2);
        canvas.fillRect(Rect(cx - 4, cy - 5, 8, 3), color);
        canvas.drawLine(Point(cx, cy + 3), Point(cx - 3, cy + 6), color, 1);
    }

    private static void drawScrollbar(ref Canvas canvas, Rect track, Rect thumb)
    {
        if (track.empty() || thumb.empty()) return;
        canvas.fillRect(track, explorerScrollbarTrack);
        canvas.fillRoundedRect(thumb, 2, explorerScrollbarThumb);
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

    private static bool pathsEqual(string a, string b)
    {
        version (Windows)
            return icmp(buildNormalizedPath(a), buildNormalizedPath(b)) == 0;
        else
            return buildNormalizedPath(a) == buildNormalizedPath(b);
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
private immutable Color explorerStatus = Color.fromHex(0x303030);
private immutable Color explorerScrollbarTrack = Color.fromHex(0x242424);
private immutable Color explorerScrollbarThumb = Color.fromHex(0x6a6a6a);
private immutable Color folderAccent = Color.fromHex(0xf4d35e);
private immutable Color fileAccent = Color.fromHex(0x78aee8);

int main(string[] args)
{
    WindowOptions options;
    options.title = "Aurora Windows File Manager";
    options.width = 1280;
    options.height = 760;
    options.darkTitleBar = true;
    auto window = new GuiWindow(options, explorerTheme());
    const initial = args.length > 1 ? args[1] : "";
    window.setRoot(new WindowsFileManagerRoot(window, initial));
    return window.run();
}
