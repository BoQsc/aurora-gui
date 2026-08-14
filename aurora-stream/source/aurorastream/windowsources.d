module aurorastream.windowsources;

import aurora;
import std.algorithm : sort;
import std.conv : to;
import std.string : icmp, lastIndexOf, strip;
import std.utf : toUTF8;

version (Windows)
{
    import core.sys.windows.windows : BOOL, CloseHandle, DWORD, EnumWindows,
        GA_ROOTOWNER, GetAncestor, GetCurrentProcessId, GetShellWindow,
        GetWindowLongPtrW, GetWindowTextW, GetWindowTextLengthW,
        GetWindowThreadProcessId, GWL_EXSTYLE, HANDLE, HWND, IsIconic, IsWindow,
        IsWindowVisible, LPARAM, LPDWORD, LPWSTR, MAX_PATH, OpenProcess,
        WNDENUMPROC, WS_EX_TOOLWINDOW;
}

/// One capturable top-level window. Aurora Stream can stream only this window
/// (a "game capture" source) so viewers never see the rest of the desktop.
struct WindowSource
{
    /// Win32 window handle, persisted as decimal text in the settings file.
    /// Handles are only valid within one Windows session, so a stale value is
    /// detected at stream start and reported instead of silently streaming the
    /// desktop.
    ulong hwnd;
    /// Visible window title (used for display and to find the window again).
    string title;
    /// Executable image name of the owning process, e.g. "notepad.exe".
    string processName;
}

/// Converts a window handle to the decimal text stored in settings. Empty
/// means "capture the entire desktop".
string hwndToText(ulong hwnd)
{
    return hwnd == 0 ? "" : to!string(hwnd);
}

/// Friendly "process — title" label shown in the capture-source selector.
string windowSourceLabel(const WindowSource source)
{
    if (source.processName.length > 0)
        return source.processName ~ " — " ~ source.title;
    return source.title;
}

/// Parses a persisted decimal window-handle string back into the Win32 handle.
/// Returns null for an empty or non-numeric value.
version (Windows)
HWND hwndFromText(string text)
{
    const cleaned = text.strip();
    if (cleaned.length == 0) return null;
    ulong value;
    try value = to!ulong(cleaned);
    catch (Exception) return null;
    if (value == 0) return null;
    return cast(HWND) value;
}

/// True when the persisted window-handle string still refers to a live window
/// in the current Windows session. Stale handles from an earlier session (or a
/// closed window) return false.
version (Windows)
bool windowExists(string hwndText)
{
    auto window = hwndFromText(hwndText);
    return window !is null && IsWindow(cast(HWND) window) != 0;
}

/// True when the persisted window-handle string refers to a minimized window.
/// A minimized window cannot be captured (its client area is 0×0 and gdigrab
/// fails or freezes on it), so the UI marks such windows and the broadcaster
/// rejects them at Start and stops the live stream the moment they minimize.
version (Windows)
bool windowIsMinimized(string hwndText)
{
    auto window = hwndFromText(hwndText);
    return window !is null && IsIconic(cast(HWND) window) != 0;
}

version (Windows)
private string windowTitle(HWND hwnd)
{
    const length = GetWindowTextLengthW(hwnd);
    if (length <= 0) return "";
    wchar[512] buffer;
    const count = GetWindowTextW(hwnd, buffer.ptr, buffer.length);
    if (count <= 0) return "";
    auto wide = buffer[0 .. cast(size_t) count];
    return toUTF8(wide).idup;
}

/// `PROCESS_QUERY_LIMITED_INFORMATION` is not exported by druntime's headers.
version (Windows)
private enum DWORD processQueryLimitedInformation = 0x1000;

/// kernel32's `QueryFullProcessImageNameW` is not exported by druntime either.
version (Windows)
private extern (Windows) BOOL QueryFullProcessImageNameW(HANDLE process,
    DWORD flags, LPWSTR exeName, LPDWORD size);

