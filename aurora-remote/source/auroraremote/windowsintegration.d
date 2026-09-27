module auroraremote.windowsintegration;

version (Windows)
{
    import core.sys.windows.shellapi : NIF_ICON, NIF_MESSAGE, NIF_TIP,
        NIM_ADD, NIM_DELETE, NIM_SETVERSION, NOTIFYICONDATAW,
        NOTIFYICON_VERSION, Shell_NotifyIconW;
    import core.sys.windows.windows;
    import core.sys.windows.winreg : RegCloseKey, RegCreateKeyExW,
        RegDeleteValueW, RegQueryValueExW, RegSetValueExW;
    import std.utf : toUTF16, toUTF16z;

    private immutable wchar[] trayClassName = "AuroraRemoteTrayWindow"w;
    private immutable wchar[] trayWindowTitle = "Aurora Remote tray"w;
    private enum UINT trayCallbackMessage = WM_APP + 0x52;
    private enum UINT trayIconId = 1;
    private enum UINT menuShow = 1;
    private enum UINT menuExit = 2;
    private enum string runKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    private enum string runValue = "Aurora Remote";

    bool autostartEnabled()
    {
        HKEY key;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, toUTF16z(runKey), 0, null,
            REG_OPTION_NON_VOLATILE, KEY_QUERY_VALUE, null, &key, null) !=
            ERROR_SUCCESS)
            return false;
        scope (exit) RegCloseKey(key);
        return RegQueryValueExW(key, toUTF16z(runValue), null, null,
            null, null) == ERROR_SUCCESS;
    }

    void setAutostart(bool enabled, string executablePath)
    {
        HKEY key;
        if (RegCreateKeyExW(HKEY_CURRENT_USER, toUTF16z(runKey), 0, null,
            REG_OPTION_NON_VOLATILE, KEY_QUERY_VALUE | KEY_SET_VALUE, null,
            &key, null) != ERROR_SUCCESS)
            throw new Exception("Windows could not open the startup registry key.");
        scope (exit) RegCloseKey(key);
        if (!enabled)
        {
            const result = RegDeleteValueW(key, toUTF16z(runValue));
            if (result != ERROR_SUCCESS && result != ERROR_FILE_NOT_FOUND)
                throw new Exception("Windows could not remove Aurora Remote from startup.");
            return;
        }
        const command = toUTF16("\"" ~ executablePath ~ "\" --background");
        if (RegSetValueExW(key, toUTF16z(runValue), 0, REG_SZ,
            cast(const(BYTE)*) command.ptr,
            cast(DWORD)((command.length + 1) * wchar.sizeof)) != ERROR_SUCCESS)
            throw new Exception("Windows could not add Aurora Remote to startup.");
    }

    final class TrayIcon
    {
        private HWND _hwnd;
        private NOTIFYICONDATAW _iconData;
        private bool _active;
        private bool _classRegistered;
        void delegate() onShow;
        void delegate() onExit;

        this()
        {
            WNDCLASSEXW wc;
            wc.cbSize = WNDCLASSEXW.sizeof;
            wc.lpfnWndProc = &windowProc;
            wc.hInstance = GetModuleHandleW(null);
            wc.hCursor = LoadCursorW(null, cast(LPCWSTR) 32512);
            wc.lpszClassName = trayClassName.ptr;
            if (RegisterClassExW(&wc) == 0 &&
                GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
                throw new Exception("Could not register the Aurora Remote tray window.");
            _classRegistered = true;
            _hwnd = CreateWindowExW(0, trayClassName.ptr,
                trayWindowTitle.ptr, WS_OVERLAPPED, 0, 0, 0, 0,
                null, null, GetModuleHandleW(null), cast(void*) this);
            if (_hwnd is null)
                throw new Exception("Could not create the Aurora Remote tray window.");
        }

        bool show()
        {
            _iconData.cbSize = NOTIFYICONDATAW.sizeof;
            _iconData.hWnd = _hwnd;
            _iconData.uID = trayIconId;
            _iconData.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
            _iconData.uCallbackMessage = trayCallbackMessage;
            _iconData.hIcon = LoadIconW(null, cast(LPCWSTR) 32512);
            copyWide(_iconData.szTip, "Aurora Remote");
            if (Shell_NotifyIconW(NIM_ADD, &_iconData) == FALSE) return false;
            _active = true;
            _iconData.uVersion = NOTIFYICON_VERSION;
            Shell_NotifyIconW(NIM_SETVERSION, &_iconData);
            return true;
        }

        void shutdown()
        {
            if (_active)
            {
                NOTIFYICONDATAW removal;
                removal.cbSize = NOTIFYICONDATAW.sizeof;
                removal.hWnd = _hwnd;
                removal.uID = trayIconId;
                Shell_NotifyIconW(NIM_DELETE, &removal);
                _active = false;
            }
            if (_hwnd !is null && IsWindow(_hwnd)) DestroyWindow(_hwnd);
            _hwnd = null;
            if (_classRegistered)
                UnregisterClassW(trayClassName.ptr, GetModuleHandleW(null));
            _classRegistered = false;
        }

        private void showMenu()
        {
            auto menu = CreatePopupMenu();
            if (menu is null) return;
            scope (exit) DestroyMenu(menu);
            AppendMenuW(menu, MF_STRING | MF_DEFAULT, menuShow,
                "Show Aurora Remote"w.ptr);
            AppendMenuW(menu, MF_SEPARATOR, 0, null);
            AppendMenuW(menu, MF_STRING, menuExit, "Exit"w.ptr);
            POINT cursor;
            GetCursorPos(&cursor);
            SetForegroundWindow(_hwnd);
            const command = TrackPopupMenu(menu,
                TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
                cursor.x, cursor.y, 0, _hwnd, null);
            if (command == menuShow && onShow !is null) onShow();
            else if (command == menuExit && onExit !is null) onExit();
        }

        private extern(Windows) static LRESULT windowProc(HWND hwnd,
            UINT message, WPARAM wParam, LPARAM lParam) nothrow
        {
            auto self = cast(TrayIcon) cast(void*)
                GetWindowLongPtrW(hwnd, GWLP_USERDATA);
            if (self is null && message == WM_NCCREATE)
            {
                auto create = cast(CREATESTRUCTW*) lParam;
                self = cast(TrayIcon) create.lpCreateParams;
                SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                    cast(LONG_PTR) cast(void*) self);
            }
            if (self !is null)
            {
                try
                {
                    if (message == trayCallbackMessage)
                    {
                        const event = cast(UINT) lParam;
                        if (event == WM_LBUTTONUP || event == WM_LBUTTONDBLCLK)
                        {
                            if (self.onShow !is null) self.onShow();
                            return 0;
                        }
                        if (event == WM_RBUTTONUP || event == WM_CONTEXTMENU)
                        {
                            self.showMenu();
                            return 0;
                        }
                    }
                }
                catch (Throwable) {}
            }
            return DefWindowProcW(hwnd, message, wParam, lParam);
        }

        private static void copyWide(WCHAR[] target, string value) @safe
        {
            const wide = toUTF16(value);
            size_t count = wide.length < target.length - 1 ?
                wide.length : target.length - 1;
            target[0 .. count] = wide[0 .. count];
            target[count] = 0;
        }
    }
}
else
{
    bool autostartEnabled() { return false; }
    void setAutostart(bool enabled, string executablePath) {}
    final class TrayIcon
    {
        void delegate() onShow;
        void delegate() onExit;
        bool show() { return false; }
        void shutdown() {}
    }
}
