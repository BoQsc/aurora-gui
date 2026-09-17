module auroradesktop.tasks;

import aurora.image : RgbaImage;
import aurora.types : Size;

version (Windows)
{
    import core.sys.windows.windows : HWND, DWORD, BOOL, LPARAM, UINT,
        HDC, HGDIOBJ, HBITMAP, RECT, HICON;
    import core.sys.windows.winuser : EnumWindows, EnumChildWindows, GetWindowTextW,
        GetWindowRect, IsWindowVisible, GetClassNameW, GetDC, ReleaseDC,
        ShowWindow, IsIconic, IsZoomed, SetForegroundWindow, GetForegroundWindow,
        GetWindow, IsWindow, GW_OWNER, PrintWindow, PostMessageW,
        SendMessageW, GetIconInfo, GetClassLongPtrW, DrawIconEx, DestroyIcon,
        ICONINFO;
    import core.sys.windows.wingdi : CreateCompatibleDC, CreateCompatibleBitmap,
        SelectObject, DeleteDC, DeleteObject, GetDIBits, DIB_RGB_COLORS,
        BITMAPINFO, BITMAPINFOHEADER, BI_RGB, BitBlt, SRCCOPY,
        GetObjectW, BITMAP;
    import core.sys.windows.winbase : GetWindowThreadProcessId, OpenProcess,
        CloseHandle;
    import core.sys.windows.shellapi : SHGetFileInfoW, SHFILEINFOW,
        SHGFI_ICON, SHGFI_LARGEICON;
    import core.sys.windows.windef : HBRUSH, HANDLE, LPWSTR;
    import std.utf : toUTF8, toUTF16z;
    import std.algorithm : sort;
    import core.stdc.stdlib : malloc, free;
    import core.stdc.string : memcpy;

    // QueryFullProcessImageNameW is not bound by druntime, so declare it here.
    extern (Windows) nothrow @nogc
    {
        BOOL QueryFullProcessImageNameW(HANDLE, DWORD, LPWSTR, DWORD*);
    }
}

/// One live top-level OS window to surface in the taskbar.
struct ExternalTask
{
    ulong hwnd;
    string title;
    bool visible;
    bool minimized;
    bool maximized;
    int x, y, width, height;
}

version (Windows)
{
    // The shell's own native window must never appear as an external task.
    private __gshared ulong g_selfHwnd;

    /// Exclude the shell's own OS window from enumeration.
    void excludeWindow(ulong hwndValue) nothrow @nogc
    {
        g_selfHwnd = hwndValue;
    }
}

version (Windows)
{
    // Skip the shell/desktop/input windows that are not user tasks. Filters are
    // by class name so windows the OS owns (tray, input overlay, full-screen
    // system surfaces) never appear as a user task.
    private bool isShellClass(string className) nothrow @nogc
    {
        switch (className)
        {
            case "Shell_TrayWnd":
            case "Shell_SecondaryTrayWnd":
            case "Shell_Sysmon":
            case "Progman":
            case "WorkerW":
            case "NotifyIconOverflowWindow":
            case "MultitaskingViewFrame":
            case "CEF-OSC-WIDGET":         // NVIDIA GeForce overlay
            case "MobilityCenterApp":       // Windows Mobility Center
                return true;
            default:
                return false;
        }
    }

    // A full-screen CoreWindow (>= 1900x1040) is an OS input surface, not a real
    // app task (e.g. Microsoft Text Input Application, full-screen Settings).
    private bool isFullScreenSystemWindow(string className, int w, int h)
        nothrow @nogc
    {
        return className == "Windows.UI.Core.CoreWindow" &&
            w >= 1900 && h >= 1040;
    }

    private string toUtf8Safe(const(wchar)[] value) nothrow
    {
        try
        {
            return toUTF8(value);
        }
        catch (Exception)
        {
            return "";
        }
    }

    private extern(Windows) BOOL enumCallback(HWND hwnd, LPARAM lparam) nothrow
    {
        auto collector = cast(ExternalTask[]*) lparam;
        if (GetWindow(hwnd, GW_OWNER) !is null) return 1;
        if (!IsWindowVisible(hwnd)) return 1;
        if (g_selfHwnd != 0 && cast(ulong) hwnd == g_selfHwnd) return 1;

        wchar[512] buffer;
        const length = GetWindowTextW(hwnd, buffer.ptr, buffer.length);
        if (length == 0) return 1;
        const title = toUtf8Safe(buffer[0 .. length]);

        wchar[128] clsBuffer;
        const n = GetClassNameW(hwnd, clsBuffer.ptr, clsBuffer.length);
        const cls = n > 0 ? toUtf8Safe(clsBuffer[0 .. n]) : "";
        if (isShellClass(cls)) return 1;

        RECT r;
        GetWindowRect(hwnd, &r);
        const ww = r.right - r.left;
        const wh = r.bottom - r.top;
        // Skip title-bar-only stubs (minimized windows collapse to the caption)
        // and full-screen always-on-top overlays that are not real tasks.
        if (wh < 60) return 1;
        if (isFullScreenSystemWindow(cls, ww, wh)) return 1;

        ExternalTask task;
        task.hwnd = cast(ulong) hwnd;
        task.title = title;
        task.visible = true;
        task.minimized = IsIconic(hwnd) != 0;
        task.maximized = IsZoomed(hwnd) != 0;
        task.x = r.left;
        task.y = r.top;
        task.width = ww;
        task.height = wh;
        (*collector) ~= task;
        return 1;
    }
}

