module aurorarecorder.tray;

/**
 * Experimental notification-area ("tray") icon.
 *
 * The recorder is fully usable from its own window, so this is offered as an
 * experimental option and stays off until the user turns it on. The icon owns a
 * hidden window that receives the shell's callback messages and shows a small
 * menu: show the window, start/stop recording, open the recordings folder, and
 * exit.
 *
 * Everything runs on the UI thread, because the shell delivers these messages
 * through the application's own message loop; no thread touches a widget.
 */

version (Windows)
{
    import core.sys.windows.shellapi : NOTIFYICONDATAW, Shell_NotifyIconW;
    import core.sys.windows.windows : AppendMenuW, CreatePopupMenu,
        CreateWindowExW, DefWindowProcW, DestroyIcon, DestroyMenu,
        DestroyWindow, GetCursorPos, GetModuleHandleW, HICON, HMENU, HWND,
        LPARAM, LPCWSTR, LRESULT, LoadIconW, LoadImageW, POINT, PostMessageW,
        RegisterClassExW, SetForegroundWindow, TrackPopupMenu, UINT,
        WNDCLASSEXW, WNDPROC, WPARAM, WM_LBUTTONDBLCLK, WM_LBUTTONUP, WM_NULL,
        WM_RBUTTONUP;
    import std.utf : toUTF16, toUTF16z;

    // Declared locally: druntime has the struct and the call, but not these
    // constants (the repo's "declare missing Win32 values locally" rule).
    private enum UINT nimAdd = 0;
    private enum UINT nimModify = 1;
    private enum UINT nimDelete = 2;
    private enum UINT nifMessage = 0x1;
    private enum UINT nifIcon = 0x2;
    private enum UINT nifTip = 0x4;
    private enum UINT imageIcon = 1;
    private enum UINT lrLoadFromFile = 0x10;
    private enum UINT mfString = 0;
    private enum UINT mfSeparator = 0x800;
    private enum UINT tpmLeftAlign = 0x0000;
    private enum UINT tpmTopAlign = 0x0000;
    private enum UINT tpmRightButton = 0x0002;
    private enum UINT tpmReturnCmd = 0x0100;
    // WM_APP + 1: the shell posts the mouse events here.
    private enum UINT trayCallbackMessage = 0x8001;
    private enum UINT trayShow = 1;
    private enum UINT trayToggle = 2;
    private enum UINT trayFolder = 3;
    private enum UINT trayExit = 4;
    private enum string trayClassName = "AuroraVideoRecorderTray";
    private enum size_t defaultIconId = 32512; // IDI_APPLICATION

    private extern(Windows) LRESULT trayWndProc(HWND window, UINT message,
        WPARAM wparam, LPARAM lparam)
    {
        if (message == trayCallbackMessage)
        {
            const UINT event = cast(UINT) lparam & 0xFFFF;
            // Menu actions are user code; a failure in one must never unwind
            // through the message loop.
            try
            {
                if (event == WM_LBUTTONUP || event == WM_LBUTTONDBLCLK)
                {
                    if (TrayIcon.current !is null &&
                        TrayIcon.current.onShow !is null)
                        TrayIcon.current.onShow();
                    return 0;
                }
                if (event == WM_RBUTTONUP)
                {
                    if (TrayIcon.current !is null)
                        TrayIcon.current.openMenu();
                    return 0;
                }
            }
            catch (Exception)
            {
                return 0;
            }
        }
        return DefWindowProcW(window, message, wparam, lparam);
    }

    /// The icon, plus the actions its menu offers.
    final class TrayIcon
    {
        /// Menu actions. Unset delegates are simply not run.
        void delegate() onShow;
        void delegate() onToggleRecord;
        void delegate() onOpenFolder;
        void delegate() onExit;

        /// True while the icon is in the notification area.
        bool active() const { return _added; }

        /**
         * Create the icon. `iconPath` is an optional `.ico`; without it the
         * generic application icon is used. False when the shell refused it.
         */
        bool start(string tip = "Aurora Video Recorder", string iconPath = "")
        {
            if (_added) return true;
            _tip = tip;
            if (!ensureWindow()) return false;
            _icon = loadIcon(iconPath);
            TrayIcon.current = this;
            _added = notify(nimAdd);
            if (!_added) TrayIcon.current = null;
            return _added;
        }

        /// Remove the icon and destroy the helper window.
        void stop()
        {
            if (_added)
            {
                notify(nimDelete);
                _added = false;
            }
            if (_icon !is null)
            {
                DestroyIcon(_icon);
                _icon = null;
            }
            if (_hwnd !is null)
            {
                DestroyWindow(_hwnd);
                _hwnd = null;
            }
            if (TrayIcon.current is this) TrayIcon.current = null;
        }

        /// Change the tooltip text.
        void setTip(string tip)
        {
            if (_tip == tip) return;
            _tip = tip;
            if (_added) notify(nimModify);
        }

        /// Remember whether a recording is running, for the menu label.
        void setRecording(bool value) { _recording = value; }

        /// The instance receiving shell callbacks (one icon per process).
        package static TrayIcon current;

        private HWND _hwnd;
        private HICON _icon;
        private bool _added;
        private bool _recording;
        private string _tip = "Aurora Video Recorder";

        private bool ensureWindow()
        {
            if (_hwnd !is null) return true;
            if (!_classRegistered)
            {
                WNDCLASSEXW info;
                info.cbSize = WNDCLASSEXW.sizeof;
                // WNDPROC is declared `nothrow`; the body catches everything,
                // so the cast states that guarantee.
                info.lpfnWndProc = cast(WNDPROC) &trayWndProc;
                info.hInstance = GetModuleHandleW(null);
                info.lpszClassName = trayClassName.toUTF16z;
                if (RegisterClassExW(&info) == 0) return false;
                _classRegistered = true;
            }
            // Not shown: it exists only to receive the shell's messages.
            _hwnd = CreateWindowExW(0, trayClassName.toUTF16z,
                "".toUTF16z, 0, 0, 0, 0, 0, null, null,
                GetModuleHandleW(null), null);
            return _hwnd !is null;
        }

        private HICON loadIcon(string path)
        {
            if (path.length > 0)
            {
                auto loaded = LoadImageW(null,
                    path.toUTF16z, imageIcon, 0, 0, lrLoadFromFile);
                if (loaded !is null) return cast(HICON) loaded;
            }
            return LoadIconW(null, cast(LPCWSTR) cast(void*) defaultIconId);
        }

        private bool notify(UINT operation)
        {
            NOTIFYICONDATAW data;
            data.cbSize = NOTIFYICONDATAW.sizeof;
            data.hWnd = _hwnd;
            data.uID = 1;
            data.uFlags = nifMessage | nifIcon | nifTip;
            data.uCallbackMessage = trayCallbackMessage;
            data.hIcon = _icon;
            copyTip(data, _recording ? _tip ~ " - recording" : _tip);
            return Shell_NotifyIconW(operation, &data) != 0;
        }

        private static void copyTip(ref NOTIFYICONDATAW data, string text)
        {
            const wchar[] wide = toUTF16(text);
            const size_t limit = data.szTip.length - 1;
            const size_t count = wide.length < limit ? wide.length : limit;
            foreach (i; 0 .. count) data.szTip[i] = wide[i];
            data.szTip[count] = 0;
        }

        /// Shell callbacks arrive on this class only.
        private static __gshared bool _classRegistered;

        package void openMenu()
        {
            HMENU menu = CreatePopupMenu();
            if (menu is null) return;
            AppendMenuW(menu, mfString, trayShow, "Show window".toUTF16z);
            AppendMenuW(menu, mfString, trayToggle,
                (_recording ? "Stop recording" : "Start recording").toUTF16z);
            AppendMenuW(menu, mfString, trayFolder,
                "Open recordings folder".toUTF16z);
            AppendMenuW(menu, mfString | mfSeparator, 0, null);
            AppendMenuW(menu, mfString, trayExit, "Exit".toUTF16z);

            POINT point;
            GetCursorPos(&point);
            // Without this the menu stays open when the user clicks elsewhere.
            SetForegroundWindow(_hwnd);
            const UINT chosen = cast(UINT) TrackPopupMenu(menu,
                tpmReturnCmd | tpmRightButton | tpmLeftAlign | tpmTopAlign,
                point.x, point.y, 0, _hwnd, null);
            PostMessageW(_hwnd, WM_NULL, 0, 0);
            DestroyMenu(menu);

            switch (chosen)
            {
                case trayShow:
                    if (onShow !is null) onShow();
                    break;
                case trayToggle:
                    if (onToggleRecord !is null) onToggleRecord();
                    break;
                case trayFolder:
                    if (onOpenFolder !is null) onOpenFolder();
                    break;
                case trayExit:
                    if (onExit !is null) onExit();
                    break;
                default:
                    break;
            }
        }
    }
}

else
{
    /// Non-Windows stand-in so callers compile everywhere.
    final class TrayIcon
    {
        void delegate() onShow;
        void delegate() onToggleRecord;
        void delegate() onOpenFolder;
        void delegate() onExit;

        bool active() const { return false; }
        bool start(string tip = "", string iconPath = "") { return false; }
        void stop() {}
        void setTip(string tip) {}
        void setRecording(bool value) {}
        package static TrayIcon current;
        package void openMenu() {}
    }
}
