module demos.windows_file_manager;

import aurora;
import std.algorithm.sorting : sort;
import std.file : DirEntry, SpanMode, copy, dirEntries, exists, getcwd, isDir,
    mkdir, readText, removeFile = remove, renameFile = rename, rmdirRecurse, thisExePath,
    writeFile = write;
import std.format : format;
import std.json : JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, extension,
    isAbsolute, rootName;
import std.process : Config, environment, spawnProcess;
import std.string : icmp, strip, toLower;
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
        CSIDL_RECENT, DROPFILES, ILFree, IEnumIDList, IShellFolder, IShellLinkW,
        LPCITEMIDLIST, LPITEMIDLIST, SFGAOF, SHCONTF, SHGNO, SHGetDesktopFolder,
        SHGetFolderPathW, SHParseDisplayName, STRRET;
    import core.sys.windows.shellapi : DragQueryFileW, FO_DELETE, FOF_ALLOWUNDO,
        HDROP, SHFILEOPSTRUCTW, SHFileOperationW, ShellExecuteW;
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
    copySelected,
    cutSelected,
    paste,
    copyPath,
    renameSelected,
    deleteSelected
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

private enum FileViewMode
{
    extraLargeIcons,
    largeIcons,
    mediumIcons,
    smallIcons,
    list,
    details,
    tiles,
    content
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
    bool thisPcChild;
}

private struct AddressSegment
{
    string label;
    string path;
    bool thisPc;
    Rect rect;
}

private final class FileManagerIconAtlas
{
    RgbaImage image;
    Rect[string] frames;

    bool frameFor(string name, out Rect frame)
    {
        auto found = name in frames;
        if (found is null) return false;
        frame = *found;
        return true;
    }
}

private class PreviewTextField : TextField
{
    bool delegate(ref Event event) onPreviewKeyDown;

    this()
    {
        super("");
    }

    override bool onKeyDown(ref Event event)
    {
        if (onPreviewKeyDown !is null && onPreviewKeyDown(event))
            return true;
        return super.onKeyDown(event);
    }
}

private final class AddressField : PreviewTextField
{
    void delegate() onAddressLostFocus;

    this()
    {
        super();
    }

    override void onFocusChanged(bool value)
    {
        super.onFocusChanged(value);
        if (!value && onAddressLostFocus !is null)
            onAddressLostFocus();
    }
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
    private enum wheelUnitsPerNotch = 3;
    private enum double autoRefreshIntervalSeconds = 1.0;
    private enum double thisPcArrowFadeSpeed = 8.0;
    private enum double wheelSmoothScrollSpeed = 18.0;
    private enum sidebarRowHeight = 27;
    private enum headerHeight = 34;
    private enum scrollbarWidth = 12;

private GuiWindow _window;
    private AddressField _addressField;
    private TextField _searchField;
private TextField _locateField;
    private TextField _renameField;
    private Scrollbar _listScrollbar;
    private Scrollbar _sidebarScrollbar;
    private ContextMenu _homeMenu;
    private ContextMenu _viewMenu;
    private DragPreviewOverlay _dragPreviewOverlay;
    private FileManagerIconAtlas _iconAtlas;
    private bool _iconAtlasLoadAttempted;
    version (Windows)
        private PropertiesWindow _propertiesWindow;
    private ExplorerEntry[] _entries;
    private ExplorerEntry[] _folderEntries;
    private VisibleRow[] _visibleRows;
    private int[] _visibleRowOffsets;
    private int[] _visibleRowColumns;
    private int _visibleContentHeight;
    private bool _visibleRowOffsetsDirty = true;
    private FileViewMode _visibleRowOffsetsViewMode = FileViewMode.details;
    private int _visibleRowOffsetsUsableListWidth = -1;
    private int _visibleRowOffsetsUiZoomPercent = -1;
    private NavigationItem[] _navigation;
    private string _currentPath;
    private bool _showQuickAccess;
    private bool _showThisPc;
    private string _searchQuery;
    private string _locateQuery;
    private bool _locateActive;
    private bool _renamingActive;
    private string _renamingOriginalPath;
    private int _renamingVisibleIndex = -1;
    private string[] _itemClipboardPaths;
    private bool _itemClipboardCut;
    private uint _itemClipboardSequence;
    private string _statusText = "Ready";
    private string[] _recentFiles;
    private string[] _history;
    private int _historyIndex = -1;
    private int _uiZoomPercent = defaultUiZoomPercent;
    private int _selectedVisibleIndex = -1;
    private bool[int] _selectedVisibleRows;
    private int _selectionAnchorVisibleIndex = -1;
    private FileViewMode _viewMode = FileViewMode.details;
    private SortColumn _sortColumn = SortColumn.name;
    private bool _sortAscending = true;
    private GroupBy _groupBy = GroupBy.none;
    private bool _groupAscending;
    private int _scrollY;
    private int _sidebarScrollY;
    private int _listSmoothScrollTargetY;
    private int _sidebarSmoothScrollTargetY;
    private bool _listSmoothScrollActive;
    private bool _sidebarSmoothScrollActive;
    private int _listWheelPixelRemainder;
    private int _sidebarWheelPixelRemainder;
    private bool _thisPcHoverArea;
    private double _thisPcArrowOpacity;
    private double _autoRefreshClock;
    private string _watchedFolderPath;
    private ulong _watchedFolderFingerprint;
    private size_t _watchedFolderCount;
    private bool _watchedFolderValid;
    version (Windows)
        private HANDLE _folderChangeHandle;
    private CommandButton _pressedCommand = CommandButton.none;
    private bool _pendingEntryDrag;
    private bool _draggingEntry;
    private bool _rubberBandSelecting;
    private Point _rubberBandStart;
    private Point _rubberBandCurrent;
    private bool[int] _rubberBandBaseSelection;
    private int _dragSourceVisibleIndex = -1;
    private int _dropTargetVisibleIndex = -1;
    private int _dropTargetNavigationIndex = -1;
    private Point _dragStart;
    private Point _dragCurrent;
    private Rect _addressRect;
    private Rect _addressTextRect;
    private Rect _searchRect;
    private Rect _searchTextRect;
    private Rect _locateRect;
    private Rect _locateTextRect;
    private Rect _newFolderRect;
    private Rect _newTextFileRect;
    private Rect _openSelectedRect;
    private Rect _copyPathRect;
    private Rect _homeTabRect;
    private Rect _viewTabRect;
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
    private Rect _nameHeaderRect;
    private Rect _dateHeaderRect;
    private Rect _typeHeaderRect;
    private Rect _sizeHeaderRect;
    private int _usableListWidth;
    private int _dateX;
    private int _typeX;
    private int _sizeX;
    private int _sizeWidth;
    private AddressSegment[] _addressSegments;
    private bool _addressEditing;
    private int _addressHoverIndex = -1;

    void delegate(string title) onTitleChanged;