/// Enumerate the live top-level OS tasks (excludes shell/desktop/input windows).
ExternalTask[] enumerateExternalTasks()
{
    version (Windows)
    {
        ExternalTask[] result;
        EnumWindows(&enumCallback, cast(LPARAM) &result);
        result.sort!((a, b) => a.hwnd < b.hwnd);
        return result;
    }
    else
    {
        return [];
    }
}

/// Bring an external window to the foreground and restore it if minimized.
void activateExternalTask(ulong hwndValue)
{
    version (Windows)
    {
        auto hwnd = cast(HWND) hwndValue;
        if (IsIconic(hwnd)) ShowWindow(hwnd, 9 /* SW_RESTORE */);
        SetForegroundWindow(hwnd);
    }
}

/// Minimize an external window.
void minimizeExternalTask(ulong hwndValue)
{
    version (Windows)
    {
        ShowWindow(cast(HWND) hwndValue, 6 /* SW_MINIMIZE */);
    }
}

/// True if the given external hwnd is the current foreground window.
bool externalTaskFocused(ulong hwndValue)
{
    version (Windows)
    {
        return GetForegroundWindow() == cast(HWND) hwndValue;
    }
    else
    {
        return false;
    }
}

/// True when an external window still exists.
bool externalTaskAlive(ulong hwndValue)
{
    version (Windows)
    {
        return IsWindow(cast(HWND) hwndValue) != 0;
    }
    else
    {
        return false;
    }
}

/// True when an external window is currently minimized (iconic).
bool externalTaskMinimized(ulong hwndValue)
{
    version (Windows)
    {
        return IsIconic(cast(HWND) hwndValue) != 0;
    }
    else
    {
        return false;
    }
}

/// Client size (logical) of an external window, for thumbnail bounds.
Size externalTaskSize(ulong hwndValue)
{
    version (Windows)
    {
        auto hwnd = cast(HWND) hwndValue;
        RECT r;
        GetWindowRect(hwnd, &r);
        const w = r.right - r.left;
        const h = r.bottom - r.top;
        return Size(w > 0 ? w : 1, h > 0 ? h : 1);
    }
    else
    {
        return Size(320, 200);
    }
}

/// Close an external window (WM_CLOSE, so it can prompt to save).
void closeExternalTask(ulong hwndValue)
{
    version (Windows)
    {
        PostMessageW(cast(HWND) hwndValue, 0x0010 /* WM_CLOSE */, 0, 0);
    }
}

/**
 * Capture a window's content into a straight-alpha RGBA image using
 * PrintWindow (PW_RENDERFULLCONTENT so occluded/minimized windows still
 * render). Falls back to a screen-region BitBlt if PrintWindow returns all
 * black. Returns null on failure.
 */
