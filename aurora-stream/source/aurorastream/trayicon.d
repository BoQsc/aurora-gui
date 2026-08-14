module aurorastream.trayicon;

/**
 * Windows system-tray integration for Aurora Stream.
 *
 * Owns a tray icon (Shell_NotifyIcon) backed by a small hidden Win32 window
 * whose messages are pumped by the main Aurora event loop, so the tray works
 * even while the broadcaster window is hidden away in the tray.
 *
 * Interaction model (as requested):
 *   - Left-click once  -> toggles Start streaming / Stop streaming.
 *   - Left-click twice -> restores the main window.
 *   - Right-click      -> a fully custom, self-drawn context menu in the app's
 *     dark gray theme (like Steam's tray menu): a borderless topmost popup
 *     window rendered with GDI. Not a native menu, so it always matches the
 *     app instead of following the OS (light) theme.
 */

version (Windows)
{
    import core.sys.windows.windows;
    import core.sys.windows.shellapi;
    import std.utf : toUTF16z;

    private enum int trayIconId = 1;
    private enum UINT_PTR traySingleClickTimer = 0xA4D1;

    // Menu command ids.
    private enum int menuShowWindow = 1;
    private enum int menuToggleStream = 2;
    private enum int menuExit = 3;

    private immutable wchar[] trayWindowClassName = "AuroraStreamTrayWindow"w;
    private immutable wchar[] trayWindowTitle = "Aurora Stream tray"w;
    private immutable wchar[] trayMenuClassName = "AuroraStreamTrayMenuWindow"w;
    private immutable wchar[] trayCallbackMessageName = "AuroraStreamTrayCallback"w;
    private immutable wchar[] taskbarCreatedMessageName = "TaskbarCreated"w;

    // Posted to the owner tray window when the custom menu closes, carrying the
    // chosen command id (or -1 for a plain dismissal). WM_APP + a value that
    // does not collide with aurora-d's WM_APP+0x31 wake message.
    private enum UINT wmMenuAction = WM_APP + 0x40;
    private enum UINT wmMenuCloseRequest = WM_APP + 0x41;
    private enum UINT modNoRepeat = 0x4000;

    // Custom tray menu palette (COLORREF is 0x00BBGGRR), matching the app theme:
    //   panel 0x252c34, button 0x2b333d, text 0xf2f6fa, border 0x0c0f12.
    private enum COLORREF menuBackground = 0x00342c25;
    private enum COLORREF menuHover = 0x003d332b;
    private enum COLORREF menuText = 0x00faf6f2;
    private enum COLORREF menuDisabledText = 0x00928478;
    private enum COLORREF menuSeparator = 0x00514639;
    private enum COLORREF menuBorder = 0x00120f0c;

    // Menu layout (logical pixels at 100% DPI).
    private enum int menuItemHeightLogical = 28;
    private enum int menuSeparatorHeightLogical = 8;
    private enum int menuPadXLogical = 12;
    private enum int menuPadYLogical = 7;
    private enum int menuMinWidthLogical = 176;
    private enum int menuMaxWidthLogical = 360;
    private enum int menuFontSizeLogical = 9;
    // CLEARTYPE_QUALITY (5) is not in druntime's wingdi headers.
    private enum BYTE menuFontQuality = 5;

    private __gshared bool trayMenuClassRegistered;

    private int signedLowWord(LPARAM value) @safe pure nothrow @nogc
    {
        return cast(short) (cast(size_t) value & 0xffff);
    }

    private int signedHighWord(LPARAM value) @safe pure nothrow @nogc
    {
        return cast(short) ((cast(size_t) value >> 16) & 0xffff);
    }

    private int maxInt(int a, int b) @safe pure nothrow @nogc
    {
        return a > b ? a : b;
    }

    /// One entry in the tray context menu. Kept as plain data so the menu
    /// structure is testable without creating a real window.
    private struct TrayMenuItem
    {
        int id;
        string label;
        bool separator;
        bool disabled;
        bool bold;
    }

    /// Builds the tray context menu structure. The toggle entry's label
    /// reflects the current stream state; a non-empty status line is shown
    /// as a disabled informational row.
    private TrayMenuItem[] buildTrayMenuItems(bool streaming, string status)
    {
        TrayMenuItem[] items;
        items ~= TrayMenuItem(menuShowWindow, "Show Aurora Stream window",
            false, false, true);
        items ~= TrayMenuItem(0, "", true, false, false);
        items ~= TrayMenuItem(menuToggleStream,
            streaming ? "Stop streaming" : "Start streaming", false, false, false);
        if (status.length > 0)
            items ~= TrayMenuItem(0, "Status: " ~ status, false, true, false);
        items ~= TrayMenuItem(0, "", true, false, false);
        items ~= TrayMenuItem(menuExit, "Exit Aurora Stream",
            false, false, false);
        return items;
    }

    unittest
    {
        // Idle state (no status) omits the status row.
        const idle = buildTrayMenuItems(false, "");
        assert(idle.length == 5);
        assert(idle[0].id == menuShowWindow && idle[0].bold);
        assert(idle[1].separator);
        assert(idle[2].id == menuToggleStream);
        assert(idle[2].label == "Start streaming");
        assert(idle[3].separator);
        assert(idle[4].id == menuExit);

        // A live stream flips the toggle label and can carry a status row.
        const live = buildTrayMenuItems(true, "Streaming to YouTube");
        assert(live.length == 6);
        assert(live[2].label == "Stop streaming");
        assert(live[3].disabled && live[3].label == "Status: Streaming to YouTube");

        // An error status still renders without crashing and keeps the menu
        // navigable (disabled rows are never the default/bold entry).
        const failed = buildTrayMenuItems(false, "Could not start");
        assert(failed[3].disabled);
        assert(failed[0].bold);
    }

    /// A row's vertical span inside the custom menu.
    private struct TrayMenuRow
    {
        int y;
        int height;
    }

    /// Pure layout: computes each row's vertical span and the total height
    /// given the item list and the (DPI-scaled) metrics. Separators are
    /// shorter; the list starts and ends with the vertical padding.
    private static TrayMenuRow[] computeMenuRows(const TrayMenuItem[] items,
        int rowHeight, int separatorHeight, int paddingY)
    {
        TrayMenuRow[] rows;
        rows.length = items.length;
        int y = paddingY;
        foreach (index, item; items)
        {
            if (item.separator)
            {
                rows[index] = TrayMenuRow(y, separatorHeight);
                y += separatorHeight;
            }
            else
            {
                rows[index] = TrayMenuRow(y, rowHeight);
                y += rowHeight;
            }
        }
        return rows;
    }

    unittest
    {
        const items = buildTrayMenuItems(true, "Streaming to YouTube");
        const rows = computeMenuRows(items, 28, 8, 7);
        // 4 selectable rows (28 each) + 2 separators (8 each) + 14 padding.
        assert(rows.length == 6);
        assert(rows[0].height == 28);
        assert(rows[1].height == 8);
        assert(rows[4].height == 8);
        const total = rows[$ - 1].y + rows[$ - 1].height + 7;
        assert(total == 4 * 28 + 2 * 8 + 14);
    }

    /**
     * A fully custom, self-drawn tray context menu (like Steam's tray menu).
     * A borderless, topmost, popup window rendered with GDI in the app's dark
     * gray theme. It dismisses itself on: choosing an item, clicking outside
     * (mouse capture), pressing Escape, or losing capture. The chosen command
     * id (or -1) is posted to the owner tray window as `wmMenuAction` so the
     * action runs after the window is safely gone.
     */
    private final class TrayContextMenu
    {
        private HWND _hwnd;
        private HWND _owner;
        private TrayMenuItem[] _items;
        private HFONT _font;
        private HFONT _boldFont;
        private bool _fontOwned;
        private bool _boldOwned;
        private int _scale;
        private int _rowHeight;
        private int _sepHeight;
        private int _padX;
        private int _padY;
        private int _width;
        private int _height;
        private TrayMenuRow[] _rows;
        private int _hot = -1;
        private int _pressed = -1;
        private bool _closing;
        private UINT _actionMessage;
        private HHOOK _mouseHook;

        /// Owns the active low-level mouse hook (one menu at a time).
        private static __gshared TrayContextMenu _hookOwner;

        this(HWND owner, const(TrayMenuItem[]) items, UINT actionMessage)
        {
            _owner = owner;
            _items = items.dup;
            _actionMessage = actionMessage;
            _scale = queryDpi();
            _padX = scaleCoord(menuPadXLogical);
            _padY = scaleCoord(menuPadYLogical);
            _rowHeight = scaleCoord(menuItemHeightLogical);
            _sepHeight = scaleCoord(menuSeparatorHeightLogical);
            _rows = computeMenuRows(_items, _rowHeight, _sepHeight, _padY);
            _height = (_rows.length > 0 ?
                _rows[$ - 1].y + _rows[$ - 1].height : 0) + _padY;
            createFonts();
            computeWidth();
            registerClass();
        }

        /// Creates and shows the popup at the given screen point, clamped to
        /// the work area. Non-modal: the main Aurora loop keeps pumping it.
        void showAt(int x, int y)
        {
            RECT work;
            if (SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0) == FALSE)
                work = RECT(0, 0, GetSystemMetrics(SM_CXSCREEN),
                    GetSystemMetrics(SM_CYSCREEN));
            if (x + _width > work.right) x = work.right - _width;
            if (y + _height > work.bottom) y = work.bottom - _height;
            if (x < work.left) x = work.left;
            if (y < work.top) y = work.top;

            _hwnd = CreateWindowExW(
                WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
                trayMenuClassName.ptr, null, WS_POPUP,
                x, y, _width, _height,
                null, null, GetModuleHandleW(null), cast(void*) this);
            if (_hwnd is null)
            {
                cleanupFonts();
                return;
            }
            ShowWindow(_hwnd, SW_SHOW);
            SetForegroundWindow(_hwnd);
            SetActiveWindow(_hwnd);
            UpdateWindow(_hwnd);
            // Belt-and-suspenders dismissal paths:
            //  - activation: an outside click deactivates the menu
            //    (WM_ACTIVATE WA_INACTIVE -> dismiss);
            //  - mouse capture: an outside click is routed to the menu window;
            //  - a WH_MOUSE_LL hook: guaranteed to see every outside click even
            //    when the target is a shell/desktop window (capture alone does
            //    not deliver those reliably);
            //  - Escape via the registered hotkey.
            SetCapture(_hwnd);
            RegisterHotKey(_hwnd, 1, modNoRepeat, VK_ESCAPE);
            installMouseHook();
        }

        private void installMouseHook() nothrow
        {
            if (_mouseHook !is null) return;
            _hookOwner = this;
            _mouseHook = SetWindowsHookExW(WH_MOUSE_LL, &mouseHookProc, null, 0);
            if (_mouseHook is null) _hookOwner = null;
        }

        /// Closes the menu without choosing anything.
        void close()
        {
            dismiss();
        }

        private void dismiss(int chosenId = -1)
        {
            if (_closing) return;
            _closing = true;
            if (_owner !is null)
                PostMessageW(_owner, _actionMessage, cast(WPARAM) chosenId, 0);
            if (_hwnd !is null)
            {
                if (_mouseHook !is null)
                {
                    UnhookWindowsHookEx(_mouseHook);
                    _mouseHook = null;
                    if (_hookOwner is this) _hookOwner = null;
                }
                if (GetCapture() == _hwnd) ReleaseCapture();
                UnregisterHotKey(_hwnd, 1);
                DestroyWindow(_hwnd);
                _hwnd = null;
            }
            cleanupFonts();
        }

        private void computeWidth()
        {
            int width = scaleCoord(menuMinWidthLogical);
            foreach (index, item; _items)
            {
                if (item.separator) continue;
                const textWidth = measureText(item.bold ? _boldFont : _font,
                    item.label);
                const needed = textWidth + 2 * _padX;
                if (needed > width) width = needed;
            }
            const maxWidth = scaleCoord(menuMaxWidthLogical);
            if (width > maxWidth) width = maxWidth;
            _width = width;
        }

        private void createFonts()
        {
            const int height = -MulDiv(menuFontSizeLogical, _scale, 72);
            _font = CreateFontW(height, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                menuFontQuality, DEFAULT_PITCH | FF_DONTCARE, "Segoe UI"w.ptr);
            if (_font !is null) _fontOwned = true;
            else _font = cast(HFONT) GetStockObject(DEFAULT_GUI_FONT);
            _boldFont = CreateFontW(height, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE,
                FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                menuFontQuality, DEFAULT_PITCH | FF_DONTCARE, "Segoe UI"w.ptr);
            if (_boldFont !is null) _boldOwned = true;
            else _boldFont = _font;
        }

        private void cleanupFonts()
        {
            if (_font !is null && _fontOwned)
                DeleteObject(cast(HGDIOBJ) _font);
            _font = null;
            if (_boldFont !is null && _boldOwned)
                DeleteObject(cast(HGDIOBJ) _boldFont);
            _boldFont = null;
        }

        private void paint()
        {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(_hwnd, &ps);
            scope (exit) EndPaint(_hwnd, &ps);

            HBRUSH bg = CreateSolidBrush(menuBackground);
            FillRect(dc, &ps.rcPaint, bg);
            DeleteObject(cast(HGDIOBJ) bg);
            SetBkMode(dc, TRANSPARENT);

            RECT client = RECT(0, 0, _width, _height);
            HBRUSH border = CreateSolidBrush(menuBorder);
            FrameRect(dc, &client, border);
            DeleteObject(cast(HGDIOBJ) border);

            foreach (index, item; _items)
            {
                const row = _rows[index];
                if (item.separator)
                {
                    const y = row.y + row.height / 2;
                    HPEN pen = CreatePen(PS_SOLID, 1, menuSeparator);
                    auto oldPen = SelectObject(dc, pen);
                    MoveToEx(dc, _padX, y, null);
                    LineTo(dc, _width - _padX, y);
                    SelectObject(dc, oldPen);
                    DeleteObject(cast(HGDIOBJ) pen);
                    continue;
                }
                RECT cell = RECT(_padX, row.y, _width - _padX,
                    row.y + row.height);
                if (index == _hot)
                {
                    HBRUSH hover = CreateSolidBrush(menuHover);
                    FillRect(dc, &cell, hover);
                    DeleteObject(cast(HGDIOBJ) hover);
                }
                SelectObject(dc, item.bold ? _boldFont : _font);
                SetTextColor(dc, item.disabled ? menuDisabledText : menuText);
                RECT text = cell;
                text.left += _padX;
                DrawTextW(dc, toUTF16z(item.label), -1, &text,
                    DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOPREFIX |
                    DT_END_ELLIPSIS);
            }
        }

        private void onMouseMove(int x, int y)
        {
            const index = hitTest(x, y);
            if (index != _hot)
            {
                _hot = index;
                invalidate();
            }
        }

        private void onButtonDown(int x, int y)
        {
            const index = hitTest(x, y);
            if (index >= 0)
            {
                _pressed = index;
                invalidate();
            }
            else
            {
                dismiss();
            }
        }

        private void onButtonUp(int x, int y)
        {
            const index = hitTest(x, y);
            const pressed = _pressed;
            _pressed = -1;
            if (pressed >= 0 && index == pressed)
                dismiss(_items[pressed].id);
            else
                invalidate();
        }

        private int hitTest(int x, int y)
        {
            foreach (index, item; _items)
            {
                if (item.separator || item.disabled) continue;
                const row = _rows[index];
                if (x >= _padX && x < _width - _padX &&
                    y >= row.y && y < row.y + row.height)
                    return cast(int) index;
            }
            return -1;
        }

        private void invalidate()
        {
            if (_hwnd !is null) InvalidateRect(_hwnd, null, FALSE);
        }

        /// Low-level mouse hook installed while the menu is open. The shell does
        /// not always deliver a click on the desktop/taskbar to the captured
        /// window, so this hook is the guaranteed "click outside closes the
        /// menu" path: any press outside the menu rectangle asks the menu to
        /// close (posted, so the hook never destroys the window reentrantly).
        private extern(Windows) static LRESULT mouseHookProc(int code,
            WPARAM wParam, LPARAM lParam) nothrow
        {
            auto owner = _hookOwner;
            if (owner !is null && code >= 0 && owner._hwnd !is null)
            {
                auto ms = cast(MSLLHOOKSTRUCT*) lParam;
                if (ms !is null &&
                    (cast(UINT) wParam == WM_LBUTTONDOWN ||
                        cast(UINT) wParam == WM_RBUTTONDOWN ||
                        cast(UINT) wParam == WM_MBUTTONDOWN))
                {
                    RECT rect;
                    GetWindowRect(owner._hwnd, &rect);
                    if (ms.pt.x < rect.left || ms.pt.x > rect.right ||
                        ms.pt.y < rect.top || ms.pt.y > rect.bottom)
                        PostMessageW(owner._hwnd, wmMenuCloseRequest, 0, 0);
                }
            }
            return CallNextHookEx(null, code, wParam, lParam);
        }

        private int measureText(HFONT font, string text)
        {
            HDC dc = CreateCompatibleDC(null);
            if (dc is null)
                return cast(int) text.length * 7 * _scale / 96;
            scope (exit) DeleteDC(dc);
            SelectObject(dc, font);
            RECT rect = RECT(0, 0, 0, 0);
            DrawTextW(dc, toUTF16z(text), -1, &rect,
                DT_CALCRECT | DT_SINGLELINE | DT_NOPREFIX);
            return rect.right - rect.left;
        }

        private static int queryDpi()
        {
            HDC dc = GetDC(null);
            if (dc !is null)
            {
                const value = GetDeviceCaps(dc, LOGPIXELSX);
                ReleaseDC(null, dc);
                if (value > 0) return value;
            }
            return 96;
        }

        private int scaleCoord(int logical) pure nothrow @nogc
        {
            const value = logical * _scale / 96;
            return value > 0 ? value : 1;
        }

        private static void registerClass()
        {
            if (trayMenuClassRegistered) return;
            WNDCLASSEXW wc;
            wc.cbSize = WNDCLASSEXW.sizeof;
            wc.style = CS_DBLCLKS;
            wc.lpfnWndProc = &trayMenuProc;
            wc.hInstance = GetModuleHandleW(null);
            wc.hCursor = LoadCursorW(null, cast(LPCWSTR) 32512);
            wc.lpszClassName = trayMenuClassName.ptr;
            if (RegisterClassExW(&wc) == 0)
            {
                const error = GetLastError();
                if (error != ERROR_CLASS_ALREADY_EXISTS)
                    throw new Exception(
                        "Aurora Stream could not register its tray menu class.");
            }
            trayMenuClassRegistered = true;
        }

        private extern(Windows) static LRESULT trayMenuProc(HWND hwnd,
            UINT message, WPARAM wParam, LPARAM lParam) nothrow
        {
            auto self = cast(TrayContextMenu) cast(void*)
                GetWindowLongPtrW(hwnd, GWLP_USERDATA);
            if (self is null)
            {
                if (message == WM_NCCREATE)
                {
                    auto create = cast(CREATESTRUCTW*) lParam;
                    self = cast(TrayContextMenu) create.lpCreateParams;
                    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        cast(LONG_PTR) cast(void*) self);
                    self._hwnd = hwnd;
                }
                return DefWindowProcW(hwnd, message, wParam, lParam);
            }
            try
            {
                switch (message)
                {
                    case WM_MOUSEACTIVATE:
                        return MA_ACTIVATE;
                    case WM_ERASEBKGND:
                        return 1;
                    case WM_PAINT:
                        self.paint();
                        return 0;
                    case WM_MOUSEMOVE:
                        self.onMouseMove(signedLowWord(lParam),
                            signedHighWord(lParam));
                        return 0;
                    case WM_LBUTTONDOWN:
                        self.onButtonDown(signedLowWord(lParam),
                            signedHighWord(lParam));
                        return 0;
                    case WM_LBUTTONUP:
                        self.onButtonUp(signedLowWord(lParam),
                            signedHighWord(lParam));
                        return 0;
                    case WM_KEYDOWN:
                        if (cast(UINT) wParam == VK_ESCAPE) self.dismiss();
                        return 0;
                    case WM_HOTKEY:
                        self.dismiss();
                        return 0;
                    case wmMenuCloseRequest:
                        // Outside click detected by the mouse hook.
                        self.dismiss();
                        return 0;
                    case WM_ACTIVATE:
                        // Clicking another window deactivates the menu.
                        if (cast(int) wParam == WA_INACTIVE && !self._closing)
                            self.dismiss();
                        return 0;
                    case WM_CAPTURECHANGED:
                        if (!self._closing) self.dismiss();
                        return 0;
                    case WM_NCHITTEST:
                        return HTCLIENT;
                    case WM_DESTROY:
                        self._hwnd = null;
                        return 0;
                    default:
                        break;
                }
            }
            catch (Throwable)
            {
            }
            return DefWindowProcW(hwnd, message, wParam, lParam);
        }
    }

    final class TrayIcon
    {
        private HWND _hwnd;
        private NOTIFYICONDATAW _nid;
        private HICON _icon;
        private UINT _callbackMessage;
        private UINT _taskbarCreatedMessage;
        private bool _active;
        private bool _singleClickPending;
        private bool _classRegistered;
        private DWORD _lastDoubleClickTick;
        private TrayContextMenu _activeMenu;

        /// Left-click once: toggle Start/Stop streaming.
        void delegate() onToggleStream;
        /// Left-click twice (or the menu's Show entry): restore the window.
        void delegate() onShowWindow;
        /// Menu Exit entry: quit the application entirely.
        void delegate() onExit;
        /// Current stream state, queried when the menu is opened.
        bool delegate() isStreaming;
        /// Short status line shown disabled at the top of the menu.
        string delegate() statusText;

        /// Windows toast/balloon notifications (the bubbles that appear next to
        /// the tray icon and in the notification center). Deliberately OFF for
        /// now: the feature is kept intact (`showBalloon` and all call sites
        /// remain) but does not bother the user. Flip to true later when
        /// notifications are refined.
        bool notificationsEnabled = false;

        this()
        {
            _callbackMessage = RegisterWindowMessageW(trayCallbackMessageName.ptr);
            _taskbarCreatedMessage = RegisterWindowMessageW(
                taskbarCreatedMessageName.ptr);
            registerWindowClass();
            // A normal (hidden) top-level window, not a message-only window:
            // the shell drives tooltip hit-testing and click-dismissal off the
            // callback window, so a real HWND with a visible-absent style is
            // the most compatible choice. Messages are pumped by the main
            // Aurora event loop on the same thread.
            _hwnd = CreateWindowExW(0, trayWindowClassName.ptr,
                trayWindowTitle.ptr, WS_OVERLAPPED, 0, 0, 0, 0,
                null, null, GetModuleHandleW(null), cast(void*) this);
            if (_hwnd is null)
                throw new Exception(
                    "Aurora Stream could not create its tray window.");
        }

        /// Adds the icon to the notification area. Returns false (silently) on
        /// failure so callers can fall back to a plain minimize.
        bool show(string iconPath, string tooltip)
        {
            if (_hwnd is null) return false;
            _icon = loadTrayIcon(iconPath);
            _nid.cbSize = NOTIFYICONDATAW.sizeof;
            _nid.hWnd = _hwnd;
            _nid.uID = trayIconId;
            _nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
            _nid.uCallbackMessage = _callbackMessage;
            _nid.hIcon = _icon;
            copyWide(_nid.szTip, tooltip);
            if (Shell_NotifyIconW(NIM_ADD, &_nid) == FALSE) return false;
            _active = true;
            // Version 3 enables balloon bubbles and NIN_* notifications on
            // modern shells. Best-effort; older shells simply ignore it.
            _nid.uVersion = NOTIFYICON_VERSION;
            Shell_NotifyIconW(NIM_SETVERSION, &_nid);
            return true;
        }

        /// Updates the tooltip to reflect the stream state.
        void setStreaming(bool streaming)
        {
            setTooltip(streaming ? "Aurora Stream â€” Streaming" :
                "Aurora Stream â€” Idle");
        }

        void setTooltip(string text)
        {
            if (!_active || _hwnd is null) return;
            _nid.uFlags = NIF_TIP;
            copyWide(_nid.szTip, text);
            Shell_NotifyIconW(NIM_MODIFY, &_nid);
        }

        /// Shows a notification balloon next to the icon. No-op while
        /// `notificationsEnabled` is false (the default) â€” the call sites stay
        /// in place so enabling notifications later is a one-line change.
        void showBalloon(string title, string message, bool error)
        {
            if (!notificationsEnabled) return;
            if (!_active || _hwnd is null) return;
            _nid.uFlags = NIF_INFO;
            _nid.dwInfoFlags = error ? NIIF_ERROR : NIIF_INFO;
            copyWide(_nid.szInfoTitle, title);
            copyWide(_nid.szInfo, message);
            Shell_NotifyIconW(NIM_MODIFY, &_nid);
        }

        /// Removes the icon from the notification area (keep the window alive).
        void remove()
        {
            if (!_active || _hwnd is null) return;
            _active = false;
            NOTIFYICONDATAW removal;
            removal.cbSize = NOTIFYICONDATAW.sizeof;
            removal.hWnd = _hwnd;
            removal.uID = trayIconId;
            Shell_NotifyIconW(NIM_DELETE, &removal);
        }

        /// Removes the icon, destroys the hidden window, and frees resources.
        void shutdown()
        {
            if (_activeMenu !is null)
            {
                _activeMenu.close();
                _activeMenu = null;
            }
            remove();
            if (_hwnd !is null)
            {
                KillTimer(_hwnd, traySingleClickTimer);
                if (IsWindow(_hwnd)) DestroyWindow(_hwnd);
                _hwnd = null;
            }
            if (_icon !is null)
            {
                DestroyIcon(_icon);
                _icon = null;
            }
            if (_classRegistered)
            {
                UnregisterClassW(trayWindowClassName.ptr,
                    GetModuleHandleW(null));
                _classRegistered = false;
            }
        }

        private extern(Windows) static LRESULT trayWindowProc(HWND hwnd,
            UINT message, WPARAM wParam, LPARAM lParam) nothrow
        {
            auto self = cast(TrayIcon) cast(void*)
                GetWindowLongPtrW(hwnd, GWLP_USERDATA);
            if (self is null)
            {
                if (message == WM_NCCREATE)
                {
                    auto create = cast(CREATESTRUCTW*) lParam;
                    self = cast(TrayIcon) create.lpCreateParams;
                    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        cast(LONG_PTR) cast(void*) self);
                    self._hwnd = hwnd;
                }
                return DefWindowProcW(hwnd, message, wParam, lParam);
            }
            try
            {
                if (message == self._callbackMessage)
                {
                    self.handleTrayCallback(wParam, lParam);
                    return 0;
                }
                if (message == self._taskbarCreatedMessage)
                {
                    // Explorer restarted and dropped the icon; re-add it.
                    self._active = false;
                    self.show("", self.tooltipText());
                    return 0;
                }
                if (message == wmMenuAction)
                {
                    self.handleMenuAction(cast(int) wParam);
                    return 0;
                }
                if (message == WM_TIMER && wParam == traySingleClickTimer)
                {
                    KillTimer(hwnd, traySingleClickTimer);
                    self._singleClickPending = false;
                    self.toggleStream();
                    return 0;
                }
            }
            catch (Throwable)
            {
            }
            return DefWindowProcW(hwnd, message, wParam, lParam);
        }

        private string tooltipText()
        {
            return isStreaming is null || !isStreaming() ?
                "Aurora Stream â€” Idle" : "Aurora Stream â€” Streaming";
        }

        private void handleTrayCallback(WPARAM wParam, LPARAM lParam)
        {
            if (cast(int) wParam != trayIconId) return;
            switch (cast(UINT) lParam)
            {
                case WM_LBUTTONUP:
                    // A real double-click is delivered as UP, DBLCLK, UP: the
                    // trailing UP arrives right after the DBLCLK and must not
                    // re-arm a pending single-click toggle.
                    if (GetTickCount() - _lastDoubleClickTick <
                        GetDoubleClickTime())
                        break;
                    // Defer the single-click action until it is clear the
                    // click was not the first half of a double-click. A real
                    // double-click cancels the pending toggle and restores the
                    // window instead.
                    SetTimer(_hwnd, traySingleClickTimer,
                        GetDoubleClickTime(), null);
                    _singleClickPending = true;
                    break;
                case WM_LBUTTONDBLCLK:
                    KillTimer(_hwnd, traySingleClickTimer);
                    _singleClickPending = false;
                    _lastDoubleClickTick = GetTickCount();
                    if (onShowWindow !is null) onShowWindow();
                    break;
                case WM_RBUTTONUP:
                case WM_CONTEXTMENU:
                    showContextMenu();
                    break;
                default:
                    break;
            }
        }

        private void toggleStream()
        {
            if (onToggleStream !is null) onToggleStream();
        }

        /// Runs the custom dark tray context menu. The chosen command (or a
        /// dismissal) is delivered asynchronously via `handleMenuAction`.
        private void showContextMenu()
        {
            if (_hwnd is null || _activeMenu !is null) return;
            const streaming = isStreaming is null ? false : isStreaming();
            string status;
            if (statusText !is null)
            {
                try status = statusText();
                catch (Throwable) status = "";
            }
            if (status.length == 0) status = "Idle";
            const items = buildTrayMenuItems(streaming, status);

            POINT cursor;
            GetCursorPos(&cursor);
            _activeMenu = new TrayContextMenu(_hwnd, items, wmMenuAction);
            _activeMenu.showAt(cursor.x, cursor.y);
        }

        private void handleMenuAction(int id)
        {
            _activeMenu = null;
            if (id == menuShowWindow)
            {
                if (onShowWindow !is null) onShowWindow();
            }
            else if (id == menuToggleStream)
            {
                toggleStream();
            }
            else if (id == menuExit)
            {
                if (onExit !is null) onExit();
            }
        }

        private void registerWindowClass()
        {
            if (_classRegistered) return;
            WNDCLASSEXW wc;
            wc.cbSize = WNDCLASSEXW.sizeof;
            wc.lpfnWndProc = &trayWindowProc;
            wc.hInstance = GetModuleHandleW(null);
            wc.hCursor = LoadCursorW(null, cast(LPCWSTR) 32512);
            wc.lpszClassName = trayWindowClassName.ptr;
            if (RegisterClassExW(&wc) == 0)
            {
                const error = GetLastError();
                if (error != ERROR_CLASS_ALREADY_EXISTS)
                    throw new Exception(
                        "Aurora Stream could not register its tray window class.");
            }
            _classRegistered = true;
        }

        private static HICON loadTrayIcon(string iconPath)
        {
            if (iconPath.length > 0)
            {
                HICON icon = cast(HICON) LoadImageW(null,
                    toUTF16z(iconPath), IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                    GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE);
                if (icon !is null) return icon;
            }
            // Fall back to the generic application icon.
            return cast(HICON) LoadIconW(null, cast(LPCWSTR) 32512);
        }

        private static void copyWide(WCHAR[] target, string value) @safe
        {
            import std.utf : toUTF16;
            if (target.length == 0) return;
            const wide = toUTF16(value);
            foreach (index, w; wide)
            {
                if (index >= target.length - 1) break;
                target[index] = w;
            }
            target[target.length - 1] = 0;
        }
    }
}
