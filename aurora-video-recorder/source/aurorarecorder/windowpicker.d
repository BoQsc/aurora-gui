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
        ShowWindow,
        WindowFromPoint, ClientToScreen, HRESULT, WNDENUMPROC, LoadLibraryW,
        GetProcAddress, IsIconic, SetWindowPos, SWP_NOACTIVATE, SWP_NOMOVE,
        SWP_NOSIZE, SetForegroundWindow;
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
    CaptureRect rect; ///< client area at the time it was listed
    bool minimised;   ///< listed but needs restoring before it can be captured

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

/**
 * Keep a recorded window visible and unoccluded, without activating it.
 *
 * Capture is a `BitBlt` of the screen, so whatever covers the window is what
 * gets recorded — a game pushed behind another window records as a black or
 * wrong image. Raising it with `SWP_NOACTIVATE` puts the target back on top
 * with no focus change and no input sent to it, so a full-screen game keeps
 * the keyboard while staying unoccluded.
 */
version (Windows)
void keepWindowOnTop(HWND window)
{
    if (window is null || IsWindow(window) == FALSE) return;
    // HWND_TOP, SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE
    SetWindowPos(window, null, 0, 0, 0, 0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

/**
 * True when the window is a candidate for the picker or for recording.
 *
 * A **minimised** window is accepted: Windows reports it at -32000,-32000, so
 * it could not be captured as-is, but hiding it made running games impossible
 * to choose (a game is usually minimised behind the recorder). `restoreForCapture`
 * brings it back on screen when recording starts. Only windows that cannot be
 * shown at all — hidden, owned-but-invisible, or broken handles — are refused.
 */
version (Windows)
bool windowRecordable(HWND window)
{
    if (window is null || IsWindow(window) == FALSE) return false;
    if (IsWindowVisible(window) == FALSE) return false;
    // A minimised window has no meaningful rect until it is restored, so only
    // require a real one when the window is on screen.
    if (IsIconic(window) != FALSE) return true;
    const rect = windowCaptureRect(window);
    if (!rect.valid()) return false;
    // Windows parks hidden windows far off-screen with a tiny size; treat that
    // as unrecordable rather than recording a meaningless region.
    return rect.width > 1 && rect.height > 1 && rect.x > -30000 &&
        rect.y > -30000;
}

/// True when the window is minimised (listed, but needs restoring to record).
version (Windows)
bool windowMinimised(HWND window)
{
    return window !is null && IsIconic(window) != FALSE;
}

/**
 * Bring a minimised window back on screen so it can be captured.
 *
 * `SW_RESTORE` is the only show command that works here: measured against a
 * running game, `SW_SHOWNA` left it at -32000,-32000 (still minimised), while
 * `SW_RESTORE` brought it back to 0,0 1920x1080. Returns true when the window
 * ended up on screen with a capture rect.
 */
/// Set when restoring a window required bringing it to the foreground.
version (Windows)
private __gshared bool _restoreActivated;

/// True when the last `restoreForCapture` had to activate the window.
version (Windows)
bool lastRestoreActivated()
{
    return _restoreActivated;
}

version (Windows)
bool restoreForCapture(HWND window)
{
    if (window is null || IsWindow(window) == FALSE) return false;
    _restoreActivated = false;
    if (IsIconic(window) != FALSE)
    {
        // SW_RESTORE = 9. SW_SHOWNA (8) does not un-minimise a window.
        ShowWindow(window, 9);
        // Give the window manager a moment to act on the request.
        foreach (_; 0 .. 20)
        {
            if (IsIconic(window) == FALSE) break;
            import core.thread : Thread, dur;
            Thread.sleep(dur!"msecs"(25));
            ShowWindow(window, 9);
        }
        // Some windows only un-minimise when the restore also activates them
        // (measured: Task Manager ignored SW_RESTORE, SW_SHOW and
        // SetWindowPos while staying at 199x34). Recording is worthless
        // without a visible window, so fall back to the activating restore and
        // report it, rather than failing silently.
        if (IsIconic(window) != FALSE)
        {
            SetForegroundWindow(window);
            ShowWindow(window, 9);
            _restoreActivated = true;
        }
    }
    const rect = windowCaptureRect(window);
    return rect.valid() && rect.width > 1 && rect.height > 1 &&
        rect.x > -30000 && rect.y > -30000;
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

/**
 * Every window the user could pick, for the selection list.
 *
 * `ownProcessId` is skipped so the recorder never offers itself. Only top-level
 * windows with a visible client area and a title are returned, in the order
 * Windows reports them (front to back), because an untitled or zero-size window
 * would record an empty video. Every such window is listed: a game exposes
 * several windows with the same title, and collapsing by title (an earlier bug)
 * dropped the game from the list entirely.
 */
/// Shell surfaces that look like windows but are not recordable applications.
private bool isShellSurface(string processName, string title)
{
    if (processName == "explorer.exe" && title == "Program Manager")
        return true; // the desktop, which records as the wallpaper
    if (processName == "textinputhost.exe") return true; // invisible IME host
    if (processName == "searchhost.exe") return true;
    if (processName == "shellexperiencehost.exe") return true;
    return false;
}

/**
 * True when this is the `ApplicationFrameHost.exe` wrapper of a UWP app.
 *
 * Such a wrapper duplicates the app's own window and is the only entry that
 * may be replaced. Matching on the title alone was wrong: a game exposes
 * several windows with identical titles (device windows, splash screens), and
 * collapsing by title dropped the game from the list entirely.
 */
private bool isFrameHostWrapper(string processName)
{
    return processName == "applicationframehost.exe";
}

version (Windows)
PickedWindow[] selectableWindows(uint ownProcessId)
{
    __gshared PickedWindow[] collected;
    collected = null;
    __gshared uint skipPid;
    skipPid = ownProcessId;

    extern(Windows) BOOL enumProc(HWND window, LPARAM)
    {
        try
        {
            if (IsWindowVisible(window) == FALSE) return 1;
            DWORD pid;
            GetWindowThreadProcessId(window, &pid);
            if (pid == skipPid) return 1;
            const title = windowTitle(window);
            if (title.length == 0) return 1;
            if (!windowRecordable(window)) return 1;
            const rect = windowCaptureRect(window);
            const process = windowProcessName(window);
            if (isShellSurface(process.toLower, title)) return 1;

            // A UWP wrapper duplicates its app's window; replace that entry
            // with the app's own window instead of listing both. Only wrappers
            // are ever collapsed, so same-titled game windows all survive.
            if (!isFrameHostWrapper(process.toLower))
            {
                foreach (index, existing; collected)
                {
                    if (existing.title != title) continue;
                    if (!isFrameHostWrapper(existing.processName.toLower))
                        continue;
                    collected[index] = PickedWindow(cast(size_t) window, title,
                        process, rect, IsIconic(window) != FALSE);
                    return 1;
                }
            }
            collected ~= PickedWindow(cast(size_t) window, title, process, rect,
                IsIconic(window) != FALSE);
            return 1;
        }
        catch (Exception)
        {
            return 1;
        }
    }

    EnumWindows(cast(WNDENUMPROC) &enumProc, 0);
    return collected;
}

/// Non-Windows stand-in so callers compile everywhere.
version (Posix)
PickedWindow[] selectableWindows(uint) { return null; }