    this(GuiWindow window, string initialPath = "")
    {
        _window = window;
        setFocusable(true);
        layoutHints().minWidth = scaled(820);
        layoutHints().minHeight = scaled(500);

        _addressField = add(new AddressField());
        _addressField.setTransparentBackground(true);
        _addressField.setShowBorder(false);
        _addressField.setPadding(scaled(4));
        _addressField.setTextColor(explorerText);
        _addressField.setVisible(false);
        _addressField.onSubmitted = delegate() { submitAddress(); };
        _addressField.onPreviewKeyDown = delegate(ref Event event)
        {
            if (event.key == Key.escape && !event.control() &&
                !event.meta() && !event.alt())
            {
                _addressField.setText(_showThisPc ? "This PC" : _currentPath, false);
                requestFocus();
                invalidate();
                return true;
            }
            return false;
        };
        _addressField.onAddressLostFocus = delegate()
        {
            if (_addressEditing)
            {
                _addressEditing = false;
                _addressField.setVisible(false);
                _addressHoverIndex = -1;
                invalidate();
            }
        };

        _searchField = add(new TextField());
        _searchField.setTransparentBackground(true);
        _searchField.setShowBorder(false);
        _searchField.setPadding(scaled(5));
        _searchField.setTextColor(explorerText);
        _searchField.onChanged = delegate()
        {
            clearLocate();
            _searchQuery = _searchField.textUtf8();
            updateSearchResults();
        };
        _searchField.onSubmitted = delegate()
        {
            requestFocus();
        };

        auto locateField = new PreviewTextField();
        locateField.onPreviewKeyDown = delegate(ref Event event)
        {
            if (event.key == Key.escape && !event.control() &&
                !event.meta() && !event.alt())
            {
                closeLocate();
                return true;
            }
            if (event.key == Key.f3 && !event.control() &&
                !event.meta() && !event.alt())
            {
                updateLocateSelection(true);
                return true;
            }
            return false;
        };
        _locateField = add(locateField);
        _locateField.setTransparentBackground(true);
        _locateField.setShowBorder(false);
        _locateField.setPadding(scaled(4));
        _locateField.setTextColor(explorerText);
        _locateField.setVisible(false);
        _locateField.onChanged = delegate()
        {
            _locateQuery = _locateField.textUtf8();
            updateLocateSelection(false);
        };
        _locateField.onSubmitted = delegate()
        {
            updateLocateSelection(true);
        };

        auto renameField = new PreviewTextField();
        renameField.onPreviewKeyDown = delegate(ref Event event)
        {
            if (event.key == Key.escape && !event.control() &&
                !event.meta() && !event.alt())
            {
                cancelRename();
                return true;
            }
            return false;
        };
        _renameField = add(renameField);
        _renameField.setPadding(scaled(3));
        _renameField.setTextColor(explorerText);
        _renameField.setVisible(false);
        _renameField.onSubmitted = delegate()
        {
            commitRename();
        };

        _listScrollbar = add(new Scrollbar());
        _listScrollbar.setColors(explorerScrollbarTrack, explorerScrollbarThumb);
        _listScrollbar.onValueChanged = delegate(int value)
        {
            setListScroll(value);
        };

        _sidebarScrollbar = add(new Scrollbar());
        _sidebarScrollbar.setColors(explorerScrollbarTrack, explorerScrollbarThumb);
        _sidebarScrollbar.onValueChanged = delegate(int value)
        {
            setSidebarScroll(value);
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
        updateThisPcArrowFade(deltaSeconds);
        updateSmoothScrolling(deltaSeconds);
        pollFolderAutoRefresh(deltaSeconds);
    }

    override bool onMouseDown(ref Event event)
    {
        updateGeometry();
        if (_renamingActive && (_renameField is null ||
                !_renameField.bounds().contains(event.position)))
        {
            commitRename();
            return true;
        }
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
        if (_viewTabRect.contains(event.position))
        {
            showViewMenu();
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
            handleAddressClick(event.position);
            return true;
        }

        const sortColumn = sortColumnAt(event.position);
        if (sortColumn >= 0)
        {
            setSortColumn(cast(SortColumn) sortColumn);
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
            const individualSelection = event.shift() || event.control() || event.meta();
            if (individualSelection)
                toggleVisibleRowSelection(visibleIndex);
            else if (visibleRowSelected(visibleIndex) && selectedVisibleCount() > 1)
                _selectedVisibleIndex = visibleIndex;
            else
                selectSingleVisibleRow(visibleIndex);
            updateSelectedStatus();
            if (event.clickCount >= 2 && !individualSelection)
            {
                activateEntry(visibleIndex);
            }
            else if (!individualSelection)
            {
                beginEntryDrag(visibleIndex, event.position);
            }
            invalidate();
            return true;
        }

        if (_rowsRect.contains(event.position))
        {
            beginRubberBandSelection(event.position, event.shift() ||
                event.control() || event.meta());
            invalidate();
            return true;
        }

        return true;
    }

override bool onMouseMove(ref Event event)
    {
        updateThisPcHoverArea(event.position);
        const hoverIndex = addressSegmentIndexAt(event.position);
        if (hoverIndex != _addressHoverIndex)
        {
            _addressHoverIndex = hoverIndex;
            invalidate();
        }
        if (_pendingEntryDrag || _draggingEntry)
        {
            updateEntryDrag(event.position);
            return true;
        }
        if (_rubberBandSelecting)
        {
            updateRubberBandSelection(event.position);
            return true;
        }
        return false;
    }

    protected override void onMouseLeave()
    {
        setThisPcHoverArea(false);
        if (_addressHoverIndex >= 0)
        {
            _addressHoverIndex = -1;
            invalidate();
        }
    }

    override bool onMouseUp(ref Event event)
    {
        if (event.button != MouseButton.left) return false;
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
        if (_rubberBandSelecting)
        {
            finishRubberBandSelection();
            releaseMouse();
            return true;
        }
        return false;
    }

    override bool nativeVerticalScrollInfo(Point localPosition, out Widget source,
        out int position, out int maximum, out int pageSize)
    {
        Scrollbar target;
        if (_sidebarRowsRect.contains(localPosition))
            target = _sidebarScrollbar;
        else if (_rowsRect.contains(localPosition))
            target = _listScrollbar;
        if (target is null || !target.visible())
        {
            source = null;
            position = 0;
            maximum = 0;
            pageSize = 1;
            return false;
        }
        return target.nativeVerticalScrollInfo(localPosition, source, position,
            maximum, pageSize);
    }

    override bool onMouseWheel(ref Event event)
    {
        updateGeometry();
        if (event.hasVerticalScrollPosition)
        {
            setListScroll(event.verticalScrollPosition);
            return true;
        }
        if (event.control() || event.meta())
        {
            if (event.wheelY == 0) return false;
            setUiZoomPercent(_uiZoomPercent + (event.wheelY > 0 ? 10 : -10));
            return true;
        }

        if (_sidebarRect.contains(event.position))
        {
            return scrollSidebarByWheel(event.wheelY, event.wheelX);
        }
        if (_mainRect.contains(event.position))
        {
            return scrollListByWheel(event.wheelY, event.wheelX);
        }
        return false;
    }

    private bool scrollListByWheel(int verticalUnits, int horizontalUnits)
    {
        const units = wheelScrollUnits(verticalUnits, horizontalUnits);
        if (units == 0) return false;
        const pixels = wheelPixelsFromUnits(units, rowHeightPx(), _listWheelPixelRemainder);
        if (pixels != 0)
            animateListScrollTo((_listSmoothScrollActive ? _listSmoothScrollTargetY :
                _scrollY) - pixels);
        return true;
    }

    private bool scrollSidebarByWheel(int verticalUnits, int horizontalUnits)
    {
        const units = wheelScrollUnits(verticalUnits, horizontalUnits);
        if (units == 0) return false;
        const pixels = wheelPixelsFromUnits(units, sidebarRowHeightPx(),
            _sidebarWheelPixelRemainder);
        if (pixels != 0)
            animateSidebarScrollTo((_sidebarSmoothScrollActive ? _sidebarSmoothScrollTargetY :
                _sidebarScrollY) - pixels);
        return true;
    }

    private static int wheelScrollUnits(int verticalUnits, int horizontalUnits)
        @safe pure nothrow @nogc
    {
        return verticalUnits != 0 ? verticalUnits : horizontalUnits;
    }

    private static int wheelPixelsFromUnits(int units, int pixelsPerNotch,
        ref int remainder) @safe pure nothrow @nogc
    {
        const scaledPixels = units * pixelsPerNotch + remainder;
        const pixels = scaledPixels / wheelUnitsPerNotch;
        remainder = scaledPixels - pixels * wheelUnitsPerNotch;
        return pixels;
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
            event.key == Key.f2)
        {
            beginRenameSelected();
            return true;
        }
        if (!event.control() && !event.meta() && !event.alt() &&
            event.key == Key.deleteKey)
        {
            deleteSelectedItem();
            return true;
        }
        if (!event.control() && !event.meta() && !event.alt() &&
            handleListNavigationKey(event.key, event.shift()))
            return true;
        if (event.key == Key.enter && _selectedVisibleIndex >= 0)
        {
            activateEntry(_selectedVisibleIndex);
            return true;
        }
        if (event.key == Key.escape && _locateActive)
        {
            closeLocate();
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
                beginAddressEditing();
                return true;
            }
            if (event.key == Key.f)
            {
                beginLocate();
                return true;
            }
            if (event.key == Key.n)
            {
                createNewFolder();
                return true;
            }
            if (event.key == Key.c && event.shift() && _selectedVisibleIndex >= 0)
            {
                copySelectedPath();
                return true;
            }
            if (event.key == Key.c)
            {
                copySelectedItem();
                return true;
            }
            if (event.key == Key.x)
            {
                cutSelectedItem();
                return true;
            }
            if (event.key == Key.v)
            {
                pasteClipboardToDefaultTarget();
                return true;
            }
        }
        return false;
    }

    override bool onDragEnter(ref Event event)
    {
        if (event.dragPayload.paths.length == 0) return false;
        event.dragAction = fileDropAction(event);
        return event.dragAction != DragAction.none;
    }

    override bool onDragMove(ref Event event)
    {
        return onDragEnter(event);
    }

    override bool onDrop(ref Event event)
    {
        if (event.dragPayload.paths.length == 0)
            return super.onDrop(event);
        const targetDirectory = dropTargetDirectoryAt(event.position, "", true);
        if (targetDirectory.length == 0)
            return super.onDrop(event);
        event.dragAction = fileDropAction(event);
        if (event.dragAction == DragAction.move)
            moveDroppedPaths(event.dragPayload.paths, targetDirectory);
        else if (event.dragAction == DragAction.copy)
            copyDroppedPaths(event.dragPayload.paths, targetDirectory);
        else
            return false;
        return true;
    }

    private DragAction fileDropAction(ref Event event) const
    {
        if (event.suggestedDragAction == DragAction.move &&
            allowsDragAction(event.allowedDragActions, DragAction.move))
            return DragAction.move;
        if (allowsDragAction(event.allowedDragActions, DragAction.copy))
            return DragAction.copy;
        if (allowsDragAction(event.allowedDragActions, DragAction.move))
            return DragAction.move;
        return DragAction.none;
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

    private void beginRubberBandSelection(Point position, bool additive)
    {
        resetEntryDrag(false);
        _rubberBandSelecting = true;
        _rubberBandStart = position;
        _rubberBandCurrent = position;
        _rubberBandBaseSelection = additive ? _selectedVisibleRows.dup : null;
        if (!additive)
            clearSelection();
        updateRubberBandSelection(position);
        captureMouse();
    }

    private void updateRubberBandSelection(Point position)
    {
        if (!_rubberBandSelecting) return;
        _rubberBandCurrent = Point(
            clampInt(position.x, _rowsRect.x, _rowsRect.right()),
            clampInt(position.y, _rowsRect.y, _rowsRect.bottom()));
        _selectedVisibleRows = _rubberBandBaseSelection.dup;

        const selectionRect = rubberBandRect();
        foreach (visibleIndex; cast(size_t) firstViewportVisibleRowIndex() .. _visibleRows.length)
        {
            const row = visibleRowRect(cast(int) visibleIndex);
            if (row.bottom() <= _rowsRect.y) continue;
            if (row.y >= _rowsRect.bottom()) break;
            if (!visibleRowSelectable(cast(int) visibleIndex)) continue;
            if (!row.intersection(selectionRect).empty())
            {
                _selectedVisibleRows[cast(int) visibleIndex] = true;
                _selectedVisibleIndex = cast(int) visibleIndex;
                if (!visibleRowSelectable(_selectionAnchorVisibleIndex))
                    _selectionAnchorVisibleIndex = cast(int) visibleIndex;
            }
        }
        if (selectedVisibleCount() == 0)
            _selectedVisibleIndex = -1;
        updateSelectedStatus();
        invalidate();
    }

    private void finishRubberBandSelection()
    {
        _rubberBandSelecting = false;
        _rubberBandBaseSelection = null;
        if (selectedVisibleCount() == 0)
            clearSelection();
        updateSelectedStatus();
        invalidate();
    }

    private Rect rubberBandRect() const
    {
        const left = minInt(_rubberBandStart.x, _rubberBandCurrent.x);
        const top = minInt(_rubberBandStart.y, _rubberBandCurrent.y);
        const right = maxInt(_rubberBandStart.x, _rubberBandCurrent.x);
        const bottom = maxInt(_rubberBandStart.y, _rubberBandCurrent.y);
        return Rect(left, top, maxInt(1, right - left), maxInt(1, bottom - top))
            .intersection(_rowsRect);
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
            if (!Rect(0, 0, bounds().width, bounds().height).contains(position))
            {
                beginOutboundEntryDrag();
                return;
            }
            updateDropTargets(position);
            updateExternalDragPreview();
        }
        invalidate();
    }

    private void beginOutboundEntryDrag()
    {
        if (!hasDragSource()) return;
        auto paths = selectedPaths();
        if (paths.length == 0) paths = [dragSourceEntry().path];
        DragPayload payload;
        payload.paths = paths;
        payload.text = toUTF32(paths[0]).idup;
        hideExternalDragPreview();
        const action = beginDrag(payload, dragActions(DragAction.copy,
            DragAction.move, DragAction.link));
        _statusText = action == DragAction.none ? "Drag canceled." :
            "External drag completed.";
        resetEntryDrag(true);
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

    private bool handleListNavigationKey(Key key, bool extendSelection)
    {
        if (visibleItemCount() == 0) return false;

        int target = -1;
        switch (key)
        {
            case Key.left:
                target = _selectedVisibleIndex < 0
                    ? firstEntryVisibleIndex()
                    : adjacentEntryVisibleIndex(_selectedVisibleIndex, -1);
                break;
            case Key.right:
                target = _selectedVisibleIndex < 0
                    ? firstEntryVisibleIndex()
                    : adjacentEntryVisibleIndex(_selectedVisibleIndex, 1);
                break;
            case Key.up:
                target = _selectedVisibleIndex < 0
                    ? lastEntryVisibleIndex()
                    : verticalEntryVisibleIndex(_selectedVisibleIndex, -1);
                break;
            case Key.down:
                target = _selectedVisibleIndex < 0
                    ? firstEntryVisibleIndex()
                    : verticalEntryVisibleIndex(_selectedVisibleIndex, 1);
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
        selectVisibleEntryByKeyboard(target, extendSelection);
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

    private int verticalEntryVisibleIndex(int start, int direction) const
    {
        if (!usesMultiColumnView())
            return adjacentEntryVisibleIndex(start, direction);

        const blockStart = entryBlockStart(start);
        const blockEnd = entryBlockEnd(start);
        if (blockStart < 0 || blockEnd <= blockStart)
            return adjacentEntryVisibleIndex(start, direction);

        const columns = viewColumnCount();
        const target = start + direction * columns;
        if (target >= blockStart && target < blockEnd &&
            entryIndexForVisibleRow(target) >= 0)
            return target;

        return direction < 0
            ? adjacentEntryVisibleIndex(blockStart, -1)
            : adjacentEntryVisibleIndex(blockEnd - 1, 1);
    }

    private int entryBlockStart(int visibleIndex) const
    {
        if (entryIndexForVisibleRow(visibleIndex) < 0) return -1;
        int index = visibleIndex;
        while (index > 0 && entryIndexForVisibleRow(index - 1) >= 0)
            --index;
        return index;
    }

    private int entryBlockEnd(int visibleIndex) const
    {
        if (entryIndexForVisibleRow(visibleIndex) < 0) return -1;
        int index = visibleIndex + 1;
        while (index < cast(int) _visibleRows.length &&
            entryIndexForVisibleRow(index) >= 0)
            ++index;
        return index;
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

    private void selectVisibleEntryByKeyboard(int visibleIndex, bool extendSelection)
    {
        if (entryIndexForVisibleRow(visibleIndex) < 0) return;
        if (extendSelection)
        {
            const anchor = visibleRowSelectable(_selectionAnchorVisibleIndex)
                ? _selectionAnchorVisibleIndex
                : (_selectedVisibleIndex >= 0 ? _selectedVisibleIndex : visibleIndex);
            selectVisibleRange(anchor, visibleIndex);
        }
        else
            selectSingleVisibleRow(visibleIndex);
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
        bool allowCurrentFolder)
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

    private void copyDroppedPaths(string[] paths, string targetDirectory)
    {
        int copied;
        string lastCopiedPath;
        foreach (path; paths)
        {
            const copiedPath = copyPathIntoDirectory(path, targetDirectory);
            if (copiedPath.length > 0)
            {
                ++copied;
                lastCopiedPath = copiedPath;
            }
        }

        if (copied > 0)
        {
            navigate(_currentPath, false, false);
            if (copied == 1 && pathsEqual(dirName(lastCopiedPath), _currentPath))
                selectPath(lastCopiedPath);
            _statusText = copied == 1 ? "Copied " ~ baseName(lastCopiedPath) ~ "." :
                format("Copied %d items.", copied);
        }
        else if (_statusText.length == 0)
            _statusText = "No items copied.";
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

    private string copyPathIntoDirectory(string sourcePath, string targetDirectory)
    {
        try
        {
            const source = buildNormalizedPath(sourcePath);
            const target = buildNormalizedPath(targetDirectory);
            if (!exists(source))
            {
                _statusText = "Cannot copy missing item: " ~ source;
                return "";
            }
            if (!exists(target) || !isDir(target))
            {
                _statusText = "Cannot copy to unavailable folder: " ~ target;
                return "";
            }
            if (pathsEqual(source, target))
            {
                _statusText = "Cannot copy a folder into itself.";
                return "";
            }
            if (isDir(source) && isSameOrDescendantPath(target, source))
            {
                _statusText = "Cannot copy a folder into itself.";
                return "";
            }

            const name = baseName(source);
            if (name.length == 0)
            {
                _statusText = "Cannot copy a drive root.";
                return "";
            }

            const destination = uniqueDestinationPath(target, name);
            copyPathRecursive(source, destination);
            return destination;
        }
        catch (Exception error)
        {
            _statusText = "Cannot copy item: " ~ error.msg;
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
        if (_locateField !is null)
            _locateField.setPadding(scaled(4));
        if (_renameField !is null)
            _renameField.setPadding(scaled(3));
    }

    private void layoutTextFields()
    {
        if (_addressField !is null)
            _addressField.setBounds(_addressTextRect);
        if (_searchField !is null)
            _searchField.setBounds(_searchTextRect);
        if (_locateField !is null)
            _locateField.setBounds(_locateTextRect);
        updateRenameFieldBounds();
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
        final switch (_viewMode)
        {
            case FileViewMode.extraLargeIcons:
                return maxInt(128, scaled(134));
            case FileViewMode.largeIcons:
                return maxInt(108, scaled(110));
            case FileViewMode.mediumIcons:
                return maxInt(86, scaled(90));
            case FileViewMode.smallIcons:
                return maxInt(29, inlineEntryIconSizePx() + scaled(7));
            case FileViewMode.list:
                return maxInt(26, inlineEntryIconSizePx() + scaled(6));
            case FileViewMode.details:
                return maxInt(26, inlineEntryIconSizePx() + scaled(6));
            case FileViewMode.tiles:
                return maxInt(58, tileEntryIconSizePx() + scaled(18));
            case FileViewMode.content:
                return maxInt(56, tileEntryIconSizePx() + scaled(16));
        }
    }

    private int viewIconSizePx() const @safe pure nothrow @nogc
    {
        final switch (_viewMode)
        {
            case FileViewMode.extraLargeIcons:
                return maxInt(76, scaled(80));
            case FileViewMode.largeIcons:
                return maxInt(58, scaled(62));
            case FileViewMode.mediumIcons:
                return maxInt(44, scaled(46));
            case FileViewMode.smallIcons:
            case FileViewMode.list:
            case FileViewMode.details:
                return inlineEntryIconSizePx();
            case FileViewMode.tiles:
            case FileViewMode.content:
                return tileEntryIconSizePx();
        }
    }

    private int viewCellWidthPx() const @safe pure nothrow @nogc
    {
        final switch (_viewMode)
        {
            case FileViewMode.extraLargeIcons:
                return scaled(160);
            case FileViewMode.largeIcons:
                return scaled(140);
            case FileViewMode.mediumIcons:
                return scaled(116);
            case FileViewMode.smallIcons:
            case FileViewMode.list:
                return scaled(200);
            case FileViewMode.details:
            case FileViewMode.content:
                return maxInt(scaled(120), _usableListWidth - scaled(24));
            case FileViewMode.tiles:
                return scaled(260);
        }
    }

    private int inlineEntryIconSizePx() const @safe pure nothrow @nogc
    {
        return maxInt(18, scaled(20));
    }

    private int tileEntryIconSizePx() const @safe pure nothrow @nogc
    {
        return maxInt(36, scaled(38));
    }

    private int inlineEntryTextXOffsetPx() const @safe pure nothrow @nogc
    {
        return scaled(6) + inlineEntryIconSizePx() + scaled(7);
    }

    private int entryTextPixelSize() const @safe pure nothrow @nogc
    {
        return fontPixelSize(entryTextScale());
    }

    private int entryTextScale() const @safe pure nothrow @nogc
    {
        return textScale();
    }

    private int entryLineHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(scaled(24), entryTextPixelSize() + scaled(7));
    }

    private int groupHeaderHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(24, scaled(groupHeaderHeight));
    }

    private int quickAccessSeparatorHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(8, scaled(quickAccessSeparatorHeight));
    }

    private int maximumVisibleRowHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(rowHeightPx(), maxInt(groupHeaderHeightPx(),
            quickAccessSeparatorHeightPx()));
    }

    private int sidebarRowHeightPx() const @safe pure nothrow @nogc
    {
        return maxInt(23, scaled(sidebarRowHeight));
    }

    private int sidebarIconSizePx() const @safe pure nothrow @nogc
    {
        return maxInt(18, scaled(20));
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
        const header = _viewMode == FileViewMode.details ? headerHeightPx() : 0;
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
        const locateWidth = clampInt(w / 4, scaled(190), scaled(340));
        const locateHeight = maxInt(scaled(20), status - scaled(6));
        _locateRect = Rect(maxInt(_statusRect.x + scaled(180),
                _statusRect.right() - locateWidth - scaled(12)),
            _statusRect.y + maxInt(0, (status - locateHeight) / 2),
            locateWidth, locateHeight);
        _locateTextRect = Rect(_locateRect.x + scaled(54), _locateRect.y + scaled(1),
            maxInt(0, _locateRect.width - scaled(62)),
            maxInt(0, _locateRect.height - scaled(2)));
        _homeTabRect = Rect(scaled(82), 0, scaled(62), ribbon);
        _viewTabRect = Rect(scaled(218), 0, scaled(62), ribbon);
        _newFolderRect = Rect.init;
        _newTextFileRect = Rect.init;
        _openSelectedRect = Rect.init;
        _copyPathRect = Rect.init;

        updateColumnGeometry();
        ensureVisibleRowOffsets();
        _scrollY = clampInt(_scrollY, 0, maxListScroll());
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

        addNavigation("Quick Access", "", IconKind.open, false,
            NavigationKind.quickAccess, true);
        if (!addNativeQuickAccessNavigationFolders())
            addDefaultQuickAccessNavigationFolders();
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
        item.enabled = forceEnabled || filesystemFolderExists(path);
        _navigation ~= item;
    }

    private bool addNativeQuickAccessNavigationFolders()
    {
        version (Windows)
        {
            size_t count;
            foreach (item; windowsQuickAccessItems())
            {
                if (!item.isFolder) continue;
                if (count >= quickAccessFrequentFolderLimit) break;
                if (addQuickAccessNavigationFolder(item.displayName, item.path,
                        quickAccessNavigationIcon(item.displayName, item.path)))
                    ++count;
            }
            return count > 0;
        }
        else
            return false;
    }

    private void addDefaultQuickAccessNavigationFolders()
    {
        addQuickAccessNavigationFolder("Desktop", defaultDesktopFolder(),
            IconKind.computer);
        addQuickAccessNavigationFolder("Downloads", defaultDownloadsFolder(),
            IconKind.open);
        addQuickAccessNavigationFolder("Documents", defaultDocumentsFolder(),
            IconKind.notepad);
        addQuickAccessNavigationFolder("Pictures", defaultPicturesFolder(),
            IconKind.image);
        addQuickAccessNavigationFolder("Videos", defaultVideosFolder(),
            IconKind.music);
        addQuickAccessNavigationFolder("Music", defaultMusicFolder(),
            IconKind.music);
        addQuickAccessNavigationFolder("OneDrive - Personal",
            defaultOneDriveFolder(), IconKind.drive);
    }

    private bool addQuickAccessNavigationFolder(string label, string path,
        IconKind icon)
    {
        if (!filesystemFolderExists(path)) return false;
        if (navigationContainsFolderPath(path)) return false;
        const displayName = label.length > 0 ? label : folderDisplayName(path);
        addNavigation(displayName, path, icon, true, NavigationKind.folder, false, 1);
        return true;
    }

    private bool navigationContainsFolderPath(string path) const
    {
        foreach (item; _navigation)
        {
            if (item.kind == NavigationKind.folder && item.path.length > 0 &&
                pathsEqual(item.path, path))
                return true;
        }
        return false;
    }

    private static IconKind quickAccessNavigationIcon(string label, string path)
    {
        if (icmp(label, "Desktop") == 0 || pathsEqual(path, defaultDesktopFolder()))
            return IconKind.computer;
        if (icmp(label, "Downloads") == 0 || pathsEqual(path, defaultDownloadsFolder()))
            return IconKind.open;
        if (icmp(label, "Documents") == 0 || pathsEqual(path, defaultDocumentsFolder()))
            return IconKind.notepad;
        if (icmp(label, "Pictures") == 0 || pathsEqual(path, defaultPicturesFolder()))
            return IconKind.image;
        if (icmp(label, "Music") == 0 || pathsEqual(path, defaultMusicFolder()))
            return IconKind.music;
        if (icmp(label, "Videos") == 0 || pathsEqual(path, defaultVideosFolder()))
            return IconKind.music;
        if (containsInsensitive(label, "onedrive"))
            return IconKind.drive;
        return IconKind.folder;
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
        _navigation[$ - 1].thisPcChild = true;
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

    private void navigate(string candidate, bool addHistory, bool clearSearch)
    {
        const path = resolvePath(candidate);
        const enteringNewFolder = _currentPath.length == 0 || !pathsEqual(_currentPath, path);
        if (enteringNewFolder)
            clearLocate();
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
            clearSelection();
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
        const downloads = defaultDownloadsFolder();
        return downloads.length > 0 && pathsEqual(path, downloads);
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
        clearSelection();
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

    private void beginLocate()
    {
        if (_locateField is null) return;
        _locateActive = true;
        _locateField.setVisible(true);
        _locateField.requestFocus();
        _locateField.selectAll();
        if (_locateQuery.length == 0)
        {
            _statusText = "Type to locate an item in " ~ locateScopeText() ~ ".";
            invalidate();
        }
        else
            updateLocateSelection(false);
    }

    private void clearLocate()
    {
        _locateActive = false;
        _locateQuery = "";
        if (_locateField !is null)
        {
            _locateField.setText("", false);
            _locateField.setVisible(false);
        }
    }

    private void closeLocate()
    {
        const hadSelection = hasSelection();
        clearLocate();
        requestFocus();
        if (hadSelection)
            updateSelectedStatus();
        else
            updateStatus();
        invalidate();
    }

    private void updateLocateSelection(bool findNext)
    {
        if (!_locateActive) return;
        const loweredQuery = _locateQuery.toLower();
        if (loweredQuery.length == 0)
        {
            _statusText = "Type to locate an item in " ~ locateScopeText() ~ ".";
            invalidate();
            return;
        }

        const matchCount = locateMatchCount(loweredQuery);
        if (matchCount == 0)
        {
            _statusText = "No matches for \"" ~ _locateQuery ~ "\" in " ~
                locateScopeText() ~ ".";
            invalidate();
            return;
        }

        if (!findNext && hasSelection() &&
            containsInsensitive(selectedEntry().name, loweredQuery))
        {
            updateLocateStatus(loweredQuery, matchCount);
            invalidate();
            return;
        }

        const startVisibleIndex = findNext ? _selectedVisibleIndex : -1;
        int match = locateVisibleMatch(loweredQuery, startVisibleIndex, true);
        if (match < 0)
            match = locateVisibleMatch(loweredQuery, startVisibleIndex, false);
        if (match < 0)
        {
            _statusText = "No visible matches for \"" ~ _locateQuery ~ "\" in " ~
                locateScopeText() ~ ".";
            invalidate();
            return;
        }

        selectSingleVisibleRow(match);
        ensureSelectionVisible();
        updateLocateStatus(loweredQuery, matchCount);
        invalidate();
    }

    private int locateVisibleMatch(string loweredQuery, int startVisibleIndex,
        bool prefixOnly) const
    {
        if (_visibleRows.length == 0) return -1;
        const rowCount = cast(int) _visibleRows.length;
        int start = startVisibleIndex >= 0 ? startVisibleIndex + 1 : 0;
        if (start >= rowCount) start = 0;
        foreach (offset; 0 .. rowCount)
        {
            const visibleIndex = (start + cast(int) offset) % rowCount;
            const entryIndex = entryIndexForVisibleRow(visibleIndex);
            if (entryIndex < 0) continue;
            const entry = _entries[cast(size_t) entryIndex];
            const matches = prefixOnly
                ? startsWithInsensitive(entry.name, loweredQuery)
                : containsInsensitive(entry.name, loweredQuery);
            if (matches) return visibleIndex;
        }
        return -1;
    }

    private size_t locateMatchCount(string loweredQuery) const
    {
        size_t count;
        foreach (row; _visibleRows)
        {
            if (row.entryIndex < 0) continue;
            if (containsInsensitive(_entries[cast(size_t) row.entryIndex].name,
                    loweredQuery))
                ++count;
        }
        return count;
    }

    private void updateLocateStatus(string loweredQuery, size_t matchCount)
    {
        if (!hasSelection()) return;
        const entry = selectedEntry();
        const ordinal = locateSelectedOrdinal(loweredQuery);
        const matchText = matchCount == 1 ? "match" : "matches";
        _statusText = format("Located %s (%d of %d %s)",
            entry.name, ordinal, matchCount, matchText);
    }

    private size_t locateSelectedOrdinal(string loweredQuery) const
    {
        size_t ordinal;
        foreach (visibleIndex, row; _visibleRows)
        {
            if (row.entryIndex < 0) continue;
            if (!containsInsensitive(_entries[cast(size_t) row.entryIndex].name,
                    loweredQuery))
                continue;
            ++ordinal;
            if (cast(int) visibleIndex == _selectedVisibleIndex)
                return ordinal;
        }
        return ordinal;
    }

    private string locateScopeText() const
    {
        if (_showQuickAccess) return "Quick Access";
        if (_showThisPc) return "This PC";
        return _currentPath.length > 0 ? folderDisplayName(_currentPath) :
            "current folder";
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
            clearSelection();
        setListScroll(_scrollY);
        updateStatus();
        invalidate();
    }

    private void ensureVisibleRowOffsets()
    {
        if (!_visibleRowOffsetsDirty &&
            _visibleRowOffsetsViewMode == _viewMode &&
            _visibleRowOffsetsUsableListWidth == _usableListWidth &&
            _visibleRowOffsetsUiZoomPercent == _uiZoomPercent &&
            _visibleRowOffsets.length == _visibleRows.length &&
            _visibleRowColumns.length == _visibleRows.length)
            return;
        rebuildVisibleRowOffsets();
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
        _visibleRowColumns.length = _visibleRows.length;
        _visibleContentHeight = 0;
        size_t index;
        while (index < _visibleRows.length)
        {
            const row = _visibleRows[index];
            if (row.entryIndex < 0)
            {
                _visibleRowOffsets[index] = _visibleContentHeight;
                _visibleRowColumns[index] = 0;
                _visibleContentHeight += row.separator
                    ? quickAccessSeparatorHeightPx() : groupHeaderHeightPx();
                ++index;
                continue;
            }

            const start = index;
            while (index < _visibleRows.length &&
                _visibleRows[index].entryIndex >= 0)
                ++index;

            const columns = viewColumnCount();
            const height = rowHeightPx();
            foreach (itemIndex; start .. index)
            {
                const relative = cast(int) (itemIndex - start);
                _visibleRowColumns[itemIndex] = relative % columns;
                _visibleRowOffsets[itemIndex] =
                    _visibleContentHeight + relative / columns * height;
            }
            const count = cast(int) (index - start);
            _visibleContentHeight += ((count + columns - 1) / columns) * height;
        }
        _visibleRowOffsetsDirty = false;
        _visibleRowOffsetsViewMode = _viewMode;
        _visibleRowOffsetsUsableListWidth = _usableListWidth;
        _visibleRowOffsetsUiZoomPercent = _uiZoomPercent;
    }

    private int firstViewportVisibleRowIndex() const
    {
        const rowCount = cast(int) _visibleRows.length;
        if (rowCount <= 0 || _visibleRowOffsets.length == 0) return 0;

        const threshold = maxInt(0, _scrollY - maximumVisibleRowHeightPx());
        int low;
        int high = rowCount;
        while (low < high)
        {
            const mid = low + (high - low) / 2;
            const offset = _visibleRowOffsets[cast(size_t) mid];
            if (offset < threshold)
                low = mid + 1;
            else
                high = mid;
        }

        if (low >= rowCount)
            low = rowCount - 1;

        // Multi-column icon/list rows share the same vertical offset. Back up
        // to the first item in that visual row so the left columns are not
        // skipped when a binary search lands in the middle of a grid row.
        while (low > 0 &&
            _visibleRowOffsets[cast(size_t) (low - 1)] ==
            _visibleRowOffsets[cast(size_t) low])
            --low;
        return low;
    }

    private int viewColumnCount() const @safe pure nothrow @nogc
    {
        if (!usesMultiColumnView()) return 1;
        const contentWidth = maxInt(1, _usableListWidth - scaled(24));
        return maxInt(1, contentWidth / maxInt(1, viewCellWidthPx()));
    }

    private bool usesMultiColumnView() const @safe pure nothrow @nogc
    {
        final switch (_viewMode)
        {
            case FileViewMode.extraLargeIcons:
            case FileViewMode.largeIcons:
            case FileViewMode.mediumIcons:
            case FileViewMode.smallIcons:
            case FileViewMode.list:
            case FileViewMode.tiles:
                return true;
            case FileViewMode.details:
            case FileViewMode.content:
                return false;
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
        if (_viewMode != FileViewMode.details) return -1;
        if (_nameHeaderRect.contains(point)) return cast(int) SortColumn.name;
        if (_dateHeaderRect.contains(point)) return cast(int) SortColumn.modified;
        if (_typeHeaderRect.contains(point)) return cast(int) SortColumn.type;
        if (_sizeHeaderRect.contains(point)) return cast(int) SortColumn.size;
        return -1;
    }

    private void setSortColumn(SortColumn column)
    {
        if (_showQuickAccess) return;
        auto selected = selectedPaths();
        const focusedPath = hasSelection() ? selectedEntry().path : "";
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
        if (selected.length > 0)
            selectPathsIfVisible(selected, focusedPath);
    }

    private void setGroupBy(GroupBy groupBy)
    {
        auto selected = selectedPaths();
        const focusedPath = hasSelection() ? selectedEntry().path : "";
        _groupBy = groupBy;
        if (_groupBy == GroupBy.dateModified)
        {
            _groupAscending = false;
            _sortColumn = SortColumn.modified;
            _sortAscending = false;
        }
        sortEntries(_entries);
        rebuildVisibleEntries();
        if (selected.length > 0)
            selectPathsIfVisible(selected, focusedPath);
    }

    private void setViewMode(FileViewMode mode)
    {
        if (_viewMode == mode) return;
        auto selected = selectedPaths();
        const focusedPath = hasSelection() ? selectedEntry().path : "";
        _viewMode = mode;
        _listWheelPixelRemainder = 0;
        updateGeometry();
        setListScroll(_scrollY);
        updateRenameFieldBounds();
        if (selected.length > 0)
            selectPathsIfVisible(selected, focusedPath);
        else
            invalidate();
    }

    private void appendViewModeItems(ref ContextMenuItem[] items)
    {
        appendViewModeItem(items, FileViewMode.extraLargeIcons);
        appendViewModeItem(items, FileViewMode.largeIcons);
        appendViewModeItem(items, FileViewMode.mediumIcons);
        appendViewModeItem(items, FileViewMode.smallIcons);
        appendViewModeItem(items, FileViewMode.list);
        appendViewModeItem(items, FileViewMode.details);
        appendViewModeItem(items, FileViewMode.tiles);
        appendViewModeItem(items, FileViewMode.content);
    }

    private void appendViewModeItem(ref ContextMenuItem[] items, FileViewMode mode)
    {
        items ~= ContextMenuItem.check(fileViewModeLabel(mode), _viewMode == mode,
            delegate() { setViewMode(mode); });
    }

    /// Adds a single cascading "View" item whose children list the view modes.
    /// Used by the right-click context menus (slides out to the right).
    private void appendViewModeSubmenu(ref ContextMenuItem[] items)
    {
        ContextMenuItem[] views;
        appendViewModeItems(views);
        items ~= ContextMenuItem.submenuItem("View", IconKind.none, views);
    }

    private static string fileViewModeLabel(FileViewMode mode)
    {
        final switch (mode)
        {
            case FileViewMode.extraLargeIcons:
                return "Extra large icons";
            case FileViewMode.largeIcons:
                return "Large icons";
            case FileViewMode.mediumIcons:
                return "Medium icons";
            case FileViewMode.smallIcons:
                return "Small icons";
            case FileViewMode.list:
                return "List";
            case FileViewMode.details:
                return "Details";
            case FileViewMode.tiles:
                return "Tiles";
            case FileViewMode.content:
                return "Content";
        }
    }

    private void openQuickAccess()
    {
        clearLocate();
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
        clearSelection();
        _scrollY = 0;
        rebuildVisibleEntries();
        updateWindowTitle();
    }

    private void openThisPc()
    {
        clearLocate();
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
        clearSelection();
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
                appendThisPcFolder(entries, "Desktop", defaultDesktopFolder());
                appendThisPcFolder(entries, "Documents", defaultDocumentsFolder());
                appendThisPcFolder(entries, "Downloads", defaultDownloadsFolder());
                appendThisPcFolder(entries, "Music", defaultMusicFolder());
                appendThisPcFolder(entries, "Pictures", defaultPicturesFolder());
                appendThisPcFolder(entries, "Videos", defaultVideosFolder());
                appendThisPcFolder(entries, "3D Objects", defaultThreeDObjectsFolder());

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
            foreach (path; [
                defaultDesktopFolder(),
                defaultDownloadsFolder(),
                defaultDocumentsFolder(),
                defaultPicturesFolder(),
                defaultVideosFolder()
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
            case CommandButton.copySelected:
                copySelectedItem();
                break;
            case CommandButton.cutSelected:
                cutSelectedItem();
                break;
            case CommandButton.paste:
                pasteClipboardToDefaultTarget();
                break;
            case CommandButton.copyPath:
                copySelectedPath();
                break;
            case CommandButton.renameSelected:
                beginRenameSelected();
                break;
            case CommandButton.deleteSelected:
                deleteSelectedItem();
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

    private void beginAddressEditing()
    {
        if (_addressEditing) return;
        _addressEditing = true;
        _addressField.setText(_showThisPc ? "This PC" : _currentPath, false);
        _addressField.setVisible(true);
        _addressField.requestFocus();
        _addressField.selectAll();
        _addressHoverIndex = -1;
        invalidate();
    }

    private void handleAddressClick(Point position)
    {
        if (_addressEditing) return;
        const index = addressSegmentIndexAt(position);
        if (index >= 0)
        {
            const seg = _addressSegments[cast(size_t) index];
            if (seg.thisPc)
                openThisPc();
            else if (seg.path.length > 0 && !_showQuickAccess && !_showThisPc &&
                !pathsEqual(seg.path, _currentPath))
                navigate(seg.path, true, true);
            return;
        }
        beginAddressEditing();
    }

    private int addressSegmentIndexAt(Point position) const
    {
        foreach (index, seg; _addressSegments)
        {
            if (seg.rect.contains(position))
                return cast(int) index;
        }
        return -1;
    }

    private void computeAddressSegments(ref Canvas canvas)
    {
        _addressSegments.length = 0;
        if (_addressEditing || _showQuickAccess || _showThisPc ||
            _currentPath.length == 0)
            return;

        string[] paths;
        string[] labels;
        const root = rootName(_currentPath);
        if (root.length > 0)
        {
            paths ~= "";
            labels ~= "This PC";
            paths ~= root;
            labels ~= displayRoot(root);
            string cumulative = root;
            foreach (part; splitPathParts(_currentPath[root.length .. $]))
            {
                cumulative = buildPath(cumulative, part);
                paths ~= cumulative;
                labels ~= part;
            }
        }
        else
        {
            paths ~= "";
            labels ~= "This PC";
            foreach (part; splitPathParts(_currentPath))
            {
                paths ~= part;
                labels ~= part;
            }
        }

        const separator = scaled(16);
        const chipPadding = scaled(6);
        int[] widths;
        widths.length = labels.length;
        foreach (index, label; labels)
            widths[cast(size_t) index] =
                canvas.measureText(toUTF32(label), textScale(), FontRole.ui).width;
        const available = _addressTextRect.width;
        long total = 0;
        foreach (index, width; widths)
        {
            if (index > 0) total += separator;
            total += widths[cast(size_t) index];
        }

        int firstIndex = 0;
        if (total > available && labels.length > 1)
        {
            long consumed = cast(long) available;
            int first = cast(int) labels.length;
            for (int i = cast(int) labels.length - 1; i >= 0; --i)
            {
                if (i < cast(int) labels.length - 1) consumed -= separator;
                consumed -= widths[cast(size_t) i];
                if (consumed < 0)
                {
                    first = i + 1;
                    consumed += widths[cast(size_t) i];
                    break;
                }
            }
            firstIndex = maxInt(1, minInt(first, cast(int) labels.length));
        }

        int x = _addressTextRect.x;
        int startIndex = 0;
        if (firstIndex > 0)
        {
            AddressSegment dots;
            dots.label = "...";
            dots.path = paths[cast(size_t) (firstIndex - 1)];
            dots.thisPc = false;
            dots.rect = Rect(x, _addressTextRect.y,
                widths[0] + chipPadding, _addressTextRect.height);
            _addressSegments ~= dots;
            startIndex = firstIndex;
            x = dots.rect.right() + separator;
        }

        foreach (index; startIndex .. cast(int) labels.length)
        {
            const segmentPath = paths[cast(size_t) index];
            if (x + widths[cast(size_t) index] > _addressTextRect.right())
                break;
            AddressSegment seg;
            seg.label = labels[cast(size_t) index];
            seg.path = segmentPath;
            seg.thisPc = index == 0;
            seg.rect = Rect(x - chipPadding / 2, _addressTextRect.y,
                widths[cast(size_t) index] + chipPadding, _addressTextRect.height);
            _addressSegments ~= seg;
            x += widths[cast(size_t) index] + chipPadding + separator;
        }
    }

    private void clearSelection()
    {
        _selectedVisibleRows = null;
        _selectedVisibleIndex = -1;
        _selectionAnchorVisibleIndex = -1;
    }

    private bool visibleRowSelectable(int visibleIndex) const
    {
        return entryIndexForVisibleRow(visibleIndex) >= 0;
    }

    private bool visibleRowSelected(int visibleIndex) const
    {
        if (!visibleRowSelectable(visibleIndex)) return false;
        return (visibleIndex in _selectedVisibleRows) !is null;
    }

    private int selectedVisibleCount() const
    {
        int count;
        foreach (visibleIndex, selected; _selectedVisibleRows)
            if (selected && visibleRowSelectable(visibleIndex))
                ++count;
        return count;
    }

    private void selectSingleVisibleRow(int visibleIndex, bool updateAnchor = true)
    {
        clearSelection();
        if (!visibleRowSelectable(visibleIndex)) return;
        _selectedVisibleRows[visibleIndex] = true;
        _selectedVisibleIndex = visibleIndex;
        if (updateAnchor)
            _selectionAnchorVisibleIndex = visibleIndex;
    }

    private void toggleVisibleRowSelection(int visibleIndex)
    {
        if (!visibleRowSelectable(visibleIndex)) return;
        if (visibleRowSelected(visibleIndex))
        {
            _selectedVisibleRows.remove(visibleIndex);
            if (_selectedVisibleIndex == visibleIndex)
                _selectedVisibleIndex = lastSelectedVisibleIndex();
            if (_selectionAnchorVisibleIndex == visibleIndex)
                _selectionAnchorVisibleIndex = _selectedVisibleIndex;
        }
        else
        {
            _selectedVisibleRows[visibleIndex] = true;
            _selectedVisibleIndex = visibleIndex;
            _selectionAnchorVisibleIndex = visibleIndex;
        }
        if (selectedVisibleCount() == 0)
            clearSelection();
    }

    private void focusVisibleRowForContextMenu(int visibleIndex)
    {
        if (!visibleRowSelectable(visibleIndex)) return;
        if (!visibleRowSelected(visibleIndex))
            selectSingleVisibleRow(visibleIndex);
        else
            _selectedVisibleIndex = visibleIndex;
        if (!visibleRowSelectable(_selectionAnchorVisibleIndex))
            _selectionAnchorVisibleIndex = visibleIndex;
    }

    private int lastSelectedVisibleIndex() const
    {
        int result = -1;
        foreach (visibleIndex, selected; _selectedVisibleRows)
        {
            if (!selected || !visibleRowSelectable(visibleIndex)) continue;
            if (result < 0 || visibleIndex > result)
                result = visibleIndex;
        }
        return result;
    }

    private void selectVisibleRange(int anchorVisibleIndex, int targetVisibleIndex)
    {
        if (!visibleRowSelectable(targetVisibleIndex)) return;
        if (!visibleRowSelectable(anchorVisibleIndex))
            anchorVisibleIndex = targetVisibleIndex;
        clearSelection();
        const low = minInt(anchorVisibleIndex, targetVisibleIndex);
        const high = maxInt(anchorVisibleIndex, targetVisibleIndex);
        foreach (visibleIndex; low .. high + 1)
            if (visibleRowSelectable(visibleIndex))
                _selectedVisibleRows[visibleIndex] = true;
        _selectedVisibleIndex = targetVisibleIndex;
        _selectionAnchorVisibleIndex = anchorVisibleIndex;
    }

    private string[] selectedPaths() const
    {
        string[] paths;
        foreach (visibleIndex; 0 .. cast(int) _visibleRows.length)
        {
            if (!visibleRowSelected(visibleIndex)) continue;
            const entryIndex = entryIndexForVisibleRow(visibleIndex);
            if (entryIndex >= 0)
                paths ~= _entries[cast(size_t) entryIndex].path;
        }
        return paths;
    }

    private ExplorerEntry[] selectedEntries() const
    {
        ExplorerEntry[] entries;
        foreach (visibleIndex; 0 .. cast(int) _visibleRows.length)
        {
            if (!visibleRowSelected(visibleIndex)) continue;
            const entryIndex = entryIndexForVisibleRow(visibleIndex);
            if (entryIndex >= 0)
                entries ~= _entries[cast(size_t) entryIndex];
        }
        return entries;
    }

    private bool allSelectedPathsCanModify() const
    {
        auto entries = selectedEntries();
        if (entries.length == 0) return false;
        foreach (entry; entries)
            if (!canModifyPath(entry.path))
                return false;
        return true;
    }

    private bool allSelectedPathsCanClipboard() const
    {
        auto entries = selectedEntries();
        if (entries.length == 0) return false;
        foreach (entry; entries)
            if (!canClipboardPath(entry.path))
                return false;
        return true;
    }

    private bool hasSelection() const
    {
        return selectedVisibleCount() > 0;
    }

    private ExplorerEntry selectedEntry() const
    {
        if (!visibleRowSelected(_selectedVisibleIndex)) return ExplorerEntry.init;
        return _entries[cast(size_t) entryIndexForVisibleRow(_selectedVisibleIndex)];
    }

    private bool canModifySelection() const
    {
        return selectedVisibleCount() == 1 && canModifyPath(selectedEntry().path);
    }

    private bool canClipboardSelection() const
    {
        return allSelectedPathsCanClipboard();
    }

    private static bool canModifyPath(string path)
    {
        return filesystemPathExists(path) && !isDriveRootPath(path);
    }

    private static bool canClipboardPath(string path)
    {
        return filesystemPathExists(path) && !isDriveRootPath(path);
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

    private void beginRenameSelected()
    {
        if (selectedVisibleCount() != 1)
        {
            _statusText = selectedVisibleCount() == 0
                ? "Select a file or folder to rename."
                : "Select exactly one item to rename.";
            invalidate();
            return;
        }
        if (!canModifySelection())
        {
            _statusText = "Select a file or folder to rename.";
            invalidate();
            return;
        }
        beginRenamePath(selectedEntry().path);
    }

    private void beginRenamePath(string path)
    {
        if (!canModifyPath(path))
        {
            _statusText = "Cannot rename this item.";
            invalidate();
            return;
        }

        if (!hasSelection() || !pathsEqual(selectedEntry().path, path))
        {
            if (!selectPathIfVisible(path))
            {
                const parent = dirName(path);
                if (!filesystemFolderExists(parent))
                {
                    _statusText = "Cannot rename this item.";
                    invalidate();
                    return;
                }
                navigate(parent, true, true);
                selectPath(path);
            }
        }

        if (!hasSelection() || !pathsEqual(selectedEntry().path, path))
        {
            _statusText = "Cannot show rename editor for this item.";
            invalidate();
            return;
        }

        clearLocate();
        resetEntryDrag(false);
        _renamingActive = true;
        _renamingOriginalPath = path;
        _renamingVisibleIndex = _selectedVisibleIndex;
        ensureSelectionVisible();
        updateRenameFieldBounds();
        if (_renameField !is null)
        {
            _renameField.setText(baseName(path), false);
            updateRenameFieldBounds();
            _renameField.requestFocus();
            _renameField.selectAll();
        }
        _statusText = "Rename " ~ baseName(path);
        invalidate();
    }

    private bool commitRename()
    {
        if (!_renamingActive) return true;
        if (_renameField is null)
        {
            finishRenameState();
            return true;
        }

        const source = _renamingOriginalPath;
        const oldName = baseName(source);
        const newName = _renameField.textUtf8().strip();
        string validationError;
        if (!validItemName(newName, validationError))
        {
            _statusText = validationError;
            _renameField.requestFocus();
            _renameField.selectAll();
            invalidate();
            return false;
        }
        if (newName == oldName)
        {
            cancelRename();
            return true;
        }

        const destination = buildNormalizedPath(dirName(source), newName);
        if (filesystemPathExists(destination) && !pathsEqual(source, destination))
        {
            _statusText = "An item named " ~ newName ~ " already exists.";
            _renameField.requestFocus();
            _renameField.selectAll();
            invalidate();
            return false;
        }

        try
        {
            renameFile(source, destination);
        }
        catch (Exception error)
        {
            _statusText = "Cannot rename " ~ oldName ~ ": " ~ error.msg;
            _renameField.requestFocus();
            _renameField.selectAll();
            invalidate();
            return false;
        }

        finishRenameState();
        refreshAfterFilesystemMutation(destination);
        selectPath(destination);
        _statusText = "Renamed " ~ oldName ~ " to " ~ newName ~ ".";
        invalidate();
        return true;
    }

    private void cancelRename()
    {
        if (!_renamingActive) return;
        finishRenameState();
        requestFocus();
        if (hasSelection())
            updateSelectedStatus();
        else
            updateStatus();
        invalidate();
    }

    private void finishRenameState()
    {
        _renamingActive = false;
        _renamingOriginalPath = "";
        _renamingVisibleIndex = -1;
        if (_renameField !is null)
        {
            _renameField.setText("", false);
            _renameField.setVisible(false);
        }
    }

    private void deleteSelectedItem()
    {
        const entries = selectedEntries();
        if (entries.length == 0)
        {
            _statusText = "Select a file or folder to delete.";
            invalidate();
            return;
        }
        foreach (entry; entries)
        {
            if (!canModifyPath(entry.path))
            {
                _statusText = "Cannot delete one or more selected items.";
                invalidate();
                return;
            }
        }
        if (entries.length == 1)
        {
            const entry = entries[0];
            deletePathFromUi(entry.path, entry.name);
            return;
        }
        deleteSelectedPathsFromUi(entries);
    }

    private void deleteSelectedPathsFromUi(const ExplorerEntry[] entries)
    {
        clearLocate();
        if (_renamingActive)
            finishRenameState();
        resetEntryDrag(false);

        int deleted;
        foreach (entry; entries)
        {
            try
            {
                version (Windows)
                {
                    bool aborted;
                    const removed = recyclePath(entry.path, aborted);
                    if (!removed)
                    {
                        _statusText = aborted ? "Delete canceled." :
                            "Cannot move " ~ entry.name ~ " to the Recycle Bin.";
                        invalidate();
                        return;
                    }
                }
                else
                    removePathRecursive(entry.path);
                ++deleted;
            }
            catch (Exception error)
            {
                _statusText = "Cannot delete " ~ entry.name ~ ": " ~ error.msg;
                invalidate();
                return;
            }
        }

        refreshAfterFilesystemMutation();
        version (Windows)
            _statusText = format("Moved %d items to the Recycle Bin.", deleted);
        else
            _statusText = format("Deleted %d items.", deleted);
        invalidate();
    }

    private void deletePathFromUi(string path, string displayName = "")
    {
        if (!canModifyPath(path))
        {
            _statusText = "Cannot delete this item.";
            invalidate();
            return;
        }

        clearLocate();
        if (_renamingActive)
            finishRenameState();
        resetEntryDrag(false);

        const shownName = displayName.length > 0 ? displayName : baseName(path);
        string fallbackPath;
        if (!_showQuickAccess && !_showThisPc && _currentPath.length > 0 &&
            isSameOrDescendantPath(_currentPath, path))
            fallbackPath = dirName(path);

        try
        {
            version (Windows)
            {
                bool aborted;
                const deleted = recyclePath(path, aborted);
                if (!deleted)
                {
                    _statusText = aborted ? "Delete canceled." :
                        "Cannot move " ~ shownName ~ " to the Recycle Bin.";
                    invalidate();
                    return;
                }
                if (fallbackPath.length > 0 && filesystemFolderExists(fallbackPath))
                    navigate(fallbackPath, true, true);
                else
                    refreshAfterFilesystemMutation();
                _statusText = "Moved " ~ shownName ~ " to the Recycle Bin.";
            }
            else
            {
                removePathRecursive(path);
                if (fallbackPath.length > 0 && filesystemFolderExists(fallbackPath))
                    navigate(fallbackPath, true, true);
                else
                    refreshAfterFilesystemMutation();
                _statusText = "Deleted " ~ shownName ~ ".";
            }
        }
        catch (Exception error)
        {
            _statusText = "Cannot delete " ~ shownName ~ ": " ~ error.msg;
        }
        invalidate();
    }

    private void copySelectedItem()
    {
        if (!canClipboardSelection())
        {
            _statusText = "Select a file or folder to copy.";
            invalidate();
            return;
        }
        setItemClipboard(selectedPaths(), false);
    }

    private void cutSelectedItem()
    {
        if (!canClipboardSelection())
        {
            _statusText = "Select a file or folder to cut.";
            invalidate();
            return;
        }
        setItemClipboard(selectedPaths(), true);
    }

    private void copyPathToItemClipboard(string path, bool cut, string displayName = "")
    {
        if (!canClipboardPath(path))
        {
            _statusText = cut ? "Cannot cut this item." : "Cannot copy this item.";
            invalidate();
            return;
        }
        setItemClipboard([path], cut, displayName);
    }

    private void setItemClipboard(string[] paths, bool cut, string displayName = "")
    {
        clearLocate();
        if (_renamingActive)
            finishRenameState();

        _itemClipboardPaths.length = 0;
        foreach (path; paths)
        {
            if (canClipboardPath(path))
                _itemClipboardPaths ~= buildNormalizedPath(path);
        }
        _itemClipboardCut = cut;
        version (Windows)
        {
            if (writeSystemFileClipboard(_itemClipboardPaths, cut))
                _itemClipboardSequence = GetClipboardSequenceNumber();
        }

        if (_itemClipboardPaths.length == 0)
        {
            _statusText = cut ? "No item cut." : "No item copied.";
            invalidate();
            return;
        }

        const name = displayName.length > 0 ? displayName :
            baseName(_itemClipboardPaths[0]);
        if (_itemClipboardPaths.length == 1)
            _statusText = (cut ? "Cut " : "Copied ") ~ name ~ ".";
        else
            _statusText = format("%s %d items.",
                cut ? "Cut" : "Copied", _itemClipboardPaths.length);
        invalidate();
    }

    private void refreshItemClipboardFromSystem()
    {
        version (Windows)
        {
            const sequence = GetClipboardSequenceNumber();
            if (_itemClipboardSequence != 0 && sequence == _itemClipboardSequence)
                return;

            string[] paths;
            bool cut;
            if (readSystemFileClipboard(paths, cut))
            {
                _itemClipboardPaths.length = 0;
                foreach (path; paths)
                    if (canClipboardPath(path))
                        _itemClipboardPaths ~= buildNormalizedPath(path);
                _itemClipboardCut = cut;
                _itemClipboardSequence = sequence;
            }
            else if (_itemClipboardSequence != 0)
            {
                _itemClipboardPaths.length = 0;
                _itemClipboardCut = false;
                _itemClipboardSequence = sequence;
            }
        }
    }

    private bool itemClipboardAvailable()
    {
        refreshItemClipboardFromSystem();
        foreach (path; _itemClipboardPaths)
            if (canClipboardPath(path))
                return true;
        return false;
    }

    private string defaultPasteTargetDirectory() const
    {
        if (!_showQuickAccess && !_showThisPc && filesystemFolderExists(_currentPath))
            return _currentPath;
        if (selectedVisibleCount() == 1)
        {
            const entry = selectedEntry();
            if (entry.directory && filesystemFolderExists(entry.path))
                return entry.path;
        }
        return "";
    }

    private bool canPasteIntoDefaultTarget()
    {
        const target = defaultPasteTargetDirectory();
        return target.length > 0 && canPasteIntoDirectory(target);
    }

    private bool canPasteIntoDirectory(string targetDirectory)
    {
        if (!filesystemFolderExists(targetDirectory) || !itemClipboardAvailable())
            return false;
        foreach (path; _itemClipboardPaths)
            if (canPastePathIntoDirectory(path, targetDirectory, _itemClipboardCut))
                return true;
        return false;
    }

    private bool canPastePathIntoDirectory(string sourcePath, string targetDirectory,
        bool move) const
    {
        const source = buildNormalizedPath(sourcePath);
        const target = buildNormalizedPath(targetDirectory);
        if (!canClipboardPath(source) || !filesystemFolderExists(target))
            return false;
        if (pathsEqual(source, target))
            return false;
        if (isDir(source) && isSameOrDescendantPath(target, source))
            return false;
        if (move && pathsEqual(dirName(source), target))
            return false;
        return true;
    }

    private void pasteClipboardToDefaultTarget()
    {
        refreshItemClipboardFromSystem();
        const target = defaultPasteTargetDirectory();
        if (target.length == 0)
        {
            _statusText = "Choose a folder to paste into.";
            invalidate();
            return;
        }
        pasteClipboardIntoDirectory(target);
    }

    private void pasteClipboardIntoDirectory(string targetDirectory)
    {
        refreshItemClipboardFromSystem();
        if (!canPasteIntoDirectory(targetDirectory))
        {
            _statusText = itemClipboardAvailable()
                ? "Cannot paste into " ~ folderDisplayName(targetDirectory) ~ "."
                : "Nothing to paste.";
            invalidate();
            return;
        }

        clearLocate();
        if (_renamingActive)
            finishRenameState();
        resetEntryDrag(false);

        const move = _itemClipboardCut;
        int pasted;
        string lastPastedPath;
        foreach (path; _itemClipboardPaths)
        {
            string pastedPath;
            if (move)
                pastedPath = movePathIntoDirectory(path, targetDirectory);
            else
                pastedPath = copyPathIntoDirectory(path, targetDirectory);
            if (pastedPath.length > 0)
            {
                ++pasted;
                lastPastedPath = pastedPath;
            }
        }

        if (pasted == 0)
        {
            if (_statusText.length == 0)
                _statusText = "Nothing pasted.";
            invalidate();
            return;
        }

        if (move)
        {
            _itemClipboardPaths.length = 0;
            _itemClipboardCut = false;
            version (Windows)
            {
                clearSystemClipboard();
                _itemClipboardSequence = GetClipboardSequenceNumber();
            }
        }

        const selectPathAfterPaste = pasted == 1 &&
            !_showQuickAccess && !_showThisPc &&
            pathsEqual(targetDirectory, _currentPath) ? lastPastedPath : "";
        refreshAfterFilesystemMutation(selectPathAfterPaste);
        if (pasted == 1)
            _statusText = (move ? "Moved " : "Copied ") ~
                baseName(lastPastedPath) ~ " to " ~
                folderDisplayName(targetDirectory) ~ ".";
        else
            _statusText = format("%s %d items to %s.",
                move ? "Moved" : "Copied", pasted,
                folderDisplayName(targetDirectory));
        invalidate();
    }

    private void refreshAfterFilesystemMutation(string preferredPath = "")
    {
        const savedSidebarScroll = _sidebarScrollY;
        if (_showQuickAccess)
            openQuickAccess();
        else if (_showThisPc)
            openThisPc();
        else
            navigate(_currentPath, false, false);
        rebuildNavigation();
        setSidebarScroll(savedSidebarScroll);
        if (preferredPath.length > 0)
            selectPath(preferredPath);
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
        selectPathIfVisible(path);
    }

    private bool selectPathIfVisible(string path)
    {
        foreach (visibleIndex, row; _visibleRows)
        {
            if (row.entryIndex >= 0 &&
                pathsEqual(_entries[cast(size_t) row.entryIndex].path, path))
            {
                selectSingleVisibleRow(cast(int) visibleIndex);
                ensureSelectionVisible();
                updateSelectedStatus();
                invalidate();
                return true;
            }
        }
        return false;
    }

    private bool selectPathsIfVisible(string[] paths, string focusedPath = "")
    {
        clearSelection();
        if (paths.length == 0) return false;

        int preferredVisibleIndex = -1;
        foreach (visibleIndex, row; _visibleRows)
        {
            if (row.entryIndex < 0) continue;
            const entry = _entries[cast(size_t) row.entryIndex];
            bool selected;
            foreach (path; paths)
            {
                if (pathsEqual(entry.path, path))
                {
                    selected = true;
                    break;
                }
            }
            if (!selected) continue;

            const index = cast(int) visibleIndex;
            _selectedVisibleRows[index] = true;
            _selectedVisibleIndex = index;
            if (preferredVisibleIndex < 0 &&
                focusedPath.length > 0 && pathsEqual(entry.path, focusedPath))
                preferredVisibleIndex = index;
        }

        if (selectedVisibleCount() == 0)
        {
            clearSelection();
            return false;
        }
        if (preferredVisibleIndex >= 0)
            _selectedVisibleIndex = preferredVisibleIndex;
        _selectionAnchorVisibleIndex = _selectedVisibleIndex;
        ensureSelectionVisible();
        updateSelectedStatus();
        invalidate();
        return true;
    }

    private void ensureSelectionVisible()
    {
        if (!hasSelection()) return;
        ensureVisibleRowOffsets();
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

    private void openSelectionInNewWindow()
    {
        const entryIndex = entryIndexForVisibleRow(_selectedVisibleIndex);
        if (entryIndex < 0) return;
        const entry = _entries[cast(size_t) entryIndex];
        openInNewWindow(entry.directory ? entry.path : dirName(entry.path));
    }

    private void openInNewWindow(string path)
    {
        string exe = "";
        try { exe = thisExePath(); } catch (Exception) { exe = ""; }
        bool spawned = false;
        if (exe.length > 0)
        {
            try
            {
                spawnProcess([exe, path], null, Config.detached);
                spawned = true;
            }
            catch (Exception)
            {
            }
        }
        if (spawned)
        {
            _statusText = "Opened " ~ baseName(path) ~ " in a new window";
            invalidate();
        }
        else if (path.length > 0 && isDir(path))
            navigate(path, true, true);
        else
            openPath(path);
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
        const paths = selectedPaths();
        string text;
        foreach (index, path; paths)
        {
            if (index > 0) text ~= "\r\n";
            text ~= path;
        }
        if (writeClipboardText(text))
        {
            if (paths.length == 1)
                _statusText = "Copied path for " ~ selectedEntry().name;
            else
                _statusText = format("Copied paths for %d items.", paths.length);
        }
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
        if (viewMenuOpen())
            _viewMenu.dismiss();
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
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Cut", IconKind.file,
            delegate() { activateCommand(CommandButton.cutSelected); }, "Ctrl+X",
            commandEnabled(CommandButton.cutSelected));
        items ~= ContextMenuItem.command("Copy", IconKind.file,
            delegate() { activateCommand(CommandButton.copySelected); }, "Ctrl+C",
            commandEnabled(CommandButton.copySelected));
        items ~= ContextMenuItem.command("Paste", IconKind.file,
            delegate() { activateCommand(CommandButton.paste); }, "Ctrl+V",
            commandEnabled(CommandButton.paste));
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Rename", IconKind.file,
            delegate() { activateCommand(CommandButton.renameSelected); }, "F2",
            commandEnabled(CommandButton.renameSelected));
        items ~= ContextMenuItem.command("Delete", IconKind.trash,
            delegate() { activateCommand(CommandButton.deleteSelected); }, "Delete",
            commandEnabled(CommandButton.deleteSelected));
        items ~= ContextMenuItem.command("Copy path", IconKind.file,
            delegate() { activateCommand(CommandButton.copyPath); }, "Ctrl+Shift+C",
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

    private void showViewMenu()
    {
        if (homeMenuOpen())
            _homeMenu.dismiss();
        if (viewMenuOpen())
        {
            _viewMenu.dismiss();
            _viewMenu = null;
            invalidate();
            return;
        }

        ContextMenuItem[] items;
        appendViewModeItems(items);
        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command(
            _groupBy == GroupBy.dateModified ? "Ungroup" : "Group by date modified",
            IconKind.file,
            delegate() { setGroupBy(_groupBy == GroupBy.dateModified
                ? GroupBy.none : GroupBy.dateModified); },
            "", !_showQuickAccess && !_showThisPc);
        _viewMenu = showContextMenu(this,
            localToGlobal(Point(_viewTabRect.x, _viewTabRect.bottom())),
            items);
        if (_viewMenu !is null)
        {
            const viewOrigin = localToGlobal(Point(_viewTabRect.x, _viewTabRect.y));
            _viewMenu.setConsumeAnchorPress(Rect(viewOrigin.x, viewOrigin.y,
                _viewTabRect.width, _viewTabRect.height));
            _viewMenu.onDismissed = delegate()
            {
                _viewMenu = null;
                invalidate();
            };
        }
        invalidate();
    }

    private bool viewMenuOpen() const
    {
        return _viewMenu !is null && !_viewMenu.dismissed();
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
                if (canClipboardPath(navigationItem.path))
                {
                    navigationItems ~= ContextMenuItem.separatorItem();
                    navigationItems ~= ContextMenuItem.command("Cut", IconKind.file,
                        delegate() { copyPathToItemClipboard(navigationItem.path,
                            true, navigationItem.label); }, "Ctrl+X");
                    navigationItems ~= ContextMenuItem.command("Copy", IconKind.file,
                        delegate() { copyPathToItemClipboard(navigationItem.path,
                            false, navigationItem.label); }, "Ctrl+C");
                }
                if (canPasteIntoDirectory(navigationItem.path))
                    navigationItems ~= ContextMenuItem.command("Paste into folder",
                        IconKind.file,
                        delegate() { pasteClipboardIntoDirectory(navigationItem.path); },
                        "Ctrl+V");
                if (canModifyPath(navigationItem.path))
                {
                    navigationItems ~= ContextMenuItem.separatorItem();
                    navigationItems ~= ContextMenuItem.command("Rename", IconKind.file,
                        delegate() { beginRenamePath(navigationItem.path); }, "F2");
                    navigationItems ~= ContextMenuItem.command("Delete", IconKind.trash,
                        delegate() { deletePathFromUi(navigationItem.path,
                            navigationItem.label); }, "Delete");
                }
                navigationItems ~= ContextMenuItem.separatorItem();
                navigationItems ~= ContextMenuItem.command("Properties", IconKind.file,
                    delegate() { showProperties(navigationItem.path); });
                showContextMenu(this, globalPosition, navigationItems);
                return;
            }
        }
        if (_showQuickAccess)
        {
            const visibleIndex = visibleEntryIndexAt(localPosition);
            const clickedEntry = visibleIndex >= 0;
            if (clickedEntry)
            {
                focusVisibleRowForContextMenu(visibleIndex);
                updateSelectedStatus();
                invalidate();
            }
            ContextMenuItem[] quickAccessItems;
            if (clickedEntry && hasSelection())
            {
                auto entry = selectedEntry();
                quickAccessItems ~= ContextMenuItem.command("Open", IconKind.open,
                    delegate() { activateEntry(_selectedVisibleIndex); }, "Enter");
                quickAccessItems ~= ContextMenuItem.command("Open in new window",
                    IconKind.open,
                    delegate() { openSelectionInNewWindow(); });
                if (!entry.directory)
                    quickAccessItems ~= ContextMenuItem.command("Open with system", IconKind.open,
                        delegate() { openPath(entry.path); });
                if (canClipboardSelection())
                {
                    quickAccessItems ~= ContextMenuItem.separatorItem();
                    quickAccessItems ~= ContextMenuItem.command("Cut", IconKind.file,
                        delegate() { cutSelectedItem(); }, "Ctrl+X");
                    quickAccessItems ~= ContextMenuItem.command("Copy", IconKind.file,
                        delegate() { copySelectedItem(); }, "Ctrl+C");
                }
                if (selectedVisibleCount() == 1 && entry.directory &&
                    canPasteIntoDirectory(entry.path))
                    quickAccessItems ~= ContextMenuItem.command("Paste into folder",
                        IconKind.file,
                        delegate() { pasteClipboardIntoDirectory(entry.path); },
                        "Ctrl+V");
                if (canModifySelection() || allSelectedPathsCanModify())
                {
                    quickAccessItems ~= ContextMenuItem.separatorItem();
                    if (canModifySelection())
                        quickAccessItems ~= ContextMenuItem.command("Rename", IconKind.file,
                            delegate() { beginRenameSelected(); }, "F2");
                    if (allSelectedPathsCanModify())
                        quickAccessItems ~= ContextMenuItem.command("Delete", IconKind.trash,
                            delegate() { deleteSelectedItem(); }, "Delete");
                }
                if (selectedVisibleCount() == 1)
                {
                    quickAccessItems ~= ContextMenuItem.separatorItem();
                    quickAccessItems ~= ContextMenuItem.command("Properties", IconKind.file,
                        delegate() { showEntryProperties(entry); });
                }
                quickAccessItems ~= ContextMenuItem.command("Copy path", IconKind.file,
                    delegate() { copySelectedPath(); }, "Ctrl+Shift+C");
                quickAccessItems ~= ContextMenuItem.separatorItem();
            }
            appendViewModeSubmenu(quickAccessItems);
            quickAccessItems ~= ContextMenuItem.separatorItem();
            quickAccessItems ~= ContextMenuItem.command("Refresh", IconKind.refresh,
                delegate() { refresh(); }, "F5");
            showContextMenu(this, globalPosition, quickAccessItems);
            return;
        }
        if (_showThisPc)
        {
            const visibleIndex = visibleEntryIndexAt(localPosition);
            const clickedEntry = visibleIndex >= 0;
            if (clickedEntry)
            {
                focusVisibleRowForContextMenu(visibleIndex);
                updateSelectedStatus();
                invalidate();
            }
            ContextMenuItem[] thisPcItems;
            if (clickedEntry && hasSelection())
            {
                auto entry = selectedEntry();
                thisPcItems ~= ContextMenuItem.command("Open", IconKind.open,
                    delegate() { activateEntry(_selectedVisibleIndex); }, "Enter");
                thisPcItems ~= ContextMenuItem.command("Open in new window",
                    IconKind.open,
                    delegate() { openSelectionInNewWindow(); });
                if (canClipboardSelection())
                {
                    thisPcItems ~= ContextMenuItem.separatorItem();
                    thisPcItems ~= ContextMenuItem.command("Cut", IconKind.file,
                        delegate() { cutSelectedItem(); }, "Ctrl+X");
                    thisPcItems ~= ContextMenuItem.command("Copy", IconKind.file,
                        delegate() { copySelectedItem(); }, "Ctrl+C");
                }
                if (selectedVisibleCount() == 1 && entry.directory &&
                    canPasteIntoDirectory(entry.path))
                    thisPcItems ~= ContextMenuItem.command("Paste into folder",
                        IconKind.file,
                        delegate() { pasteClipboardIntoDirectory(entry.path); },
                        "Ctrl+V");
                if (canModifySelection() || allSelectedPathsCanModify())
                {
                    thisPcItems ~= ContextMenuItem.separatorItem();
                    if (canModifySelection())
                        thisPcItems ~= ContextMenuItem.command("Rename", IconKind.file,
                            delegate() { beginRenameSelected(); }, "F2");
                    if (allSelectedPathsCanModify())
                        thisPcItems ~= ContextMenuItem.command("Delete", IconKind.trash,
                            delegate() { deleteSelectedItem(); }, "Delete");
                }
                if (selectedVisibleCount() == 1)
                {
                    thisPcItems ~= ContextMenuItem.separatorItem();
                    thisPcItems ~= ContextMenuItem.command("Properties", IconKind.file,
                        delegate() { showEntryProperties(entry); });
                }
                thisPcItems ~= ContextMenuItem.command("Copy path", IconKind.file,
                    delegate() { copySelectedPath(); }, "Ctrl+Shift+C");
                thisPcItems ~= ContextMenuItem.separatorItem();
            }
            appendViewModeSubmenu(thisPcItems);
            thisPcItems ~= ContextMenuItem.separatorItem();
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
        const clickedEntry = visibleIndex >= 0;
        if (clickedEntry)
        {
            focusVisibleRowForContextMenu(visibleIndex);
            updateSelectedStatus();
            invalidate();
        }

        ContextMenuItem[] items;
        if (clickedEntry && hasSelection())
        {
            auto entry = selectedEntry();
            items ~= ContextMenuItem.command("Open", IconKind.open,
                delegate() { activateEntry(_selectedVisibleIndex); }, "Enter");
            items ~= ContextMenuItem.command("Open in new window",
                IconKind.open,
                delegate() { openSelectionInNewWindow(); });
            if (!entry.directory)
                items ~= ContextMenuItem.command("Open with system", IconKind.open,
                    delegate() { openPath(entry.path); });
            if (canClipboardSelection())
            {
                items ~= ContextMenuItem.separatorItem();
                items ~= ContextMenuItem.command("Cut", IconKind.file,
                    delegate() { cutSelectedItem(); }, "Ctrl+X");
                items ~= ContextMenuItem.command("Copy", IconKind.file,
                    delegate() { copySelectedItem(); }, "Ctrl+C");
            }
            if (selectedVisibleCount() == 1 && entry.directory &&
                canPasteIntoDirectory(entry.path))
                items ~= ContextMenuItem.command("Paste into folder", IconKind.file,
                    delegate() { pasteClipboardIntoDirectory(entry.path); },
                    "Ctrl+V");
            if (canModifySelection() || allSelectedPathsCanModify())
            {
                items ~= ContextMenuItem.separatorItem();
                if (canModifySelection())
                    items ~= ContextMenuItem.command("Rename", IconKind.file,
                        delegate() { beginRenameSelected(); }, "F2");
                if (allSelectedPathsCanModify())
                    items ~= ContextMenuItem.command("Delete", IconKind.trash,
                        delegate() { deleteSelectedItem(); }, "Delete");
            }
            if (selectedVisibleCount() == 1)
            {
                items ~= ContextMenuItem.separatorItem();
                items ~= ContextMenuItem.command("Properties", IconKind.file,
                    delegate() { showEntryProperties(entry); });
            }
            items ~= ContextMenuItem.command("Copy path", IconKind.file,
                delegate() { copySelectedPath(); }, "Ctrl+Shift+C");
            items ~= ContextMenuItem.separatorItem();
        }
        if (!clickedEntry && canPasteIntoDirectory(_currentPath))
        {
            items ~= ContextMenuItem.command("Paste", IconKind.file,
                delegate() { pasteClipboardIntoDirectory(_currentPath); }, "Ctrl+V");
            items ~= ContextMenuItem.separatorItem();
        }
        items ~= ContextMenuItem.command("New folder", IconKind.folder,
            delegate() { createNewFolder(); }, "Ctrl+N");
        items ~= ContextMenuItem.command("New text file", IconKind.newDocument,
            delegate() { createNewTextFile(); });
        items ~= ContextMenuItem.separatorItem();
        appendViewModeSubmenu(items);
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
        const selectionCount = selectedVisibleCount();
        if (selectionCount > 1)
        {
            ulong totalSize;
            bool hasKnownSize;
            foreach (entry; selectedEntries())
            {
                if (entry.directory || !entry.sizeKnown) continue;
                totalSize += entry.size;
                hasKnownSize = true;
            }
            _statusText = hasKnownSize
                ? format("%d items selected  %s", selectionCount, humanSize(totalSize))
                : format("%d items selected", selectionCount);
            return;
        }
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

    private bool commandEnabled(CommandButton command)
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
                return hasSelection();
            case CommandButton.copySelected:
            case CommandButton.cutSelected:
                return canClipboardSelection();
            case CommandButton.paste:
                return canPasteIntoDefaultTarget();
            case CommandButton.copyPath:
                return hasSelection();
            case CommandButton.renameSelected:
                return canModifySelection();
            case CommandButton.deleteSelected:
                return allSelectedPathsCanModify();
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

    private void updateThisPcHoverArea(Point point)
    {
        const index = navigationIndexAt(point);
        setThisPcHoverArea(navigationIndexInThisPcBlock(index));
    }

    private bool navigationIndexInThisPcBlock(int index) const
    {
        if (index < 0 || index >= cast(int) _navigation.length) return false;
        const item = _navigation[cast(size_t) index];
        return item.kind == NavigationKind.thisPc || item.thisPcChild;
    }

    private void setThisPcHoverArea(bool value)
    {
        if (_thisPcHoverArea == value) return;
        _thisPcHoverArea = value;
        invalidate();
    }

    private void updateThisPcArrowFade(double deltaSeconds)
    {
        const target = _thisPcHoverArea ? 1.0 : 0.0;
        if (_thisPcArrowOpacity == target) return;
        const step = deltaSeconds * thisPcArrowFadeSpeed;
        if (_thisPcArrowOpacity < target)
        {
            _thisPcArrowOpacity += step;
            if (_thisPcArrowOpacity > target) _thisPcArrowOpacity = target;
        }
        else
        {
            _thisPcArrowOpacity -= step;
            if (_thisPcArrowOpacity < target) _thisPcArrowOpacity = target;
        }
        invalidate();
    }

    // Returns the visual row index. The visual index includes group headers;
    // it must not be confused with the underlying _entries index.
    private int visibleEntryIndexAt(Point point)
    {
        if (!_rowsRect.contains(point)) return -1;
        ensureVisibleRowOffsets();
        foreach (index; cast(size_t) firstViewportVisibleRowIndex() .. _visibleRows.length)
        {
            const visibleIndex = cast(int) index;
            const row = visibleRowRect(visibleIndex);
            if (row.y >= _rowsRect.bottom()) break;
            if (entryIndexForVisibleRow(visibleIndex) >= 0 &&
                row.contains(point))
                return visibleIndex;
        }
        return -1;
    }

    private Rect visibleRowRect(int visibleIndex) const
    {
        if (visibleIndex < 0 || visibleIndex >= cast(int) _visibleRows.length)
            return Rect.init;
        const y = _rowsRect.y + _visibleRowOffsets[cast(size_t) visibleIndex] - _scrollY;
        const height = visibleRowHeight(visibleIndex);
        if (entryIndexForVisibleRow(visibleIndex) < 0 || !usesMultiColumnView())
        {
            const x = _viewMode == FileViewMode.details
                ? _rowsRect.x + scaled(20) : _rowsRect.x + scaled(12);
            return Rect(x, y, maxInt(0, _usableListWidth - scaled(24)), height);
        }

        const cellWidth = viewCellWidthPx();
        const column = _visibleRowColumns.length > cast(size_t) visibleIndex
            ? _visibleRowColumns[cast(size_t) visibleIndex] : 0;
        const x = _rowsRect.x + scaled(12) + column * cellWidth;
        const right = _mainRect.x + _usableListWidth - scaled(8);
        return Rect(x, y, maxInt(0, minInt(cellWidth - scaled(8), right - x)), height);
    }

    private Rect renameFieldRect(int visibleIndex) const
    {
        const row = visibleRowRect(visibleIndex);
        if (row.width <= 0 || row.height <= 0) return Rect.init;
        if (_viewMode == FileViewMode.details)
        {
            const x = row.x + inlineEntryTextXOffsetPx() - scaled(1);
            const right = minInt(row.right() - scaled(6), _dateX - scaled(8));
            return Rect(x, row.y + scaled(2), maxInt(0, right - x),
                maxInt(0, row.height - scaled(4)));
        }
        if (_viewMode == FileViewMode.content || _viewMode == FileViewMode.tiles)
        {
            const x = row.x + scaled(8) + viewIconSizePx() + scaled(8);
            return Rect(x, row.y + scaled(6), maxInt(0, row.right() - x - scaled(8)),
                maxInt(scaled(20), entryLineHeightPx()));
        }
        if (_viewMode == FileViewMode.smallIcons || _viewMode == FileViewMode.list)
        {
            const x = row.x + inlineEntryTextXOffsetPx() - scaled(1);
            return Rect(x, row.y + scaled(2), maxInt(0, row.width - scaled(32)),
                maxInt(0, row.height - scaled(4)));
        }

        const top = row.y + viewIconSizePx() + scaled(9);
        return Rect(row.x + scaled(6), top, maxInt(0, row.width - scaled(12)),
            maxInt(scaled(20), row.bottom() - top - scaled(4)));
    }

    private void updateRenameFieldBounds()
    {
        if (_renameField is null) return;
        if (!_renamingActive)
        {
            _renameField.setVisible(false);
            return;
        }
        const rect = renameFieldRect(_renamingVisibleIndex);
        if (rect.width <= 0 || rect.height <= 0 ||
            rect.bottom() <= _rowsRect.y || rect.y >= _rowsRect.bottom())
        {
            _renameField.setVisible(false);
            return;
        }
        _renameField.setBounds(rect);
        _renameField.setVisible(true);
    }

    private void setListScroll(int value)
    {
        ensureVisibleRowOffsets();
        _scrollY = clampInt(value, 0, maxListScroll());
        _listSmoothScrollTargetY = _scrollY;
        _listSmoothScrollActive = false;
        rebuildScrollbars();
        updateRenameFieldBounds();
        invalidate();
    }

    private void setSidebarScroll(int value)
    {
        _sidebarScrollY = clampInt(value, 0, maxSidebarScroll());
        _sidebarSmoothScrollTargetY = _sidebarScrollY;
        _sidebarSmoothScrollActive = false;
        rebuildScrollbars();
        invalidate();
    }

    private void animateListScrollTo(int value)
    {
        ensureVisibleRowOffsets();
        _listSmoothScrollTargetY = clampInt(value, 0, maxListScroll());
        _listSmoothScrollActive = _listSmoothScrollTargetY != _scrollY;
        if (!_listSmoothScrollActive)
            _listSmoothScrollTargetY = _scrollY;
        invalidate();
    }

    private void animateSidebarScrollTo(int value)
    {
        _sidebarSmoothScrollTargetY = clampInt(value, 0, maxSidebarScroll());
        _sidebarSmoothScrollActive = _sidebarSmoothScrollTargetY != _sidebarScrollY;
        if (!_sidebarSmoothScrollActive)
            _sidebarSmoothScrollTargetY = _sidebarScrollY;
        invalidate();
    }

    private void updateSmoothScrolling(double deltaSeconds)
    {
        bool changed;
        if (_listSmoothScrollActive)
        {
            ensureVisibleRowOffsets();
            _listSmoothScrollTargetY = clampInt(_listSmoothScrollTargetY, 0,
                maxListScroll());
            const next = smoothScrollStep(_scrollY, _listSmoothScrollTargetY,
                deltaSeconds);
            if (next != _scrollY)
            {
                _scrollY = next;
                changed = true;
            }
            if (_scrollY == _listSmoothScrollTargetY)
                _listSmoothScrollActive = false;
        }

        if (_sidebarSmoothScrollActive)
        {
            _sidebarSmoothScrollTargetY = clampInt(_sidebarSmoothScrollTargetY, 0,
                maxSidebarScroll());
            const next = smoothScrollStep(_sidebarScrollY, _sidebarSmoothScrollTargetY,
                deltaSeconds);
            if (next != _sidebarScrollY)
            {
                _sidebarScrollY = next;
                changed = true;
            }
            if (_sidebarScrollY == _sidebarSmoothScrollTargetY)
                _sidebarSmoothScrollActive = false;
        }

        if (changed)
        {
            rebuildScrollbars();
            updateRenameFieldBounds();
            invalidate();
        }
    }

    private static int smoothScrollStep(int current, int target, double deltaSeconds)
    {
        const distance = target - current;
        const magnitude = absInt(distance);
        if (magnitude <= 1) return target;

        double factor = deltaSeconds * wheelSmoothScrollSpeed;
        if (factor <= 0.0)
            factor = 1.0;
        else if (factor > 1.0)
            factor = 1.0;

        int step = cast(int) (cast(double) distance * factor);
        if (step == 0)
            step = distance > 0 ? 1 : -1;
        if (absInt(step) >= magnitude)
            return target;
        return current + step;
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

    private void rebuildScrollbars()
    {
        const listMax = maxListScroll();
        const scrollbar = scrollbarWidthPx();
        _listScrollbar.setBounds(Rect(_rowsRect.right() - scrollbar, _rowsRect.y,
            scrollbar, _rowsRect.height));
        _listScrollbar.setMinimumThumbLength(scaled(34));
        _listScrollbar.setThumbCrossInset(scaled(2));
        _listScrollbar.setCornerRadii(0, scaled(2));
        _listScrollbar.setLineStep(rowHeightPx());
        _listScrollbar.setPageStep(maxInt(rowHeightPx(),
            _rowsRect.height - rowHeightPx()));
        _listScrollbar.setRange(0, listMax, _rowsRect.height);
        _listScrollbar.setValue(_scrollY, false);
        _listScrollbar.setVisible(listMax > 0);

        const navMax = maxSidebarScroll();
        _sidebarScrollbar.setBounds(Rect(_sidebarRowsRect.right() - scrollbar,
            _sidebarRowsRect.y, scrollbar, _sidebarRowsRect.height));
        _sidebarScrollbar.setMinimumThumbLength(scaled(34));
        _sidebarScrollbar.setThumbCrossInset(scaled(2));
        _sidebarScrollbar.setCornerRadii(0, scaled(2));
        _sidebarScrollbar.setLineStep(sidebarRowHeightPx());
        _sidebarScrollbar.setPageStep(maxInt(sidebarRowHeightPx(),
            _sidebarRowsRect.height - sidebarRowHeightPx()));
        _sidebarScrollbar.setRange(0, navMax, _sidebarRowsRect.height);
        _sidebarScrollbar.setValue(_sidebarScrollY, false);
        _sidebarScrollbar.setVisible(navMax > 0);
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
        if (viewMenuOpen())
        {
            canvas.fillRect(_viewTabRect, Color.rgba(255, 255, 255, 12));
            canvas.fillRect(Rect(_viewTabRect.x, _viewTabRect.bottom() - scaled(2),
                _viewTabRect.width, scaled(2)), explorerBlue);
        }
        drawText(canvas, _viewTabRect.inset(scaled(8), 0, scaled(8), 0), "View", explorerText,
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
        drawFileManagerIcon(canvas, IconKind.folder, Rect(_addressRect.x + scaled(8),
            _addressRect.y + scaled(6), scaled(16), scaled(16)),
            explorerText, folderAccent);

        if (!_addressEditing)
            drawAddressSegments(canvas);

        drawRefreshButton(canvas, _refreshRect);

        canvas.drawRoundedRect(_searchRect, 0, explorerField, explorerFieldBorder, 1);
        drawIcon(canvas, IconKind.search, Rect(_searchRect.x + scaled(9),
            _searchRect.y + scaled(7), scaled(15), scaled(15)),
            explorerMuted, explorerMuted);
    }

    private void drawAddressSegments(ref Canvas canvas)
    {
        computeAddressSegments(canvas);
        foreach (index, seg; _addressSegments)
        {
            if (cast(int) index == _addressHoverIndex)
                canvas.fillRect(seg.rect, explorerSelection);
            const textColor = seg.thisPc ? explorerBlue : explorerText;
            drawTextWithScale(canvas, seg.rect, seg.label, textColor,
                HorizontalAlign.center, textScale());
        }
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
            const sidebarIcon = sidebarIconSizePx();
            const sidebarIconY = row.y + maxInt(0, (row.height - sidebarIcon) / 2);
            const thisPcArrowAlpha = cast(int) (textColor.a * _thisPcArrowOpacity + 0.5);
            if (thisPcArrowAlpha > 0 && item.kind == NavigationKind.thisPc)
            {
                const arrowColor = textColor.withAlpha(thisPcArrowAlpha);
                drawIcon(content, IconKind.chevronDown,
                    Rect(row.x + scaled(9), row.y + scaled(8),
                        scaled(10), scaled(10)), arrowColor, arrowColor);
            }
            else if (thisPcArrowAlpha > 0 && item.thisPcChild)
            {
                const arrowColor = textColor.withAlpha(thisPcArrowAlpha);
                drawIcon(content, IconKind.chevronRight,
                    Rect(row.x + scaled(22), row.y + scaled(8),
                        scaled(10), scaled(10)), arrowColor, arrowColor);
            }
            drawFileManagerIcon(content, item.icon, Rect(row.x + scaled(34) + nestedOffset,
                sidebarIconY, sidebarIcon, sidebarIcon),
                textColor, folderAccent);
            drawText(content, Rect(row.x + scaled(60) + nestedOffset, row.y,
                maxInt(0, row.width - scaled(86) - nestedOffset), row.height),
                item.label, textColor, HorizontalAlign.left);

            if (item.pinned)
                drawPin(content, Rect(row.right() - scaled(22), row.y + scaled(7),
                    scaled(11), scaled(11)),
                    explorerMuted);
        }

    }

    private void drawDetailsView(ref Canvas canvas)
    {
        canvas.fillRect(_mainRect, explorerContent);
        if (_viewMode == FileViewMode.details)
        {
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
        }

        auto rows = canvas.clipped(_rowsRect);
        foreach (visibleIndex; cast(size_t) firstViewportVisibleRowIndex() .. _visibleRows.length)
        {
            const visibleRow = _visibleRows[visibleIndex];
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
                const headerLabel = (_showQuickAccess || _showThisPc)
                    ? visibleRow.groupLabel : "Date modified: " ~ visibleRow.groupLabel;
                drawText(rows, Rect(row.x + scaled(8), row.y, row.width - scaled(16),
                    row.height), headerLabel,
                    explorerMuted, HorizontalAlign.left);
                rows.fillRect(Rect(row.x, row.bottom() - 1, row.width, 1), explorerLine);
                continue;
            }
            const entry = _entries[cast(size_t) visibleRow.entryIndex];
            if (_draggingEntry && visibleIndex == _dropTargetVisibleIndex)
            {
                fillEntrySelection(rows, row, explorerDropTarget);
                rows.strokeRect(row, explorerBlue, 1);
            }
            else if (visibleRowSelected(cast(int) visibleIndex))
            {
                fillEntrySelection(rows, row, explorerSelection);
                if (visibleIndex == cast(size_t) _selectedVisibleIndex)
                    rows.strokeRect(row, explorerSelectionBorder, 1);
            }

            drawEntryForCurrentView(rows, row, cast(int) visibleIndex, entry);
        }

        drawRubberBandSelection(rows);
    }

    private void drawRubberBandSelection(ref Canvas canvas)
    {
        if (!_rubberBandSelecting) return;
        const rect = rubberBandRect();
        if (rect.empty()) return;
        canvas.fillRect(rect, Color.rgba(0, 90, 158, 38));
        canvas.strokeRect(rect, explorerBlue, 1);
    }

    private void fillEntrySelection(ref Canvas canvas, Rect row, Color color)
    {
        if (_viewMode == FileViewMode.details || _viewMode == FileViewMode.content)
            canvas.fillRect(row, color);
        else
            canvas.fillRoundedRect(row.inset(scaled(1)), scaled(3), color);
    }

    private void drawEntryForCurrentView(ref Canvas canvas, Rect row,
        int visibleIndex, ExplorerEntry entry)
    {
        final switch (_viewMode)
        {
            case FileViewMode.details:
                drawDetailsEntry(canvas, row, visibleIndex, entry);
                break;
            case FileViewMode.extraLargeIcons:
            case FileViewMode.largeIcons:
            case FileViewMode.mediumIcons:
                drawIconEntry(canvas, row, visibleIndex, entry);
                break;
            case FileViewMode.smallIcons:
            case FileViewMode.list:
                drawListEntry(canvas, row, visibleIndex, entry);
                break;
            case FileViewMode.tiles:
                drawTileEntry(canvas, row, visibleIndex, entry);
                break;
            case FileViewMode.content:
                drawContentEntry(canvas, row, visibleIndex, entry);
                break;
        }
    }

    private void drawDetailsEntry(ref Canvas canvas, Rect row,
        int visibleIndex, ExplorerEntry entry)
    {
        const iconSize = inlineEntryIconSizePx();
        const iconY = row.y + maxInt(0, (row.height - iconSize) / 2);
        const textX = row.x + inlineEntryTextXOffsetPx();
        drawExplorerEntryIcon(canvas, entry, Rect(row.x + scaled(6), iconY,
            iconSize, iconSize));
        if (!drawRenameFieldBackground(canvas, visibleIndex))
            drawEntryText(canvas, Rect(textX, row.y,
                maxInt(0, _dateX - textX - scaled(8)), row.height),
                entry.name, explorerText, HorizontalAlign.left);
        drawEntryText(canvas, Rect(_dateX + scaled(8), row.y,
            maxInt(0, _typeX - _dateX - scaled(14)), row.height), entry.modified,
            explorerText, HorizontalAlign.left);
        drawEntryText(canvas, Rect(_typeX + scaled(8), row.y,
            maxInt(0, _sizeX - _typeX - scaled(14)), row.height), entry.type,
            explorerText, HorizontalAlign.left);
        drawEntryText(canvas, Rect(_sizeX + scaled(8), row.y, maxInt(0, _sizeWidth - scaled(16)),
            row.height), entrySizeText(entry),
            explorerText, HorizontalAlign.right);
    }

    private void drawListEntry(ref Canvas canvas, Rect row,
        int visibleIndex, ExplorerEntry entry)
    {
        const iconSize = inlineEntryIconSizePx();
        const iconY = row.y + maxInt(0, (row.height - iconSize) / 2);
        const textX = row.x + inlineEntryTextXOffsetPx();
        drawExplorerEntryIcon(canvas, entry, Rect(row.x + scaled(6), iconY,
            iconSize, iconSize));
        if (!drawRenameFieldBackground(canvas, visibleIndex))
            drawEntryText(canvas, Rect(textX, row.y,
                maxInt(0, row.right() - textX - scaled(6)), row.height), entry.name,
                explorerText, HorizontalAlign.left);
    }

    private void drawIconEntry(ref Canvas canvas, Rect row,
        int visibleIndex, ExplorerEntry entry)
    {
        const iconSize = viewIconSizePx();
        const iconX = row.x + maxInt(0, (row.width - iconSize) / 2);
        drawExplorerEntryIcon(canvas, entry, Rect(iconX, row.y + scaled(10),
            iconSize, iconSize));
        if (!drawRenameFieldBackground(canvas, visibleIndex))
        {
            const textTop = row.y + iconSize + scaled(12);
            canvas.drawTextInRect(Rect(row.x + scaled(4), textTop,
                    maxInt(0, row.width - scaled(8)), maxInt(0, row.bottom() - textTop)),
                toUTF32(entry.name), explorerText, entryTextScale(),
                HorizontalAlign.center, VerticalAlign.top, true);
        }
    }

    private void drawTileEntry(ref Canvas canvas, Rect row,
        int visibleIndex, ExplorerEntry entry)
    {
        const iconSize = viewIconSizePx();
        const iconY = row.y + maxInt(0, (row.height - iconSize) / 2);
        drawExplorerEntryIcon(canvas, entry, Rect(row.x + scaled(8), iconY,
            iconSize, iconSize));
        const textX = row.x + iconSize + scaled(16);
        if (!drawRenameFieldBackground(canvas, visibleIndex))
            drawEntryText(canvas, Rect(textX, row.y + scaled(6),
                maxInt(0, row.right() - textX - scaled(8)), entryLineHeightPx()),
                entry.name, explorerText, HorizontalAlign.left);
        drawEntryText(canvas, Rect(textX, row.y + scaled(6) + entryLineHeightPx(),
            maxInt(0, row.right() - textX - scaled(8)), entryLineHeightPx()),
            entryMetadataText(entry), explorerMuted, HorizontalAlign.left);
    }

    private void drawContentEntry(ref Canvas canvas, Rect row,
        int visibleIndex, ExplorerEntry entry)
    {
        const iconSize = viewIconSizePx();
        const iconY = row.y + maxInt(0, (row.height - iconSize) / 2);
        drawExplorerEntryIcon(canvas, entry, Rect(row.x + scaled(8), iconY,
            iconSize, iconSize));
        const textX = row.x + iconSize + scaled(18);
        if (!drawRenameFieldBackground(canvas, visibleIndex))
            drawEntryText(canvas, Rect(textX, row.y + scaled(6),
                maxInt(0, row.right() - textX - scaled(12)), entryLineHeightPx()),
                entry.name, explorerText, HorizontalAlign.left);
        drawEntryText(canvas, Rect(textX, row.y + scaled(6) + entryLineHeightPx(),
            maxInt(0, row.right() - textX - scaled(12)), entryLineHeightPx()),
            entryMetadataText(entry), explorerMuted, HorizontalAlign.left);
    }

    private bool drawRenameFieldBackground(ref Canvas canvas, int visibleIndex)
    {
        if (!_renamingActive || visibleIndex != _renamingVisibleIndex) return false;
        const renameRect = renameFieldRect(visibleIndex);
        if (renameRect.width > 0 && renameRect.height > 0)
            canvas.drawRoundedRect(renameRect, 0, explorerField,
                explorerFieldBorder, 1);
        return true;
    }

    private IconKind entryIcon(ExplorerEntry entry) const
    {
        return entry.drive ? IconKind.drive :
            (entry.directory ? IconKind.folder : iconForFile(entry.name));
    }

    private void drawExplorerEntryIcon(ref Canvas canvas, ExplorerEntry entry, Rect rect)
    {
        if (drawAtlasIcon(canvas, atlasIconNameForEntry(entry), rect))
            return;
        drawIcon(canvas, entryIcon(entry), rect, explorerText,
            entry.directory ? folderAccent : fileAccent);
    }

    private bool drawAtlasIcon(ref Canvas canvas, string name, Rect rect,
        bool mirrorX = false, Color tint = Color(255, 255, 255, 255))
    {
        if (name.length == 0 || rect.empty()) return false;
        auto atlas = iconAtlas();
        if (atlas is null || atlas.image is null) return false;
        Rect source;
        if (!atlas.frameFor(name, source)) return false;
        canvas.drawImage(fitImageRect(rect, source), atlas.image, source,
            tint, true, mirrorX);
        return true;
    }

    private void drawFileManagerIcon(ref Canvas canvas, IconKind icon, Rect rect,
        Color foreground, Color accent)
    {
        if (foreground.a > 220 && drawAtlasIcon(canvas, atlasIconNameForIcon(icon), rect))
            return;
        drawIcon(canvas, icon, rect, foreground, accent);
    }

    private FileManagerIconAtlas iconAtlas()
    {
        if (!_iconAtlasLoadAttempted)
        {
            _iconAtlasLoadAttempted = true;
            _iconAtlas = loadFileManagerIconAtlas();
        }
        return _iconAtlas;
    }

    private static Rect fitImageRect(Rect bounds, Rect source)
        @safe pure nothrow @nogc
    {
        if (bounds.empty() || source.empty()) return bounds;
        const sourceWidth = maxInt(1, source.width);
        const sourceHeight = maxInt(1, source.height);
        int width = bounds.width;
        int height = cast(int) ((cast(long) width * sourceHeight + sourceWidth / 2) /
            sourceWidth);
        if (height > bounds.height)
        {
            height = bounds.height;
            width = cast(int) ((cast(long) height * sourceWidth + sourceHeight / 2) /
                sourceHeight);
        }
        width = maxInt(1, minInt(bounds.width, width));
        height = maxInt(1, minInt(bounds.height, height));
        return Rect(bounds.x + (bounds.width - width) / 2,
            bounds.y + (bounds.height - height) / 2, width, height);
    }

    private static string atlasIconNameForEntry(ExplorerEntry entry)
    {
        if (entry.drive) return "drive";
        if (entry.directory)
        {
            if (icmp(entry.name, "Desktop") == 0 ||
                pathsEqual(entry.path, defaultDesktopFolder()))
                return "desktop";
            if (icmp(entry.name, "Documents") == 0 ||
                pathsEqual(entry.path, defaultDocumentsFolder()))
                return "document";
            if (icmp(entry.name, "Downloads") == 0 ||
                pathsEqual(entry.path, defaultDownloadsFolder()))
                return "download";
            if (icmp(entry.name, "Music") == 0 ||
                pathsEqual(entry.path, defaultMusicFolder()))
                return "music";
            if (icmp(entry.name, "Pictures") == 0 ||
                pathsEqual(entry.path, defaultPicturesFolder()))
                return "pictures";
            if (icmp(entry.name, "Videos") == 0 ||
                pathsEqual(entry.path, defaultVideosFolder()))
                return "videos";
            return "folder";
        }

        const ext = extension(entry.name);
        if (icmp(ext, ".png") == 0 || icmp(ext, ".jpg") == 0 ||
            icmp(ext, ".jpeg") == 0 || icmp(ext, ".gif") == 0 ||
            icmp(ext, ".bmp") == 0 || icmp(ext, ".webp") == 0 ||
            icmp(ext, ".svg") == 0)
            return "pictures";
        if (icmp(ext, ".mp3") == 0 || icmp(ext, ".wav") == 0 ||
            icmp(ext, ".flac") == 0 || icmp(ext, ".ogg") == 0 ||
            icmp(ext, ".m4a") == 0)
            return "music";
        if (icmp(ext, ".mp4") == 0 || icmp(ext, ".mov") == 0 ||
            icmp(ext, ".mkv") == 0 || icmp(ext, ".avi") == 0 ||
            icmp(ext, ".webm") == 0)
            return "videos";
        if (icmp(ext, ".zip") == 0 || icmp(ext, ".7z") == 0 ||
            icmp(ext, ".rar") == 0 || icmp(ext, ".tar") == 0 ||
            icmp(ext, ".gz") == 0)
            return "storage_box";
        if (icmp(ext, ".txt") == 0 || icmp(ext, ".md") == 0 ||
            icmp(ext, ".json") == 0 || icmp(ext, ".d") == 0 ||
            icmp(ext, ".doc") == 0 || icmp(ext, ".docx") == 0 ||
            icmp(ext, ".pdf") == 0)
            return "document";
        return "file";
    }

    private static string atlasIconNameForIcon(IconKind icon)
    {
        switch (icon)
        {
            case IconKind.file:
                return "file";
            case IconKind.folder:
                return "folder";
            case IconKind.home:
                return "home";
            case IconKind.computer:
                return "desktop";
            case IconKind.notepad:
            case IconKind.newDocument:
                return "document";
            case IconKind.trash:
                return "trash";
            case IconKind.open:
                return "folder_open";
            case IconKind.up:
                return "up";
            case IconKind.settings:
                return "settings";
            case IconKind.image:
                return "pictures";
            case IconKind.music:
                return "music";
            case IconKind.drive:
                return "drive";
            default:
                return "";
        }
    }

    private static FileManagerIconAtlas loadFileManagerIconAtlas()
    {
        foreach (directory; fileManagerIconAssetDirectories())
        {
            const atlasPath = buildPath(directory, "file_manager_icon_atlas.json");
            if (!exists(atlasPath)) continue;
            try
            {
                auto atlas = readFileManagerIconAtlas(atlasPath);
                if (atlas !is null) return atlas;
            }
            catch (Exception)
            {
                // Asset loading is optional; vector icons remain the fallback.
            }
        }
        return null;
    }

    private static FileManagerIconAtlas readFileManagerIconAtlas(string atlasPath)
    {
        auto root = parseJSON(readText(atlasPath));
        const directory = dirName(atlasPath);
        const imageName = root["image"].str;
        const imagePath = buildPath(directory, imageName);
        if (!exists(imagePath)) return null;

        auto atlas = new FileManagerIconAtlas();
        atlas.image = loadPngImage(imagePath);
        foreach (icon; root["icons"].array)
        {
            auto frameValue = icon["frame"];
            Rect frame = Rect(jsonInt(frameValue, "x"), jsonInt(frameValue, "y"),
                jsonInt(frameValue, "width"), jsonInt(frameValue, "height"));
            atlas.frames[icon["name"].str] = frame;
            foreach (aliasValue; icon["aliases"].array)
                atlas.frames[aliasValue.str] = frame;
        }
        return atlas.frames.length > 0 && atlas.image !is null ? atlas : null;
    }

    private static string[] fileManagerIconAssetDirectories()
    {
        string[] directories;
        appendUniqueDirectory(directories, buildPath(getcwd(), "assets", "icons"));
        try
        {
            const exePath = thisExePath();
            appendUniqueDirectory(directories, buildPath(dirName(exePath), "assets", "icons"));
            appendUniqueDirectory(directories, buildPath(dirName(dirName(exePath)),
                "assets", "icons"));
        }
        catch (Exception)
        {
        }

        const sourceRoot = dirName(dirName(dirName(dirName(__FILE_FULL_PATH__))));
        appendUniqueDirectory(directories, buildPath(sourceRoot, "assets", "icons"));
        return directories;
    }

    private static void appendUniqueDirectory(ref string[] directories, string path)
    {
        if (path.length == 0) return;
        foreach (existing; directories)
            if (pathsEqual(existing, path))
                return;
        directories ~= path;
    }

    private static int jsonInt(JSONValue value, string key)
    {
        return cast(int) value[key].integer;
    }

    private string entryMetadataText(ExplorerEntry entry) const
    {
        string text;
        if (entry.type.length > 0)
            text = entry.type;
        if (entry.modified.length > 0)
            text = appendMetadataPart(text, entry.modified);
        const sizeText = entrySizeText(entry);
        if (sizeText.length > 0)
            text = appendMetadataPart(text, sizeText);
        return text;
    }

    private static string appendMetadataPart(string text, string part)
    {
        return text.length == 0 ? part : text ~ " • " ~ part;
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
        drawExplorerEntryIcon(canvas, entry, Rect(preview.x + scaled(8),
            preview.y + scaled(6), scaled(17), scaled(17)));
        drawText(canvas, Rect(preview.x + scaled(32), preview.y,
            maxInt(0, preview.width - scaled(42)), preview.height), entry.name,
            explorerText, HorizontalAlign.left);
    }

    private void drawStatusBar(ref Canvas canvas)
    {
        canvas.fillRect(_statusRect, explorerStatus);
        canvas.fillRect(Rect(_statusRect.x, _statusRect.y, _statusRect.width, 1),
            explorerLine);
        const rightInset = _locateActive
            ? maxInt(scaled(40), _statusRect.right() - _locateRect.x + scaled(10))
            : scaled(40);
        drawText(canvas, Rect(_statusRect.x + scaled(20), _statusRect.y,
            maxInt(0, _statusRect.width - scaled(20) - rightInset), _statusRect.height), _statusText,
            explorerText, HorizontalAlign.left);
        if (_locateActive)
        {
            canvas.drawRoundedRect(_locateRect, 0, explorerField, explorerFieldBorder, 1);
            drawText(canvas, Rect(_locateRect.x + scaled(8), _locateRect.y,
                scaled(42), _locateRect.height), "Find:", explorerMuted,
                HorizontalAlign.left);
        }
    }

    private void drawNavButton(ref Canvas canvas, Rect rect, CommandButton command,
        bool enabled)
    {
        const pressed = _pressedCommand == command;
        if (pressed)
            canvas.fillRect(rect, explorerPressed);
        const color = enabled ? explorerText : explorerDisabled;
        const iconRect = Rect(rect.x + scaled(5), rect.y + scaled(5),
            scaled(18), scaled(18));
        if (drawAtlasIcon(canvas, "forward", iconRect,
                command == CommandButton.back,
                Color(color.r, color.g, color.b, color.a)))
            return;
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
        drawFileManagerIcon(canvas, IconKind.up, Rect(rect.x + scaled(5), rect.y + scaled(5),
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
        drawFileManagerIcon(canvas, icon, Rect(rect.x + scaled(5), rect.y + scaled(4),
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
        drawTextWithScale(canvas, rect, text, color, horizontal, textScale());
    }

    private void drawEntryText(ref Canvas canvas, Rect rect, string text, Color color,
        HorizontalAlign horizontal)
    {
        drawTextWithScale(canvas, rect, text, color, horizontal, entryTextScale());
    }

    private void drawTextWithScale(ref Canvas canvas, Rect rect, string text,
        Color color, HorizontalAlign horizontal, int scale)
    {
        canvas.drawTextInRect(rect, toUTF32(text), color, scale,
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

    private static string defaultUserProfileFolder()
    {
        version (Windows)
        {
            auto home = windowsCsidlFolder(CSIDL_PROFILE);
            if (home.length > 0) return home;
        }
        return environment.get("USERPROFILE", environment.get("HOME", getcwd()));
    }

    private static string defaultDesktopFolder()
    {
        version (Windows)
        {
            auto path = windowsCsidlFolder(CSIDL_DESKTOPDIRECTORY);
            if (path.length > 0) return path;
        }
        return buildNormalizedPath(defaultUserProfileFolder(), "Desktop");
    }

    private static string defaultDocumentsFolder()
    {
        version (Windows)
        {
            auto path = windowsCsidlFolder(CSIDL_PERSONAL);
            if (path.length > 0) return path;
        }
        return buildNormalizedPath(defaultUserProfileFolder(), "Documents");
    }

    private static string defaultDownloadsFolder()
    {
        version (Windows)
        {
            auto path = windowsKnownFolderPath(&folderIdDownloads);
            if (path.length > 0) return path;
        }
        return buildNormalizedPath(defaultUserProfileFolder(), "Downloads");
    }

    private static string defaultMusicFolder()
    {
        version (Windows)
        {
            auto path = windowsCsidlFolder(CSIDL_MYMUSIC);
            if (path.length > 0) return path;
        }
        return buildNormalizedPath(defaultUserProfileFolder(), "Music");
    }

    private static string defaultPicturesFolder()
    {
        version (Windows)
        {
            auto path = windowsCsidlFolder(CSIDL_MYPICTURES);
            if (path.length > 0) return path;
        }
        return buildNormalizedPath(defaultUserProfileFolder(), "Pictures");
    }

    private static string defaultVideosFolder()
    {
        version (Windows)
        {
            auto path = windowsCsidlFolder(CSIDL_MYVIDEO);
            if (path.length > 0) return path;
        }
        return buildNormalizedPath(defaultUserProfileFolder(), "Videos");
    }

    private static string defaultThreeDObjectsFolder()
    {
        return buildNormalizedPath(defaultUserProfileFolder(), "3D Objects");
    }

    private static string defaultOneDriveFolder()
    {
        foreach (name; ["OneDriveConsumer", "OneDrive", "OneDriveCommercial"])
        {
            const path = environment.get(name, "");
            if (filesystemFolderExists(path)) return path;
        }
        return buildNormalizedPath(defaultUserProfileFolder(), "OneDrive");
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

    private static bool filesystemFolderExists(string path)
    {
        try
        {
            return path.length > 0 && exists(path) && isDir(path);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool filesystemPathExists(string path)
    {
        try
        {
            return path.length > 0 && exists(path);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool validItemName(string name, out string error)
    {
        if (name.length == 0)
        {
            error = "Name cannot be empty.";
            return false;
        }
        if (name == "." || name == "..")
        {
            error = "Name cannot be " ~ name ~ ".";
            return false;
        }
        if (name[$ - 1] == '.')
        {
            error = "Name cannot end with a period.";
            return false;
        }
        foreach (ch; name)
        {
            if (ch < 32 || ch == '\\' || ch == '/' || ch == ':' ||
                ch == '*' || ch == '?' || ch == '"' || ch == '<' ||
                ch == '>' || ch == '|')
            {
                error = "Name contains a character that is not allowed.";
                return false;
            }
        }

        const reserved = reservedDeviceNameStem(name);
        foreach (device; ["CON", "PRN", "AUX", "NUL",
            "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
            "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"])
        {
            if (icmp(reserved, device) == 0)
            {
                error = "Name is reserved by Windows.";
                return false;
            }
        }

        error = "";
        return true;
    }

    private static string reservedDeviceNameStem(string name)
    {
        foreach (index, ch; name)
            if (ch == '.')
                return name[0 .. index];
        return name;
    }

    version (Windows)
    private static bool recyclePath(string path, out bool aborted)
    {
        aborted = false;
        if (path.length == 0) return false;

        wchar[] from = toUTF16(path).dup;
        from ~= cast(wchar) 0;
        from ~= cast(wchar) 0;

        SHFILEOPSTRUCTW operation;
        operation.wFunc = FO_DELETE;
        operation.pFrom = from.ptr;
        operation.fFlags = FOF_ALLOWUNDO;
        const result = SHFileOperationW(&operation);
        aborted = operation.fAnyOperationsAborted != FALSE;
        return result == 0 && !aborted;
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

    private static bool startsWithInsensitive(string value, string loweredNeedle)
    {
        if (loweredNeedle.length == 0) return true;
        const haystack = value.toLower();
        return haystack.length >= loweredNeedle.length &&
            haystack[0 .. loweredNeedle.length] == loweredNeedle;
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

    version (AuroraHeadless)
    {
        int testListScrollY() const @safe pure nothrow @nogc { return _scrollY; }
        int testSidebarScrollY() const @safe pure nothrow @nogc { return _sidebarScrollY; }
        int testMaxListScroll() const { return maxListScroll(); }
        int testMaxSidebarScroll() const { return maxSidebarScroll(); }
        int testVisibleEntryCount() const @safe pure nothrow @nogc
        {
            return cast(int) _visibleRows.length;
        }
        bool testListSmoothScrollActive() const @safe pure nothrow @nogc
        {
            return _listSmoothScrollActive;
        }
        Scrollbar testListScrollbar() @safe pure nothrow @nogc
        {
            return _listScrollbar;
        }
        Scrollbar testSidebarScrollbar() @safe pure nothrow @nogc
        {
            return _sidebarScrollbar;
        }
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
private bool writeSystemFileClipboard(const string[] paths, bool cut)
{
    if (paths.length == 0) return false;
    if (!OpenClipboard(null)) return false;
    scope (exit) CloseClipboard();
    if (!EmptyClipboard()) return false;

    auto fileList = encodedDropFileList(paths);
    if (fileList.length == 0) return false;

    const bytes = DROPFILES.sizeof + fileList.length * wchar.sizeof;
    auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (memory is null) return false;
    auto raw = GlobalLock(memory);
    if (raw is null)
    {
        GlobalFree(memory);
        return false;
    }

    auto drop = cast(DROPFILES*) raw;
    *drop = DROPFILES.init;
    drop.pFiles = cast(DWORD) DROPFILES.sizeof;
    drop.fWide = TRUE;

    auto target = cast(wchar*) (cast(ubyte*) raw + DROPFILES.sizeof);
    foreach (index, ch; fileList)
        target[index] = ch;
    GlobalUnlock(memory);

    if (SetClipboardData(CF_HDROP, memory) is null)
    {
        GlobalFree(memory);
        return false;
    }

    writeSystemDropEffect(cut);
    return true;
}

version (Windows)
private wchar[] encodedDropFileList(const string[] paths)
{
    wchar[] encoded;
    foreach (path; paths)
    {
        if (path.length == 0) continue;
        encoded ~= toUTF16(path);
        encoded ~= cast(wchar) 0;
    }
    if (encoded.length == 0) return encoded;
    encoded ~= cast(wchar) 0;
    return encoded;
}

version (Windows)
private bool writeSystemDropEffect(bool cut)
{
    const format = RegisterClipboardFormatW("Preferred DropEffect".toUTF16z);
    if (format == 0) return false;
    auto memory = GlobalAlloc(GMEM_MOVEABLE, DWORD.sizeof);
    if (memory is null) return false;
    auto raw = GlobalLock(memory);
    if (raw is null)
    {
        GlobalFree(memory);
        return false;
    }
    *cast(DWORD*) raw = cut ? 2u : 1u;
    GlobalUnlock(memory);
    if (SetClipboardData(format, memory) is null)
    {
        GlobalFree(memory);
        return false;
    }
    return true;
}

version (Windows)
private bool readSystemFileClipboard(out string[] paths, out bool cut)
{
    paths.length = 0;
    cut = false;
    if (!IsClipboardFormatAvailable(CF_HDROP)) return false;
    if (!OpenClipboard(null)) return false;
    scope (exit) CloseClipboard();

    auto handle = GetClipboardData(CF_HDROP);
    if (handle is null) return false;
    auto drop = cast(HDROP) handle;
    const count = DragQueryFileW(drop, uint.max, null, 0);
    foreach (index; 0 .. count)
    {
        const length = DragQueryFileW(drop, index, null, 0);
        if (length == 0) continue;
        wchar[] buffer;
        buffer.length = length + 1;
        const written = DragQueryFileW(drop, index, buffer.ptr,
            cast(UINT) buffer.length);
        if (written > 0)
            paths ~= toUTF8(buffer[0 .. written]);
    }
    cut = readSystemDropEffect();
    return paths.length > 0;
}

version (Windows)
private bool readSystemDropEffect()
{
    const format = RegisterClipboardFormatW("Preferred DropEffect".toUTF16z);
    if (format == 0 || !IsClipboardFormatAvailable(format))
        return false;
    auto handle = GetClipboardData(format);
    if (handle is null) return false;
    auto raw = GlobalLock(handle);
    if (raw is null) return false;
    const effect = *cast(DWORD*) raw;
    GlobalUnlock(handle);
    return (effect & 2u) != 0;
}

version (Windows)
private void clearSystemClipboard()
{
    if (!OpenClipboard(null)) return;
    scope (exit) CloseClipboard();
    EmptyClipboard();
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
    options.extendedScrollInput = true;
    options.nativeVerticalScrollHost = true;
    options.iconPath = windowsFileManagerIconPath();
    auto window = new GuiWindow(options, explorerTheme());
    const initial = args.length > 1 ? args[1] : "";
    window.setRoot(new WindowsFileManagerRoot(window, initial));
    return window.run();
}
