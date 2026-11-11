module aurorarecorder.hotkey;

/**
 * Global start/stop hotkey for the recorder.
 *
 * Windows delivers `WM_HOTKEY` to the thread that called `RegisterHotKey`, so
 * the registration lives on a dedicated thread that owns a message-only window
 * and its own message loop. The hotkey therefore works no matter which
 * application has focus, and nothing in Aurora's window procedure changes.
 *
 * The chord model (`HotkeyChord`, parsing, display text) is pure and covered by
 * `tests/headless_smoke.d`; only `GlobalHotkey` touches Win32.
 */

import core.atomic : MemoryOrder, atomicExchange, atomicLoad, atomicStore;
import core.thread : Thread, dur;
import std.format : format;
import std.conv : to;
import std.conv : text;
import std.string : split, strip;
import std.exception : assumeUnique;

/// Modifier bits, matching `RegisterHotKey`'s `MOD_*` values.
enum uint hotkeyAlt = 0x0001;
enum uint hotkeyControl = 0x0002;
enum uint hotkeyShift = 0x0004;
enum uint hotkeyWin = 0x0008;
/// `MOD_NOREPEAT`: holding the chord does not fire it repeatedly.
enum uint hotkeyNoRepeat = 0x4000;

/// The Win32 error `RegisterHotKey` returns when the chord is already taken.
enum uint hotkeyErrorAlreadyRegistered = 1409;

/// A parsed global hotkey.
struct HotkeyChord
{
    uint modifiers;   ///< hotkeyAlt | hotkeyControl | hotkeyShift | hotkeyWin
    uint virtualKey;  ///< Win32 virtual-key code, e.g. 0x74 for F5

    bool valid() const pure nothrow @safe
    {
        return virtualKey != 0 && modifiers != 0;
    }

    /// Keep only the four modifier bits and the key.
    HotkeyChord normalized() const pure nothrow @safe
    {
        return HotkeyChord(modifiers &
            (hotkeyAlt | hotkeyControl | hotkeyShift | hotkeyWin), virtualKey);
    }

    bool opEquals(const HotkeyChord other) const pure nothrow @safe
    {
        return modifiers == other.modifiers &&
            virtualKey == other.virtualKey;
    }
}

/// Default: Ctrl+Shift+R (Win+Shift+R is the Windows screen-record overlay).
enum HotkeyChord defaultHotkey = HotkeyChord(hotkeyControl | hotkeyShift, 0x52);

/// Shift, Ctrl, Alt, Win, CapsLock, the Applications key and their L/R forms.
private bool isModifierKey(uint virtualKey) pure nothrow @safe
{
    return (virtualKey >= 0x10 && virtualKey <= 0x12) ||   // SHIFT, CTRL, MENU
        (virtualKey >= 0xA0 && virtualKey <= 0xA5) ||      // L/R SHIFT/CTRL/ALT
        virtualKey == 0x5B || virtualKey == 0x5C ||        // L/R WIN
        virtualKey == 0x14 || virtualKey == 0x5D;          // CAPS, APPS
}

/// F1..F24 (0x70..0x87).
private bool isFunctionKey(uint virtualKey) pure nothrow @safe
{
    return virtualKey >= 0x70 && virtualKey <= 0x87;
}

/// A..Z (0x41..0x5A).
private bool isLetter(uint virtualKey) pure nothrow @safe
{
    return virtualKey >= 0x41 && virtualKey <= 0x5A;
}

/// 0..9 on the top row (0x30..0x39).
private bool isDigit(uint virtualKey) pure nothrow @safe
{
    return virtualKey >= 0x30 && virtualKey <= 0x39;
}

/**
 * Can `virtualKey` be the non-modifier half of a global hotkey?
 *
 * Function keys may stand alone. Letters and digits need Ctrl, Alt or Win so
 * the chord cannot swallow ordinary typing.
 */
bool hotkeyKeyAllowed(uint virtualKey, uint modifiers) pure nothrow @safe
{
    if (virtualKey == 0 || isModifierKey(virtualKey)) return false;
    if (isFunctionKey(virtualKey)) return true;
    if ((modifiers & (hotkeyAlt | hotkeyControl | hotkeyWin)) == 0)
        return false;
    return isLetter(virtualKey) || isDigit(virtualKey);
}

/// `Ctrl+Shift+R` text for the UI.
string describeHotkey(HotkeyChord chord)
{
    const normalized = chord.normalized;
    if (normalized.virtualKey == 0) return "Not set";
    string text;
    if (normalized.modifiers & hotkeyControl) text ~= "Ctrl+";
    if (normalized.modifiers & hotkeyAlt) text ~= "Alt+";
    if (normalized.modifiers & hotkeyShift) text ~= "Shift+";
    if (normalized.modifiers & hotkeyWin) text ~= "Win+";
    return text ~ keyName(normalized.virtualKey);
}

