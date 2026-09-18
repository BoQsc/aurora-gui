module auroradesktop.tasks;

import aurora.image : RgbaImage;
import aurora.types : Size;

version (Windows)
{
    import core.sys.windows.windows : HWND, DWORD, BOOL, LPARAM, WPARAM, UINT,
        HDC, HGDIOBJ, HBITMAP, RECT, HICON, SIZE_T, PVOID;
    import core.sys.windows.winuser : EnumWindows, EnumChildWindows, GetWindowTextW,
        GetWindowRect, IsWindowVisible, GetClassNameW, GetDC, ReleaseDC,
        ShowWindow, IsIconic, IsZoomed, SetForegroundWindow, GetForegroundWindow,
        SetWindowPos, HWND_TOP, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW,
        AttachThreadInput, BringWindowToTop, SetActiveWindow,
        GetWindow, IsWindow, FindWindowW, GW_OWNER, GW_CHILD, GW_HWNDNEXT,
        PrintWindow, PostMessageW, SendMessageW, GetIconInfo, GetClassLongPtrW,
        DrawIconEx, DestroyIcon, ICONINFO;
    import core.sys.windows.wingdi : CreateCompatibleDC, CreateCompatibleBitmap,
        SelectObject, DeleteDC, DeleteObject, GetDIBits, DIB_RGB_COLORS,
        BITMAPINFO, BITMAPINFOHEADER, BI_RGB, BitBlt, SRCCOPY,
        GetObjectW, BITMAP;
    import core.sys.windows.commctrl : TBBUTTON, TB_GETBUTTON, TB_BUTTONCOUNT;
    import core.sys.windows.winbase : GetWindowThreadProcessId, OpenProcess,
        CloseHandle, VirtualAllocEx, VirtualFreeEx, ReadProcessMemory,
        GetCurrentThreadId;
    import core.sys.windows.shellapi : SHGetFileInfoW, SHFILEINFOW,
        SHGFI_ICON, SHGFI_LARGEICON;
    import core.sys.windows.windef : HBRUSH, HANDLE, LPWSTR;
    import std.utf : toUTF8, toUTF16z;
    import std.algorithm : sort;
    import std.conv : to;
    import core.stdc.stdlib : malloc, free;
    import core.stdc.string : memcpy;

    // QueryFullProcessImageNameW is not bound by druntime, so declare it here.
    extern (Windows) nothrow @nogc
    {
        BOOL QueryFullProcessImageNameW(HANDLE, DWORD, LPWSTR, DWORD*);
    }

    enum DWORD PROCESS_VM_OPERATION = 0x0008;
    enum DWORD PROCESS_VM_READ = 0x0010;
    enum DWORD PROCESS_QUERY_INFORMATION = 0x0400;
    enum DWORD MEM_COMMIT = 0x1000;
    enum DWORD MEM_RESERVE = 0x2000;
    enum DWORD MEM_RELEASE = 0x8000;
    enum DWORD PAGE_READWRITE = 0x04;
    enum UINT TBSTATE_HIDDEN_ = 8;
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
        const minimized = IsIconic(hwnd) != 0;
        // Windows keeps a minimized window in the taskbar (dimmed indicator), so
        // never drop it. A minimized window's GetWindowRect collapses to a
        // title-bar/off-screen stub, so the stub and full-screen-overlay filters
        // only apply to normal windows; dropping minimized windows here made a
        // task button vanish the moment it was minimized by a click.
        if (!minimized)
        {
            if (wh < 60) return 1;
            if (isFullScreenSystemWindow(cls, ww, wh)) return 1;
        }

        ExternalTask task;
        task.hwnd = cast(ulong) hwnd;
        task.title = title;
        task.visible = true;
        task.minimized = minimized;
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
///
/// A plain SetForegroundWindow is unreliable: Windows' foreground lock can
/// ignore it and leave the OS taskbar focused instead of the target app. The
/// AttachThreadInput dance (plus raising the window) is the standard workaround
/// and is what actually makes the program come up.
void activateExternalTask(ulong hwndValue)
{
    version (Windows)
    {
        auto hwnd = cast(HWND) hwndValue;
        if (IsIconic(hwnd)) ShowWindow(hwnd, 9 /* SW_RESTORE */);
        if (!IsWindowVisible(hwnd)) ShowWindow(hwnd, 5 /* SW_SHOW */);
        SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        auto targetThread = GetWindowThreadProcessId(hwnd, null);
        auto thisThread = GetCurrentThreadId();
        auto foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(),
            null);
        bool attachedTarget = targetThread != 0 && targetThread != thisThread &&
            AttachThreadInput(thisThread, targetThread, 1) != 0;
        bool attachedForeground = foregroundThread != 0 &&
            foregroundThread != thisThread &&
            foregroundThread != targetThread &&
            AttachThreadInput(thisThread, foregroundThread, 1) != 0;
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        SetActiveWindow(hwnd);
        if (attachedForeground)
            AttachThreadInput(thisThread, foregroundThread, 0);
        if (attachedTarget)
            AttachThreadInput(thisThread, targetThread, 0);
    }
}

