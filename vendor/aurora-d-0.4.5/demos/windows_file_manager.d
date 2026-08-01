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
import std.utf : toUTF16, toUTF16z, toUTF32, toUTF8;

version (Windows)
{
    pragma(lib, "ole32.lib");
    pragma(lib, "shell32.lib");
    pragma(lib, "shlwapi.lib");
    import core.sys.windows.com : CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED,
        CoCreateInstance, CoInitializeEx, CoUninitialize, RPC_E_CHANGED_MODE,
        S_FALSE, S_OK;
    import core.sys.windows.objbase : CoTaskMemFree, STGM_READ;
    import core.sys.windows.objidl : IPersistFile;
    import core.sys.windows.shlobj : CSIDL_DESKTOPDIRECTORY, CSIDL_MYMUSIC,
        CSIDL_MYPICTURES, CSIDL_MYVIDEO, CSIDL_PERSONAL, CSIDL_PROFILE,
        CSIDL_RECENT, ILFree, IEnumIDList, IShellFolder, IShellLinkW,
        LPCITEMIDLIST, LPITEMIDLIST, SFGAOF, SHCONTF, SHGNO, SHGetDesktopFolder,
        SHGetFolderPathW, SHParseDisplayName, STRRET;
    import core.sys.windows.shellapi : ShellExecuteW;
    import core.sys.windows.shlwapi : StrRetToBufW;
    import core.sys.windows.uuid : CLSID_ShellLink, IID_IPersistFile, IID_IShellFolder,
        IID_IShellLinkW;
    import core.sys.windows.windows;

    private const GUID folderIdDownloads =
        {0x374DE290, 0x123F, 0x4565,
            [0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B]};

    extern (Windows) private HRESULT SHGetKnownFolderPath(const(GUID)* folderId,
        DWORD flags, HANDLE token, wchar** path);
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

private enum GroupBy
{
    none,
    dateModified
}

private enum NavigationKind
{
    quickAccess,
    folder,
    thisPc,
    network
}

private struct ExplorerEntry
{
    string name;
    string path;
    bool directory;
    bool drive;
    ulong size;
    string sizeText;
    string modified;
    string modifiedDay;
    string modifiedSortKey;
    string type;
    bool sizeKnown;
    bool quickAccessRecent;
}

private struct VisibleRow
{
    int entryIndex;
    string groupLabel;
    bool separator;
}

version (Windows)
private struct WindowsQuickAccessItem
{
    string path;
    string displayName;
    bool isFolder;
}

private struct NavigationItem
{
    string label;
    string path;
    IconKind icon;
    NavigationKind kind;
    bool enabled = true;
    bool pinned;
    int indentLevel;
}

version (Windows)
{
    private immutable wchar[] dragPreviewWindowClassName =
        "AuroraWindowsFileManagerDragPreview"w;
    private immutable wchar[] propertiesWindowClassName =
        "AuroraWindowsFileManagerProperties"w;
    private enum int dragPreviewCursorArrow = 32512;
    private enum DWORD dragPreviewLayerAlpha = 232;
    private enum DWORD errorClassAlreadyExists = 1410;
    private __gshared bool dragPreviewWindowClassRegistered;
    private __gshared bool propertiesWindowClassRegistered;

    private extern(Windows) nothrow LRESULT dragPreviewWindowProc(
        HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
    {
        DragPreviewOverlay overlay;
        if (message == WM_NCCREATE)
        {
            auto create = cast(CREATESTRUCTW*) lParam;
            overlay = cast(DragPreviewOverlay) create.lpCreateParams;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, cast(LONG_PTR) cast(void*) overlay);
        }
        else
            overlay = cast(DragPreviewOverlay) cast(void*)
                GetWindowLongPtrW(hwnd, GWLP_USERDATA);

        if (overlay !is null)
        {
            if (message == WM_PAINT)
            {
                overlay.paint(hwnd);
                return 0;
            }
            if (message == WM_ERASEBKGND)
                return 1;
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private bool registerDragPreviewWindowClass() nothrow
    {
        if (dragPreviewWindowClassRegistered) return true;

        WNDCLASSEXW wc;
        wc.cbSize = WNDCLASSEXW.sizeof;
        wc.style = CS_HREDRAW | CS_VREDRAW;
        wc.lpfnWndProc = &dragPreviewWindowProc;
        wc.hInstance = GetModuleHandleW(null);
        wc.hCursor = LoadCursorW(null, cast(LPCWSTR) dragPreviewCursorArrow);
        wc.lpszClassName = dragPreviewWindowClassName.ptr;

        if (RegisterClassExW(&wc) == 0 && GetLastError() != errorClassAlreadyExists)
            return false;
        dragPreviewWindowClassRegistered = true;
        return true;
    }

    private extern(Windows) nothrow LRESULT propertiesWindowProc(
        HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
    {
        PropertiesWindow window;
        if (message == WM_NCCREATE)
        {
            auto create = cast(CREATESTRUCTW*) lParam;
            window = cast(PropertiesWindow) create.lpCreateParams;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, cast(LONG_PTR) cast(void*) window);
        }
        else
            window = cast(PropertiesWindow) cast(void*)
                GetWindowLongPtrW(hwnd, GWLP_USERDATA);

        if (window !is null)
        {
            LRESULT result;
            if (window.handleMessage(hwnd, message, wParam, lParam, result))
                return result;
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private bool registerPropertiesWindowClass() nothrow
    {
        if (propertiesWindowClassRegistered) return true;

        WNDCLASSEXW wc;
        wc.cbSize = WNDCLASSEXW.sizeof;
        wc.style = CS_HREDRAW | CS_VREDRAW;
        wc.lpfnWndProc = &propertiesWindowProc;
        wc.hInstance = GetModuleHandleW(null);
        wc.hCursor = LoadCursorW(null, cast(LPCWSTR) dragPreviewCursorArrow);
        wc.lpszClassName = propertiesWindowClassName.ptr;

        if (RegisterClassExW(&wc) == 0 && GetLastError() != errorClassAlreadyExists)
            return false;
        propertiesWindowClassRegistered = true;
        return true;
    }
}

private final class DragPreviewOverlay
{
    version (Windows)
    {
        private HWND _hwnd;
        private string _label;
        private wstring _wideLabel;
        private bool _directory;
        private bool _visible;
        private int _width = 150;
        private int _height = 30;
    }

    void show(string label, bool directory)
    {
        version (Windows)
        {
            _label = label;
            _wideLabel = toUTF16(label);
            _directory = directory;
            _visible = true;
            update();
        }
    }

    void update()
    {
        version (Windows)
        {
            if (!_visible || !ensureWindow()) return;

            _width = clampPreviewInt(56 + cast(int) _label.length * 8, 150, 360);
            _height = 30;

            POINT cursor;
            if (GetCursorPos(&cursor) == FALSE) return;
            SetWindowPos(_hwnd, HWND_TOPMOST, cursor.x + 14, cursor.y + 18,
                _width, _height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
            InvalidateRect(_hwnd, null, FALSE);
            UpdateWindow(_hwnd);
        }
    }

    void hide()
    {
        version (Windows)
        {
            _visible = false;
            if (_hwnd !is null)
                ShowWindow(_hwnd, SW_HIDE);
        }
    }

    bool visible() const @safe pure nothrow @nogc
    {
        version (Windows)
            return _visible;
        else
            return false;
    }

    version (Windows)
    private bool ensureWindow()
    {
        if (_hwnd !is null) return true;
        if (!registerDragPreviewWindowClass()) return false;

        _hwnd = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_LAYERED,
            dragPreviewWindowClassName.ptr,
            null,
            WS_POPUP,
            0,
            0,
            _width,
            _height,
            null,
            null,
            GetModuleHandleW(null),
            cast(void*) this);
        if (_hwnd is null) return false;
        SetLayeredWindowAttributes(_hwnd, 0, cast(ubyte) dragPreviewLayerAlpha, LWA_ALPHA);
        return true;
    }

    version (Windows)
    void paint(HWND hwnd) nothrow
    {
        PAINTSTRUCT ps;
        auto dc = BeginPaint(hwnd, &ps);
        if (dc !is null)
        {
            RECT client;
            GetClientRect(hwnd, &client);
            fillPreviewRect(dc, client, previewRgb(32, 32, 32));
            fillPreviewRect(dc, RECT(0, 0, client.right, 1), previewRgb(116, 144, 178));
            fillPreviewRect(dc, RECT(0, client.bottom - 1, client.right, client.bottom),
                previewRgb(58, 76, 96));
            fillPreviewRect(dc, RECT(0, 0, 1, client.bottom), previewRgb(58, 76, 96));
            fillPreviewRect(dc, RECT(client.right - 1, 0, client.right, client.bottom),
                previewRgb(58, 76, 96));

            if (_directory)
            {
                fillPreviewRect(dc, RECT(9, 8, 21, 14), previewRgb(245, 205, 82));
                fillPreviewRect(dc, RECT(9, 12, 29, 24), previewRgb(235, 174, 38));
                fillPreviewRect(dc, RECT(11, 14, 29, 24), previewRgb(251, 214, 76));
            }
            else
            {
                fillPreviewRect(dc, RECT(11, 6, 27, 24), previewRgb(220, 226, 233));
                fillPreviewRect(dc, RECT(20, 6, 27, 13), previewRgb(178, 191, 205));
                fillPreviewRect(dc, RECT(13, 15, 25, 17), previewRgb(95, 145, 205));
                fillPreviewRect(dc, RECT(13, 20, 24, 22), previewRgb(124, 135, 148));
            }

            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, previewRgb(245, 247, 249));
            RECT textRect = RECT(36, 0, maxPreviewInt(36, client.right - 8), client.bottom);
            DrawTextW(dc, _wideLabel.ptr, cast(int) _wideLabel.length,
                &textRect, cast(UINT) (DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS));
        }
        EndPaint(hwnd, &ps);
    }

    version (Windows)
    private static void fillPreviewRect(HDC dc, RECT rect, COLORREF color) nothrow
    {
        auto brush = CreateSolidBrush(color);
        if (brush !is null)
        {
            FillRect(dc, &rect, brush);
            DeleteObject(brush);
        }
    }

    version (Windows)
    private static COLORREF previewRgb(ubyte r, ubyte g, ubyte b)
        @safe pure nothrow @nogc
    {
        return cast(COLORREF) (cast(uint) r | (cast(uint) g << 8) | (cast(uint) b << 16));
    }

    version (Windows)
    private static int clampPreviewInt(int value, int minimum, int maximum)
        @safe pure nothrow @nogc
    {
        if (value < minimum) return minimum;
        if (value > maximum) return maximum;
        return value;
    }

    version (Windows)
    private static int maxPreviewInt(int a, int b) @safe pure nothrow @nogc
    {
        return a > b ? a : b;
    }
}

version (Windows)
private final class PropertiesWindow
{
    private static immutable wchar[] fontName = "Segoe UI"w;
    private enum int titleBarHeight = 40;
    private HWND _hwnd;
    private string _path;
    private wstring _wideTitle;
    private wstring _wideName;
    private wstring _wideType;
    private wstring _wideLocation;
    private wstring _wideSize;
    private wstring _wideModified;
    private wstring _widePath;
    private string _copyStatus;
    private int _hoverButton = -1;
    private int _width = 560;
    private int _height = 410;

    bool visible() const @safe pure nothrow @nogc
    {
        return _hwnd !is null;
    }

    void show(string path, string name, string type, string location, string size,
        string modified)
    {
        _path = path;
        _wideName = toUTF16(name);
        _wideType = toUTF16(type);
        _wideLocation = toUTF16(location);
        _wideSize = toUTF16(size);
        _wideModified = toUTF16(modified);
        _widePath = toUTF16(path);
        _copyStatus = "";

        const title = "Properties - " ~ name;
        _wideTitle = toUTF16(title);
        if (_hwnd is null)
        {
            if (!registerPropertiesWindowClass()) return;
            HWND owner = GetActiveWindow();
            if (owner is null) owner = GetForegroundWindow();

            int x = maxInt(0, (GetSystemMetrics(SM_CXSCREEN) - _width) / 2);
            int y = maxInt(0, (GetSystemMetrics(SM_CYSCREEN) - _height) / 2);
            RECT ownerRect;
            if (owner !is null && GetWindowRect(owner, &ownerRect) != FALSE)
            {
                x = ownerRect.left + (ownerRect.right - ownerRect.left - _width) / 2;
                y = ownerRect.top + (ownerRect.bottom - ownerRect.top - _height) / 2;
            }

            const style = WS_POPUP | WS_SYSMENU;
            _hwnd = CreateWindowExW(
                WS_EX_TOOLWINDOW,
                propertiesWindowClassName.ptr,
                title.toUTF16z,
                style,
                x,
                y,
                _width,
                _height,
                owner,
                null,
                GetModuleHandleW(null),
                cast(void*) this);
            if (_hwnd is null) return;
        }
        else
            SetWindowTextW(_hwnd, title.toUTF16z);

        SetWindowPos(_hwnd, HWND_TOP, 0, 0, _width, _height,
            SWP_NOMOVE | SWP_SHOWWINDOW);
        ShowWindow(_hwnd, SW_SHOWNORMAL);
        SetForegroundWindow(_hwnd);
        InvalidateRect(_hwnd, null, FALSE);
        UpdateWindow(_hwnd);
    }

    void close()
    {
        if (_hwnd !is null)
            DestroyWindow(_hwnd);
    }

    bool handleMessage(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam,
        out LRESULT result) nothrow
    {
        result = 0;
        switch (message)
        {
            case WM_PAINT:
                paint(hwnd);
                return true;
            case WM_ERASEBKGND:
                result = 1;
                return true;
            case WM_MOUSEMOVE:
            {
                RECT client;
                GetClientRect(hwnd, &client);
                const x = cast(int) cast(short) (lParam & 0xffff);
                const y = cast(int) cast(short) ((lParam >> 16) & 0xffff);
                const next = buttonAt(client, x, y);
                if (next != _hoverButton)
                {
                    _hoverButton = next;
                    InvalidateRect(hwnd, null, FALSE);
                }
                return true;
            }
            case WM_LBUTTONDOWN:
            {
                RECT client;
                GetClientRect(hwnd, &client);
                const x = cast(int) cast(short) (lParam & 0xffff);
                const y = cast(int) cast(short) ((lParam >> 16) & 0xffff);
                if (contains(titleBarDragRect(client), x, y))
                {
                    ReleaseCapture();
                    SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
                    return true;
                }
                break;
            }
            case WM_MOUSELEAVE:
                _hoverButton = -1;
                InvalidateRect(hwnd, null, FALSE);
                return true;
            case WM_LBUTTONUP:
            {
                RECT client;
                GetClientRect(hwnd, &client);
                const x = cast(int) cast(short) (lParam & 0xffff);
                const y = cast(int) cast(short) ((lParam >> 16) & 0xffff);
                const button = buttonAt(client, x, y);
                if (button == 0) copyPath();
                else if (button == 1) DestroyWindow(hwnd);
                else if (button == 2) DestroyWindow(hwnd);
                return true;
            }
            case WM_KEYDOWN:
                if (wParam == VK_ESCAPE)
                {
                    DestroyWindow(hwnd);
                    return true;
                }
                break;
            case WM_NCDESTROY:
                _hwnd = null;
                _hoverButton = -1;
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
                break;
            default:
                break;
        }
        return false;
    }

    private void paint(HWND hwnd) nothrow
    {
        PAINTSTRUCT ps;
        auto dc = BeginPaint(hwnd, &ps);
        if (dc !is null)
        {
            RECT client;
            GetClientRect(hwnd, &client);
            fillRect(dc, client, rgb(32, 32, 32));
            drawTitleBar(dc, client, _wideTitle, _hoverButton == 2);

            drawText(dc, _wideName, RECT(20, 58, client.right - 20, 88),
                rgb(245, 247, 249), true, 17);
            drawRow(dc, "Type"w, _wideType, 108, client.right);
            drawRow(dc, "Location"w, _wideLocation, 144, client.right);
            drawRow(dc, "Size"w, _wideSize, 180, client.right);
            drawRow(dc, "Modified"w, _wideModified, 216, client.right);
            drawRow(dc, "Path"w, _widePath, 252, client.right);

            if (_copyStatus.length > 0)
                drawText(dc, toUTF16(_copyStatus),
                    RECT(20, client.bottom - 76, client.right - 20, client.bottom - 50),
                    rgb(167, 167, 167), false, 12);

            const copy = copyButtonRect(client);
            const close = closeButtonRect(client);
            drawButton(dc, copy, "Copy path"w, _hoverButton == 0);
            drawButton(dc, close, "Close"w, _hoverButton == 1);
            drawWindowBorder(dc, client);
        }
        EndPaint(hwnd, &ps);
    }

    private void copyPath() nothrow
    {
        try
        {
            _copyStatus = writeClipboardText(_path)
                ? "Path copied to clipboard." : "Clipboard is unavailable.";
        }
        catch (Exception)
        {
            _copyStatus = "Clipboard is unavailable.";
        }
        if (_hwnd !is null)
        {
            InvalidateRect(_hwnd, null, FALSE);
            UpdateWindow(_hwnd);
        }
    }

    private static int buttonAt(RECT client, int x, int y) @safe pure nothrow @nogc
    {
        if (contains(copyButtonRect(client), x, y)) return 0;
        if (contains(closeButtonRect(client), x, y)) return 1;
        if (contains(titleCloseButtonRect(client), x, y)) return 2;
        return -1;
    }

    private static RECT titleCloseButtonRect(RECT client) @safe pure nothrow @nogc
    {
        return RECT(client.right - 46, 0, client.right, titleBarHeight);
    }

    private static RECT titleBarDragRect(RECT client) @safe pure nothrow @nogc
    {
        return RECT(0, 0, maxInt(0, client.right - 46), titleBarHeight);
    }

    private static RECT copyButtonRect(RECT client) @safe pure nothrow @nogc
    {
        return RECT(client.right - 202, client.bottom - 46, client.right - 108,
            client.bottom - 12);
    }

    private static RECT closeButtonRect(RECT client) @safe pure nothrow @nogc
    {
        return RECT(client.right - 98, client.bottom - 46, client.right - 12,
            client.bottom - 12);
    }

    private static bool contains(RECT rect, int x, int y) @safe pure nothrow @nogc
    {
        return x >= rect.left && x < rect.right && y >= rect.top && y < rect.bottom;
    }

    private static void drawTitleBar(HDC dc, RECT client, const(wchar)[] title,
        bool closeHovered) nothrow
    {
        const titleRect = RECT(0, 0, client.right, titleBarHeight);
        fillRect(dc, titleRect, rgb(38, 38, 38));
        fillRect(dc, RECT(0, titleBarHeight - 1, client.right, titleBarHeight),
            rgb(58, 58, 58));
        drawText(dc, title, RECT(14, 0, maxInt(14, client.right - 58),
            titleBarHeight), rgb(242, 242, 242), false, 12);

        const close = titleCloseButtonRect(client);
        fillRect(dc, close, closeHovered ? rgb(196, 43, 28) : rgb(38, 38, 38));
        auto pen = CreatePen(PS_SOLID, 1, rgb(242, 242, 242));
        auto oldPen = SelectObject(dc, pen);
        const cx = (close.left + close.right) / 2;
        const cy = (close.top + close.bottom) / 2;
        MoveToEx(dc, cx - 5, cy - 5, null);
        LineTo(dc, cx + 6, cy + 6);
        MoveToEx(dc, cx + 5, cy - 5, null);
        LineTo(dc, cx - 6, cy + 6);
        SelectObject(dc, oldPen);
        if (pen !is null) DeleteObject(pen);
    }

    private static void drawRow(HDC dc, const(wchar)[] label, const(wchar)[] value,
        int y, int right) nothrow
    {
        drawText(dc, label, RECT(20, y, 132, y + 28), rgb(167, 167, 167), false, 12);
        drawText(dc, value, RECT(145, y, maxInt(145, right - 20), y + 28),
            rgb(242, 242, 242), false, 12);
    }

    private static void drawButton(HDC dc, RECT rect, const(wchar)[] label,
        bool hovered) nothrow
    {
        const background = hovered ? rgb(53, 53, 53) : rgb(32, 32, 32);
        fillRect(dc, rect, background);
        auto pen = CreatePen(PS_SOLID, 1, rgb(90, 90, 90));
        auto oldPen = SelectObject(dc, pen);
        auto oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH));
        Rectangle(dc, rect.left, rect.top, rect.right, rect.bottom);
        SelectObject(dc, oldBrush);
        SelectObject(dc, oldPen);
        if (pen !is null) DeleteObject(pen);
        drawText(dc, label, rect, rgb(242, 242, 242), false, 12);
    }

    private static void drawWindowBorder(HDC dc, RECT client) nothrow
    {
        auto pen = CreatePen(PS_SOLID, 1, rgb(74, 74, 74));
        auto oldPen = SelectObject(dc, pen);
        auto oldBrush = SelectObject(dc, GetStockObject(NULL_BRUSH));
        Rectangle(dc, 0, 0, client.right, client.bottom);
        SelectObject(dc, oldBrush);
        SelectObject(dc, oldPen);
        if (pen !is null) DeleteObject(pen);
    }

    private static void drawText(HDC dc, const(wchar)[] text, RECT rect,
        COLORREF color, bool bold, int size) nothrow
    {
        auto font = CreateFontW(-size, 0, 0, 0, bold ? FW_SEMIBOLD : FW_NORMAL,
            FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
            CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
            fontName.ptr);
        auto oldFont = SelectObject(dc, font);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, color);
        DrawTextW(dc, text.ptr, cast(int) text.length, &rect,
            cast(UINT) (DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS));
        SelectObject(dc, oldFont);
        if (font !is null) DeleteObject(font);
    }

    private static void fillRect(HDC dc, RECT rect, COLORREF color) nothrow
    {
        auto brush = CreateSolidBrush(color);
        if (brush !is null)
        {
            FillRect(dc, &rect, brush);
            DeleteObject(brush);
        }
    }

    private static COLORREF rgb(ubyte r, ubyte g, ubyte b)
        @safe pure nothrow @nogc
    {
        return cast(COLORREF) (cast(uint) r | (cast(uint) g << 8) | (cast(uint) b << 16));
    }
}

final class WindowsFileManagerRoot : Widget
{
    private enum defaultUiZoomPercent = 80;
    private enum minimumUiZoomPercent = 80;
    private enum maximumUiZoomPercent = 125;
    private enum ribbonHeight = 34;
    private enum addressHeight = 40;
    private enum statusHeight = 26;
    private enum sidebarMinimumWidth = 228;
    private enum sidebarMaximumWidth = 330;
    private enum rowHeight = 25;
    private enum groupHeaderHeight = 28;
    private enum quickAccessSeparatorHeight = 12;
    private enum quickAccessFrequentFolderLimit = 24;
    private enum quickAccessRecentFileLimit = 20;
    private enum maximumSearchDepth = 64;
    private enum maximumSearchResults = 10000;
    private enum double autoRefreshIntervalSeconds = 1.0;
    private enum sidebarRowHeight = 27;
    private enum headerHeight = 34;
    private enum scrollbarWidth = 12;

    private GuiWindow _window;
    private TextField _addressField;
    private TextField _searchField;
    private ContextMenu _homeMenu;
    private DragPreviewOverlay _dragPreviewOverlay;
    version (Windows)
        private PropertiesWindow _propertiesWindow;
    private ExplorerEntry[] _entries;
    private ExplorerEntry[] _folderEntries;
    private VisibleRow[] _visibleRows;
    private int[] _visibleRowOffsets;
    private int _visibleContentHeight;
    private NavigationItem[] _navigation;
    private string _currentPath;
    private bool _showQuickAccess;
    private bool _showThisPc;
    private string _searchQuery;
    private string _statusText = "Ready";
    private string[] _recentFiles;
    private string[] _history;
    private int _historyIndex = -1;
    private int _uiZoomPercent = defaultUiZoomPercent;
    private int _selectedVisibleIndex = -1;
    private SortColumn _sortColumn = SortColumn.name;
    private bool _sortAscending = true;
    private GroupBy _groupBy = GroupBy.none;
    private bool _groupAscending;
    private int _scrollY;
    private int _sidebarScrollY;
    private double _autoRefreshClock;
    private string _watchedFolderPath;
    private ulong _watchedFolderFingerprint;
    private size_t _watchedFolderCount;
    private bool _watchedFolderValid;
    version (Windows)
        private HANDLE _folderChangeHandle;
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
    private Rect _homeTabRect;
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
            updateSearchResults();
        };
        _searchField.onSubmitted = delegate()
        {
            requestFocus();
        };

        rebuildNavigation();
        navigate(initialPath.length > 0 ? initialPath : getcwd(), true, true);
    }

    ~this()
    {
        version (Windows)
            closeFolderChangeNotification();
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

    protected override void onTick(double deltaSeconds)
    {
        pollFolderAutoRefresh(deltaSeconds);
    }

    override bool onMouseDown(ref Event event)
    {
        updateGeometry();
        if (event.button == MouseButton.right)
        {
            requestFocus();
            showContextMenuFor(event.position);
            return true;
        }
        if (event.button != MouseButton.left) return false;
        requestFocus();

        if (_homeTabRect.contains(event.position))
        {
            showHomeMenu();
            return true;
        }

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

        const visibleIndex = visibleEntryIndexAt(event.position);
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
        if (!event.control() && !event.meta() && !event.alt() &&
            handleListNavigationKey(event.key))
            return true;
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
            showExternalDragPreview();
        }
        if (_draggingEntry)
        {
            updateDropTargets(position);
            updateExternalDragPreview();
        }
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

        const visibleIndex = visibleEntryIndexAt(position);
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
        hideExternalDragPreview();
        _pendingEntryDrag = false;
        _draggingEntry = false;
        _dragSourceVisibleIndex = -1;
        _dropTargetVisibleIndex = -1;
        _dropTargetNavigationIndex = -1;
        if (redraw) invalidate();
    }

    private DragPreviewOverlay dragPreviewOverlay()
    {
        if (_dragPreviewOverlay is null)
            _dragPreviewOverlay = new DragPreviewOverlay();
        return _dragPreviewOverlay;
    }

    private void showExternalDragPreview()
    {
        if (!hasDragSource()) return;
        const entry = dragSourceEntry();
        dragPreviewOverlay().show(entry.name, entry.directory);
    }

    private void updateExternalDragPreview()
    {
        if (_dragPreviewOverlay !is null)
            _dragPreviewOverlay.update();
    }

    private void hideExternalDragPreview()
    {
        if (_dragPreviewOverlay !is null)
            _dragPreviewOverlay.hide();
    }

    private int entryIndexForVisibleRow(int visibleIndex) const
    {
        if (visibleIndex < 0 || visibleIndex >= cast(int) _visibleRows.length)
            return -1;
        return _visibleRows[cast(size_t) visibleIndex].entryIndex;
    }

    private int visibleRowHeight(int visibleIndex) const
    {
        if (visibleIndex < 0 || visibleIndex >= cast(int) _visibleRows.length)
            return 0;
        if (entryIndexForVisibleRow(visibleIndex) >= 0)
            return rowHeightPx();
        return _visibleRows[cast(size_t) visibleIndex].separator
            ? quickAccessSeparatorHeightPx() : groupHeaderHeightPx();
    }

    private int visibleItemCount() const
    {
        int count;
        foreach (row; _visibleRows)
            if (row.entryIndex >= 0)
                ++count;
        return count;
    }

    private bool handleListNavigationKey(Key key)
    {
        if (visibleItemCount() == 0) return false;

        int target = -1;
        switch (key)
        {
            case Key.up:
                target = _selectedVisibleIndex < 0
                    ? lastEntryVisibleIndex()
                    : adjacentEntryVisibleIndex(_selectedVisibleIndex, -1);
                break;
            case Key.down:
                target = _selectedVisibleIndex < 0
                    ? firstEntryVisibleIndex()
                    : adjacentEntryVisibleIndex(_selectedVisibleIndex, 1);
                break;
            case Key.pageUp:
                target = pageEntryVisibleIndex(-1);
                break;
            case Key.pageDown:
                target = pageEntryVisibleIndex(1);
                break;
            case Key.home:
                target = firstEntryVisibleIndex();
                break;
            case Key.end:
                target = lastEntryVisibleIndex();
                break;
            default:
                return false;
        }

        if (target < 0) return true;
        selectVisibleEntryByKeyboard(target);
        return true;
    }

    private int firstEntryVisibleIndex() const
    {
        foreach (index, row; _visibleRows)
            if (row.entryIndex >= 0)
                return cast(int) index;
        return -1;
    }

    private int lastEntryVisibleIndex() const
    {
        for (size_t index = _visibleRows.length; index > 0; --index)
            if (_visibleRows[index - 1].entryIndex >= 0)
                return cast(int) index - 1;
        return -1;
    }

    private int adjacentEntryVisibleIndex(int start, int direction) const
    {
        int index = start + direction;
        while (index >= 0 && index < cast(int) _visibleRows.length)
        {
            if (_visibleRows[cast(size_t) index].entryIndex >= 0)
                return index;
            index += direction;
        }
        return direction < 0 ? firstEntryVisibleIndex() : lastEntryVisibleIndex();
    }

    private int pageEntryVisibleIndex(int direction) const
    {
        int current = _selectedVisibleIndex;
        if (current < 0)
            return direction < 0 ? lastEntryVisibleIndex() : firstEntryVisibleIndex();

        const stepCount = maxInt(1, _rowsRect.height / rowHeightPx());
        foreach (_; 0 .. stepCount)
        {
            const next = adjacentEntryVisibleIndex(current, direction);
            if (next == current || next < 0) break;
            current = next;
        }
        return current;
    }

    private void selectVisibleEntryByKeyboard(int visibleIndex)
    {
        if (entryIndexForVisibleRow(visibleIndex) < 0) return;
        _selectedVisibleIndex = visibleIndex;
        ensureSelectionVisible();
        updateSelectedStatus();
        invalidate();
    }

    private bool hasDragSource() const
    {
        return _dragSourceVisibleIndex >= 0 &&
            _dragSourceVisibleIndex < cast(int) _visibleRows.length &&
            entryIndexForVisibleRow(_dragSourceVisibleIndex) >= 0;
    }

    private ExplorerEntry dragSourceEntry() const
    {
        if (!hasDragSource()) return ExplorerEntry.init;
        return _entries[cast(size_t) entryIndexForVisibleRow(_dragSourceVisibleIndex)];
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

        const visibleIndex = visibleEntryIndexAt(point);
        if (isEntryDropTarget(visibleIndex, sourcePath))
        {
            const entry = _entries[cast(size_t) entryIndexForVisibleRow(visibleIndex)];
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
        const entryIndex = entryIndexForVisibleRow(visibleIndex);
        if (entryIndex < 0) return false;
        const entry = _entries[cast(size_t) entryIndex];
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
        rebuildVisibleRowOffsets();
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

    private int commandButtonWidth(string label) const @safe pure nothrow @nogc
    {
        return maxInt(scaled(96), scaled(46) + cast(int) label.length * scaled(8));
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

    private int groupHeaderHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(24, scaled(groupHeaderHeight));
    }

    private int quickAccessSeparatorHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(8, scaled(quickAccessSeparatorHeight));
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
        _homeTabRect = Rect(scaled(82), 0, scaled(62), ribbon);
        _newFolderRect = Rect.init;
        _newTextFileRect = Rect.init;
        _openSelectedRect = Rect.init;
        _copyPathRect = Rect.init;

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

        addNavigation("Quick Access", "", IconKind.open, false,
            NavigationKind.quickAccess, true);
        addNavigation("Personal", home, IconKind.folder, true);
        addNavigation("Desktop", buildNormalizedPath(home, "Desktop"), IconKind.computer, true);
        addNavigation("Downloads", buildNormalizedPath(home, "Downloads"), IconKind.open, true);
        addNavigation("Documents", documents, IconKind.notepad, true);
        addNavigation("Pictures", buildNormalizedPath(home, "Pictures"), IconKind.image, true);
        addNavigation("Videos", buildNormalizedPath(home, "Videos"), IconKind.music, true);
        addDocumentFolders(documents, 12);
        addNavigation("OneDrive - Personal", buildNormalizedPath(home, "OneDrive"), IconKind.drive, false);
        addNavigation("This PC", "", IconKind.computer, false,
            NavigationKind.thisPc, true);
        addThisPcNavigationChildren();
        addNavigation("Network", "", IconKind.drive, false, NavigationKind.network, true);
    }

    private void addNavigation(string label, string path, IconKind icon, bool pinned,
        NavigationKind kind = NavigationKind.folder, bool forceEnabled = false,
        int indentLevel = -1)
    {
        NavigationItem item;
        item.label = label;
        item.path = path;
        item.icon = icon;
        item.kind = kind;
        item.pinned = pinned;
        item.indentLevel = indentLevel >= 0 ? indentLevel : (pinned ? 1 : 0);
        item.enabled = forceEnabled || (path.length > 0 && exists(path) && isDir(path));
        _navigation ~= item;
    }

    private void addThisPcNavigationChildren()
    {
        const entries = buildThisPcEntries();
        bool[] added;
        added.length = entries.length;

        foreach (label; [
            "3D Objects",
            "Desktop",
            "Documents",
            "Downloads",
            "Music",
            "Pictures",
            "Videos"
        ])
        {
            foreach (index, entry; entries)
            {
                if (added[index] || icmp(entry.name, label) != 0) continue;
                addThisPcNavigationEntry(entry);
                added[index] = true;
                break;
            }
        }

        foreach (index, entry; entries)
        {
            if (added[index]) continue;
            addThisPcNavigationEntry(entry);
        }
    }

    private void addThisPcNavigationEntry(ExplorerEntry entry)
    {
        if (entry.path.length == 0) return;
        addNavigation(entry.name, entry.path, thisPcNavigationIcon(entry), false,
            NavigationKind.folder, true, 1);
    }

    private static IconKind thisPcNavigationIcon(ExplorerEntry entry)
    {
        if (entry.drive) return IconKind.drive;
        if (icmp(entry.name, "Desktop") == 0) return IconKind.computer;
        if (icmp(entry.name, "Documents") == 0) return IconKind.notepad;
        if (icmp(entry.name, "Downloads") == 0) return IconKind.open;
        if (icmp(entry.name, "Music") == 0) return IconKind.music;
        if (icmp(entry.name, "Pictures") == 0) return IconKind.image;
        if (icmp(entry.name, "Videos") == 0) return IconKind.music;
        return IconKind.folder;
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
                    nav.indentLevel = 1;
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
        const enteringNewFolder = _currentPath.length == 0 || !pathsEqual(_currentPath, path);
        try
        {
            if (!exists(path) || !isDir(path))
            {
                _statusText = "Not a folder: " ~ path;
                invalidate();
                return;
            }

            _showQuickAccess = false;
            _showThisPc = false;
            ExplorerEntry[] entries;
            foreach (DirEntry item; dirEntries(path, SpanMode.shallow))
            {
                ExplorerEntry entry;
                if (!populateExplorerEntry(item, "", entry)) continue;
                entries ~= entry;
            }
            if (enteringNewFolder)
                applyDefaultViewForPath(path);
            _folderEntries = entries;
            _entries = entries;
            _currentPath = path;
            _selectedVisibleIndex = -1;
            _scrollY = 0;
            resetFolderWatch(path);

            if (clearSearch)
            {
                _searchQuery = "";
                _searchField.setText("", false);
            }
            _addressField.setText(path, false);
            _searchField.setPlaceholder(searchPlaceholder());

            if (addHistory)
                pushHistory(path);
            updateSearchResults();
            updateWindowTitle();
        }
        catch (Exception error)
        {
            _statusText = "Cannot open folder: " ~ error.msg;
            invalidate();
        }
    }

    private void applyDefaultViewForPath(string path)
    {
        if (isDownloadsPath(path))
        {
            _groupBy = GroupBy.dateModified;
            _groupAscending = false;
            _sortColumn = SortColumn.modified;
            _sortAscending = false;
        }
        else
        {
            _groupBy = GroupBy.none;
            _groupAscending = false;
            _sortColumn = SortColumn.name;
            _sortAscending = true;
        }
    }

    private static bool isDownloadsPath(string path)
    {
        const current = getcwd();
        const home = environment.get("USERPROFILE", environment.get("HOME", current));
        return pathsEqual(path, buildNormalizedPath(home, "Downloads"));
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

    private void updateSearchResults()
    {
        _selectedVisibleIndex = -1;
        _scrollY = 0;
        if (_showQuickAccess || _showThisPc)
            _entries = _folderEntries.dup;
        else if (_searchQuery.length == 0)
            _entries = _folderEntries.dup;
        else
            _entries = recursiveSearchEntries(_currentPath, _searchQuery.toLower());
        if (!_showQuickAccess)
            sortEntries(_entries);
        rebuildVisibleEntries();
    }

    private void clearFolderWatch()
    {
        version (Windows)
            closeFolderChangeNotification();
        _autoRefreshClock = 0.0;
        _watchedFolderPath = "";
        _watchedFolderFingerprint = 0;
        _watchedFolderCount = 0;
        _watchedFolderValid = false;
    }

    private void resetFolderWatch(string path)
    {
        clearFolderWatch();
        ulong fingerprint;
        size_t count;
        if (folderSnapshot(path, fingerprint, count))
        {
            setFolderWatchBaseline(path, fingerprint, count);
            version (Windows)
                startFolderChangeNotification(path);
        }
    }

    private void setFolderWatchBaseline(string path, ulong fingerprint, size_t count)
    {
        _watchedFolderPath = path;
        _watchedFolderFingerprint = fingerprint;
        _watchedFolderCount = count;
        _watchedFolderValid = true;
    }

    private void pollFolderAutoRefresh(double deltaSeconds)
    {
        if (_showQuickAccess || _showThisPc || _currentPath.length == 0)
        {
            if (_watchedFolderValid) clearFolderWatch();
            return;
        }
        if (_pendingEntryDrag || _draggingEntry)
            return;

        bool shouldCheck;
        bool forceRefresh;
        version (Windows)
        {
            if (folderChangeNotificationActive())
            {
                if (!folderChangeNotificationPending())
                    return;
                shouldCheck = true;
                forceRefresh = _searchQuery.length > 0;
            }
            else
            {
                _autoRefreshClock += deltaSeconds;
                if (_autoRefreshClock < autoRefreshIntervalSeconds)
                    return;
                _autoRefreshClock = 0.0;
                shouldCheck = true;
            }
        }
        else
        {
            _autoRefreshClock += deltaSeconds;
            if (_autoRefreshClock < autoRefreshIntervalSeconds)
                return;
            _autoRefreshClock = 0.0;
            shouldCheck = true;
        }
        if (!shouldCheck) return;

        ulong fingerprint;
        size_t count;
        const valid = folderSnapshot(_currentPath, fingerprint, count);
        if (!valid)
        {
            if (_watchedFolderValid)
            {
                _watchedFolderValid = false;
                _statusText = "Folder is no longer available: " ~ _currentPath;
                invalidate();
            }
            return;
        }

        if (!_watchedFolderValid || !pathsEqual(_watchedFolderPath, _currentPath))
        {
            setFolderWatchBaseline(_currentPath, fingerprint, count);
            return;
        }

        if (forceRefresh || fingerprint != _watchedFolderFingerprint ||
            count != _watchedFolderCount)
            autoRefreshCurrentFolder(fingerprint, count);
    }

    private void autoRefreshCurrentFolder(ulong fingerprint, size_t count)
    {
        const path = _currentPath;
        const selectedPath = hasSelection() ? selectedEntry().path : "";
        const savedScroll = _scrollY;
        const savedSidebarScroll = _sidebarScrollY;
        navigate(path, false, false);
        setFolderWatchBaseline(path, fingerprint, count);
        if (selectedPath.length > 0)
            selectPath(selectedPath);
        setListScroll(savedScroll);
        setSidebarScroll(savedSidebarScroll);
    }

    version (Windows)
    private void startFolderChangeNotification(string path)
    {
        closeFolderChangeNotification();
        if (path.length == 0) return;
        const filter = FILE_NOTIFY_CHANGE_FILE_NAME |
            FILE_NOTIFY_CHANGE_DIR_NAME |
            FILE_NOTIFY_CHANGE_ATTRIBUTES |
            FILE_NOTIFY_CHANGE_SIZE |
            FILE_NOTIFY_CHANGE_LAST_WRITE |
            FILE_NOTIFY_CHANGE_CREATION;
        auto handle = FindFirstChangeNotificationW(path.toUTF16z, FALSE, filter);
        if (handle !is null && handle != INVALID_HANDLE_VALUE)
            _folderChangeHandle = handle;
    }

    version (Windows)
    private void closeFolderChangeNotification()
    {
        if (_folderChangeHandle !is null &&
            _folderChangeHandle != INVALID_HANDLE_VALUE)
            FindCloseChangeNotification(_folderChangeHandle);
        _folderChangeHandle = null;
    }

    version (Windows)
    private bool folderChangeNotificationActive() const @safe pure nothrow @nogc
    {
        return _folderChangeHandle !is null &&
            _folderChangeHandle != INVALID_HANDLE_VALUE;
    }

    version (Windows)
    private bool folderChangeNotificationPending()
    {
        if (!folderChangeNotificationActive()) return false;
        const waitResult = WaitForSingleObject(_folderChangeHandle, 0);
        if (waitResult == WAIT_OBJECT_0)
        {
            if (FindNextChangeNotification(_folderChangeHandle) == FALSE)
                closeFolderChangeNotification();
            return true;
        }
        if (waitResult == WAIT_FAILED)
        {
            closeFolderChangeNotification();
            return true;
        }
        return false;
    }

    private static bool folderSnapshot(string path, out ulong fingerprint,
        out size_t count)
    {
        fingerprint = 14695981039346656037UL;
        count = 0;
        if (path.length == 0) return false;
        try
        {
            if (!exists(path) || !isDir(path))
                return false;
        }
        catch (Exception)
        {
            return false;
        }

        string[] signatures;
        try
        {
            foreach (DirEntry item; dirEntries(path, SpanMode.shallow))
            {
                signatures ~= folderSnapshotEntry(item);
                ++count;
            }
        }
        catch (Exception)
        {
            return false;
        }

        sort(signatures);
        foreach (signature; signatures)
            mixFolderHash(fingerprint, signature);
        mixFolderHash(fingerprint, cast(ulong) count);
        return true;
    }

    private static string folderSnapshotEntry(DirEntry item)
    {
        bool directory;
        ulong size;
        string modified;
        try
        {
            directory = item.isDir;
            if (!directory) size = item.size;
            modified = format("%s", item.timeLastModified);
        }
        catch (Exception)
        {
        }
        return item.name ~ "\t" ~ (directory ? "d" : "f") ~ "\t" ~
            format("%d", size) ~ "\t" ~ modified;
    }

    private static void mixFolderHash(ref ulong hash, const(char)[] value)
        @safe pure nothrow @nogc
    {
        foreach (ch; value)
        {
            hash ^= cast(ubyte) ch;
            hash *= 1099511628211UL;
        }
        hash ^= 0xFF;
        hash *= 1099511628211UL;
    }

    private static void mixFolderHash(ref ulong hash, ulong value)
        @safe pure nothrow @nogc
    {
        foreach (shift; 0 .. 64 / 8)
        {
            hash ^= cast(ubyte) (value >> (shift * 8));
            hash *= 1099511628211UL;
        }
    }

    private static ExplorerEntry[] recursiveSearchEntries(string root, string loweredQuery)
    {
        ExplorerEntry[] results;
        bool[string] visited;
        collectSearchEntries(root, root, loweredQuery, results, visited, 0);
        return results;
    }

    private static void collectSearchEntries(string root, string folder, string loweredQuery,
        ref ExplorerEntry[] results, ref bool[string] visited, int depth)
    {
        if (depth > maximumSearchDepth || results.length >= maximumSearchResults)
            return;

        const normalizedFolder = buildNormalizedPath(folder);
        if (normalizedFolder in visited) return;
        visited[normalizedFolder] = true;

        try
        {
            foreach (DirEntry item; dirEntries(folder, SpanMode.shallow))
            {
                ExplorerEntry entry;
                if (!populateExplorerEntry(item, relativeSearchName(root, item.name), entry))
                    continue;
                if (containsInsensitive(baseName(item.name), loweredQuery))
                    results ~= entry;
                if (entry.directory)
                    collectSearchEntries(root, item.name, loweredQuery, results, visited,
                        depth + 1);
                if (results.length >= maximumSearchResults)
                    return;
            }
        }
        catch (Exception)
        {
        }
    }

    private static bool populateExplorerEntry(DirEntry item, string displayName,
        out ExplorerEntry entry)
    {
        entry = ExplorerEntry.init;
        entry.path = item.name;
        entry.name = displayName.length > 0 ? displayName : baseName(item.name);
        if (entry.name.length == 0) entry.name = item.name;
        try
        {
            entry.directory = item.isDir;
            if (!entry.directory)
            {
                entry.size = item.size;
                entry.sizeKnown = true;
            }
            entry.modified = modifiedText(item);
            entry.modifiedSortKey = modifiedSortKey(item);
            entry.modifiedDay = entry.modifiedSortKey.length >= 10
                ? entry.modifiedSortKey[0 .. 10] : "Unknown date";
            entry.type = typeText(entry.name, entry.directory);
            return true;
        }
        catch (Exception)
        {
            entry = ExplorerEntry.init;
            return false;
        }
    }

    private static string relativeSearchName(string root, string path)
    {
        const normalizedRoot = ensureTrailingSeparator(buildNormalizedPath(root));
        const normalizedPath = buildNormalizedPath(path);
        if (normalizedPath.length >= normalizedRoot.length)
        {
            version (Windows)
            {
                if (icmp(normalizedPath[0 .. normalizedRoot.length], normalizedRoot) == 0)
                    return normalizedPath[normalizedRoot.length .. $];
            }
            else if (normalizedPath[0 .. normalizedRoot.length] == normalizedRoot)
                return normalizedPath[normalizedRoot.length .. $];
        }
        return baseName(path);
    }

    private void rebuildVisibleEntries()
    {
        _visibleRows.length = 0;
        const query = _searchQuery.toLower();

        if (_showQuickAccess)
        {
            const frequentCount = quickAccessVisibleCount(false, query);
            const recentCount = quickAccessVisibleCount(true, query);
            VisibleRow frequentHeader;
            frequentHeader.entryIndex = -1;
            frequentHeader.groupLabel = format("Frequent folders (%d)", frequentCount);
            _visibleRows ~= frequentHeader;
            foreach (index, entry; _entries)
            {
                if (!entry.quickAccessRecent &&
                    (query.length == 0 || containsInsensitive(entry.name, query)))
                {
                    VisibleRow row;
                    row.entryIndex = cast(int) index;
                    _visibleRows ~= row;
                }
            }

            VisibleRow separator;
            separator.entryIndex = -1;
            separator.separator = true;
            _visibleRows ~= separator;

            VisibleRow recentHeader;
            recentHeader.entryIndex = -1;
            recentHeader.groupLabel = format("Recent files (%d)", recentCount);
            _visibleRows ~= recentHeader;
            foreach (index, entry; _entries)
            {
                if (entry.quickAccessRecent &&
                    (query.length == 0 || containsInsensitive(entry.name, query)))
                {
                    VisibleRow row;
                    row.entryIndex = cast(int) index;
                    _visibleRows ~= row;
                }
            }
        }
        else if (_showThisPc)
        {
            const folderCount = thisPcVisibleCount(false, query);
            const driveCount = thisPcVisibleCount(true, query);
            VisibleRow folderHeader;
            folderHeader.entryIndex = -1;
            folderHeader.groupLabel = format("Folders (%d)", folderCount);
            _visibleRows ~= folderHeader;
            foreach (index, entry; _entries)
            {
                if (!entry.drive &&
                    (query.length == 0 || containsInsensitive(entry.name, query)))
                {
                    VisibleRow row;
                    row.entryIndex = cast(int) index;
                    _visibleRows ~= row;
                }
            }

            VisibleRow separator;
            separator.entryIndex = -1;
            separator.separator = true;
            _visibleRows ~= separator;

            VisibleRow driveHeader;
            driveHeader.entryIndex = -1;
            driveHeader.groupLabel = format("Devices and drives (%d)", driveCount);
            _visibleRows ~= driveHeader;
            foreach (index, entry; _entries)
            {
                if (entry.drive &&
                    (query.length == 0 || containsInsensitive(entry.name, query)))
                {
                    VisibleRow row;
                    row.entryIndex = cast(int) index;
                    _visibleRows ~= row;
                }
            }
        }

        string previousGroupLabel;
        if (!_showQuickAccess && !_showThisPc)
        {
            foreach (index, entry; _entries)
            {
                if (query.length == 0 || containsInsensitive(entry.name, query))
                {
                    if (_groupBy == GroupBy.dateModified)
                    {
                        const groupLabel = entry.modifiedDay.length > 0
                            ? entry.modifiedDay : "Unknown date";
                        if (_visibleRows.length == 0 || previousGroupLabel != groupLabel)
                        {
                            VisibleRow groupRow;
                            groupRow.entryIndex = -1;
                            groupRow.groupLabel = groupLabel;
                            _visibleRows ~= groupRow;
                            previousGroupLabel = groupLabel;
                        }
                    }
                    VisibleRow row;
                    row.entryIndex = cast(int) index;
                    _visibleRows ~= row;
                }
            }
        }
        rebuildVisibleRowOffsets();
        if (!hasSelection())
            _selectedVisibleIndex = -1;
        setListScroll(_scrollY);
        updateStatus();
        invalidate();
    }

    private size_t quickAccessVisibleCount(bool recent, string query) const
    {
        size_t count;
        foreach (entry; _entries)
        {
            if (entry.quickAccessRecent != recent) continue;
            if (query.length == 0 || containsInsensitive(entry.name, query))
                ++count;
        }
        return count;
    }

    private size_t thisPcVisibleCount(bool drive, string query) const
    {
        size_t count;
        foreach (entry; _entries)
        {
            if (entry.drive != drive) continue;
            if (query.length == 0 || containsInsensitive(entry.name, query))
                ++count;
        }
        return count;
    }

    private void rebuildVisibleRowOffsets()
    {
        _visibleRowOffsets.length = _visibleRows.length;
        _visibleContentHeight = 0;
        foreach (index, row; _visibleRows)
        {
            _visibleRowOffsets[index] = _visibleContentHeight;
            _visibleContentHeight += row.entryIndex >= 0 ? rowHeightPx() :
                (row.separator ? quickAccessSeparatorHeightPx() : groupHeaderHeightPx());
        }
    }

    private void sortEntries(ref ExplorerEntry[] entries)
    {
        sort!((a, b) => compareEntries(a, b) < 0)(entries);
    }

    private int compareEntries(ExplorerEntry a, ExplorerEntry b) const
    {
        if (_groupBy == GroupBy.dateModified)
        {
            auto result = icmp(a.modifiedDay, b.modifiedDay);
            if (!_groupAscending) result = -result;
            if (result != 0) return result;
        }
        else if (a.directory != b.directory)
            return a.directory ? -1 : 1;

        int result;
        final switch (_sortColumn)
        {
            case SortColumn.name:
                result = icmp(a.name, b.name);
                break;
            case SortColumn.modified:
                result = icmp(a.modifiedSortKey, b.modifiedSortKey);
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
        if (_showQuickAccess) return;
        const selectedPath = hasSelection() ? selectedEntry().path : "";
        if (_groupBy == GroupBy.dateModified && column == SortColumn.modified)
        {
            _groupAscending = !_groupAscending;
            _sortColumn = column;
            _sortAscending = _groupAscending;
        }
        else if (_sortColumn == column)
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

    private void setGroupBy(GroupBy groupBy)
    {
        const selectedPath = hasSelection() ? selectedEntry().path : "";
        _groupBy = groupBy;
        if (_groupBy == GroupBy.dateModified)
        {
            _groupAscending = false;
            _sortColumn = SortColumn.modified;
            _sortAscending = false;
        }
        sortEntries(_entries);
        rebuildVisibleEntries();
        if (selectedPath.length > 0)
            selectPath(selectedPath);
    }

    private void openQuickAccess()
    {
        _showQuickAccess = true;
        _showThisPc = false;
        _currentPath = "";
        clearFolderWatch();
        _groupBy = GroupBy.none;
        _sortColumn = SortColumn.name;
        _sortAscending = true;
        _searchQuery = "";
        _searchField.setText("", false);
        _searchField.setPlaceholder(searchPlaceholder());
        _addressField.setText("Quick Access", false);
        _folderEntries = buildQuickAccessEntries();
        _entries = _folderEntries.dup;
        _selectedVisibleIndex = -1;
        _scrollY = 0;
        rebuildVisibleEntries();
        updateWindowTitle();
    }

    private void openThisPc()
    {
        _showQuickAccess = false;
        _showThisPc = true;
        _currentPath = "";
        clearFolderWatch();
        _groupBy = GroupBy.none;
        _sortColumn = SortColumn.name;
        _sortAscending = true;
        _searchQuery = "";
        _searchField.setText("", false);
        _searchField.setPlaceholder(searchPlaceholder());
        _addressField.setText("This PC", false);
        _folderEntries = buildThisPcEntries();
        _entries = _folderEntries.dup;
        _selectedVisibleIndex = -1;
        _scrollY = 0;
        updateSearchResults();
        updateWindowTitle();
    }

    private static ExplorerEntry[] buildThisPcEntries()
    {
        ExplorerEntry[] entries;
        version (Windows)
        {
            foreach (item; windowsThisPcItems())
            {
                const path = item.path;
                if (path.length == 0) continue;
                if (isDriveRootPath(path))
                    appendThisPcDrive(entries, path, item.displayName);
                else
                    appendThisPcFolder(entries, item.displayName, path, true);
            }

            if (entries.length == 0)
            {
                const current = getcwd();
                auto home = windowsCsidlFolder(CSIDL_PROFILE);
                if (home.length == 0)
                    home = environment.get("USERPROFILE", environment.get("HOME", current));

                appendThisPcFolder(entries, "Desktop",
                    windowsCsidlFolder(CSIDL_DESKTOPDIRECTORY));
                appendThisPcFolder(entries, "Documents",
                    windowsCsidlFolder(CSIDL_PERSONAL));

                auto downloads = windowsKnownFolderPath(&folderIdDownloads);
                if (downloads.length == 0)
                    downloads = buildNormalizedPath(home, "Downloads");
                appendThisPcFolder(entries, "Downloads", downloads);

                appendThisPcFolder(entries, "Music",
                    windowsCsidlFolder(CSIDL_MYMUSIC));
                appendThisPcFolder(entries, "Pictures",
                    windowsCsidlFolder(CSIDL_MYPICTURES));
                appendThisPcFolder(entries, "Videos",
                    windowsCsidlFolder(CSIDL_MYVIDEO));

                const threeDObjects = buildNormalizedPath(home, "3D Objects");
                appendThisPcFolder(entries, "3D Objects", threeDObjects);

                const mask = GetLogicalDrives();
                foreach (index; 0 .. 26)
                {
                    if ((mask & (1u << index)) == 0) continue;
                    const letter = cast(char) ('A' + index);
                    appendThisPcDrive(entries, format("%c:\\", letter));
                }
            }
        }
        else
        {
            ExplorerEntry entry;
            entry.path = "/";
            entry.name = "/";
            entry.directory = true;
            entry.drive = true;
            entry.type = "Filesystem";
            entries ~= entry;
        }
        return entries;
    }

    private static bool appendThisPcFolder(ref ExplorerEntry[] entries, string label,
        string path, bool nativeShellItem = false)
    {
        bool filesystemFolder;
        try
        {
            filesystemFolder = exists(path) && isDir(path);
        }
        catch (Exception)
        {
            filesystemFolder = false;
        }
        if (path.length == 0 || (!filesystemFolder && !nativeShellItem)) return false;
        foreach (entry; entries)
            if (pathsEqual(entry.path, path))
                return false;

        ExplorerEntry entry;
        if (filesystemFolder)
        {
            try
            {
                if (!populateExplorerEntry(DirEntry(path), label, entry))
                    return false;
            }
            catch (Exception)
            {
                return false;
            }
        }
        else
        {
            populateNativeQuickAccessEntry(path, label, true, entry);
        }
        entry.type = "System folder";
        entries ~= entry;
        return true;
    }

    version (Windows)
    private static void appendThisPcDrive(ref ExplorerEntry[] entries, string path,
        string displayName = "")
    {
        if (path.length == 0) return;
        ExplorerEntry entry;
        entry.path = path;
        entry.name = displayName.length > 0 ? displayName : driveDisplayName(path);
        entry.directory = true;
        entry.drive = true;
        entry.type = driveTypeText(GetDriveTypeW(path.toUTF16z));
        entry.modifiedDay = "Unknown date";
        ulong freeBytes;
        ulong totalBytes;
        if (queryDiskSpace(path, freeBytes, totalBytes))
        {
            entry.size = totalBytes;
            entry.sizeKnown = true;
            entry.sizeText = diskSizeText(freeBytes, totalBytes);
        }
        entries ~= entry;
    }

    private ExplorerEntry[] buildQuickAccessEntries()
    {
        ExplorerEntry[] entries;

        version (Windows)
        {
            size_t frequentFolderCount;
            size_t recentFileCount;
            foreach (item; windowsQuickAccessItems())
            {
                const path = item.path;
                if (path.length == 0) continue;
                if (item.isFolder)
                {
                    if (frequentFolderCount < quickAccessFrequentFolderLimit &&
                        appendQuickAccessFolder(entries, path, item.displayName, true))
                        ++frequentFolderCount;
                }
                else if (recentFileCount < quickAccessRecentFileLimit &&
                    appendQuickAccessRecentFile(entries, path, item.displayName, true))
                    ++recentFileCount;
            }

            if (recentFileCount == 0)
            {
                foreach (path; windowsRecentShortcutPaths())
                {
                    if (path.length == 0 || !exists(path)) continue;
                    if (!isDir(path) && recentFileCount < quickAccessRecentFileLimit &&
                        appendQuickAccessRecentFile(entries, path))
                        ++recentFileCount;
                }
            }
        }

        if (quickAccessFolderCount(entries) == 0)
        {
            const current = getcwd();
            const home = environment.get("USERPROFILE", environment.get("HOME", current));
            const documents = buildNormalizedPath(home, "Documents");
            foreach (path; [
                buildNormalizedPath(home, "Desktop"),
                buildNormalizedPath(home, "Downloads"),
                documents,
                buildNormalizedPath(home, "Pictures"),
                buildNormalizedPath(home, "Videos")
            ])
            {
                if (quickAccessFolderCount(entries) >= quickAccessFrequentFolderLimit)
                    break;
                appendQuickAccessFolder(entries, path);
            }

            for (int index = cast(int) _history.length - 1;
                index >= 0 && quickAccessFolderCount(entries) < quickAccessFrequentFolderLimit;
                --index)
                appendQuickAccessFolder(entries, _history[cast(size_t) index]);
        }

        if (quickAccessRecentFileCount(entries) == 0)
        {
            foreach (path; _recentFiles)
                appendQuickAccessRecentFile(entries, path);
        }
        return entries;
    }

    private static size_t quickAccessFolderCount(const ExplorerEntry[] entries)
    {
        size_t count;
        foreach (entry; entries)
            if (!entry.quickAccessRecent) ++count;
        return count;
    }

    private static size_t quickAccessRecentFileCount(const ExplorerEntry[] entries)
    {
        size_t count;
        foreach (entry; entries)
            if (entry.quickAccessRecent) ++count;
        return count;
    }

    private static bool appendQuickAccessFolder(ref ExplorerEntry[] entries, string path,
        string displayName = "", bool nativeShellItem = false)
    {
        bool filesystemFolder;
        try
        {
            filesystemFolder = exists(path) && isDir(path);
        }
        catch (Exception)
        {
            filesystemFolder = false;
        }
        if (path.length == 0 || (!filesystemFolder && !nativeShellItem)) return false;
        foreach (entry; entries)
            if (!entry.quickAccessRecent && pathsEqual(entry.path, path))
                return false;

        ExplorerEntry entry;
        if (filesystemFolder)
        {
            try
            {
                if (!populateExplorerEntry(DirEntry(path), displayName, entry))
                    return false;
            }
            catch (Exception)
            {
                return false;
            }
        }
        else
        {
            populateNativeQuickAccessEntry(path, displayName, true, entry);
        }
        entries ~= entry;
        return true;
    }

    private static bool appendQuickAccessRecentFile(ref ExplorerEntry[] entries, string path,
        string displayName = "", bool nativeShellItem = false)
    {
        bool filesystemFile;
        try
        {
            filesystemFile = exists(path) && !isDir(path);
        }
        catch (Exception)
        {
            filesystemFile = false;
        }
        if (path.length == 0 || (!filesystemFile && !nativeShellItem)) return false;
        foreach (entry; entries)
            if (pathsEqual(entry.path, path))
                return false;

        ExplorerEntry entry;
        if (filesystemFile)
        {
            try
            {
                if (!populateExplorerEntry(DirEntry(path), displayName, entry))
                    return false;
            }
            catch (Exception)
            {
                return false;
            }
        }
        else
        {
            populateNativeQuickAccessEntry(path, displayName, false, entry);
        }
        entry.quickAccessRecent = true;
        entries ~= entry;
        return true;
    }

    private static void populateNativeQuickAccessEntry(string path, string displayName,
        bool directory, out ExplorerEntry entry)
    {
        entry = ExplorerEntry.init;
        entry.path = path;
        entry.name = displayName.length > 0 ? displayName : baseName(path);
        if (entry.name.length == 0) entry.name = path;
        entry.directory = directory;
        entry.modifiedDay = "Unknown date";
        entry.type = typeText(entry.name, directory);
    }

    private void activateNavigation(int index)
    {
        if (index < 0 || index >= cast(int) _navigation.length) return;
        const item = _navigation[cast(size_t) index];
        if (item.kind == NavigationKind.quickAccess)
        {
            openQuickAccess();
            return;
        }
        if (item.kind == NavigationKind.thisPc)
        {
            openThisPc();
            return;
        }
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
        if (item.kind == NavigationKind.quickAccess)
            return _showQuickAccess;
        if (item.kind == NavigationKind.thisPc)
            return _showThisPc;
        if (item.kind != NavigationKind.folder)
            return false;
        return item.path.length > 0 && pathsEqual(item.path, _currentPath);
    }

    private void activateEntry(int visibleIndex)
    {
        const entryIndex = entryIndexForVisibleRow(visibleIndex);
        if (entryIndex < 0) return;
        const entry = _entries[cast(size_t) entryIndex];
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
        if (_showQuickAccess || _showThisPc) return;
        const parent = dirName(_currentPath);
        if (parent.length > 0 && !pathsEqual(parent, _currentPath))
            navigate(parent, true, true);
    }

    private void refresh()
    {
        if (_showQuickAccess)
        {
            openQuickAccess();
            return;
        }
        if (_showThisPc)
        {
            openThisPc();
            return;
        }
        navigate(_currentPath, false, false);
    }

    private void submitAddress()
    {
        const requested = _addressField.textUtf8();
        if (icmp(requested, "This PC") == 0)
        {
            openThisPc();
            requestFocus();
            return;
        }
        if (icmp(requested, "Quick Access") == 0)
        {
            openQuickAccess();
            requestFocus();
            return;
        }
        navigate(requested, true, true);
        _addressField.setText(_showThisPc ? "This PC" : _currentPath, false);
        requestFocus();
    }

    private bool hasSelection() const
    {
        return entryIndexForVisibleRow(_selectedVisibleIndex) >= 0;
    }

    private ExplorerEntry selectedEntry() const
    {
        if (!hasSelection()) return ExplorerEntry.init;
        return _entries[cast(size_t) entryIndexForVisibleRow(_selectedVisibleIndex)];
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
        if (_showQuickAccess || _showThisPc)
        {
            _statusText = _showThisPc ? "This PC is not a folder." :
                "Quick Access is not a folder.";
            invalidate();
            return;
        }
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
        if (_showQuickAccess || _showThisPc)
        {
            _statusText = _showThisPc ? "This PC is not a folder." :
                "Quick Access is not a folder.";
            invalidate();
            return;
        }
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
        foreach (visibleIndex, row; _visibleRows)
        {
            if (row.entryIndex >= 0 &&
                pathsEqual(_entries[cast(size_t) row.entryIndex].path, path))
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
        const top = _visibleRowOffsets[cast(size_t) _selectedVisibleIndex];
        const bottom = top + visibleRowHeight(_selectedVisibleIndex);
        if (top < _scrollY)
            setListScroll(top);
        else if (bottom > _scrollY + _rowsRect.height)
            setListScroll(bottom - _rowsRect.height);
    }

    private void openPath(string path)
    {
        try
        {
            const opened = openPathWithSystem(path);
            if (opened)
            {
                recordRecentFile(path);
                _statusText = "Opened " ~ baseName(path);
            }
            else
                _statusText = "No system opener is available for " ~ baseName(path);
        }
        catch (Exception error)
        {
            _statusText = "Cannot open item: " ~ error.msg;
        }
        invalidate();
    }

    private void showEntryProperties(ExplorerEntry entry)
    {
        const location = entry.drive ? "This PC" : dirName(entry.path);
        showProperties(entry.path, entry.name, entry.type, entry.sizeText, location);
    }

    private void showProperties(string path, string preferredName = "",
        string preferredType = "", string preferredSizeText = "",
        string preferredLocation = "")
    {
        if (path.length == 0) return;
        version (Windows)
        {
            bool directory;
            ulong size;
            string sizeText;
            string modified;
            try
            {
                const item = DirEntry(path);
                directory = item.isDir;
                if (!directory) size = item.size;
                version (Windows)
                {
                    if (directory && pathsEqual(path, rootPathFor(path)))
                    {
                        ulong freeBytes;
                        ulong totalBytes;
                        if (queryDiskSpace(path, freeBytes, totalBytes))
                            sizeText = diskSizeText(freeBytes, totalBytes);
                    }
                }
                modified = format("%s", item.timeLastModified);
            }
            catch (Exception error)
            {
                _statusText = "Cannot read properties: " ~ error.msg;
                invalidate();
                return;
            }

            const fallbackName = baseName(path).length > 0 ? baseName(path) : path;
            const name = preferredName.length > 0 ? preferredName : fallbackName;
            const type = preferredType.length > 0 ? preferredType :
                typeText(name, directory);
            const location = preferredLocation.length > 0 ? preferredLocation :
                dirName(path);
            const displaySize = preferredSizeText.length > 0 ? preferredSizeText :
                (directory ? (sizeText.length > 0 ? sizeText : "Folder") :
                    humanSize(size));
            if (_propertiesWindow is null)
                _propertiesWindow = new PropertiesWindow();
            _propertiesWindow.show(path, name, type, location, displaySize, modified);
            _statusText = _propertiesWindow.visible()
                ? "Showing properties for " ~ name
                : "Cannot open the Properties window.";
        }
        else
            _statusText = "Properties are only available on Windows.";
        invalidate();
    }

    private void showThisPcProperties()
    {
        version (Windows)
        {
            const entries = _showThisPc ? _folderEntries : buildThisPcEntries();
            const folderCount = thisPcEntryCount(entries, false);
            const driveCount = thisPcEntryCount(entries, true);
            if (_propertiesWindow is null)
                _propertiesWindow = new PropertiesWindow();
            _propertiesWindow.show("This PC", "This PC", "System folder", "Desktop",
                format("%d folders, %d drives", folderCount, driveCount),
                "Not applicable");
            _statusText = _propertiesWindow.visible()
                ? "Showing properties for This PC"
                : "Cannot open the Properties window.";
        }
        else
            _statusText = "Properties are only available on Windows.";
        invalidate();
    }

    private static size_t thisPcEntryCount(const ExplorerEntry[] entries, bool drive)
    {
        size_t count;
        foreach (entry; entries)
            if (entry.drive == drive) ++count;
        return count;
    }

    private void recordRecentFile(string path)
    {
        if (path.length == 0) return;
        string[] updated = [path];
        foreach (recent; _recentFiles)
        {
            if (!pathsEqual(recent, path))
                updated ~= recent;
        }
        if (updated.length > 10)
            updated = updated[0 .. 10];
        _recentFiles = updated;
        if (_showQuickAccess)
            openQuickAccess();
        else
        {
            rebuildNavigation();
            setSidebarScroll(_sidebarScrollY);
        }
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

    private void openThisPcWithSystem()
    {
        version (Windows)
        {
            if (openPathWithSystem("shell:MyComputerFolder"))
                _statusText = "Opened This PC in the system file manager.";
            else
                _statusText = "Cannot open This PC in the system file manager.";
        }
        else
            _statusText = "This PC is only available on Windows.";
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
        if (_showQuickAccess || _showThisPc)
        {
            _statusText = _showThisPc ? "This PC has no filesystem path." :
                "Quick Access has no filesystem path.";
            invalidate();
            return;
        }
        if (writeClipboardText(_currentPath))
            _statusText = "Copied current folder path.";
        else
            _statusText = "Clipboard is not available.";
        invalidate();
    }

    private void showHomeMenu()
    {
        if (homeMenuOpen())
        {
            _homeMenu.dismiss();
            _homeMenu = null;
            invalidate();
            return;
        }

        ContextMenuItem[] items;
        items ~= ContextMenuItem.command("New folder", IconKind.folder,
            delegate() { activateCommand(CommandButton.newFolder); }, "Ctrl+N",
            commandEnabled(CommandButton.newFolder));
        items ~= ContextMenuItem.command("New text file", IconKind.newDocument,
            delegate() { activateCommand(CommandButton.newTextFile); }, "",
            commandEnabled(CommandButton.newTextFile));
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Open", IconKind.open,
            delegate() { activateCommand(CommandButton.openSelected); }, "Enter",
            commandEnabled(CommandButton.openSelected));
        items ~= ContextMenuItem.command("Copy path", IconKind.file,
            delegate() { activateCommand(CommandButton.copyPath); }, "Ctrl+C",
            commandEnabled(CommandButton.copyPath));
        _homeMenu = showContextMenu(this,
            localToGlobal(Point(_homeTabRect.x, _homeTabRect.bottom())),
            items);
        if (_homeMenu !is null)
        {
            const homeOrigin = localToGlobal(Point(_homeTabRect.x, _homeTabRect.y));
            _homeMenu.setConsumeAnchorPress(Rect(homeOrigin.x, homeOrigin.y,
                _homeTabRect.width, _homeTabRect.height));
            _homeMenu.onDismissed = delegate()
            {
                _homeMenu = null;
                invalidate();
            };
        }
        invalidate();
    }

    private bool homeMenuOpen() const
    {
        return _homeMenu !is null && !_homeMenu.dismissed();
    }

    private void showContextMenuFor(Point localPosition)
    {
        const globalPosition = localToGlobal(localPosition);
        const navigationIndex = navigationIndexAt(localPosition);
        if (navigationIndex >= 0)
        {
            const navigationItem = _navigation[cast(size_t) navigationIndex];
            if (navigationItem.kind == NavigationKind.quickAccess && navigationItem.enabled)
            {
                ContextMenuItem[] navigationItems;
                navigationItems ~= ContextMenuItem.command("Open", IconKind.open,
                    delegate() { openQuickAccess(); });
                navigationItems ~= ContextMenuItem.command("Refresh", IconKind.refresh,
                    delegate() { openQuickAccess(); }, "F5");
                showContextMenu(this, globalPosition, navigationItems);
                return;
            }
            if (navigationItem.kind == NavigationKind.thisPc && navigationItem.enabled)
            {
                ContextMenuItem[] navigationItems;
                navigationItems ~= ContextMenuItem.command("Open", IconKind.open,
                    delegate() { openThisPc(); });
                navigationItems ~= ContextMenuItem.command("Open with system", IconKind.open,
                    delegate() { openThisPcWithSystem(); });
                navigationItems ~= ContextMenuItem.command("Properties", IconKind.file,
                    delegate() { showThisPcProperties(); });
                navigationItems ~= ContextMenuItem.command("Refresh", IconKind.refresh,
                    delegate() { openThisPc(); }, "F5");
                showContextMenu(this, globalPosition, navigationItems);
                return;
            }
            if (navigationItem.kind == NavigationKind.folder &&
                navigationItem.enabled && navigationItem.path.length > 0)
            {
                ContextMenuItem[] navigationItems;
                navigationItems ~= ContextMenuItem.command("Open", IconKind.open,
                    delegate() { navigate(navigationItem.path, true, true); });
                navigationItems ~= ContextMenuItem.command("Properties", IconKind.file,
                    delegate() { showProperties(navigationItem.path); });
                showContextMenu(this, globalPosition, navigationItems);
                return;
            }
        }
        if (_showQuickAccess)
        {
            const visibleIndex = visibleEntryIndexAt(localPosition);
            if (visibleIndex >= 0)
            {
                _selectedVisibleIndex = visibleIndex;
                updateSelectedStatus();
                invalidate();
            }
            ContextMenuItem[] quickAccessItems;
            if (hasSelection())
            {
                auto entry = selectedEntry();
                quickAccessItems ~= ContextMenuItem.command("Open", IconKind.open,
                    delegate() { activateEntry(_selectedVisibleIndex); }, "Enter");
                if (!entry.directory)
                    quickAccessItems ~= ContextMenuItem.command("Open with system", IconKind.open,
                        delegate() { openPath(entry.path); });
                quickAccessItems ~= ContextMenuItem.command("Properties", IconKind.file,
                    delegate() { showEntryProperties(entry); });
                quickAccessItems ~= ContextMenuItem.separatorItem();
            }
            quickAccessItems ~= ContextMenuItem.command("Refresh", IconKind.refresh,
                delegate() { refresh(); }, "F5");
            showContextMenu(this, globalPosition, quickAccessItems);
            return;
        }
        if (_showThisPc)
        {
            const visibleIndex = visibleEntryIndexAt(localPosition);
            if (visibleIndex >= 0)
            {
                _selectedVisibleIndex = visibleIndex;
                updateSelectedStatus();
                invalidate();
            }
            ContextMenuItem[] thisPcItems;
            if (hasSelection())
            {
                auto entry = selectedEntry();
                thisPcItems ~= ContextMenuItem.command("Open", IconKind.open,
                    delegate() { activateEntry(_selectedVisibleIndex); }, "Enter");
                thisPcItems ~= ContextMenuItem.command("Properties", IconKind.file,
                    delegate() { showEntryProperties(entry); });
                thisPcItems ~= ContextMenuItem.command("Copy path", IconKind.file,
                    delegate() { copySelectedPath(); }, "Ctrl+C");
                thisPcItems ~= ContextMenuItem.separatorItem();
            }
            thisPcItems ~= ContextMenuItem.command("Open This PC with system", IconKind.open,
                delegate() { openThisPcWithSystem(); });
            thisPcItems ~= ContextMenuItem.command("This PC properties", IconKind.file,
                delegate() { showThisPcProperties(); });
            thisPcItems ~= ContextMenuItem.separatorItem();
            thisPcItems ~= ContextMenuItem.command("Refresh", IconKind.refresh,
                delegate() { refresh(); }, "F5");
            showContextMenu(this, globalPosition, thisPcItems);
            return;
        }
        const visibleIndex = visibleEntryIndexAt(localPosition);
        if (visibleIndex >= 0)
        {
            _selectedVisibleIndex = visibleIndex;
            updateSelectedStatus();
            invalidate();
        }

        ContextMenuItem[] items;
        if (hasSelection())
        {
            auto entry = selectedEntry();
            items ~= ContextMenuItem.command("Open", IconKind.open,
                delegate() { activateEntry(_selectedVisibleIndex); }, "Enter");
            if (!entry.directory)
                items ~= ContextMenuItem.command("Open with system", IconKind.open,
                    delegate() { openPath(entry.path); });
            items ~= ContextMenuItem.command("Properties", IconKind.file,
                delegate() { showEntryProperties(entry); });
            items ~= ContextMenuItem.command("Copy path", IconKind.file,
                delegate() { copySelectedPath(); }, "Ctrl+C");
            items ~= ContextMenuItem.separatorItem();
        }
        items ~= ContextMenuItem.command("New folder", IconKind.folder,
            delegate() { createNewFolder(); }, "Ctrl+N");
        items ~= ContextMenuItem.command("New text file", IconKind.newDocument,
            delegate() { createNewTextFile(); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command(
            _groupBy == GroupBy.dateModified ? "Ungroup" : "Group by date modified",
            IconKind.file,
            delegate() { setGroupBy(_groupBy == GroupBy.dateModified
                ? GroupBy.none : GroupBy.dateModified); });
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Copy current path", IconKind.file,
            delegate() { copyCurrentPath(); });
        items ~= ContextMenuItem.command("Refresh", IconKind.refresh,
            delegate() { refresh(); }, "F5");
        showContextMenu(this, globalPosition, items);
    }

    private void updateStatus()
    {
        if (_showThisPc)
        {
            if (_searchQuery.length > 0)
                _statusText = format("%d matches in This PC", visibleItemCount());
            else
                _statusText = format("%d folders, %d drives",
                    thisPcEntryCount(_entries, false), thisPcEntryCount(_entries, true));
        }
        else if (_searchQuery.length > 0)
            _statusText = format("%d matches in %d items",
                visibleItemCount(), _entries.length);
        else
            _statusText = format("%d items", _entries.length);
    }

    private void updateSelectedStatus()
    {
        const entryIndex = entryIndexForVisibleRow(_selectedVisibleIndex);
        if (entryIndex < 0)
        {
            updateStatus();
            return;
        }
        const entry = _entries[cast(size_t) entryIndex];
        const sizeText = entrySizeText(entry);
        _statusText = sizeText.length > 0 ? entry.name ~ "  " ~ sizeText :
            (entry.drive ? entry.name ~ " drive" :
            (entry.directory ? entry.name ~ " folder" :
                (entry.sizeKnown ? entry.name ~ "  " ~ humanSize(entry.size) :
                    entry.name)));
    }

    private void updateWindowTitle()
    {
        if (_showQuickAccess)
        {
            const fullTitle = "Quick Access - Aurora Windows File Manager";
            if (_window !is null)
                _window.setTitle(fullTitle);
            if (onTitleChanged !is null)
                onTitleChanged(fullTitle);
            return;
        }
        if (_showThisPc)
        {
            const fullTitle = "This PC - Aurora Windows File Manager";
            if (_window !is null)
                _window.setTitle(fullTitle);
            if (onTitleChanged !is null)
                onTitleChanged(fullTitle);
            return;
        }
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
                return !_showQuickAccess && !_showThisPc &&
                    _currentPath.length > 0 && exists(_currentPath) && isDir(_currentPath);
            case CommandButton.refresh:
                return _showQuickAccess || _showThisPc ||
                    (_currentPath.length > 0 && exists(_currentPath) && isDir(_currentPath));
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

    // Returns the visual row index. The visual index includes group headers;
    // it must not be confused with the underlying _entries index.
    private int visibleEntryIndexAt(Point point) const
    {
        if (!_rowsRect.contains(point)) return -1;
        foreach (index; 0 .. _visibleRows.length)
        {
            const visibleIndex = cast(int) index;
            if (entryIndexForVisibleRow(visibleIndex) >= 0 &&
                visibleRowRect(visibleIndex).contains(point))
                return visibleIndex;
        }
        return -1;
    }

    private Rect visibleRowRect(int visibleIndex) const
    {
        if (visibleIndex < 0 || visibleIndex >= cast(int) _visibleRows.length)
            return Rect.init;
        return Rect(_rowsRect.x + scaled(20),
            _rowsRect.y + _visibleRowOffsets[cast(size_t) visibleIndex] - _scrollY,
            maxInt(0, _usableListWidth - scaled(24)), visibleRowHeight(visibleIndex));
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
        return maxInt(0, _visibleContentHeight - _rowsRect.height);
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
            const contentHeight = _visibleContentHeight;
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
        const tabHeight = ribbon;
        canvas.fillRect(Rect(0, 0, bounds().width, ribbon), explorerBlack);
        canvas.fillRect(Rect(0, tabHeight, bounds().width, 1), explorerLine);
        canvas.fillRect(Rect(0, ribbon - 1, bounds().width, 1), explorerLine);

        canvas.fillRect(Rect(0, 0, scaled(70), tabHeight), explorerBlue);
        drawText(canvas, Rect(0, 0, scaled(70), tabHeight), "File", explorerText,
            HorizontalAlign.center);

        if (homeMenuOpen())
        {
            canvas.fillRect(_homeTabRect, Color.rgba(255, 255, 255, 12));
            canvas.fillRect(Rect(_homeTabRect.x, _homeTabRect.bottom() - scaled(2),
                _homeTabRect.width, scaled(2)), explorerBlue);
        }
        drawText(canvas, _homeTabRect.inset(scaled(8), 0, scaled(8), 0),
            "Home", explorerText, HorizontalAlign.left);
        drawText(canvas, Rect(scaled(150), 0, scaled(62), tabHeight), "Share", explorerText,
            HorizontalAlign.left);
        drawText(canvas, Rect(scaled(218), 0, scaled(62), tabHeight), "View", explorerText,
            HorizontalAlign.left);
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
            const nestedOffset = scaled(14 * item.indentLevel);
            if (item.kind == NavigationKind.thisPc)
                drawIcon(content, IconKind.chevronDown,
                    Rect(row.x + scaled(9), row.y + scaled(8),
                        scaled(10), scaled(10)), textColor, textColor);
            else if (item.indentLevel > 0 && !item.pinned)
                drawIcon(content, IconKind.chevronRight,
                    Rect(row.x + scaled(22), row.y + scaled(8),
                        scaled(10), scaled(10)), textColor, textColor);
            drawIcon(content, item.icon, Rect(row.x + scaled(36) + nestedOffset,
                row.y + scaled(5),
                scaled(17), scaled(17)),
                textColor, folderAccent);
            drawText(content, Rect(row.x + scaled(60) + nestedOffset, row.y,
                maxInt(0, row.width - scaled(86) - nestedOffset), row.height),
                item.label, textColor, HorizontalAlign.left);

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
        foreach (visibleIndex, visibleRow; _visibleRows)
        {
            const row = visibleRowRect(cast(int) visibleIndex);
            if (row.bottom() <= _rowsRect.y) continue;
            if (row.y >= _rowsRect.bottom()) break;
            if (visibleRow.entryIndex < 0)
            {
                if (visibleRow.separator)
                {
                    rows.fillRect(Rect(row.x + scaled(8), row.y + row.height / 2,
                        maxInt(0, row.width - scaled(16)), 1), explorerLine);
                    continue;
                }
                rows.fillRect(row, explorerHeader);
                const headerLabel = _showQuickAccess ? visibleRow.groupLabel :
                    "Date modified: " ~ visibleRow.groupLabel;
                drawText(rows, Rect(row.x + scaled(8), row.y, row.width - scaled(16),
                    row.height), headerLabel,
                    explorerMuted, HorizontalAlign.left);
                rows.fillRect(Rect(row.x, row.bottom() - 1, row.width, 1), explorerLine);
                continue;
            }
            const entry = _entries[cast(size_t) visibleRow.entryIndex];
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

            const icon = entry.drive ? IconKind.drive :
                (entry.directory ? IconKind.folder : iconForFile(entry.name));
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
                row.height), entrySizeText(entry),
                explorerText, HorizontalAlign.right);
        }

        drawScrollbar(canvas, _listScrollbarRect, _listScrollbarThumbRect);
    }

    private void drawDragPreview(ref Canvas canvas)
    {
        if (!_draggingEntry || !hasDragSource()) return;
        if (_dragPreviewOverlay !is null && _dragPreviewOverlay.visible()) return;
        const entry = dragSourceEntry();
        const previewWidth = clampInt(scaled(52) + cast(int) entry.name.length * scaled(7),
            scaled(150), scaled(320));
        const preview = Rect(_dragCurrent.x + scaled(12), _dragCurrent.y + scaled(12),
            previewWidth, scaled(30));
        canvas.drawRoundedRect(preview, scaled(2), explorerDragPreview, explorerSelectionBorder, 1);
        const icon = entry.drive ? IconKind.drive :
            (entry.directory ? IconKind.folder : iconForFile(entry.name));
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
        const dir = command == CommandButton.back ? 1 : -1;
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
        if (_showQuickAccess)
            return "Search Quick Access";
        if (_showThisPc)
            return "Search This PC";
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

    private static bool isDriveRootPath(string path)
    {
        const root = rootName(path);
        return root.length > 0 && pathsEqual(path, rootPathFor(path));
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

    private static string driveDisplayName(string path)
    {
        const root = rootName(path);
        if (root.length >= 2 && root[1] == ':')
        {
            version (Windows)
            {
                wchar[MAX_PATH] volumeName;
                if (GetVolumeInformationW(path.toUTF16z, volumeName.ptr,
                        cast(DWORD) volumeName.length, null, null, null, null,
                        0) != FALSE)
                {
                    const label = windowsWideBufferString(volumeName[]);
                    if (label.length > 0)
                        return label ~ " (" ~ root[0 .. 2] ~ ")";
                }
            }
            return "Local Disk (" ~ root[0 .. 2] ~ ")";
        }
        return displayRoot(path);
    }

    private static string entrySizeText(ExplorerEntry entry)
    {
        if (entry.sizeText.length > 0) return entry.sizeText;
        if (entry.directory || !entry.sizeKnown) return "";
        return humanSize(entry.size);
    }

    private static string diskSizeText(ulong freeBytes, ulong totalBytes)
    {
        if (totalBytes == 0) return "";
        return humanSize(freeBytes) ~ " free of " ~ humanSize(totalBytes);
    }

    version (Windows)
    private static string driveTypeText(uint driveType)
    {
        switch (driveType)
        {
            case DRIVE_REMOVABLE:
                return "Removable Drive";
            case DRIVE_FIXED:
                return "Local Disk";
            case DRIVE_REMOTE:
                return "Network Drive";
            case DRIVE_CDROM:
                return "DVD Drive";
            case DRIVE_RAMDISK:
                return "RAM Disk";
            default:
                return "Drive";
        }
    }

    version (Windows)
    private static bool queryDiskSpace(string path, out ulong freeBytes, out ulong totalBytes)
    {
        freeBytes = 0;
        totalBytes = 0;
        ULARGE_INTEGER freeAvailable;
        ULARGE_INTEGER total;
        ULARGE_INTEGER totalFree;
        if (GetDiskFreeSpaceExW(path.toUTF16z, &freeAvailable, &total,
                &totalFree) == FALSE)
            return false;
        freeBytes = cast(ulong) totalFree.QuadPart;
        totalBytes = cast(ulong) total.QuadPart;
        return true;
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

    private static string modifiedSortKey(DirEntry item)
    {
        try
        {
            const time = item.timeLastModified;
            return format("%04d-%02d-%02d %02d:%02d:%02d",
                cast(int) time.year, cast(int) time.month, cast(int) time.day,
                cast(int) time.hour, cast(int) time.minute, cast(int) time.second);
        }
        catch (Exception)
        {
            return "";
        }
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

version (Windows)
private string windowsWideBufferString(const(wchar)[] buffer)
{
    size_t length;
    while (length < buffer.length && buffer[length] != 0)
        ++length;
    return length > 0 ? toUTF8(buffer[0 .. length]) : "";
}

version (Windows)
private string windowsWidePointerString(const(wchar)* buffer)
{
    if (buffer is null) return "";
    size_t length;
    while (buffer[length] != 0)
        ++length;
    return length > 0 ? toUTF8(buffer[0 .. length]) : "";
}

version (Windows)
private string windowsCsidlFolder(int csidl)
{
    wchar[MAX_PATH] path;
    if (SHGetFolderPathW(null, csidl, null, 0, path.ptr) != S_OK)
        return "";
    return windowsWideBufferString(path[]);
}

version (Windows)
private string windowsKnownFolderPath(const(GUID)* folderId)
{
    wchar* path;
    if (SHGetKnownFolderPath(folderId, 0, null, &path) != S_OK || path is null)
        return "";
    scope (exit) CoTaskMemFree(path);
    return windowsWidePointerString(path);
}

version (Windows)
private string windowsRecentFolder()
{
    return windowsCsidlFolder(CSIDL_RECENT);
}

version (Windows)
private string resolveWindowsShortcut(string shortcutPath)
{
    const initResult = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    if (initResult != S_OK && initResult != S_FALSE && initResult != RPC_E_CHANGED_MODE)
        return "";
    const shouldUninitialize = initResult == S_OK || initResult == S_FALSE;
    scope (exit)
    {
        if (shouldUninitialize) CoUninitialize();
    }

    IShellLinkW shellLink;
    if (CoCreateInstance(&CLSID_ShellLink, null, CLSCTX_INPROC_SERVER,
            &IID_IShellLinkW, cast(void**) &shellLink) != S_OK || shellLink is null)
        return "";
    scope (exit) shellLink.Release();

    IPersistFile persistFile;
    if (shellLink.QueryInterface(&IID_IPersistFile, cast(void**) &persistFile) != S_OK ||
        persistFile is null)
        return "";
    scope (exit) persistFile.Release();

    if (persistFile.Load(shortcutPath.toUTF16z, STGM_READ) != S_OK)
        return "";

    wchar[MAX_PATH] target;
    WIN32_FIND_DATAW findData;
    if (shellLink.GetPath(target.ptr, cast(int) target.length, &findData, 0) != S_OK)
        return "";
    return windowsWideBufferString(target[]);
}

version (Windows)
private string[] windowsRecentShortcutPaths()
{
    string[] paths;
    const recentFolder = windowsRecentFolder();
    if (recentFolder.length == 0 || !exists(recentFolder)) return paths;

    try
    {
        foreach (DirEntry item; dirEntries(recentFolder, SpanMode.shallow))
        {
            if (item.isDir || icmp(extension(item.name), ".lnk") != 0) continue;
            const target = resolveWindowsShortcut(item.name);
            if (target.length > 0 && paths.length < 40)
                paths ~= target;
            if (paths.length >= 40) break;
        }
    }
    catch (Exception)
    {
    }
    return paths;
}

version (Windows)
private string shellFolderDisplayName(IShellFolder folder, LPITEMIDLIST child, DWORD flags)
{
    STRRET displayName;
    if (folder.GetDisplayNameOf(child, flags, &displayName) != S_OK)
        return "";
    wchar[MAX_PATH] buffer;
    if (StrRetToBufW(&displayName, child, buffer.ptr, cast(UINT) buffer.length) != S_OK)
        return "";
    return windowsWideBufferString(buffer[]);
}

version (Windows)
private bool shellFolderItemIsFolder(IShellFolder folder, LPITEMIDLIST child)
{
    LPCITEMIDLIST childConst = cast(LPCITEMIDLIST) child;
    ULONG attributes = cast(ULONG) SFGAOF.SFGAO_FOLDER;
    if (folder.GetAttributesOf(1, &childConst, &attributes) != S_OK)
        return false;
    return (attributes & cast(ULONG) SFGAOF.SFGAO_FOLDER) != 0;
}

version (Windows)
private WindowsQuickAccessItem[] windowsQuickAccessItems()
{
    return windowsShellNamespaceItems("shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}", 96);
}

version (Windows)
private WindowsQuickAccessItem[] windowsThisPcItems()
{
    return windowsShellNamespaceItems("shell:::{20d04fe0-3aea-1069-a2d8-08002b30309d}", 96);
}

version (Windows)
private WindowsQuickAccessItem[] windowsShellNamespaceItems(string shellNamespace, size_t limit)
{
    WindowsQuickAccessItem[] items;
    const initResult = CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    if (initResult != S_OK && initResult != S_FALSE && initResult != RPC_E_CHANGED_MODE)
        return items;
    const shouldUninitialize = initResult == S_OK || initResult == S_FALSE;
    scope (exit)
    {
        if (shouldUninitialize) CoUninitialize();
    }

    LPITEMIDLIST namespacePidl;
    if (SHParseDisplayName(shellNamespace.toUTF16z, null,
            cast(LPITEMIDLIST) &namespacePidl, SFGAOF.init,
            null) != S_OK || namespacePidl is null)
        return items;
    scope (exit) ILFree(namespacePidl);

    IShellFolder desktopFolder;
    if (SHGetDesktopFolder(&desktopFolder) != S_OK || desktopFolder is null)
        return items;
    scope (exit) desktopFolder.Release();

    IShellFolder shellFolder;
    if (desktopFolder.BindToObject(namespacePidl, null, &IID_IShellFolder,
            cast(void**) &shellFolder) != S_OK || shellFolder is null)
        return items;
    scope (exit) shellFolder.Release();

    IEnumIDList enumerator;
    const enumFlags = SHCONTF.SHCONTF_FOLDERS | SHCONTF.SHCONTF_NONFOLDERS;
    if (shellFolder.EnumObjects(null, enumFlags, &enumerator) != S_OK ||
        enumerator is null)
        return items;
    scope (exit) enumerator.Release();

    while (items.length < limit)
    {
        LPITEMIDLIST child;
        ULONG fetched;
        if (enumerator.Next(1, &child, &fetched) != S_OK || fetched == 0 || child is null)
            break;
        scope (exit) ILFree(child);

        const resolvedPath = shellFolderDisplayName(shellFolder, child,
            SHGNO.SHGDN_FORPARSING);
        if (resolvedPath.length > 0)
        {
            WindowsQuickAccessItem item;
            item.path = resolvedPath;
            item.displayName = shellFolderDisplayName(shellFolder, child,
                SHGNO.SHGDN_NORMAL);
            item.isFolder = shellFolderItemIsFolder(shellFolder, child);
            items ~= item;
        }
    }
    return items;
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