/// The non-modifier key's label: `R`, `5` or `F5`.
string keyName(uint virtualKey)
{
    if (isLetter(virtualKey) || isDigit(virtualKey))
        return format("%c", cast(char) virtualKey);
    if (isFunctionKey(virtualKey))
        return format("F%d", virtualKey - 0x6F);
    return format("Key %d", virtualKey);
}

/**
 * Parse `Ctrl+Shift+R`, `alt+f5`, `win+shift+5` and any case or order variant.
 * Returns an invalid chord when the text is not a usable hotkey.
 */
HotkeyChord chordFromText(string text)
{
    uint modifiers;
    uint virtualKey;
    foreach (part; split(strip(text), "+"))
    {
        const token = strip(part);
        if (token.length == 0) return HotkeyChord.init;

        const lower = toLowerASCII(token);
        if (lower == "ctrl" || lower == "control")
            modifiers |= hotkeyControl;
        else if (lower == "alt")
            modifiers |= hotkeyAlt;
        else if (lower == "shift")
            modifiers |= hotkeyShift;
        else if (lower == "win" || lower == "windows")
            modifiers |= hotkeyWin;
        else
        {
            const code = virtualKeyFromToken(lower);
            if (code == 0) return HotkeyChord.init;
            if (virtualKey != 0) return HotkeyChord.init; // two plain keys
            virtualKey = code;
        }
    }
    if (!hotkeyKeyAllowed(virtualKey, modifiers)) return HotkeyChord.init;
    return HotkeyChord(modifiers, virtualKey).normalized;
}

private uint virtualKeyFromToken(string lower) pure nothrow @safe
{
    if (lower.length == 1)
    {
        const c = lower[0];
        if (c >= 'a' && c <= 'z') return cast(uint) (c - 'a' + 'A');
        if (c >= '0' && c <= '9') return cast(uint) c;
        return 0;
    }
    if (lower.length >= 2 && lower[0] == 'f')
    {
        uint number;
        foreach (i; 1 .. lower.length)
        {
            const c = lower[i];
            if (c < '0' || c > '9') return 0;
            number = number * 10 + (c - '0');
        }
        if (number >= 1 && number <= 24) return 0x70 + number - 1;
    }
    return 0;
}

/// `Ctrl+Shift+R`, canonical and sorted, for settings persistence.
string hotkeyToText(HotkeyChord chord)
{
    return describeHotkey(chord);
}