/// Returns the executable image name (e.g. "notepad.exe") of the process that
/// owns `hwnd`. Falls back to an empty string when the name cannot be read.
version (Windows)
private string windowProcessName(HWND hwnd, DWORD processId)
{
    HANDLE process = OpenProcess(processQueryLimitedInformation, 0, processId);
    if (process is null) return "";
    scope (exit) CloseHandle(process);

    wchar[MAX_PATH * 4] buffer;
    DWORD size = buffer.length;
    if (QueryFullProcessImageNameW(process, 0, buffer.ptr, &size) == 0)
        return "";
    if (size == 0 || size > buffer.length) return "";
    auto wide = buffer[0 .. cast(size_t) size];
    auto path = toUTF8(wide).idup;
    const separator = path.lastIndexOf('\\');
    return separator >= 0 ? path[separator + 1 .. $] : path;
}

version (Windows)
private struct WindowCollector
{
    WindowSource[] windows;
    DWORD ownProcessId;
}

/// Must be `extern (Windows)`: `EnumWindows` calls this through the Win32 ABI,
/// and DMD's default convention for plain D functions reads the arguments from
/// the wrong places, so the handle arrived as null and every window was
/// filtered out.
version (Windows)
private extern (Windows) BOOL collectWindow(HWND hwnd, LPARAM lParam)
{
    auto collector = cast(WindowCollector*) cast(void*) lParam;
    if (collector is null) return 0;

    // Keep only visible top-level application windows: no shell desktop, no
    // tool windows, no owned dialogs, no windows without a title.
    if (hwnd is null || hwnd == GetShellWindow()) return 1;
    if (IsWindowVisible(hwnd) == 0) return 1;
    if ((GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return 1;
    if (GetAncestor(hwnd, GA_ROOTOWNER) != hwnd) return 1;

    // Never list Aurora Stream's own window as a capture target.
    DWORD processId;
    GetWindowThreadProcessId(hwnd, &processId);
    if (processId == collector.ownProcessId) return 1;

    const title = windowTitle(hwnd);
    if (title.length == 0) return 1;

    WindowSource source;
    source.hwnd = cast(ulong) hwnd;
    source.title = title;
    source.processName = windowProcessName(hwnd, processId);
    collector.windows ~= source;
    return 1;
}

/// Enumerates visible titled top-level windows, sorted by process name then
/// title for a stable, predictable capture-source list.
version (Windows)
WindowSource[] enumerateWindows()
{
    WindowCollector collector;
    collector.ownProcessId = GetCurrentProcessId();
    EnumWindows(cast(WNDENUMPROC) &collectWindow,
        cast(LPARAM) cast(void*) &collector);
    collector.windows.sort!((a, b)
    {
        const byProcess = icmp(a.processName, b.processName);
        if (byProcess != 0) return byProcess < 0;
        return icmp(a.title, b.title) < 0;
    });
    return collector.windows;
}

/// The windows that can actually be captured right now: the full enumeration
/// minus any minimized windows. A minimized window's client area is 0×0, so
/// FFmpeg's `gdigrab` fails on it; listing those rows first (and a busy desktop
/// has mostly minimized windows) buried the usable windows and made the
/// selector feel broken. The current selection, if minimized, is still surfaced
/// separately through the saved-selection item so the user can switch away.
version (Windows)
WindowSource[] capturableWindows(const WindowSource[] windows)
{
    WindowSource[] result;
    foreach (window; windows)
        if (!windowIsMinimized(hwndToText(window.hwnd)))
            result ~= window;
    return result;
}

version (Windows)
unittest
{
    // The persisted-handle parsing rejects empty/non-numeric values and the
    // existence check never crashes on them.
    assert(hwndFromText("") is null);
    assert(hwndFromText("0") is null);
    assert(hwndFromText("not-a-number") is null);
    assert(hwndFromText("464340") !is null);
    assert(!windowExists(""));
    assert(!windowExists("not-a-number"));
    assert(!windowIsMinimized(""));
    assert(!windowIsMinimized("not-a-number"));

    // Enumerating windows must never throw. On an interactive desktop session
    // it must find windows with non-empty titles, unique handles, and the
    // existence check must accept a freshly enumerated handle (this catches the
    // extern(Windows) callback-convention bug that made every handle arrive as
    // null and emptied the list). Headless/service sessions may find none.
    const windows = enumerateWindows();
    foreach (window; windows)
        assert(window.title.length > 0);
    if (windows.length > 0)
    {
        foreach (i, window; windows)
            foreach (j; i + 1 .. windows.length)
                assert(window.hwnd != windows[j].hwnd);
        assert(windowExists(hwndToText(windows[0].hwnd)));
    }

    // The capturable-window filter removes every minimized window so a busy
    // desktop does not bury the usable windows, but it must never invent
    // entries or drop non-minimized ones.
    const capturable = capturableWindows(windows);
    assert(capturable.length <= windows.length);
    foreach (window; capturable)
    {
        assert(!windowIsMinimized(hwndToText(window.hwnd)));
        bool foundInSource;
        foreach (candidate; windows)
            if (candidate.hwnd == window.hwnd) foundInSource = true;
        assert(foundInSource);
    }
    foreach (window; windows)
        if (!windowIsMinimized(hwndToText(window.hwnd)))
        {
            bool foundInResult;
            foreach (candidate; capturable)
                if (candidate.hwnd == window.hwnd) foundInResult = true;
            assert(foundInResult);
        }
}
else
{
    /// Aurora Stream only supports Windows desktop capture; these fallbacks
    /// keep the module (and the selector widget) compilable elsewhere.
    bool windowExists(string hwndText) { return false; }

    bool windowIsMinimized(string hwndText) { return false; }

    WindowSource[] enumerateWindows() { return []; }

    WindowSource[] capturableWindows(const WindowSource[] windows)
    {
        return windows.dup;
    }
}

/// Aurora-native capture-source selector: "Entire desktop" or one window.
/// An empty selected value means the whole desktop is captured. The window list
/// is re-enumerated every time the menu opens so games launched after startup
/// appear without a manual refresh.
final class CaptureSourceDropdown : Button
{
    private string _selected;
    private string _selectedLabel;
    private WindowSource[] _windows;
    private bool _windowsKnown;
    private size_t _enumeratedCount;
    private string _emptyMessage;

    void delegate(string hwnd) onChanged;

    this(string selected = "", string selectedLabel = "",
        string emptyMessage = "No capturable windows found")
    {
        super("");
        _selected = selected.strip().idup;
        _selectedLabel = selectedLabel.strip().idup;
        _emptyMessage = emptyMessage.idup;
        onClick = delegate() { openMenu(); };
        updateCaption();
    }

    string selectedHwnd() const
    {
        return _selected;
    }

    string selectedLabel() const
    {
        const index = findWindowIndex(_selected);
        if (index >= 0)
            return windowSourceLabel(_windows[cast(size_t) index]);
        return _selectedLabel;
    }

    private ptrdiff_t findWindowIndex(string value) const
    {
        foreach (index, window; _windows)
            if (hwndToText(window.hwnd) == value) return cast(ptrdiff_t) index;
        return -1;
    }

    private void refreshWindows()
    {
        const all = enumerateWindows();
        _enumeratedCount = all.length;
        // Only windows that can be captured right now appear in the list; a
        // desktop full of minimized windows (the common case on a busy session)
        // no longer buries the usable windows behind rows of
        // "(minimized — not capturable)".
        _windows = capturableWindows(all);
        _windowsKnown = true;
        updateCaption();
    }

    private string savedWindowLabel() const
    {
        if (_selectedLabel.length > 0) return _selectedLabel;
        return _selected;
    }

    private void updateCaption()
    {
        string caption;
        bool unavailable;
        if (_selected.length == 0)
        {
            caption = "Entire desktop";
        }
        else
        {
            const index = findWindowIndex(_selected);
            if (index >= 0)
            {
                caption = windowSourceLabel(_windows[cast(size_t) index]);
                // A minimized window cannot be captured (gdigrab fails on its
                // 0×0 client area), so show it as a problem and reject at Start.
                if (windowIsMinimized(_selected))
                {
                    caption = "Window (minimized): " ~ caption;
                    unavailable = true;
                }
            }
            else if (_windowsKnown)
            {
                if (windowExists(_selected))
                {
                    // The selected window is usually in the (capturable-only)
                    // list; this branch covers a minimized selection that was
                    // filtered out — it still cannot be captured, so keep the
                    // same red warning.
                    if (windowIsMinimized(_selected))
                    {
                        caption = "Window (minimized): " ~ savedWindowLabel();
                        unavailable = true;
                    }
                    else
                    {
                        caption = "Window: " ~ savedWindowLabel();
                    }
                }
                else
                {
                    caption = "Window closed: " ~ savedWindowLabel();
                    unavailable = true;
                }
            }
            else
            {
                caption = savedWindowLabel();
            }
        }

        setText(caption ~ "  ▼");
        setDanger(unavailable);
        layoutHints().minWidth = 280;
        layoutHints().preferredWidth = 500;
    }

    private ContextMenuItem windowItem(WindowSource window, string label)
    {
        immutable value = hwndToText(window.hwnd).idup;
        const shown = windowIsMinimized(value) ?
            label ~ " (minimized — not capturable)" : label;
        return ContextMenuItem.check(shown, _selected == value,
            delegate() { setSelected(value, label.idup); });
    }

    private void openMenu()
    {
        refreshWindows();
        ContextMenuItem[] items;
        items ~= ContextMenuItem.check("Entire desktop", _selected.length == 0,
            delegate() { setSelected("", ""); });
        items ~= ContextMenuItem.separatorItem();

        if (_windows.length == 0)
        {
            // Distinguish "no windows found at all" from "every window is
            // minimized right now" so the message is not misleading.
            string message;
            if (_windowsKnown && _enumeratedCount > 0)
                message = "All visible windows are minimized — restore one to capture it";
            else
                message = _windowsKnown ? _emptyMessage : "Scanning for windows…";
            items ~= ContextMenuItem.command(message, delegate() {}, "", false);
        }
        else
        {
            foreach (window; _windows)
                items ~= windowItem(window, windowSourceLabel(window));
        }

        // Keep showing a saved selection that is not in the current list so the
        // user can still switch away from it (it may be a minimized or renamed
        // window, or a stale handle from an earlier session).
        if (_selected.length > 0 && findWindowIndex(_selected) < 0)
        {
            immutable saved = _selected.idup;
            immutable savedLabel = savedWindowLabel().idup;
            string savedPrefix;
            if (windowExists(_selected))
                savedPrefix = windowIsMinimized(_selected) ?
                    "Saved window (minimized — not capturable): " :
                    "Saved window: ";
            else
                savedPrefix = "Saved window closed: ";
            items ~= ContextMenuItem.separatorItem();
            items ~= ContextMenuItem.check(savedPrefix ~ savedLabel, true,
                delegate() { setSelected(saved, savedLabel); });
        }

        items ~= ContextMenuItem.separatorItem();
        items ~= ContextMenuItem.command("Refresh window list", delegate() {
            refreshWindows();
            openMenu();
        });

        showContextMenuBelow(this, items);
    }

    private void setSelected(string hwnd, string label, bool notify = true)
    {
        immutable next = hwnd.strip().idup;
        if (next == _selected) return;
        _selected = next;
        _selectedLabel = label.strip().idup;
        updateCaption();
        if (notify && onChanged !is null) onChanged(_selected);
    }
}