/// Restore an external window without forcing it to the foreground (used when
/// un-doing Show Desktop).
void restoreExternalTask(ulong hwndValue)
{
    version (Windows)
    {
        auto hwnd = cast(HWND) hwndValue;
        if (IsIconic(hwnd)) ShowWindow(hwnd, 9 /* SW_RESTORE */);
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

/**
 * Stable grouping key for an external task: the owning executable path, so
 * every window of the same application collapses into one taskbar button.
 * UWP host frames resolve to the hosted app's process (see
 * `externalTaskIcon`). Returns "" when the owner cannot be determined.
 */
string externalTaskGroupKey(ulong hwndValue)
{
    version (Windows)
        return executablePathForWindow(cast(HWND) hwndValue);
    else
        return "";
}

/// True when a tray callback looks usable: a real owner window and an
/// application-defined message (WM_USER range or a RegisterWindowMessage value).
private bool usableTrayCallback(ulong hwndValue, uint callbackMessage)
{
    return hwndValue != 0 && callbackMessage >= 0x0400 &&
        callbackMessage <= 0xFFFF;
}

/**
 * Ask an application to perform its own primary (left-click) tray action by
 * posting its tray callback message with WM_LBUTTONUP.
 *
 * Per the Shell_NotifyIcon contract, while uVersion is 0 or NOTIFYICON_VERSION
 * (3) the callback carries wParam = notification id and lParam = the mouse
 * message, so this is exactly what Explorer sends the owning application. The
 * same packing is used by `postTrayContextMenu`. Returns false when the callback
 * looks unusable so the caller can activate the app instead.
 */
bool postTrayPrimaryClick(ulong hwndValue, uint callbackMessage, uint id)
{
    version (Windows)
    {
        if (!usableTrayCallback(hwndValue, callbackMessage)) return false;
        enum UINT WM_LBUTTONUP = 0x0202;
        return PostMessageW(cast(HWND) hwndValue, callbackMessage,
            cast(WPARAM) id, cast(LPARAM) WM_LBUTTONUP) != 0;
    }
    else
    {
        return false;
    }
}

/**
 * Ask an application to run its tray DOUBLE-click action by replaying the
 * Windows double-click sequence (down, up, dblclk, up) on its tray callback.
 * Apps such as Task Manager toggle their flyout on a single click but open
 * their main window only on WM_LBUTTONDBLCLK, so two independent single clicks
 * cancel out and appear to do nothing. Returns false when the callback is
 * unusable so the caller can fall back to the single-click action.
 */
bool postTrayDoubleClick(ulong hwndValue, uint callbackMessage, uint id)
{
    version (Windows)
    {
        if (!usableTrayCallback(hwndValue, callbackMessage)) return false;
        enum UINT WM_LBUTTONDOWN = 0x0201;
        enum UINT WM_LBUTTONUP = 0x0202;
        enum UINT WM_LBUTTONDBLCLK = 0x0203;
        auto target = cast(HWND) hwndValue;
        auto wparam = cast(WPARAM) id;
        bool ok = PostMessageW(target, callbackMessage, wparam,
            cast(LPARAM) WM_LBUTTONDOWN) != 0;
        ok = PostMessageW(target, callbackMessage, wparam,
            cast(LPARAM) WM_LBUTTONUP) != 0 && ok;
        ok = PostMessageW(target, callbackMessage, wparam,
            cast(LPARAM) WM_LBUTTONDBLCLK) != 0 && ok;
        ok = PostMessageW(target, callbackMessage, wparam,
            cast(LPARAM) WM_LBUTTONUP) != 0 && ok;
        return ok;
    }
    else
    {
        return false;
    }
}

/**
 * Ask an application to open its own tray context menu by posting its tray
 * callback message with WM_RBUTTONUP (classic packing: wParam = notification
 * id, lParam = WM_RBUTTONUP). Returns false when the callback looks unusable so
 * the caller can show a fallback menu.
 */
bool postTrayContextMenu(ulong hwndValue, uint callbackMessage, uint id)
{
    version (Windows)
    {
        if (!usableTrayCallback(hwndValue, callbackMessage)) return false;
        enum UINT WM_RBUTTONUP = 0x0205;
        return PostMessageW(cast(HWND) hwndValue, callbackMessage,
            cast(WPARAM) id, cast(LPARAM) WM_RBUTTONUP) != 0;
    }
    else
    {
        return false;
    }
}

/// Shell icon for an executable path (used by pinned taskbar apps).
RgbaImage executableIcon(string path)
{
    version (Windows)
        return path.length > 0 ? shellIconForPath(path) : null;
    else
        return null;
}

/// Shell icon for any filesystem path (file, folder or shortcut).
RgbaImage fileIcon(string path)
{
    version (Windows)
        return path.length > 0 ? shellIconForPath(path) : null;
    else
        return null;
}

/// Current caption of an external window ("" when it cannot be read).
string externalTaskTitle(ulong hwndValue)
{
    version (Windows)
    {
        wchar[512] buffer;
        const length = GetWindowTextW(cast(HWND) hwndValue, buffer.ptr,
            buffer.length);
        return length > 0 ? toUtf8Safe(buffer[0 .. length]) : "";
    }
    else
    {
        return "";
    }
}

/// One real notification-area (system tray) icon from the Windows shell.
struct TrayIconInfo
{
    /// Owning application window (0 when unknown).
    ulong hwnd;
    /// Notification id within that window (0 when unknown).
    uint id;
    /// Window message the owner registered for tray callbacks (0 when unknown).
    uint callbackMessage;
    /// Short label (tooltip first line, else the owning executable name).
    string label;
    /// Full multi-line tooltip text.
    string tooltip;
    /// Owning process image path ("" when unknown).
    string exePath;
    /// The real 16/20/32 px tray icon (null when it could not be read).
    RgbaImage icon;
    /// True when the icon lives in the overflow ("hidden icons") flyout.
    bool hidden;
    /// True for Windows-provided system icons (network/battery/security/...).
    bool isSystem;
}

version (Windows)
{
    private HWND findDescendantByText(HWND parent, string wanted)
    {
        for (auto child = GetWindow(parent, GW_CHILD); child !is null;
            child = GetWindow(child, GW_HWNDNEXT))
        {
            wchar[512] buffer;
            const length = GetWindowTextW(child, buffer.ptr, buffer.length);
            if (length > 0 && toUtf8Safe(buffer[0 .. length]) == wanted)
                return child;
            auto nested = findDescendantByText(child, wanted);
            if (nested !is null) return nested;
        }
        return null;
    }

    private string firstLine(string value)
    {
        foreach (i, c; value)
            if (c == '\n' || c == '\r') return value[0 .. i];
        return value;
    }

    private string stripExtension(string name)
    {
        foreach (i; 0 .. name.length)
        {
            const offset = name.length - 1 - i;
            if (name[offset] == '.') return name[0 .. offset];
        }
        return name;
    }

    /// Windows-provided tray icons (network/battery/security/...) that the
    /// shell may optionally hide behind its own system glyphs.
    private bool isSystemTrayExecutable(string path)
    {
        if (path.length == 0) return false;
        import std.string : toLower;
        const name = toLower(baseNameOf(path));
        switch (name)
        {
            case "explorer.exe":
            case "securityhealthsystray.exe":
            case "securityhealthservice.exe":
            case "systemsettings.exe":
            case "shellexperiencehost.exe":
            case "startmenuexperiencehost.exe":
                return true;
            default:
                return false;
        }
    }

    /// Read a UTF-16 string from another process ("" on failure).
    private string readRemoteString(HANDLE process, size_t address, size_t chars)
    {
        if (address == 0) return "";
        auto buffer = new wchar[chars];
        SIZE_T read;
        if (!ReadProcessMemory(process, cast(const(void)*) address,
                buffer.ptr, chars * wchar.sizeof, &read))
            return "";
        size_t length;
        while (length < chars && buffer[length] != 0 && length < 200) ++length;
        return toUtf8Safe(buffer[0 .. length]);
    }

    /**
     * Enumerate the real notification-area icons.
     *
     * The classic Explorer tray toolbars still exist on Windows 11: the
     * "User Promoted Notification Area" toolbar holds the visible icons (and
     * hidden placeholders marked TBSTATE_HIDDEN) and the
     * "NotifyIconOverflowWindow" toolbar holds the overflow icons. For each
     * button the undocumented TRAYDATA read from `TBBUTTON.dwData` exposes the
     * owning HWND (+0), notification id (+8) and HICON (+24), while
     * `TBBUTTON.iString` points at the tooltip. All reads are validated so a
     * layout change degrades to fewer icons instead of crashing.
     */
    // Steady-state caches for the 1 s tray refresh. An icon's owning executable
    // and its raster almost never change, but the old code re-ran OpenProcess +
    // iconToRgba (GDI + a full per-pixel loop) for every icon every second -
    // the main periodic UI hitch. Keyed by owner window / HICON.
    private string[ulong] _trayExePathCache;
    private bool[ulong] _traySystemCache;
    private RgbaImage[ulong] _trayIconRasterCache;

    TrayIconInfo[] enumerateTrayIcons()
    {
        TrayIconInfo[] result;
        auto tray = FindWindowW(toUTF16z("Shell_TrayWnd"), null);
        if (tray !is null)
        {
            auto promoted = findDescendantByText(tray,
                "User Promoted Notification Area");
            readTrayToolbar(promoted, false, result);
        }
        auto overflow = FindWindowW(toUTF16z("NotifyIconOverflowWindow"), null);
        if (overflow !is null)
        {
            auto toolbar = findDescendantByText(overflow,
                "Overflow Notification Area");
            readTrayToolbar(toolbar, true, result);
        }
        return result;
    }

    private void readTrayToolbar(HWND toolbar, bool overflow,
        ref TrayIconInfo[] output)
    {
        if (toolbar is null) return;
        DWORD pid;
        GetWindowThreadProcessId(toolbar, &pid);
        if (pid == 0) return;
        auto process = OpenProcess(PROCESS_VM_OPERATION | PROCESS_VM_READ |
            PROCESS_QUERY_INFORMATION, 0, pid);
        if (process is null) return;
        scope (exit) CloseHandle(process);

        const remote = cast(size_t) VirtualAllocEx(process, null, 0x2000,
            MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
        if (remote == 0) return;
        scope (exit) VirtualFreeEx(process, cast(void*) remote, 0, MEM_RELEASE);

        const count = cast(int) SendMessageW(toolbar, TB_BUTTONCOUNT, 0, 0);
        foreach (i; 0 .. count)
        {
            TBBUTTON button;
            SIZE_T read;
            if (!SendMessageW(toolbar, TB_GETBUTTON, cast(WPARAM) i,
                    cast(LPARAM) remote))
                continue;
            if (!ReadProcessMemory(process, cast(const(void)*) remote,
                    &button, TBBUTTON.sizeof, &read))
                continue;
            // Hidden placeholders in the promoted toolbar are not real icons.
            if (!overflow && (button.fsState & TBSTATE_HIDDEN_) != 0)
                continue;

            TrayIconInfo info;
            info.hidden = overflow;
            info.tooltip = readRemoteString(process, cast(size_t) button.iString,
                256);
            info.label = firstLine(info.tooltip);

            // TRAYDATA: HWND at +0, uID at +8, HICON at +24.
            ubyte[56] header;
            if (ReadProcessMemory(process, cast(const(void)*) button.dwData,
                    header.ptr, header.length, &read))
            {
                ulong ownerHwnd;
                uint ownerId;
                uint ownerCallback;
                ulong iconHandle;
                foreach (k; 0 .. 8)
                    ownerHwnd |= cast(ulong) header[k] << (8 * k);
                foreach (k; 0 .. 4)
                    ownerId |= cast(uint) header[8 + k] << (8 * k);
                foreach (k; 0 .. 4)
                    ownerCallback |= cast(uint) header[12 + k] << (8 * k);
                foreach (k; 0 .. 8)
                    iconHandle |= cast(ulong) header[24 + k] << (8 * k);
                if (ownerHwnd != 0 && IsWindow(cast(HWND) ownerHwnd))
                {
                    info.hwnd = ownerHwnd;
                    info.id = ownerId;
                    info.callbackMessage = ownerCallback;
                    // Resolve the owning executable once per window: this path
                    // opens the process and reads its image path, which is too
                    // expensive to repeat every second for every icon.
                    if (auto cachedPath = ownerHwnd in _trayExePathCache)
                        info.exePath = *cachedPath;
                    else
                    {
                        info.exePath = processImagePath(cast(HWND) ownerHwnd);
                        if (_trayExePathCache.length >= 256)
                        {
                            _trayExePathCache = null;
                            _traySystemCache = null;
                        }
                        _trayExePathCache[ownerHwnd] = info.exePath;
                    }
                    if (auto cachedSystem = ownerHwnd in _traySystemCache)
                        info.isSystem = *cachedSystem;
                    else
                    {
                        info.isSystem = isSystemTrayExecutable(info.exePath);
                        _traySystemCache[ownerHwnd] = info.isSystem;
                    }
                    // Re-rasterize only when the icon handle actually changed
                    // (e.g. Task Manager's animated CPU meter).
                    if (iconHandle != 0)
                    {
                        if (auto cachedIcon = iconHandle in _trayIconRasterCache)
                            info.icon = *cachedIcon;
                        else
                        {
                            auto raster = iconToRgba(cast(HICON) iconHandle);
                            if (raster !is null)
                            {
                                if (_trayIconRasterCache.length >= 128)
                                    _trayIconRasterCache = null;
                                _trayIconRasterCache[iconHandle] = raster;
                            }
                            info.icon = raster;
                        }
                    }
                }
            }

            if (info.label.length == 0 && info.exePath.length > 0)
                info.label = stripExtension(baseNameOf(info.exePath));
            if (info.label.length == 0)
                info.label = "Notification";
            output ~= info;
        }
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

        // Preferred: read the icon's own colour bitmap directly. DrawIconEx
        // alpha-blends the icon onto a background, which darkens/softens the
        // anti-aliased edges; the raw DIB keeps the exact straight-alpha pixels
        // (sharp and solid), and lets the renderer do the only scaling.
        if (info.hbmColor !is null)
        {
            auto rawDc = GetDC(null);
            if (rawDc !is null)
            {
                BITMAPINFO rbi;
                rbi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
                rbi.bmiHeader.biWidth = w;
                rbi.bmiHeader.biHeight = -h;
                rbi.bmiHeader.biPlanes = 1;
                rbi.bmiHeader.biBitCount = 32;
                rbi.bmiHeader.biCompression = BI_RGB;
                auto colorPixels = cast(uint*) malloc(cast(size_t) w * h * 4 + 4);
                if (colorPixels !is null)
                {
                    ubyte[] direct;
                    bool directAlpha;
                    if (GetDIBits(rawDc, info.hbmColor, 0, h, colorPixels, &rbi,
                            DIB_RGB_COLORS) > 0)
                    {
                        direct.length = cast(size_t) w * h * 4;
                        const directCount = cast(size_t) w * h;
                        foreach (i; 0 .. directCount)
                        {
                            const argb = colorPixels[i];
                            const t = i * 4;
                            direct[t + 0] = cast(ubyte) ((argb >> 16) & 0xff);
                            direct[t + 1] = cast(ubyte) ((argb >> 8) & 0xff);
                            direct[t + 2] = cast(ubyte) (argb & 0xff);
                            direct[t + 3] = cast(ubyte) ((argb >> 24) & 0xff);
                            if (direct[t + 3] != 0) directAlpha = true;
                        }
                    }
                    free(colorPixels);
                    ReleaseDC(null, rawDc);
                    if (directAlpha) return new RgbaImage(w, h, direct);
                }
                else
                    ReleaseDC(null, rawDc);
            }
        }

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
        bool anyAlpha;
        foreach (i; 0 .. count)
        {
            const argb = raw[i];
            const t = i * 4;
            rgba[t + 0] = cast(ubyte) ((argb >> 16) & 0xff);
            rgba[t + 1] = cast(ubyte) ((argb >> 8) & 0xff);
            rgba[t + 2] = cast(ubyte) (argb & 0xff);
            rgba[t + 3] = cast(ubyte) ((argb >> 24) & 0xff);
            if (rgba[t + 3] != 0) anyAlpha = true;
        }
        free(raw);

        // DrawIconEx onto a compatible bitmap produces no alpha channel for
        // legacy (mask-based) icons, leaving them fully transparent and thus
        // invisible. Recover alpha from the AND mask: 1 = transparent,
        // 0 = opaque.
        if (!anyAlpha && info.hbmColor !is null && info.hbmMask !is null)
        {
            auto maskDc = GetDC(null);
            if (maskDc !is null)
            {
                auto maskRaw = cast(uint*) malloc(count * 4 + 4);
                if (maskRaw !is null)
                {
                    if (GetDIBits(maskDc, info.hbmMask, 0, h, maskRaw, &bi,
                            DIB_RGB_COLORS) > 0)
                    {
                        foreach (i; 0 .. count)
                            rgba[i * 4 + 3] =
                                (maskRaw[i] & 0x00ffffff) != 0 ? 0 : 255;
                    }
                    free(maskRaw);
                }
                ReleaseDC(null, maskDc);
            }
        }
        return new RgbaImage(w, h, rgba);
    }
}

// --- background thumbnail worker ---------------------------------------------
// Native taskbars show window previews instantly because DWM already has the
// frames. `captureExternalThumbnail` costs 15-70 ms per window, so capturing on
// hover made a grouped preview (15 windows) take seconds. This worker keeps a
// warm cache off the UI thread; the UI only ever reads it, so previews are
// instant and no hover ever stalls.
//
// All module-level state is __gshared because the worker is a real OS thread
// (D module globals are thread-local by default and the worker would otherwise
// see a private, empty copy).
version (Windows)
{
    import core.thread : Thread;
    import core.sync.mutex : Mutex;
    import core.time : MonoTime, dur;

    private __gshared Thread _thumbWorker;
    private __gshared bool _thumbWorkerStop;
    private __gshared Mutex _thumbLock;
    private __gshared ulong[] _thumbTargets;
    private __gshared ulong[] _thumbPriority;
    private __gshared RgbaImage[ulong] _thumbShared;
    private __gshared MonoTime[ulong] _thumbSharedAt;
    private __gshared bool _thumbWorkerRunning;
    // Warm each window once, then refresh only on demand (hover). A 1 s
    // round-robin over 40 windows would be a constant ~50% of a core of
    // PrintWindow work for previews nobody is looking at.
    private enum double thumbRefreshSeconds = 60.0;
    private enum double thumbBackgroundRefreshSeconds = 60.0;
    // Previews render at ~200 px wide; capturing larger is wasted work.
    private enum int thumbMaxDimension = 480;

    /// Fit a capture inside the thumbnail box, preserving aspect. PrintWindow
    /// scales the window into the destination DC (verified: capped vs full
    /// downscale MAE 8/255), so a small capture is a correct large one scaled.
    void thumbnailCaptureSize(int fullWidth, int fullHeight, out int width,
        out int height)
    {
        if (fullWidth <= 0 || fullHeight <= 0)
        {
            width = 1;
            height = 1;
            return;
        }
        if (fullWidth <= thumbMaxDimension && fullHeight <= thumbMaxDimension)
        {
            width = fullWidth;
            height = fullHeight;
            return;
        }
        if (fullWidth >= fullHeight)
        {
            width = thumbMaxDimension;
            height = cast(int) (cast(long) fullHeight * thumbMaxDimension /
                fullWidth);
        }
        else
        {
            height = thumbMaxDimension;
            width = cast(int) (cast(long) fullWidth * thumbMaxDimension /
                fullHeight);
        }
        if (width < 1) width = 1;
        if (height < 1) height = 1;
    }

    /// Start the worker. Safe to call repeatedly. Call from the real app only
    /// (tests never stop it, so a daemon thread would outlive their root).
    void startThumbnailWorker()
    {
        if (_thumbWorkerRunning) return;
        _thumbLock = new Mutex();
        _thumbWorkerStop = false;
        _thumbWorkerRunning = true;
        _thumbWorker = new Thread(&thumbnailWorkerMain);
        _thumbWorker.isDaemon = true;
        _thumbWorker.start();
    }

    void stopThumbnailWorker()
    {
        if (!_thumbWorkerRunning) return;
        _thumbWorkerStop = true;
        if (_thumbWorker !is null) _thumbWorker.join();
        _thumbWorker = null;
        _thumbWorkerRunning = false;
    }

    /// Publish the windows whose previews should stay warm (live tasks; may
    /// include minimized ones, whose last frame is kept but not refreshed).
    void setThumbnailTargets(ulong[] hwnds)
    {
        if (_thumbLock is null) return;
        synchronized (_thumbLock)
        {
            _thumbTargets = hwnds.dup;
            bool[ulong] live;
            foreach (hwnd; hwnds) live[hwnd] = true;
            ulong[] stale;
            foreach (hwnd; _thumbShared.keys)
                if (hwnd !in live) stale ~= hwnd;
            foreach (hwnd; stale)
            {
                _thumbShared.remove(hwnd);
                _thumbSharedAt.remove(hwnd);
            }
        }
    }

    /// Ask for an immediate capture (the window the user just hovered).
    void requestThumbnail(ulong hwnd)
    {
        if (_thumbLock is null || hwnd == 0) return;
        synchronized (_thumbLock)
        {
            foreach (existing; _thumbPriority)
                if (existing == hwnd) return;
            _thumbPriority ~= hwnd;
        }
    }

    /// The cached frame for `hwnd`, or null when not captured yet. Never blocks
    /// on a capture: the caller shows a placeholder and the worker fills it.
    RgbaImage cachedThumbnail(ulong hwnd)
    {
        if (_thumbLock is null) return null;
        synchronized (_thumbLock)
        {
            auto found = hwnd in _thumbShared;
            return found is null ? null : *found;
        }
    }

    /// A failed PrintWindow is uniformly black; sample cheaply instead of
    /// storing an empty frame.
    private bool thumbnailHasContent(RgbaImage image)
    {
        if (image is null) return false;
        const px = image.pixels();
        for (size_t i = 0; i + 3 < px.length; i += 4 * 7)
            if (px[i] > 16 || px[i + 1] > 16 || px[i + 2] > 16) return true;
        return false;
    }

    private bool thumbnailDue(ulong hwnd, MonoTime now)
    {
        if (externalTaskMinimized(hwnd)) return false;
        auto at = hwnd in _thumbSharedAt;
        if (at is null) return true;
        return (now - *at).total!"seconds" >= thumbRefreshSeconds;
    }

    private void thumbnailWorkerMain()
    {
        while (!_thumbWorkerStop)
        {
            ulong target;
            bool have;
            synchronized (_thumbLock)
            {
                const now = MonoTime.currTime;
                while (_thumbPriority.length > 0)
                {
                    const candidate = _thumbPriority[0];
                    _thumbPriority = _thumbPriority[1 .. $];
                    if (candidate != 0 && thumbnailDue(candidate, now))
                    {
                        target = candidate;
                        have = true;
                        break;
                    }
                }
                if (!have)
                {
                    foreach (hwnd; _thumbTargets)
                    {
                        if (!thumbnailDue(hwnd, now)) continue;
                        target = hwnd;
                        have = true;
                        break;
                    }
                }
            }
            if (!have)
            {
                Thread.sleep(dur!"msecs"(15));
                continue;
            }

            auto size = externalTaskSize(target);
            int width;
            int height;
            thumbnailCaptureSize(size.width, size.height, width, height);
            auto image = captureExternalThumbnail(target, width, height);
            if (image !is null && !thumbnailHasContent(image)) image = null;

            synchronized (_thumbLock)
            {
                if (externalTaskAlive(target))
                {
                    if (image !is null) _thumbShared[target] = image;
                    _thumbSharedAt[target] = MonoTime.currTime;
                }
                else
                {
                    _thumbShared.remove(target);
                    _thumbSharedAt.remove(target);
                }
            }
        }
    }
}