RgbaImage captureExternalThumbnail(ulong hwndValue, int width, int height)
{
    version (Windows)
    {
        if (width <= 0 || height <= 0) return null;
        auto hwnd = cast(HWND) hwndValue;
        const w = width;
        const h = height;

        auto screenDc = GetDC(null);
        if (screenDc is null) return null;
        auto memDc = CreateCompatibleDC(screenDc);
        auto bitmap = CreateCompatibleBitmap(screenDc, w, h);
        if (memDc is null || bitmap is null)
        {
            ReleaseDC(null, screenDc);
            if (memDc !is null) DeleteDC(memDc);
            return null;
        }
        auto old = SelectObject(memDc, bitmap);
        scope (exit)
        {
            SelectObject(memDc, old);
            DeleteObject(bitmap);
            DeleteDC(memDc);
            ReleaseDC(null, screenDc);
        }

        BOOL ok = PrintWindow(hwnd, memDc, 2); // PW_RENDERFULLCONTENT
        if (!ok)
        {
            RECT r;
            GetWindowRect(hwnd, &r);
            BitBlt(memDc, 0, 0, w, h, screenDc, r.left, r.top, SRCCOPY);
        }

        BITMAPINFO bi;
        bi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h; // top-down
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        bi.bmiHeader.biSizeImage = 0;
        auto raw = cast(uint*) malloc(cast(size_t) w * h * 4 + 4);
        if (raw is null) return null;
        scope (exit) free(raw);
        int got = GetDIBits(memDc, bitmap, 0, h, raw, &bi, DIB_RGB_COLORS);
        if (got <= 0) return null;

        ubyte[] rgba;
        rgba.length = cast(size_t) w * cast(size_t) h * 4;
        const count = cast(size_t) w * cast(size_t) h;
        foreach (i; 0 .. count)
        {
            const argb = raw[i];
            const t = i * 4;
            rgba[t + 0] = cast(ubyte) ((argb >> 16) & 0xff);
            rgba[t + 1] = cast(ubyte) ((argb >> 8) & 0xff);
            rgba[t + 2] = cast(ubyte) (argb & 0xff);
            rgba[t + 3] = cast(ubyte) 255;
        }
        return new RgbaImage(w, h, rgba);
    }
    else
    {
        return null;
    }
}

/**
 * Extract a window's icon as a straight-alpha RGBA image.
 *
 * Probe order (verified live against real apps): WM_GETICON big, WM_GETICON
 * small2, class big (GCLP_HICON), class small (GCLP_HICONSM). The largest
 * usable raster wins so the 26 px taskbar slot is not upscaled from a 16 px
 * icon. If the window publishes no icon at all (or only an all-transparent
 * one, e.g. 7-Zip's frame) the owning executable's shell icon is used, which
 * also fixes UWP windows hosted by ApplicationFrameHost.exe by resolving the
 * hosted child process instead. Returns null when nothing usable exists.
 */
RgbaImage externalTaskIcon(ulong hwndValue)
{
    version (Windows)
    {
        auto hwnd = cast(HWND) hwndValue;
        enum UINT WM_GETICON = 0x007F;
        enum int ICON_BIG = 1;
        enum int ICON_SMALL2 = 2;
        enum int GCLP_HICON = -14;
        enum int GCLP_HICONSM = -34;

        HICON[4] candidates = [
            cast(HICON) SendMessageW(hwnd, WM_GETICON, ICON_BIG, 0),
            cast(HICON) SendMessageW(hwnd, WM_GETICON, ICON_SMALL2, 0),
            cast(HICON) GetClassLongPtrW(hwnd, GCLP_HICON),
            cast(HICON) GetClassLongPtrW(hwnd, GCLP_HICONSM)
        ];

        RgbaImage best;
        foreach (candidate; candidates)
        {
            if (candidate is null) continue;
            auto image = iconToRgba(candidate);
            if (image is null || !iconHasInk(image)) continue;
            if (best is null || image.width() > best.width())
                best = image;
        }
        if (best !is null) return best;

        // No usable window icon: fall back to the owning executable's shell
        // icon (SHGetFileInfoW asks the shell for the real, tagged icon).
        const path = executablePathForWindow(hwnd);
        return path.length > 0 ? shellIconForPath(path) : null;
    }
    else
    {
        return null;
    }
}