private string toLowerASCII(string value)
{
    auto copy = value.dup;
    foreach (ref c; copy)
        if (c >= 'A' && c <= 'Z')
            c = cast(char) (c - 'A' + 'a');
    return assumeUnique(copy);
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

/// Outcome of one registration attempt.
struct HotkeyResult
{
    bool ok;
    uint error;   ///< Win32 error from `RegisterHotKey` (0 when it worked)
}

version (Windows)
    private import core.sys.windows.windows : BOOL, CreateWindowExW,
        DefWindowProcW, DestroyWindow, DispatchMessageW, FALSE,
        GetCurrentThreadId, GetLastError, GetMessageW, GetModuleHandleW,
        HINSTANCE, HWND, HWND_MESSAGE, LPARAM, LRESULT, MSG,
        PostMessageW, RegisterClassExW, RegisterHotKey, TranslateMessage,
        TRUE, UINT, UINT_PTR, UnregisterHotKey, WNDCLASSEXW, WNDPROC, WPARAM,
        WM_HOTKEY, WM_QUIT, WS_EX_TOOLWINDOW;

version (Windows)
    private import std.utf : toUTF16z;

/**
 * Owns the global registration for one chord. Create once; `apply` can be
 * called again whenever the user picks a different chord.
 *
 * `onPressed` runs on the registration thread; it must only record the press
 * (the UI polls `takePressed` from its own tick).
 */
version (Windows)
final class GlobalHotkey
{
    // WM_USER + 1: re-register on the hotkey thread.
    private enum uint wmApply = 0x0401;
    /// Ends the registration thread's message loop (WM_USER + 2).
    private enum uint wmQuit = 0x0402;
    private enum int hotkeyId = 0x5241;
    private enum string className = "AuroraVideoRecorderHotkey";

    private static __gshared GlobalHotkey g_owner;
    private static __gshared HotkeyChord g_pending;
    private static __gshared HotkeyResult g_result;
    private static __gshared bool g_applyDone;

    private Thread _thread;
    /// Published by the registration thread once its window exists and its
    /// message loop is running; `apply` posts to this window, never to the
    /// thread, so an early request cannot be lost.
    private shared size_t _window;
    private shared bool _stop;
    private shared bool _pressed;
    private void delegate() _onPressed;
    private HotkeyResult _last;

    this(void delegate() onPressed)
    {
        _onPressed = onPressed;
        g_owner = this;
        _thread = new Thread(&run);
        _thread.isDaemon = true;
        _thread.start();
    }

    /// Register `chord`. An invalid chord turns the hotkey off and succeeds
    /// (that is the "Not set" setting).
    HotkeyResult apply(HotkeyChord chord)
    {
        // The registration thread creates its window asynchronously; wait for
        // it so a request made right after construction is not dropped.
        HWND window;
        foreach (_; 0 .. 400)
        {
            window = cast(HWND) atomicLoad!(MemoryOrder.acq)(_window);
            if (window !is null) break;
            if (_thread is null || !_thread.isRunning) break;
            Thread.sleep(dur!"msecs"(5));
        }
        if (window is null) return _last = HotkeyResult(false, 0);
        if (_thread is null || !_thread.isRunning)
            return _last = HotkeyResult(false, 0);

        g_pending = chord.valid() ? chord.normalized : HotkeyChord.init;
        atomicStore!(MemoryOrder.rel)(g_applyDone, false);
        const posted = PostMessageW(window, wmApply, 0, 0);
        if (posted == FALSE)
            return _last = HotkeyResult(false, 0);

        foreach (_; 0 .. 400)
        {
            if (atomicLoad!(MemoryOrder.acq)(g_applyDone))
                break;
            Thread.sleep(dur!"msecs"(5));
        }
        return _last = atomicLoad!(MemoryOrder.acq)(g_applyDone) ?
            g_result : HotkeyResult(false, 0);
    }

    /// Outcome of the most recent `apply`.
    HotkeyResult lastResult() const { return _last; }

    /// True when the chord fired since the previous call; clears the flag.
    bool takePressed()
    {
        // exchange is the read-and-clear in one step: a press that lands
        // between these two operations can never be lost.
        return atomicExchange(&_pressed, false);
    }

    /// Release the chord and stop the registration thread.
    void shutdown()
    {
        if (_thread is null) return;
        atomicStore!(MemoryOrder.rel)(_stop, true);
        HWND window = cast(HWND) atomicLoad!(MemoryOrder.acq)(_window);
        if (window !is null) PostMessageW(window, wmQuit, 0, 0);
        _thread.join();
        _thread = null;
        atomicStore!(MemoryOrder.rel)(_window, 0u);
        if (g_owner is this) g_owner = null;
    }

    /// Message loop for the message-only hotkey window.
    private void run()
    {
        HINSTANCE instance = GetModuleHandleW(null);
        WNDCLASSEXW windowClass;
        windowClass.cbSize = WNDCLASSEXW.sizeof;
        windowClass.lpfnWndProc = cast(WNDPROC) &windowProc;
        windowClass.hInstance = instance;
        windowClass.lpszClassName = toUTF16z(className);
        // ERROR_CLASS_ALREADY_EXISTS is harmless: a previous instance of this
        // process registered the identical class.
        RegisterClassExW(&windowClass);

        HWND window = CreateWindowExW(WS_EX_TOOLWINDOW,
            toUTF16z(className), toUTF16z("Aurora Video Recorder hotkey"),
            0, 0, 0, 0, 0, cast(HWND) HWND_MESSAGE, null, instance, null);
        if (window is null)
            return;

        // Publish the window only once its procedure and loop are ready.
        atomicStore!(MemoryOrder.rel)(_window, cast(size_t) window);

        MSG message;
        while (!atomicLoad!(MemoryOrder.acq)(_stop) &&
            GetMessageW(&message, null, 0, 0) > 0)
        {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        UnregisterHotKey(window, hotkeyId);
        DestroyWindow(window);
        atomicStore!(MemoryOrder.rel)(_window, 0u);
    }

    /// Replace the current registration with `g_pending` and publish the
    /// result for `apply` (runs on the registration thread).
    private static void applyPending(HWND window)
    {
        UnregisterHotKey(window, hotkeyId);
        const chord = g_pending;
        HotkeyResult result;
        if (!chord.valid())
        {
            result.ok = true; // "Not set" disables the hotkey.
        }
        else
        {
            result.ok = RegisterHotKey(window, hotkeyId,
                chord.modifiers | hotkeyNoRepeat, chord.virtualKey) != FALSE;
            if (!result.ok) result.error = GetLastError();
        }
        g_result = result;
        atomicStore!(MemoryOrder.rel)(g_applyDone, true);
    }

    private static extern(Windows) LRESULT windowProc(HWND window, UINT message,
        WPARAM wParam, LPARAM lParam)
    {
        GlobalHotkey owner = g_owner;
        if (message == wmQuit)
        {
            DestroyWindow(window);
            return 0;
        }
        if (owner !is null && message == wmApply)
        {
            applyPending(window);
            return 0;
        }
        if (owner !is null && message == WM_HOTKEY &&
            cast(int) wParam == hotkeyId)
        {
            atomicStore!(MemoryOrder.rel)(owner._pressed, true);
            if (owner._onPressed !is null) owner._onPressed();
            return 0;
        }
        return DefWindowProcW(window, message, wParam, lParam);
    }
}

