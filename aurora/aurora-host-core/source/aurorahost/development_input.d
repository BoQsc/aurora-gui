module aurorahost.development_input;

// ===========================================================================
// Development input policy.
//
// Host applications are driven over the control channel during development:
// `click`, `pointer`, `key`, `setText`, `trigger`, and the JSON-lines socket.
// Those commands enter the retained UI through UiTestDriver without touching
// the desktop. Automating the window with OS-level mouse/keyboard injection
// (SetCursorPos + mouse_event, SendInput, SendKeys, keybd_event) steals focus,
// moves the user's pointer, and can click whatever happens to be under it.
//
// This guard discards injected pointer and keyboard events aimed at the host
// window, and only those events. A real user's mouse and keyboard are
// unaffected, and injected input aimed at another application passes through.
// An explicit `--allow-injected-input` flag exists for a deliberately
// disposable run; the normal development host does not accept injected input.
// ===========================================================================

version (Windows)
{
    import core.sys.windows.windows : CallNextHookEx, DWORD, GetAncestor,
        GetForegroundWindow, GetModuleHandleW, HHOOK, HWND, LPARAM, LRESULT,
        SetWindowsHookExW, TRUE,
        UnhookWindowsHookEx, WH_KEYBOARD_LL, WH_MOUSE_LL, WPARAM, WindowFromPoint,
        GA_ROOT, KBDLLHOOKSTRUCT, MSLLHOOKSTRUCT;
    import aurorahost.console : errLine;

    private enum DWORD llmhfInjected = 0x0000_0001;
    private enum DWORD llmhfLowerIlInjected = 0x0000_0002;
    private enum DWORD llkhfInjected = 0x0000_0010;
    private enum DWORD llkhfLowerIlInjected = 0x0000_0002;

    private __gshared HWND _guardedWindow;
    private __gshared HHOOK _mouseHook;
    private __gshared HHOOK _keyboardHook;

    private bool targetsGuardedWindow(HWND window)
    {
        if (window is null || _guardedWindow is null) return false;
        return GetAncestor(window, GA_ROOT) == _guardedWindow;
    }

    private bool isInjectedMouse(const ref MSLLHOOKSTRUCT info)
    {
        return (info.flags & (llmhfInjected | llmhfLowerIlInjected)) != 0;
    }

    private bool isInjectedKey(const ref KBDLLHOOKSTRUCT info)
    {
        return (info.flags & (llkhfInjected | llkhfLowerIlInjected)) != 0;
    }

    private LRESULT nextHook(int code, WPARAM wParam, LPARAM lParam) nothrow
    {
        try return CallNextHookEx(null, code, wParam, lParam);
        catch (Throwable) return 0;
    }

    private extern(Windows) LRESULT lowLevelMouse(int code, WPARAM wParam,
        LPARAM lParam) nothrow
    {
        try
        {
            if (code >= 0 && lParam != 0)
            {
                auto info = cast(MSLLHOOKSTRUCT*) cast(void*) lParam;
                if (info !is null && isInjectedMouse(*info) &&
                    targetsGuardedWindow(WindowFromPoint(info.pt)))
                    return 1;
            }
        }
        catch (Throwable) {}
        return nextHook(code, wParam, lParam);
    }

    private extern(Windows) LRESULT lowLevelKeyboard(int code, WPARAM wParam,
        LPARAM lParam) nothrow
    {
        try
        {
            if (code >= 0 && lParam != 0)
            {
                auto info = cast(KBDLLHOOKSTRUCT*) cast(void*) lParam;
                if (info !is null && isInjectedKey(*info) &&
                    targetsGuardedWindow(GetForegroundWindow()))
                    return 1;
            }
        }
        catch (Throwable) {}
        return nextHook(code, wParam, lParam);
    }

    /**
     * Install the development input guard for `window`. Safe to call more than
     * once. Returns false when Windows refuses the low-level hooks; the host
     * then runs without the guard rather than failing to open.
     */
    bool installDevelopmentInputGuard(void* window)
    {
        if (window is null) return false;
        _guardedWindow = cast(HWND) window;
        if (_mouseHook is null)
            _mouseHook = SetWindowsHookExW(WH_MOUSE_LL, &lowLevelMouse,
                GetModuleHandleW(null), 0);
        if (_keyboardHook is null)
            _keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL,
                &lowLevelKeyboard, GetModuleHandleW(null), 0);
        return _mouseHook !is null || _keyboardHook !is null;
    }

    /// Remove the hooks. Called when the host loop ends.
    void removeDevelopmentInputGuard()
    {
        if (_mouseHook !is null) UnhookWindowsHookEx(_mouseHook);
        if (_keyboardHook !is null) UnhookWindowsHookEx(_keyboardHook);
        _mouseHook = null;
        _keyboardHook = null;
        _guardedWindow = null;
    }
}
else
{
    bool installDevelopmentInputGuard(void*) { return false; }
    void removeDevelopmentInputGuard() {}
}