version (Windows)
{
    /// True when an icon actually contains a visible (non-zero alpha) pixel.
    private bool iconHasInk(RgbaImage image)
    {
        if (image is null) return false;
        const pixels = image.pixels();
        for (size_t i = 3; i < pixels.length; i += 4)
            if (pixels[i] != 0) return true;
        return false;
    }

    /**
     * Full path of the process owning `hwnd`. UWP windows are hosted by
     * ApplicationFrameHost.exe, whose icon is generic, so for those the hosted
     * child process (e.g. SystemSettings.exe) is returned instead.
     */
    private string executablePathForWindow(HWND hwnd) nothrow
    {
        const owner = processImagePath(hwnd);
        if (owner.length == 0) return "";
        if (baseNameOf(owner) == "ApplicationFrameHost.exe")
        {
            auto hosted = hostedChildProcessPath(hwnd, owner);
            if (hosted.length > 0) return hosted;
        }
        return owner;
    }

    private struct ChildSearch
    {
        string parentPath;
        string found;
    }

    private extern(Windows) BOOL childSearchCallback(HWND hwnd, LPARAM context)
        nothrow
    {
        auto search = cast(ChildSearch*) context;
        const path = processImagePath(hwnd);
        if (path.length > 0 && path != search.parentPath &&
            search.found.length == 0)
        {
            search.found = path;
            return 0;
        }
        return 1;
    }

    private string hostedChildProcessPath(HWND hwnd, string parentPath) nothrow
    {
        ChildSearch search;
        search.parentPath = parentPath;
        EnumChildWindows(hwnd, &childSearchCallback, cast(LPARAM) &search);
        return search.found;
    }

    private string processImagePath(HWND hwnd) nothrow
    {
        DWORD pid;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid == 0) return "";
        // PROCESS_QUERY_LIMITED_INFORMATION works without elevation for
        // windows owned by the current user.
        auto process = OpenProcess(0x1000, 0, pid);
        if (process is null) return "";
        scope (exit) CloseHandle(process);
        wchar[1024] buffer;
        buffer[0] = 0;
        DWORD length = buffer.length;
        if (!QueryFullProcessImageNameW(process, 0, buffer.ptr, &length))
            return "";
        return toUtf8Safe(buffer[0 .. length]);
    }

    private string baseNameOf(string path) nothrow
    {
        foreach (i; 0 .. path.length)
        {
            const offset = path.length - 1 - i;
            if (path[offset] == '\\' || path[offset] == '/')
                return path[offset + 1 .. $];
        }
        return path;
    }

    /// The shell's large (32 px) icon for an executable/file path.
    private RgbaImage shellIconForPath(string path)
    {
        SHFILEINFOW info;
        const result = SHGetFileInfoW(toUTF16z(path), 0, &info,
            SHFILEINFOW.sizeof, SHGFI_ICON | SHGFI_LARGEICON);
        if (result == 0 || info.hIcon is null) return null;
        scope (exit) DestroyIcon(info.hIcon);
        return iconToRgba(info.hIcon);
    }
}

version (Windows)
{
    private RgbaImage iconToRgba(HICON icon)
    {
        ICONINFO info;
        if (!GetIconInfo(icon, &info)) return null;
        scope (exit)
        {
            if (info.hbmColor !is null) DeleteObject(info.hbmColor);
            if (info.hbmMask !is null) DeleteObject(info.hbmMask);
        }

        BITMAP bm;
        if (info.hbmColor !is null)
            GetObjectW(info.hbmColor, BITMAP.sizeof, &bm);
        else
            GetObjectW(info.hbmMask, BITMAP.sizeof, &bm);
        const w = bm.bmWidth > 0 ? bm.bmWidth : 16;
        const h = bm.bmHeight > 0 ? bm.bmHeight : 16;

        auto dc = GetDC(null);
        if (dc is null) return null;
        auto memDc = CreateCompatibleDC(dc);
        auto bmp = CreateCompatibleBitmap(dc, w, h);
        if (memDc is null || bmp is null)
        {
            ReleaseDC(null, dc);
            if (memDc !is null) DeleteDC(memDc);
            return null;
        }
        auto old = SelectObject(memDc, bmp);
        DrawIconEx(memDc, 0, 0, icon, w, h, 0, null, 3 /* DI_NORMAL */);
        SelectObject(memDc, old);

        BITMAPINFO bi;
        bi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        auto raw = cast(uint*) malloc(cast(size_t) w * h * 4 + 4);
        if (raw is null)
        {
            DeleteObject(bmp);
            DeleteDC(memDc);
            ReleaseDC(null, dc);
            return null;
        }
        int got = GetDIBits(memDc, bmp, 0, h, raw, &bi, DIB_RGB_COLORS);

        DeleteObject(bmp);
        DeleteDC(memDc);
        ReleaseDC(null, dc);

        if (got <= 0)
        {
            free(raw);
            return null;
        }
        ubyte[] rgba;
        rgba.length = cast(size_t) w * cast(size_t) h * 4;
        const count = cast(size_t) w * cast(size_t) h;
        foreach (i; 0 .. count)
        {
            const argb = raw[i];
            const t = i * 4;
            rgba[t + 0] = cast(ubyte) ((argb >> 16) & 0xff);
            rgba[t + 1] = cast(ubyte) ((argb >> 8) & 0xff);
            rgba[t + 2] = cast(ubyte) (argb & 0xff);
            rgba[t + 3] = cast(ubyte) ((argb >> 24) & 0xff);
        }
        free(raw);
        return new RgbaImage(w, h, rgba);
    }
}
