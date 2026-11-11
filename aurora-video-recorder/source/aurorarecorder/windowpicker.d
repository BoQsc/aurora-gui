module aurorarecorder.windowpicker;

/**
 * Focused ("record this window") capture support.
 *
 * A window is identified by its `HWND`, which is stable for the life of the
 * window but not across restarts, so the chosen window is remembered by the
 * pair (process name, title) and re-resolved when a recording starts.
 *
 * Geometry comes from `DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS)`
 * first, because `GetWindowRect` includes the invisible resize border on
 * Windows 10+, which would leave a transparent margin around the recording.
 */

import aurorarecorder.settings : CaptureRect;

version (Windows)
{
    import core.sys.windows.windows : BOOL, CloseHandle, DWORD, EnumWindows,
        FALSE, GetAncestor, GetClientRect, GetWindowRect, GetWindowTextLengthW,
        GetWindowTextW, GetWindowThreadProcessId, HANDLE, HWND, IsWindow,
        IsWindowVisible, LPARAM, LPWSTR, MAX_PATH, OpenProcess, POINT, RECT, TRUE,
        WindowFromPoint, ClientToScreen, HRESULT, WNDENUMPROC, LoadLibraryW,
        GetProcAddress;
    import std.path : baseName;
    import std.string : toLower;
    import std.utf : toUTF8;

    // druntime omits both (see the repo's "declare missing Win32 prototypes
    // locally" rule).
    private enum DWORD PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    extern(Windows) BOOL QueryFullProcessImageNameW(HANDLE, DWORD, LPWSTR,
        DWORD*);
}

/// A window the user picked.
struct PickedWindow
{
    size_t handle;    ///< HWND as an integer (0 = none)
    string title;
    string processName;

    bool valid() const pure nothrow @safe { return handle != 0; }
}

/// Geometry of a live window in physical screen pixels.
version (Windows)
CaptureRect windowCaptureRect(HWND window, bool clientAreaOnly = true)
{
    if (window is null || IsWindow(window) == FALSE) return CaptureRect.init;
    if (clientAreaOnly)
    {
        RECT client;
        POINT origin;
        origin.x = 0;
        origin.y = 0;
        if (ClientToScreen(window, &origin) != FALSE &&
            GetClientRect(window, &client) != FALSE)
        {
            const width = client.right - client.left;
            const height = client.bottom - client.top;
            if (width > 0 && height > 0)
                return CaptureRect(origin.x, origin.y, width, height);
        }
    }
    // Window frame, excluding the DWM shadow/virtual border when possible.
    RECT frame;
    if (dwmExtendedFrameBounds(window, frame))
    {
        const width = frame.right - frame.left;
        const height = frame.bottom - frame.top;
        if (width > 0 && height > 0)
            return CaptureRect(frame.left, frame.top, width, height);
    }
    if (GetWindowRect(window, &frame) == FALSE) return CaptureRect.init;
    const width = frame.right - frame.left;
    const height = frame.bottom - frame.top;
    if (width <= 0 || height <= 0) return CaptureRect.init;
    return CaptureRect(frame.left, frame.top, width, height);
}

version (Windows)
private bool dwmExtendedFrameBounds(HWND window, out RECT bounds)
{
    // Declared and resolved locally: druntime has no DWMWA_EXTENDED_FRAME_BOUNDS
    // binding, and dwmapi has no import library in the default search path.
    // 9 = DWMWA_EXTENDED_FRAME_BOUNDS on Windows 10/11.
    alias DwmGetWindowAttributeFn = extern(Windows) HRESULT function(HWND,
        DWORD, void*, DWORD);
    __gshared DwmGetWindowAttributeFn resolve;
    if (resolve is null)
    {
        auto dwmapi = LoadLibraryW("dwmapi.dll");
        if (dwmapi !is null)
            resolve = cast(DwmGetWindowAttributeFn) GetProcAddress(dwmapi,
                "DwmGetWindowAttribute");
        if (resolve is null) return false;
    }
    enum DWORD dWMWAExtendedFrameBounds = 9;
    RECT rect;
    const hr = resolve(window, dWMWAExtendedFrameBounds, &rect,
        RECT.sizeof);
    if (hr < 0) return false;
    bounds = rect;
    return true;
}

/**
 * The top-level window under a screen point, or 0 when the point hits the
 * desktop. Helper/owned windows are promoted to their top-level owner so the
 * recording follows the whole application window.
 */
version (Windows)
HWND topLevelWindowAt(int screenX, int screenY)
{
    POINT point;
    point.x = screenX;
    point.y = screenY;
    HWND window = WindowFromPoint(point);
    if (window is null) return null;
    // GA_ROOT = 2
    HWND root = GetAncestor(window, 2);
    return root !is null ? root : window;
}

/// True when the window can be recorded (visible, non-zero client area).
version (Windows)
bool windowRecordable(HWND window)
{
    return window !is null && IsWindow(window) != FALSE &&
        IsWindowVisible(window) != FALSE &&
        windowCaptureRect(window).valid();
}

/// Display title of a window ("" when it has none).
version (Windows)
string windowTitle(HWND window)
{
    if (window is null) return "";
    // GetWindowTextW with a local buffer; declared through the length form.
    const length = GetWindowTextLengthW(window);
    if (length <= 0) return "";
    wchar[] buffer;
    buffer.length = length + 1;
    const written = GetWindowTextW(window, buffer.ptr,
        cast(int) buffer.length);
    if (written <= 0) return "";
    return toUTF8(buffer[0 .. written]);
}

/// Executable file name (no path) of the window's process.
version (Windows)
string windowProcessName(HWND window)
{
    if (window is null) return "";
    DWORD pid;
    GetWindowThreadProcessId(window, &pid);
    if (pid == 0) return "";
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (process is null) return "";
    scope (exit) CloseHandle(process);
    wchar[MAX_PATH] path;
    DWORD size = MAX_PATH;
    if (QueryFullProcessImageNameW(process, 0, path.ptr, &size) == FALSE)
        return "";
    return baseName(toUTF8(path[0 .. size]));
}

/**
 * Find a window again by its remembered title and process name.
 *
 * Matching is exact on the title and case-insensitive on the process name, so
 * a reopened window is found again without guessing between lookalikes.
 */
version (Windows)
HWND findWindow(string title, string processName)
{
    if (title.length == 0) return null;
    __gshared HWND found;
    __gshared string wantedTitle;
    __gshared string wantedProcess;
    found = null;
    wantedTitle = title;
    wantedProcess = processName.toLower;

    extern(Windows) BOOL enumProc(HWND window, LPARAM)
    {
        try
        {
            if (IsWindowVisible(window) == FALSE) return 1;
            if (!windowRecordable(window)) return 1;
            if (windowTitle(window) != wantedTitle) return 1;
            if (wantedProcess.length > 0 &&
                windowProcessName(window).toLower != wantedProcess) return 1;
            found = window;
            return 0; // stop enumeration
        }
        catch (Exception)
        {
            return 1; // never unwind through the Win32 callback
        }
    }

    EnumWindows(cast(WNDENUMPROC) &enumProc, 0);
    return found;
}
