module aurora.platform.win32;

version (AuroraHeadless)
{
    // Native backend intentionally omitted from headless builds.
}
else version (Windows)
{
    import aurora.event : Event, EventType, Key, KeyModifier, MouseButton;
    import aurora.platform.base : NativeSurfaceInfo, NativeSurfaceKind, NativeWindow, NativeWindowSink, WindowOptions;
    import aurora.types : CursorKind, DisplayScale, Point, PointF, Rect, Size;
    import core.sys.windows.windows;
    import std.utf : toUTF16z, toUTF8;

    pragma(lib, "user32");
    pragma(lib, "gdi32");
    pragma(lib, "shell32");

    private alias HDROP = HANDLE;
    private extern(Windows) nothrow
    {
        void DragAcceptFiles(HWND hwnd, BOOL accept);
        UINT DragQueryFileW(HDROP drop, UINT index, LPWSTR buffer, UINT capacity);
        BOOL DragQueryPoint(HDROP drop, POINT* point);
        void DragFinish(HDROP drop);
    }

    private enum : int
    {
        cursorArrow = 32512,
        cursorIBeam = 32513,
        cursorSizeNWSE = 32642,
        cursorSizeNESW = 32643,
        cursorSizeWE = 32644,
        cursorSizeNS = 32645,
        cursorSizeAll = 32646,
        cursorNo = 32648,
        cursorHand = 32649
    }

    private enum UINT wmMouseHWheel = 0x020E;
    private enum UINT wmUniChar = 0x0109;
    private enum UINT wmDpiChanged = 0x02E0;
    private enum UINT wmDropFiles = 0x0233;
    private enum UINT dragQueryFileCount = 0xffff_ffff;
    private enum UINT wmAuroraWake = WM_APP + 0x31;
    private enum UINT_PTR liveResizeTimerId = 0xA304;
    private enum uint maximumMessagesPerBatch = 64;
    private enum WPARAM unicodeNoChar = 0xffff;
    private enum int wheelDelta = 120;
    private enum int wheelUnitDelta = wheelDelta / 3;
    private enum uint defaultDpi = 96;
    private enum int processPerMonitorDpiAware = 2;

    private alias SetProcessDpiAwarenessContextFn =
        extern(Windows) BOOL function(HANDLE value) nothrow;
    private alias SetProcessDPIAwareFn = extern(Windows) BOOL function() nothrow;
    private alias SetProcessDpiAwarenessFn = extern(Windows) HRESULT function(int value) nothrow;
    private alias GetDpiForSystemFn = extern(Windows) UINT function() nothrow;
    private alias GetDpiForWindowFn = extern(Windows) UINT function(HWND hwnd) nothrow;
    private alias AdjustWindowRectExForDpiFn = extern(Windows) BOOL function(
        LPRECT rect, DWORD style, BOOL menu, DWORD exStyle, UINT dpi) nothrow;
    private alias DwmSetWindowAttributeFn = extern(Windows) HRESULT function(
        HWND hwnd, DWORD attribute, const(void)* value, DWORD size) nothrow;

    // Process-wide Win32 entry points and state. __gshared is intentional: a
    // DPI context belongs to the process rather than to D's thread-local data.
    private __gshared SetProcessDpiAwarenessContextFn setProcessDpiAwarenessContext;
    private __gshared SetProcessDPIAwareFn setProcessDPIAware;
    private __gshared SetProcessDpiAwarenessFn setProcessDpiAwareness;
    private __gshared GetDpiForSystemFn getDpiForSystem;
    private __gshared GetDpiForWindowFn getDpiForWindow;
    private __gshared AdjustWindowRectExForDpiFn adjustWindowRectExForDpi;
    private __gshared DwmSetWindowAttributeFn dwmSetWindowAttribute;
    private __gshared bool dpiFunctionsLoaded;
    private __gshared bool dwmFunctionsLoaded;
    private __gshared bool dpiAwarenessInitialized;

    private immutable wchar[] windowClassName = "AuroraDSoftwareWindow"w;
    private immutable wchar[] user32LibraryName = "user32.dll"w;
    private immutable wchar[] shcoreLibraryName = "shcore.dll"w;
    private immutable wchar[] dwmapiLibraryName = "dwmapi.dll"w;
    private __gshared bool classRegistered;

    private enum DWORD dwmwaUseImmersiveDarkModeBefore20H1 = 19;
    private enum DWORD dwmwaUseImmersiveDarkMode = 20;
    private enum DWORD dwmwaBorderColor = 34;
    private enum DWORD dwmwaCaptionColor = 35;
    private enum DWORD dwmwaTextColor = 36;
    private enum DWORD darkBorderColor = 0x00141414;
    private enum DWORD darkCaptionColor = 0x0020242a;
    private enum DWORD darkCaptionTextColor = 0x00ffffff;

    // Run before main so applications using Aurora do not create an HWND while
    // the process is still DPI-unaware. The call is harmless when a host
    // executable has already selected its awareness through a manifest.
    shared static this()
    {
        initializeDpiAwareness();
    }

    private void loadDpiFunctions() nothrow
    {
        if (dpiFunctionsLoaded) return;
        dpiFunctionsLoaded = true;

        HMODULE user32 = GetModuleHandleW(user32LibraryName.ptr);
        if (user32 is null) user32 = LoadLibraryW(user32LibraryName.ptr);
        if (user32 !is null)
        {
            setProcessDpiAwarenessContext = cast(SetProcessDpiAwarenessContextFn)
                GetProcAddress(user32, "SetProcessDpiAwarenessContext".ptr);
            setProcessDPIAware = cast(SetProcessDPIAwareFn)
                GetProcAddress(user32, "SetProcessDPIAware".ptr);
            getDpiForSystem = cast(GetDpiForSystemFn)
                GetProcAddress(user32, "GetDpiForSystem".ptr);
            getDpiForWindow = cast(GetDpiForWindowFn)
                GetProcAddress(user32, "GetDpiForWindow".ptr);
            adjustWindowRectExForDpi = cast(AdjustWindowRectExForDpiFn)
                GetProcAddress(user32, "AdjustWindowRectExForDpi".ptr);
        }

        HMODULE shcore = LoadLibraryW(shcoreLibraryName.ptr);
        if (shcore !is null)
            setProcessDpiAwareness = cast(SetProcessDpiAwarenessFn)
                GetProcAddress(shcore, "SetProcessDpiAwareness".ptr);
    }

    private void initializeDpiAwareness() nothrow
    {
        if (dpiAwarenessInitialized) return;
        dpiAwarenessInitialized = true;
        loadDpiFunctions();

        // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 is the pseudo-handle -4.
        if (setProcessDpiAwarenessContext !is null &&
            setProcessDpiAwarenessContext(cast(HANDLE) cast(ptrdiff_t) -4))
            return;
        if (setProcessDpiAwareness !is null &&
            setProcessDpiAwareness(processPerMonitorDpiAware) >= 0)
            return;
        if (setProcessDPIAware !is null)
            setProcessDPIAware();
    }

    private void loadDwmFunctions() nothrow
    {
        if (dwmFunctionsLoaded) return;
        dwmFunctionsLoaded = true;

        HMODULE dwmapi = GetModuleHandleW(dwmapiLibraryName.ptr);
        if (dwmapi is null) dwmapi = LoadLibraryW(dwmapiLibraryName.ptr);
        if (dwmapi !is null)
            dwmSetWindowAttribute = cast(DwmSetWindowAttributeFn)
                GetProcAddress(dwmapi, "DwmSetWindowAttribute".ptr);
    }

    private void applyDarkTitleBar(HWND hwnd) nothrow
    {
        if (hwnd is null) return;
        loadDwmFunctions();
        if (dwmSetWindowAttribute is null) return;

        BOOL enabled = TRUE;
        if (dwmSetWindowAttribute(hwnd, dwmwaUseImmersiveDarkMode,
                &enabled, cast(DWORD) enabled.sizeof) < 0)
            dwmSetWindowAttribute(hwnd, dwmwaUseImmersiveDarkModeBefore20H1,
                &enabled, cast(DWORD) enabled.sizeof);

        DWORD border = darkBorderColor;
        DWORD caption = darkCaptionColor;
        DWORD text = darkCaptionTextColor;
        dwmSetWindowAttribute(hwnd, dwmwaBorderColor, &border,
            cast(DWORD) border.sizeof);
        dwmSetWindowAttribute(hwnd, dwmwaCaptionColor, &caption,
            cast(DWORD) caption.sizeof);
        dwmSetWindowAttribute(hwnd, dwmwaTextColor, &text,
            cast(DWORD) text.sizeof);
    }

    private uint querySystemDpi() nothrow
    {
        loadDpiFunctions();
        if (getDpiForSystem !is null)
        {
            const value = getDpiForSystem();
            if (value != 0) return value;
        }
        HDC dc = GetDC(null);
        if (dc !is null)
        {
            const value = GetDeviceCaps(dc, LOGPIXELSX);
            ReleaseDC(null, dc);
            if (value > 0) return cast(uint) value;
        }
        return defaultDpi;
    }

    private uint queryWindowDpi(HWND hwnd, uint fallback) nothrow
    {
        loadDpiFunctions();
        if (hwnd !is null && getDpiForWindow !is null)
        {
            const value = getDpiForWindow(hwnd);
            if (value != 0) return value;
        }
        return fallback == 0 ? defaultDpi : fallback;
    }

    private void adjustOuterRectForDpi(ref RECT rect, DWORD style, DWORD exStyle,
        uint dpi) nothrow
    {
        loadDpiFunctions();
        if (adjustWindowRectExForDpi !is null &&
            adjustWindowRectExForDpi(&rect, style, FALSE, exStyle, dpi))
            return;
        AdjustWindowRectEx(&rect, style, FALSE, exStyle);
    }

    private int signedLowWord(LPARAM value) @safe pure nothrow @nogc
    {
        return cast(short) (cast(size_t) value & 0xffff);
    }

    private int signedHighWord(LPARAM value) @safe pure nothrow @nogc
    {
        return cast(short) ((cast(size_t) value >> 16) & 0xffff);
    }

    private uint unsignedLowWord(LPARAM value) @safe pure nothrow @nogc
    {
        return cast(uint) (cast(size_t) value & 0xffff);
    }

    private uint unsignedHighWord(LPARAM value) @safe pure nothrow @nogc
    {
        return cast(uint) ((cast(size_t) value >> 16) & 0xffff);
    }

    private short highWordSigned(WPARAM value) @safe pure nothrow @nogc
    {
        return cast(short) ((cast(size_t) value >> 16) & 0xffff);
    }

    private extern(Windows) nothrow LRESULT auroraWindowProc(
        HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam)
    {
        PlatformWindow window;
        if (message == WM_NCCREATE)
        {
            auto create = cast(CREATESTRUCTW*) lParam;
            window = cast(PlatformWindow) create.lpCreateParams;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, cast(LONG_PTR) cast(void*) window);
            window._hwnd = hwnd;
        }
        else
        {
            window = cast(PlatformWindow) cast(void*) GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        }

        if (window !is null)
        {
            try
            {
                return window.processMessage(message, wParam, lParam);
            }
            catch (Throwable)
            {
                window._closed = true;
                PostQuitMessage(1);
                return 0;
            }
        }
        return DefWindowProcW(hwnd, message, wParam, lParam);
    }

    private void registerAuroraWindowClass()
    {
        initializeDpiAwareness();
        if (classRegistered) return;
        WNDCLASSEXW wc;
        wc.cbSize = WNDCLASSEXW.sizeof;
        wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
        wc.lpfnWndProc = &auroraWindowProc;
        wc.hInstance = GetModuleHandleW(null);
        wc.hCursor = LoadCursorW(null, cast(LPCWSTR) cursorArrow);
        wc.lpszClassName = windowClassName.ptr;
        if (RegisterClassExW(&wc) == 0)
        {
            const error = GetLastError();
            if (error != ERROR_CLASS_ALREADY_EXISTS)
                throw new Exception("Aurora could not register its Win32 window class.");
        }
        classRegistered = true;
    }

    final class PlatformWindow : NativeWindow
    {
        private HWND _hwnd;
        private Size _clientSize;
        private Size _framebufferSize;
        private DisplayScale _displayScale;
        private uint _dpi = defaultDpi;
        private bool _inDpiChange;
        private bool _closed;
        private bool _needsPaint = true;
        private bool _wakePosted;
        private bool _painting;
        private bool _shown;
        private bool _inSizeMove;
        private bool _fullscreen;
        private bool _hasWindowedPlacement;
        private LONG_PTR _windowedStyle;
        private LONG_PTR _windowedExStyle;
        private WINDOWPLACEMENT _windowedPlacement;
        private HCURSOR _cursor;
        private HICON _largeIcon;
        private HICON _smallIcon;
        private bool _pointerVisible = true;
        private int _wheelRemainderX;
        private int _wheelRemainderY;
        private wchar _pendingHighSurrogate;

        this(WindowOptions options, NativeWindowSink sink)
        {
            super(options, sink);
            initializeDpiAwareness();
            registerAuroraWindowClass();

            _dpi = querySystemDpi();
            _displayScale = DisplayScale.fromDpi(_dpi);

            DWORD style = options.decorated ? WS_OVERLAPPEDWINDOW : WS_POPUP;
            if (!options.decorated && options.resizable)
                style |= WS_THICKFRAME;
            if (!options.resizable)
                style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
            DWORD exStyle = options.alwaysOnTop ? WS_EX_TOPMOST : 0;

            const requestedClient = _displayScale.logicalToPhysical(
                Size(maxIntLocal(1, options.width), maxIntLocal(1, options.height)));
            RECT outer = RECT(0, 0, requestedClient.width, requestedClient.height);
            if (options.decorated)
                adjustOuterRectForDpi(outer, style, exStyle, _dpi);
            const width = outer.right - outer.left;
            const height = outer.bottom - outer.top;
            const x = options.x == int.min ? CW_USEDEFAULT :
                _displayScale.logicalToPhysicalX(options.x);
            const y = options.y == int.min ? CW_USEDEFAULT :
                _displayScale.logicalToPhysicalY(options.y);

            _hwnd = CreateWindowExW(
                exStyle,
                windowClassName.ptr,
                toUTF16z(options.title),
                style,
                x,
                y,
                width,
                height,
                null,
                null,
                GetModuleHandleW(null),
                cast(void*) this);
            if (_hwnd is null)
                throw new Exception("Aurora could not create a Win32 window.");
            if (options.decorated && options.darkTitleBar)
                applyDarkTitleBar(_hwnd);

            const creationDpi = _dpi;
            _dpi = queryWindowDpi(_hwnd, creationDpi);
            _displayScale = DisplayScale.fromDpi(_dpi);
            if (_dpi != creationDpi)
            {
                // An explicitly positioned window may have been created on a
                // monitor whose DPI differs from the system DPI used before an
                // HWND existed. Preserve the requested logical client size.
                resizeClientToLogical(Size(maxIntLocal(1, options.width),
                    maxIntLocal(1, options.height)), style, exStyle);
            }
            updateClientSize();
            setWindowIcon(options.iconPath);
            DragAcceptFiles(_hwnd, TRUE);
            setCursor(CursorKind.arrow);
        }

        override void show()
        {
            if (options.startFullscreen && !_fullscreen)
                setFullscreen(true);
            _shown = true;
            const command = _fullscreen ? SW_SHOWNORMAL :
                (options.startMaximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
            ShowWindow(_hwnd, command);
            UpdateWindow(_hwnd);
            updateClientSize();
            notifyResize();
        }

        override int run()
        {
            MSG message;
            WPARAM exitCode;
            auto previousTick = GetTickCount();
            while (!_closed)
            {
                uint dispatchedCount;
                while (dispatchedCount < maximumMessagesPerBatch &&
                    PeekMessageW(&message, null, 0, 0, PM_REMOVE))
                {
                    ++dispatchedCount;
                    // Preserve message ordering while collapsing consecutive
                    // pointer updates to the newest position. This prevents a
                    // present-limited frame from leaving stale drag positions
                    // queued behind it.
                    if (options.lowLatency && message.message == WM_MOUSEMOVE)
                    {
                        MSG next;
                        while (PeekMessageW(&next, null, 0, 0, PM_NOREMOVE) &&
                            next.message == WM_MOUSEMOVE && next.hwnd == message.hwnd)
                        {
                            PeekMessageW(&message, null, 0, 0, PM_REMOVE);
                            ++dispatchedCount;
                        }
                    }
                    if (message.message == WM_QUIT)
                    {
                        exitCode = message.wParam;
                        _closed = true;
                        break;
                    }
                    const latencySensitive = isLatencySensitiveMessage(message.message);
                    TranslateMessage(&message);
                    DispatchMessageW(&message);
                    if (_closed) break;

                    // Repaint the newest pointer-driven state before an input
                    // stream can starve presentation of the frame it produced.
                    if (options.lowLatency && latencySensitive && _needsPaint)
                        break;
                }
                if (_closed) break;

                // Tick first so animation state invalidated by the tick can be
                // included in this same frame instead of the next iteration.
                const now = GetTickCount();
                double delta = cast(double) (now - previousTick) / 1000.0;
                if (delta > 0.1) delta = 0.1;
                if (delta > 0.0)
                {
                    previousTick = now;
                    sink.onNativeTick(delta);
                }
                paintNow();

                if (!_closed)
                {
                    if (_needsPaint && options.lowLatency)
                    {
                        // Do not put a present-limited drag behind a nominal
                        // one-millisecond Win32 timeout: timer quantization can
                        // turn that into a substantial fraction of a refresh.
                        // Poll messages without blocking and yield the current
                        // quantum, then immediately retry acquisition with the
                        // newest late-latched pointer. This busy-yield path is
                        // active only while a frame remains pending.
                        MsgWaitForMultipleObjectsEx(0, null, 0,
                            QS_ALLINPUT, MWMO_INPUTAVAILABLE);
                        SwitchToThread();
                    }
                    else
                    {
                        // Idle windows still sleep and wake immediately for
                        // native input or Aurora's private invalidation message.
                        const waitMilliseconds = options.lowLatency ? 8u : 16u;
                        MsgWaitForMultipleObjectsEx(0, null, waitMilliseconds,
                            QS_ALLINPUT, MWMO_INPUTAVAILABLE);
                    }
                }
            }
            if (_hwnd !is null && _inSizeMove)
                KillTimer(_hwnd, liveResizeTimerId);
            sink.onNativeShutdown();
            if (_hwnd !is null && IsWindow(_hwnd))
                DestroyWindow(_hwnd);
            releaseWindowIcons();
            _hwnd = null;
            return cast(int) exitCode;
        }

        override void invalidate()
        {
            _needsPaint = true;
            if (_hwnd !is null && !_wakePosted)
            {
                _wakePosted = true;
                if (!PostMessageW(_hwnd, wmAuroraWake, 0, 0))
                    _wakePosted = false;
            }
        }

        override void present(const(uint)[] pixels, int width, int height)
        {
            if (_closed || _hwnd is null || pixels.length == 0) return;
            HDC dc = GetDC(_hwnd);
            if (dc is null) return;

            BITMAPINFO info;
            info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            info.bmiHeader.biWidth = width;
            info.bmiHeader.biHeight = -height;
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            // The software renderer already produces the native framebuffer
            // extent. Copy it 1:1 so GDI never performs a second resampling pass.
            SetDIBitsToDevice(
                dc,
                0,
                0,
                cast(DWORD) width,
                cast(DWORD) height,
                0,
                0,
                0,
                cast(UINT) height,
                cast(const(void)*) pixels.ptr,
                &info,
                DIB_RGB_COLORS);
            ReleaseDC(_hwnd, dc);
        }

        override void setTitle(string title)
        {
            if (_hwnd !is null)
                SetWindowTextW(_hwnd, toUTF16z(title));
        }

        private void setWindowIcon(string path)
        {
            if (_hwnd is null || path.length == 0) return;
            auto large = loadWindowIcon(path, SM_CXICON, SM_CYICON);
            auto small = loadWindowIcon(path, SM_CXSMICON, SM_CYSMICON);
            if (large !is null)
            {
                SendMessageW(_hwnd, WM_SETICON, ICON_BIG,
                    cast(LPARAM) large);
                _largeIcon = large;
            }
            if (small !is null)
            {
                SendMessageW(_hwnd, WM_SETICON, ICON_SMALL,
                    cast(LPARAM) small);
                _smallIcon = small;
            }
        }

        private HICON loadWindowIcon(string path, int metricX, int metricY)
        {
            const width = GetSystemMetrics(metricX);
            const height = GetSystemMetrics(metricY);
            return cast(HICON) LoadImageW(null, toUTF16z(path), IMAGE_ICON,
                width, height, LR_LOADFROMFILE);
        }

        private void releaseWindowIcons()
        {
            if (_largeIcon !is null)
            {
                DestroyIcon(_largeIcon);
                _largeIcon = null;
            }
            if (_smallIcon !is null)
            {
                DestroyIcon(_smallIcon);
                _smallIcon = null;
            }
        }

        override void setCursor(CursorKind cursor)
        {
            const id = cursorResource(cursor);
            _cursor = LoadCursorW(null, cast(LPCWSTR) id);
            if (_pointerVisible && _cursor !is null)
                SetCursor(_cursor);
        }

        override bool setPointerVisible(bool visible)
        {
            _pointerVisible = visible;
            if (_hwnd !is null)
                SetCursor(visible ? _cursor : null);
            return true;
        }

        override bool beginSystemMove()
        {
            if (_hwnd is null || _fullscreen) return false;
            ReleaseCapture();
            SendMessageW(_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
            return true;
        }

        override void setFullscreen(bool value)
        {
            if (_hwnd is null || value == _fullscreen) return;

            // SetWindowLongPtr/SetWindowPos synchronously emit WM_SIZE. Suppress
            // those intermediate callbacks and publish one coherent resize when
            // the complete style/placement transition has finished.
            _inDpiChange = true;
            if (value)
            {
                RECT monitor;
                if (!nearestMonitorRect(monitor))
                {
                    _inDpiChange = false;
                    return;
                }

                _windowedStyle = GetWindowLongPtrW(_hwnd, GWL_STYLE);
                _windowedExStyle = GetWindowLongPtrW(_hwnd, GWL_EXSTYLE);
                _windowedPlacement = WINDOWPLACEMENT.init;
                _windowedPlacement.length = WINDOWPLACEMENT.sizeof;
                _hasWindowedPlacement = GetWindowPlacement(_hwnd,
                    &_windowedPlacement) != FALSE;
                if (!_shown && _hasWindowedPlacement)
                    _windowedPlacement.showCmd = options.startMaximized ?
                        SW_SHOWMAXIMIZED : SW_SHOWNORMAL;

                _fullscreen = true;
                const fullscreenStyle = (_windowedStyle &
                    ~cast(LONG_PTR) WS_OVERLAPPEDWINDOW) | cast(LONG_PTR) WS_POPUP;
                const fullscreenExStyle = _windowedExStyle &
                    ~cast(LONG_PTR) (WS_EX_DLGMODALFRAME | WS_EX_WINDOWEDGE |
                        WS_EX_CLIENTEDGE | WS_EX_STATICEDGE);
                SetWindowLongPtrW(_hwnd, GWL_STYLE, fullscreenStyle);
                SetWindowLongPtrW(_hwnd, GWL_EXSTYLE, fullscreenExStyle);
                SetWindowPos(_hwnd, options.alwaysOnTop ? HWND_TOPMOST : HWND_TOP,
                    monitor.left, monitor.top, monitor.right - monitor.left,
                    monitor.bottom - monitor.top,
                    SWP_NOOWNERZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
            }
            else
            {
                _fullscreen = false;
                SetWindowLongPtrW(_hwnd, GWL_STYLE, _windowedStyle);
                SetWindowLongPtrW(_hwnd, GWL_EXSTYLE, _windowedExStyle);
                if (_hasWindowedPlacement)
                {
                    _windowedPlacement.length = WINDOWPLACEMENT.sizeof;
                    SetWindowPlacement(_hwnd, &_windowedPlacement);
                }
                SetWindowPos(_hwnd,
                    options.alwaysOnTop ? HWND_TOPMOST : HWND_NOTOPMOST,
                    0, 0, 0, 0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOOWNERZORDER |
                    SWP_NOACTIVATE | SWP_FRAMECHANGED);
            }
            _inDpiChange = false;
            options.startFullscreen = value;
            updateClientSize();
            if (_shown) notifyResize();
            invalidate();
            if (_shown) paintNow();
        }

        override bool fullscreen() const
        {
            return _fullscreen;
        }

        override void close()
        {
            if (_closed) return;
            if (sink.onNativeCloseRequested())
            {
                _closed = true;
                if (_hwnd !is null) DestroyWindow(_hwnd);
            }
        }

        override Size clientSize() const
        {
            return _clientSize;
        }

        override bool windowBounds(out Rect bounds)
        {
            bounds = Rect.init;
            if (_hwnd is null) return false;
            RECT native;
            if (GetWindowRect(_hwnd, &native) == FALSE) return false;
            const topLeft = _displayScale.physicalToLogical(
                Point(native.left, native.top));
            const bottomRight = _displayScale.physicalToLogical(
                Point(native.right, native.bottom));
            bounds = Rect(topLeft.x, topLeft.y,
                maxIntLocal(1, bottomRight.x - topLeft.x),
                maxIntLocal(1, bottomRight.y - topLeft.y));
            return true;
        }

        override Size framebufferSize() const
        {
            return _framebufferSize;
        }

        override DisplayScale displayScale() const
        {
            return _displayScale;
        }

        override bool queryPointerPosition(out PointF position)
        {
            position = PointF.init;
            if (_hwnd is null) return false;
            POINT point;
            if (!GetCursorPos(&point) || !ScreenToClient(_hwnd, &point))
                return false;
            position = _displayScale.physicalToLogicalPrecise(Point(point.x, point.y));
            return true;
        }

        override NativeSurfaceInfo nativeSurfaceInfo()
        {
            NativeSurfaceInfo info;
            info.kind = NativeSurfaceKind.win32;
            info.handleA = cast(void*) GetModuleHandleW(null);
            info.handleB = cast(void*) _hwnd;
            return info;
        }

        private LRESULT processMessage(UINT message, WPARAM wParam, LPARAM lParam)
        {
            Event event;
            switch (message)
            {
                case WM_ENTERSIZEMOVE:
                    _inSizeMove = true;
                    updateClientSize();
                    notifyResizeLifecycle(EventType.resizeStarted);
                    SetTimer(_hwnd, liveResizeTimerId, 16, null);
                    return 0;
                case WM_EXITSIZEMOVE:
                    KillTimer(_hwnd, liveResizeTimerId);
                    _inSizeMove = false;
                    updateClientSize();
                    notifyResize();
                    notifyResizeLifecycle(EventType.resizeEnded);
                    invalidate();
                    paintNow();
                    return 0;
                case WM_TIMER:
                    if (wParam == liveResizeTimerId && _inSizeMove)
                    {
                        // DefWindowProc owns a modal move/resize loop. Tick and
                        // paint inside it so live resizing remains responsive.
                        sink.onNativeTick(0.016);
                        paintNow();
                        return 0;
                    }
                    break;
                case WM_NCCALCSIZE:
                    if (!options.decorated)
                        return 0;
                    break;
                case WM_NCHITTEST:
                    if (!options.decorated && options.resizable && !_fullscreen)
                        return hitTestBorderlessResize(lParam);
                    break;
                case wmDropFiles:
                {
                    auto drop = cast(HDROP) wParam;
                    scope (exit) DragFinish(drop);
                    string[] paths;
                    const count = DragQueryFileW(drop, dragQueryFileCount, null, 0);
                    foreach (index; 0 .. count)
                    {
                        const length = DragQueryFileW(drop, index, null, 0);
                        if (length == 0) continue;
                        wchar[] buffer = new wchar[cast(size_t) length + 1];
                        const written = DragQueryFileW(drop, index, buffer.ptr,
                            cast(UINT) buffer.length);
                        if (written == 0) continue;
                        paths ~= toUTF8(buffer[0 .. written]).idup;
                    }

                    POINT point;
                    DragQueryPoint(drop, &point);
                    const physical = Point(point.x, point.y);
                    event.type = EventType.filesDropped;
                    event.position = _displayScale.physicalToLogical(physical);
                    event.globalPosition = event.position;
                    event.precisePosition = _displayScale.physicalToLogicalPrecise(physical);
                    event.preciseGlobalPosition = event.precisePosition;
                    event.hasPrecisePosition = true;
                    event.paths = paths;
                    event.modifiers = currentModifiers();
                    event.timestampMs = cast(long) GetTickCount();
                    sink.onNativeEvent(event);
                    return 0;
                }
                case WM_PAINT:
                {
                    PAINTSTRUCT paint;
                    BeginPaint(_hwnd, &paint);
                    EndPaint(_hwnd, &paint);
                    _needsPaint = true;
                    paintNow();
                    return 0;
                }
                case wmAuroraWake:
                    _wakePosted = false;
                    if (_inSizeMove) paintNow();
                    return 0;
                case WM_ERASEBKGND:
                    return 1;
                case WM_SIZE:
                    updateClientSize(cast(int) unsignedLowWord(lParam),
                        cast(int) unsignedHighWord(lParam));
                    if (!_inDpiChange)
                    {
                        notifyResize();
                        _needsPaint = true;
                        paintNow();
                    }
                    else
                    {
                        _needsPaint = true;
                    }
                    return 0;
                case wmDpiChanged:
                {
                    // A fullscreen style transition can synchronously produce
                    // WM_DPICHANGED. Update the scale and rectangle here, but
                    // let the outer transition publish its single final resize.
                    const suppressNotification = _inDpiChange;
                    uint dpiX = cast(uint) (cast(size_t) wParam & 0xffff);
                    uint dpiY = cast(uint) ((cast(size_t) wParam >> 16) & 0xffff);
                    if (dpiX == 0) dpiX = defaultDpi;
                    if (dpiY == 0) dpiY = dpiX;
                    _dpi = dpiX;
                    _displayScale = DisplayScale.fromDpi(dpiX, dpiY);

                    _inDpiChange = true;
                    if (_fullscreen)
                    {
                        RECT monitor;
                        if (nearestMonitorRect(monitor))
                            SetWindowPos(_hwnd, null, monitor.left, monitor.top,
                                monitor.right - monitor.left,
                                monitor.bottom - monitor.top,
                                SWP_NOZORDER | SWP_NOACTIVATE);
                    }
                    else
                    {
                        auto suggested = cast(RECT*) lParam;
                        if (suggested !is null)
                            SetWindowPos(_hwnd, null, suggested.left, suggested.top,
                                suggested.right - suggested.left,
                                suggested.bottom - suggested.top,
                                SWP_NOZORDER | SWP_NOACTIVATE);
                    }
                    _inDpiChange = suppressNotification;
                    updateClientSize();
                    _needsPaint = true;
                    if (!suppressNotification)
                    {
                        notifyResize();
                        invalidate();
                        if (_inSizeMove) paintNow();
                    }
                    return 0;
                }
                case WM_DISPLAYCHANGE:
                    if (_fullscreen)
                    {
                        RECT monitor;
                        if (nearestMonitorRect(monitor))
                        {
                            _inDpiChange = true;
                            SetWindowPos(_hwnd,
                                options.alwaysOnTop ? HWND_TOPMOST : HWND_TOP,
                                monitor.left, monitor.top,
                                monitor.right - monitor.left,
                                monitor.bottom - monitor.top,
                                SWP_NOOWNERZORDER | SWP_NOACTIVATE);
                            _inDpiChange = false;
                            updateClientSize();
                            notifyResize();
                        }
                    }
                    invalidate();
                    return 0;
                case WM_SETFOCUS:
                    event.type = EventType.focusGained;
                    sink.onNativeEvent(event);
                    return 0;
                case WM_KILLFOCUS:
                    event.type = EventType.focusLost;
                    sink.onNativeEvent(event);
                    return 0;
                case WM_MOUSEMOVE:
                    if (!_pointerVisible) SetCursor(null);
                    event.type = EventType.mouseMove;
                    fillMouseEvent(event, lParam);
                    sink.onNativeEvent(event);
                    return 0;
                case WM_LBUTTONDOWN:
                case WM_MBUTTONDOWN:
                case WM_RBUTTONDOWN:
                case WM_XBUTTONDOWN:
                    SetCapture(_hwnd);
                    event.type = EventType.mouseDown;
                    fillMouseEvent(event, lParam);
                    event.button = buttonForMessage(message, wParam);
                    sink.onNativeEvent(event);
                    return message == WM_XBUTTONDOWN ? TRUE : 0;
                case WM_LBUTTONUP:
                case WM_MBUTTONUP:
                case WM_RBUTTONUP:
                case WM_XBUTTONUP:
                    ReleaseCapture();
                    event.type = EventType.mouseUp;
                    fillMouseEvent(event, lParam);
                    event.button = buttonForMessage(message, wParam);
                    sink.onNativeEvent(event);
                    return message == WM_XBUTTONUP ? TRUE : 0;
                case WM_MOUSEWHEEL:
                case wmMouseHWheel:
                {
                    POINT point = POINT(signedLowWord(lParam), signedHighWord(lParam));
                    ScreenToClient(_hwnd, &point);
                    event.type = EventType.mouseWheel;
                    const physical = Point(point.x, point.y);
                    event.position = _displayScale.physicalToLogical(physical);
                    event.globalPosition = event.position;
                    event.precisePosition = _displayScale.physicalToLogicalPrecise(physical);
                    event.preciseGlobalPosition = event.precisePosition;
                    event.hasPrecisePosition = true;
                    event.modifiers = currentModifiers();
                    const rawDelta = cast(int) highWordSigned(wParam);
                    if (message == WM_MOUSEWHEEL)
                        event.wheelY = wheelUnitsFromRawDelta(rawDelta, _wheelRemainderY);
                    else
                        event.wheelX = wheelUnitsFromRawDelta(rawDelta, _wheelRemainderX);
                    if (event.wheelX == 0 && event.wheelY == 0) return 0;
                    event.timestampMs = cast(long) GetTickCount();
                    sink.onNativeEvent(event);
                    return 0;
                }
                case WM_KEYDOWN:
                case WM_SYSKEYDOWN:
                case WM_KEYUP:
                case WM_SYSKEYUP:
                    event.type = (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)
                        ? EventType.keyDown : EventType.keyUp;
                    event.key = mapKey(cast(UINT) wParam);
                    event.modifiers = currentModifiers();
                    event.repeat = (cast(size_t) lParam & 0x40000000) != 0;
                    event.timestampMs = cast(long) GetTickCount();
                    sink.onNativeEvent(event);
                    return 0;
                case WM_CHAR:
                    emitUtf16(cast(wchar) wParam);
                    return 0;
                case wmUniChar:
                    if (wParam == unicodeNoChar) return TRUE;
                    emitCodePoint(cast(dchar) wParam);
                    return 0;
                case WM_SETCURSOR:
                    if (!options.decorated && options.resizable && !_fullscreen &&
                        unsignedLowWord(lParam) != HTCLIENT)
                        break;
                    if (!_pointerVisible)
                    {
                        SetCursor(null);
                        return TRUE;
                    }
                    if (_cursor !is null)
                    {
                        SetCursor(_cursor);
                        return TRUE;
                    }
                    break;
                case WM_CLOSE:
                    if (sink.onNativeCloseRequested())
                    {
                        _closed = true;
                        DestroyWindow(_hwnd);
                    }
                    return 0;
                case WM_DESTROY:
                    if (_inSizeMove) KillTimer(_hwnd, liveResizeTimerId);
                    _inSizeMove = false;
                    _closed = true;
                    releaseWindowIcons();
                    _hwnd = null;
                    return 0;
                default:
                    break;
            }
            return DefWindowProcW(_hwnd, message, wParam, lParam);
        }

        private void paintNow()
        {
            if (!_needsPaint || _closed || _painting) return;
            _needsPaint = false;
            _painting = true;
            scope (exit) _painting = false;
            _needsPaint = !sink.onNativePaint();
        }

        private bool nearestMonitorRect(out RECT result) nothrow
        {
            if (_hwnd is null) return false;
            HMONITOR monitor = MonitorFromWindow(_hwnd, MONITOR_DEFAULTTONEAREST);
            if (monitor is null) return GetWindowRect(_hwnd, &result) != 0;
            MONITORINFO info;
            info.cbSize = MONITORINFO.sizeof;
            if (!GetMonitorInfoW(monitor, &info)) return false;
            result = info.rcMonitor;
            return true;
        }

        private void notifyResize()
        {
            Event event;
            fillResizeEvent(event);
            sink.onNativeEvent(event);
        }

        private void notifyResizeLifecycle(EventType type)
        {
            Event event;
            fillResizeEvent(event);
            event.type = type;
            sink.onNativeEvent(event);
        }

        private static bool isLatencySensitiveMessage(UINT message)
            @safe pure nothrow @nogc
        {
            switch (message)
            {
                case WM_MOUSEMOVE:
                case WM_LBUTTONDOWN:
                case WM_LBUTTONUP:
                case WM_MBUTTONDOWN:
                case WM_MBUTTONUP:
                case WM_RBUTTONDOWN:
                case WM_RBUTTONUP:
                case WM_XBUTTONDOWN:
                case WM_XBUTTONUP:
                case WM_MOUSEWHEEL:
                case wmMouseHWheel:
                case WM_SIZE:
                case WM_PAINT:
                case wmDpiChanged:
                    return true;
                default:
                    return false;
            }
        }

        private void resizeClientToLogical(Size logical, DWORD style, DWORD exStyle)
        {
            const physical = _displayScale.logicalToPhysical(logical);
            RECT outer = RECT(0, 0, physical.width, physical.height);
            if (options.decorated)
                adjustOuterRectForDpi(outer, style, exStyle, _dpi);
            _inDpiChange = true;
            SetWindowPos(_hwnd, null, 0, 0, outer.right - outer.left,
                outer.bottom - outer.top,
                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
            _inDpiChange = false;
        }

        private LRESULT hitTestBorderlessResize(LPARAM lParam)
        {
            RECT rect;
            if (_hwnd is null || GetWindowRect(_hwnd, &rect) == FALSE)
                return HTCLIENT;

            const x = signedLowWord(lParam);
            const y = signedHighWord(lParam);
            const marginX = maxIntLocal(6, _displayScale.logicalToPhysicalX(8));
            const marginY = maxIntLocal(6, _displayScale.logicalToPhysicalY(8));
            const onLeft = x >= rect.left && x < rect.left + marginX;
            const onRight = x < rect.right && x >= rect.right - marginX;
            const onTop = y >= rect.top && y < rect.top + marginY;
            const onBottom = y < rect.bottom && y >= rect.bottom - marginY;

            if (onTop && onLeft) return HTTOPLEFT;
            if (onTop && onRight) return HTTOPRIGHT;
            if (onBottom && onLeft) return HTBOTTOMLEFT;
            if (onBottom && onRight) return HTBOTTOMRIGHT;
            if (onLeft) return HTLEFT;
            if (onRight) return HTRIGHT;
            if (onTop) return HTTOP;
            if (onBottom) return HTBOTTOM;
            return HTCLIENT;
        }

        private void updateClientSize(int knownWidth = -1, int knownHeight = -1)
        {
            int width = knownWidth;
            int height = knownHeight;
            if (width < 0 || height < 0)
            {
                RECT rect;
                GetClientRect(_hwnd, &rect);
                width = rect.right - rect.left;
                height = rect.bottom - rect.top;
            }
            _framebufferSize = Size(maxIntLocal(1, width), maxIntLocal(1, height));
            _clientSize = _displayScale.physicalToLogical(_framebufferSize);
        }

        private void fillResizeEvent(ref Event event)
        {
            event.type = EventType.resized;
            event.size = _clientSize;
            event.framebufferSize = _framebufferSize;
            event.displayScale = _displayScale;
        }

        private void fillMouseEvent(ref Event event, LPARAM lParam)
        {
            const physical = Point(signedLowWord(lParam), signedHighWord(lParam));
            event.position = _displayScale.physicalToLogical(physical);
            event.globalPosition = event.position;
            event.precisePosition = _displayScale.physicalToLogicalPrecise(physical);
            event.preciseGlobalPosition = event.precisePosition;
            event.hasPrecisePosition = true;
            event.modifiers = currentModifiers();
            event.timestampMs = cast(long) GetTickCount();
        }

        private void emitUtf16(wchar value)
        {
            if (value >= 0xD800 && value <= 0xDBFF)
            {
                _pendingHighSurrogate = value;
                return;
            }
            if (value >= 0xDC00 && value <= 0xDFFF && _pendingHighSurrogate != 0)
            {
                const high = cast(uint) _pendingHighSurrogate - 0xD800;
                const low = cast(uint) value - 0xDC00;
                _pendingHighSurrogate = 0;
                emitCodePoint(cast(dchar) (0x10000 + ((high << 10) | low)));
                return;
            }
            _pendingHighSurrogate = 0;
            emitCodePoint(cast(dchar) value);
        }

        private void emitCodePoint(dchar value)
        {
            if (value == 0 || value > 0x10ffff) return;
            Event input;
            input.type = EventType.textInput;
            input.text = [value].idup;
            input.modifiers = currentModifiers();
            input.timestampMs = cast(long) GetTickCount();
            sink.onNativeEvent(input);
        }

        private static MouseButton buttonForMessage(UINT message, WPARAM wParam)
            @safe pure nothrow @nogc
        {
            switch (message)
            {
                case WM_LBUTTONDOWN:
                case WM_LBUTTONUP:
                    return MouseButton.left;
                case WM_MBUTTONDOWN:
                case WM_MBUTTONUP:
                    return MouseButton.middle;
                case WM_RBUTTONDOWN:
                case WM_RBUTTONUP:
                    return MouseButton.right;
                case WM_XBUTTONDOWN:
                case WM_XBUTTONUP:
                    return ((cast(size_t) wParam >> 16) & 0xffff) == XBUTTON1
                        ? MouseButton.extra1 : MouseButton.extra2;
                default:
                    return MouseButton.none;
            }
        }

        private static uint currentModifiers() nothrow @nogc
        {
            uint result;
            if (GetKeyState(VK_SHIFT) < 0) result |= cast(uint) KeyModifier.shift;
            if (GetKeyState(VK_CONTROL) < 0) result |= cast(uint) KeyModifier.control;
            if (GetKeyState(VK_MENU) < 0) result |= cast(uint) KeyModifier.alt;
            if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0)
                result |= cast(uint) KeyModifier.meta;
            if ((GetKeyState(VK_CAPITAL) & 1) != 0) result |= cast(uint) KeyModifier.capsLock;
            if ((GetKeyState(VK_NUMLOCK) & 1) != 0) result |= cast(uint) KeyModifier.numLock;
            return result;
        }

        private static Key mapKey(UINT key) @safe pure nothrow @nogc
        {
            if (key >= '0' && key <= '9')
                return cast(Key) (cast(int) Key.digit0 + cast(int) (key - '0'));
            if (key >= 'A' && key <= 'Z')
                return cast(Key) (cast(int) Key.a + cast(int) (key - 'A'));
            switch (key)
            {
                case VK_BACK: return Key.backspace;
                case VK_TAB: return Key.tab;
                case VK_RETURN: return Key.enter;
                case VK_ESCAPE: return Key.escape;
                case VK_SPACE: return Key.space;
                case VK_PRIOR: return Key.pageUp;
                case VK_NEXT: return Key.pageDown;
                case VK_END: return Key.end;
                case VK_HOME: return Key.home;
                case VK_LEFT: return Key.left;
                case VK_UP: return Key.up;
                case VK_RIGHT: return Key.right;
                case VK_DOWN: return Key.down;
                case VK_INSERT: return Key.insert;
                case VK_DELETE: return Key.deleteKey;
                case VK_F1: return Key.f1;
                case VK_F2: return Key.f2;
                case VK_F3: return Key.f3;
                case VK_F4: return Key.f4;
                case VK_F5: return Key.f5;
                case VK_F6: return Key.f6;
                case VK_F7: return Key.f7;
                case VK_F8: return Key.f8;
                case VK_F9: return Key.f9;
                case VK_F10: return Key.f10;
                case VK_F11: return Key.f11;
                case VK_F12: return Key.f12;
                case VK_OEM_MINUS: return Key.minus;
                case VK_OEM_PLUS: return Key.equal;
                case VK_OEM_4: return Key.leftBracket;
                case VK_OEM_6: return Key.rightBracket;
                case VK_OEM_5: return Key.backslash;
                case VK_OEM_1: return Key.semicolon;
                case VK_OEM_7: return Key.apostrophe;
                case VK_OEM_3: return Key.grave;
                case VK_OEM_COMMA: return Key.comma;
                case VK_OEM_PERIOD: return Key.period;
                case VK_OEM_2: return Key.slash;
                default: return Key.unknown;
            }
        }

        private static int cursorResource(CursorKind cursor) @safe pure nothrow @nogc
        {
            final switch (cursor)
            {
                case CursorKind.arrow: return cursorArrow;
                case CursorKind.hand: return cursorHand;
                case CursorKind.text: return cursorIBeam;
                case CursorKind.resizeHorizontal: return cursorSizeWE;
                case CursorKind.resizeVertical: return cursorSizeNS;
                case CursorKind.resizeDiagonalNWSE: return cursorSizeNWSE;
                case CursorKind.resizeDiagonalNESW: return cursorSizeNESW;
                case CursorKind.move: return cursorSizeAll;
                case CursorKind.forbidden: return cursorNo;
            }
        }

        private static int wheelUnitsFromRawDelta(int rawDelta, ref int remainder)
            @safe pure nothrow @nogc
        {
            if (rawDelta == 0) return 0;
            if ((rawDelta > 0 && remainder < 0) || (rawDelta < 0 && remainder > 0))
                remainder = 0;
            remainder += rawDelta;
            const units = remainder / wheelUnitDelta;
            remainder -= units * wheelUnitDelta;
            return units;
        }

        private static int maxIntLocal(int a, int b) @safe pure nothrow @nogc
        {
            return a > b ? a : b;
        }
    }
}
