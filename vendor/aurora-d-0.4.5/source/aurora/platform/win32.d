module aurora.platform.win32;

version (AuroraHeadless)
{
    // Native backend intentionally omitted from headless builds.
}
else version (Windows)
{
    import aurora.color : Color;
    import aurora.dragdrop : DragAction, DragActions, DragFormat, DragPayload,
        allowsDragAction;
    import aurora.event : Event, EventType, Key, KeyModifier, MouseButton;
    import aurora.platform.base : NativeSurfaceInfo, NativeSurfaceKind, NativeWindow, NativeWindowSink, WindowOptions;
    import aurora.types : CursorKind, DisplayScale, Point, PointF, Rect, Size;
    import core.sys.windows.windows;
    import core.sys.windows.objidl : CLIPFORMAT, DATADIR, FORMATETC, IAdviseSink,
        IDataObject, IEnumFORMATETC, IEnumSTATDATA, STGMEDIUM, TYMED;
    import core.sys.windows.ole2 : DoDragDrop, OleInitialize, OleUninitialize,
        RegisterDragDrop, ReleaseStgMedium, RevokeDragDrop;
    import core.sys.windows.oleidl : DROPEFFECT, IDropSource, IDropTarget;
    import core.sys.windows.shlobj : DROPFILES;
    import core.sys.windows.uuid : IID_IDataObject, IID_IDropSource,
        IID_IDropTarget, IID_IEnumFORMATETC, IID_IUnknown;
    import core.sys.windows.winerror : DATA_S_SAMEFORMATETC, DRAGDROP_S_CANCEL,
        DRAGDROP_S_DROP, DRAGDROP_S_USEDEFAULTCURSORS, DV_E_FORMATETC,
        DV_E_TYMED, E_INVALIDARG, E_NOINTERFACE, E_NOTIMPL, E_OUTOFMEMORY,
        E_POINTER,
        OLE_E_ADVISENOTSUPPORTED, S_FALSE, S_OK;
    import core.sys.windows.wtypes : DVASPECT;
    import core.stdc.string : memcpy, memcmp;
    import std.array : split;
    import std.string : fromStringz, startsWith, strip;
    import std.utf : toUTF16, toUTF16z, toUTF32, toUTF8;

    pragma(lib, "user32");
    pragma(lib, "gdi32");
    pragma(lib, "shell32");
    pragma(lib, "ole32");

    private alias HDROP = HANDLE;
    private alias HGESTUREINFO = HANDLE;
    private struct AuroraGestureInfo
    {
        UINT size;
        DWORD flags;
        DWORD id;
        HWND target;
        short x;
        short y;
        DWORD instanceId;
        DWORD sequenceId;
        ulong arguments;
        UINT extraArgsSize;
    }

    private struct AuroraGestureConfig
    {
        DWORD id;
        DWORD want;
        DWORD block;
    }

    private struct AuroraScrollInfo
    {
        UINT size;
        UINT mask;
        int minimum;
        int maximum;
        UINT page;
        int position;
        int trackPosition;
    }

    private extern(Windows) nothrow
    {
        void DragAcceptFiles(HWND hwnd, BOOL accept);
        UINT DragQueryFileW(HDROP drop, UINT index, LPWSTR buffer, UINT capacity);
        BOOL DragQueryPoint(HDROP drop, POINT* point);
        void DragFinish(HDROP drop);
        BOOL GetGestureInfo(HGESTUREINFO gesture, AuroraGestureInfo* info);
        BOOL CloseGestureInfoHandle(HGESTUREINFO gesture);
        BOOL SetGestureConfig(HWND hwnd, DWORD reserved, UINT count,
            AuroraGestureConfig* config, UINT size);
        int SetScrollInfo(HWND hwnd, int bar, const(AuroraScrollInfo)* info,
            BOOL redraw);
        BOOL GetScrollInfo(HWND hwnd, int bar, AuroraScrollInfo* info);
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
    private enum UINT wmPointerWheel = 0x024E;
    private enum UINT wmPointerHWheel = 0x024F;
    private enum UINT wmGesture = 0x0119;
    private enum UINT wmVScroll = 0x0115;
    private enum DWORD gestureIdPan = 4;
    private enum DWORD gestureFlagBegin = 0x0001;
    private enum DWORD gestureFlagEnd = 0x0004;
    private enum DWORD gesturePanConfiguration = 0x0001 | 0x0002 |
        0x0004 | 0x0008 | 0x0010;
    private enum int scrollBarVertical = 1;
    private enum UINT scrollInfoRange = 0x0001;
    private enum UINT scrollInfoPage = 0x0002;
    private enum UINT scrollInfoPosition = 0x0004;
    private enum UINT scrollInfoDisableNoScroll = 0x0008;
    private enum UINT scrollInfoTrackPosition = 0x0010;
    private enum UINT wmUniChar = 0x0109;
    private enum UINT wmDpiChanged = 0x02E0;
    private enum UINT wmDropFiles = 0x0233;
    private enum UINT dragQueryFileCount = 0xffff_ffff;
    private enum UINT wmAuroraWake = WM_APP + 0x31;
    private enum UINT_PTR liveResizeTimerId = 0xA304;
    private enum UINT_PTR iconRefreshTimerId = 0xA305;
    private enum uint maximumMessagesPerBatch = 64;
    private enum WPARAM unicodeNoChar = 0xffff;
    private enum int wheelDelta = 120;
    private enum int wheelUnitDelta = wheelDelta / 3;
    private enum uint defaultDpi = 96;
    private enum int processPerMonitorDpiAware = 2;
    private enum int auroraColorOnColor = 3;
    private enum DWORD auroraSrcCopy = 0x00CC0020;

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
        // Aurora owns invalidation and Vulkan does not need a private window
        // DC. CS_HREDRAW/CS_VREDRAW make Windows erase/invalidate the complete
        // client area during every sizing step, which exposes the class
        // background before the next presented image. CS_DBLCLKS lets Windows
        // detect double-clicks (respecting the user's system double-click
        // time/area settings) and deliver WM_*BUTTONDBLCLK instead of relying
        // on the application's own fixed 500 ms / 6 px counting.
        wc.style = CS_DBLCLKS;
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

    private bool sameIid(const(IID)* left, ref const IID right) nothrow @nogc
    {
        return left !is null && memcmp(left, &right, IID.sizeof) == 0;
    }

    private DragActions actionsFromDropEffect(DWORD effect) nothrow @nogc
    {
        DragActions result;
        if ((effect & DROPEFFECT.DROPEFFECT_COPY) != 0)
            result |= cast(DragActions) DragAction.copy;
        if ((effect & DROPEFFECT.DROPEFFECT_MOVE) != 0)
            result |= cast(DragActions) DragAction.move;
        if ((effect & DROPEFFECT.DROPEFFECT_LINK) != 0)
            result |= cast(DragActions) DragAction.link;
        return result;
    }

    private DWORD dropEffectFromActions(DragActions actions) nothrow @nogc
    {
        DWORD result;
        if (allowsDragAction(actions, DragAction.copy))
            result |= DROPEFFECT.DROPEFFECT_COPY;
        if (allowsDragAction(actions, DragAction.move))
            result |= DROPEFFECT.DROPEFFECT_MOVE;
        if (allowsDragAction(actions, DragAction.link))
            result |= DROPEFFECT.DROPEFFECT_LINK;
        return result;
    }

    private DWORD dropEffectFromAction(DragAction action) nothrow @nogc
    {
        final switch (action)
        {
            case DragAction.none: return DROPEFFECT.DROPEFFECT_NONE;
            case DragAction.copy: return DROPEFFECT.DROPEFFECT_COPY;
            case DragAction.move: return DROPEFFECT.DROPEFFECT_MOVE;
            case DragAction.link: return DROPEFFECT.DROPEFFECT_LINK;
        }
    }

    private DragAction suggestedAction(DragActions allowed, DWORD keyState)
        nothrow @nogc
    {
        if ((keyState & MK_CONTROL) != 0 && (keyState & MK_SHIFT) != 0 &&
            allowsDragAction(allowed, DragAction.link))
            return DragAction.link;
        if ((keyState & MK_CONTROL) != 0 &&
            allowsDragAction(allowed, DragAction.copy))
            return DragAction.copy;
        if ((keyState & MK_SHIFT) != 0 &&
            allowsDragAction(allowed, DragAction.move))
            return DragAction.move;
        if (allowsDragAction(allowed, DragAction.copy)) return DragAction.copy;
        if (allowsDragAction(allowed, DragAction.move)) return DragAction.move;
        if (allowsDragAction(allowed, DragAction.link)) return DragAction.link;
        return DragAction.none;
    }

    private struct NativeDragEntry
    {
        CLIPFORMAT format;
        ubyte[] bytes;
    }

    private ubyte[] unicodeTextBytes(const(dchar)[] value)
    {
        const encoded = toUTF16(value);
        ubyte[] bytes;
        bytes.length = (encoded.length + 1) * wchar.sizeof;
        if (encoded.length != 0)
            memcpy(bytes.ptr, encoded.ptr, encoded.length * wchar.sizeof);
        return bytes;
    }

    private ubyte[] fileDropBytes(const(string)[] paths)
    {
        size_t characterCount = 1;
        foreach (path; paths) characterCount += toUTF16(path).length + 1;
        ubyte[] bytes;
        bytes.length = DROPFILES.sizeof + characterCount * wchar.sizeof;
        auto header = cast(DROPFILES*) bytes.ptr;
        *header = DROPFILES.init;
        header.pFiles = DROPFILES.sizeof;
        header.fWide = TRUE;
        auto output = cast(wchar*) (bytes.ptr + DROPFILES.sizeof);
        size_t cursor;
        foreach (path; paths)
        {
            const encoded = toUTF16(path);
            if (encoded.length != 0)
                memcpy(output + cursor, encoded.ptr, encoded.length * wchar.sizeof);
            cursor += encoded.length;
            output[cursor++] = 0;
        }
        output[cursor] = 0;
        return bytes;
    }

    private CLIPFORMAT registeredDragFormat(string mimeType)
    {
        string nativeName;
        if (mimeType == "text/html") nativeName = "HTML Format";
        else if (mimeType == "text/uri-list") nativeName = "text/uri-list";
        else nativeName = "Aurora MIME " ~ mimeType;
        return cast(CLIPFORMAT) RegisterClipboardFormatW(toUTF16z(nativeName));
    }

    private final class WindowsFormatEnumerator : IEnumFORMATETC
    {
        private FORMATETC[] _formats;
        private size_t _index;
        private ULONG _references = 1;

        this(FORMATETC[] formats, size_t index = 0)
        {
            _formats = formats.dup;
            _index = index;
        }

        override HRESULT QueryInterface(IID* iid, void** output)
        {
            if (output is null) return cast(HRESULT) E_POINTER;
            *output = null;
            if (!sameIid(iid, IID_IUnknown) &&
                !sameIid(iid, IID_IEnumFORMATETC))
                return cast(HRESULT) E_NOINTERFACE;
            *output = cast(void*) cast(IEnumFORMATETC) this;
            AddRef();
            return S_OK;
        }

        override ULONG AddRef() { return ++_references; }
        override ULONG Release()
        {
            if (_references != 0) --_references;
            return _references;
        }

        override HRESULT Next(ULONG count, FORMATETC* output, ULONG* fetched)
        {
            if (output is null || (count != 1 && fetched is null))
                return cast(HRESULT) E_INVALIDARG;
            ULONG written;
            while (written < count && _index < _formats.length)
                output[written++] = _formats[_index++];
            if (fetched !is null) *fetched = written;
            return written == count ? S_OK : S_FALSE;
        }

        override HRESULT Skip(ULONG count)
        {
            const remaining = _formats.length - _index;
            const advance = count < remaining ? count : cast(ULONG) remaining;
            _index += advance;
            return advance == count ? S_OK : S_FALSE;
        }

        override HRESULT Reset()
        {
            _index = 0;
            return S_OK;
        }

        override HRESULT Clone(IEnumFORMATETC* output)
        {
            if (output is null) return cast(HRESULT) E_POINTER;
            *output = new WindowsFormatEnumerator(_formats, _index);
            return S_OK;
        }
    }

    private final class WindowsDragDataObject : IDataObject
    {
        private NativeDragEntry[] _entries;
        private ULONG _references = 1;

        this(DragPayload payload)
        {
            if (payload.paths.length != 0)
                addEntry(cast(CLIPFORMAT) CF_HDROP,
                    fileDropBytes(payload.paths));
            if (payload.text.length != 0)
                addEntry(cast(CLIPFORMAT) CF_UNICODETEXT,
                    unicodeTextBytes(payload.text));
            if (payload.uris.length != 0)
            {
                string list;
                foreach (uri; payload.uris) list ~= uri ~ "\r\n";
                addEntry(registeredDragFormat("text/uri-list"),
                    cast(const(ubyte)[]) list);
                addEntry(cast(CLIPFORMAT) RegisterClipboardFormatW(
                    toUTF16z("UniformResourceLocatorW")),
                    unicodeTextBytes(toUTF32(payload.uris[0])));
            }
            foreach (format; payload.formats)
                addEntry(registeredDragFormat(format.mimeType), format.data);
        }

        private void addEntry(CLIPFORMAT format, const(ubyte)[] bytes)
        {
            if (format == 0 || bytes.length == 0) return;
            foreach (entry; _entries)
                if (entry.format == format) return;
            NativeDragEntry entry;
            entry.format = format;
            entry.bytes = bytes.dup;
            _entries ~= entry;
        }

        override HRESULT QueryInterface(IID* iid, void** output)
        {
            if (output is null) return cast(HRESULT) E_POINTER;
            *output = null;
            if (!sameIid(iid, IID_IUnknown) && !sameIid(iid, IID_IDataObject))
                return cast(HRESULT) E_NOINTERFACE;
            *output = cast(void*) cast(IDataObject) this;
            AddRef();
            return S_OK;
        }

        override ULONG AddRef() { return ++_references; }
        override ULONG Release()
        {
            if (_references != 0) --_references;
            return _references;
        }

        private const(NativeDragEntry)* matching(FORMATETC* format)
        {
            if (format is null || format.dwAspect != DVASPECT.DVASPECT_CONTENT)
                return null;
            foreach (ref const entry; _entries)
                if (entry.format == format.cfFormat) return &entry;
            return null;
        }

        override HRESULT GetData(FORMATETC* format, STGMEDIUM* medium)
        {
            if (medium is null) return cast(HRESULT) E_POINTER;
            *medium = STGMEDIUM.init;
            if (format is null || (format.tymed & TYMED.TYMED_HGLOBAL) == 0)
                return cast(HRESULT) DV_E_TYMED;
            auto entry = matching(format);
            if (entry is null) return cast(HRESULT) DV_E_FORMATETC;
            auto memory = GlobalAlloc(GMEM_MOVEABLE, entry.bytes.length);
            if (memory is null) return cast(HRESULT) E_OUTOFMEMORY;
            auto target = GlobalLock(memory);
            if (target is null)
            {
                GlobalFree(memory);
                return cast(HRESULT) E_OUTOFMEMORY;
            }
            memcpy(target, entry.bytes.ptr, entry.bytes.length);
            GlobalUnlock(memory);
            medium.tymed = TYMED.TYMED_HGLOBAL;
            medium.hGlobal = memory;
            medium.pUnkForRelease = null;
            return S_OK;
        }

        override HRESULT GetDataHere(FORMATETC*, STGMEDIUM*)
        {
            return cast(HRESULT) E_NOTIMPL;
        }

        override HRESULT QueryGetData(FORMATETC* format)
        {
            if (format is null) return cast(HRESULT) E_INVALIDARG;
            if ((format.tymed & TYMED.TYMED_HGLOBAL) == 0)
                return cast(HRESULT) DV_E_TYMED;
            return matching(format) is null ? cast(HRESULT) DV_E_FORMATETC : S_OK;
        }

        override HRESULT GetCanonicalFormatEtc(FORMATETC*, FORMATETC* output)
        {
            if (output is null) return cast(HRESULT) E_POINTER;
            output.ptd = null;
            return cast(HRESULT) DATA_S_SAMEFORMATETC;
        }

        override HRESULT SetData(FORMATETC*, STGMEDIUM*, BOOL)
        {
            return cast(HRESULT) E_NOTIMPL;
        }

        override HRESULT EnumFormatEtc(DWORD direction, IEnumFORMATETC* output)
        {
            if (output is null) return cast(HRESULT) E_POINTER;
            *output = null;
            if (direction != DATADIR.DATADIR_GET) return cast(HRESULT) E_NOTIMPL;
            FORMATETC[] formats;
            formats.reserve(_entries.length);
            foreach (entry; _entries)
            {
                FORMATETC format;
                format.cfFormat = entry.format;
                format.dwAspect = DVASPECT.DVASPECT_CONTENT;
                format.lindex = -1;
                format.tymed = TYMED.TYMED_HGLOBAL;
                formats ~= format;
            }
            *output = new WindowsFormatEnumerator(formats);
            return S_OK;
        }

        override HRESULT DAdvise(FORMATETC*, DWORD, IAdviseSink, PDWORD)
        {
            return cast(HRESULT) OLE_E_ADVISENOTSUPPORTED;
        }
        override HRESULT DUnadvise(DWORD)
        {
            return cast(HRESULT) OLE_E_ADVISENOTSUPPORTED;
        }
        override HRESULT EnumDAdvise(IEnumSTATDATA*)
        {
            return cast(HRESULT) OLE_E_ADVISENOTSUPPORTED;
        }
    }

    private final class WindowsDropSource : IDropSource
    {
        private ULONG _references = 1;

        override HRESULT QueryInterface(IID* iid, void** output)
        {
            if (output is null) return cast(HRESULT) E_POINTER;
            *output = null;
            if (!sameIid(iid, IID_IUnknown) && !sameIid(iid, IID_IDropSource))
                return cast(HRESULT) E_NOINTERFACE;
            *output = cast(void*) cast(IDropSource) this;
            AddRef();
            return S_OK;
        }
        override ULONG AddRef() { return ++_references; }
        override ULONG Release()
        {
            if (_references != 0) --_references;
            return _references;
        }
        override HRESULT QueryContinueDrag(BOOL escapePressed, DWORD keyState)
        {
            if (escapePressed) return cast(HRESULT) DRAGDROP_S_CANCEL;
            if ((keyState & MK_LBUTTON) == 0)
                return cast(HRESULT) DRAGDROP_S_DROP;
            return S_OK;
        }
        override HRESULT GiveFeedback(DWORD)
        {
            return cast(HRESULT) DRAGDROP_S_USEDEFAULTCURSORS;
        }
    }

    private DragPayload payloadFromDataObject(IDataObject data)
    {
        DragPayload payload;
        if (data is null) return payload;

        FORMATETC filesFormat;
        filesFormat.cfFormat = cast(CLIPFORMAT) CF_HDROP;
        filesFormat.dwAspect = DVASPECT.DVASPECT_CONTENT;
        filesFormat.lindex = -1;
        filesFormat.tymed = TYMED.TYMED_HGLOBAL;
        STGMEDIUM medium;
        if (data.GetData(&filesFormat, &medium) == S_OK)
        {
            scope(exit) ReleaseStgMedium(&medium);
            const count = DragQueryFileW(cast(HDROP) medium.hGlobal,
                dragQueryFileCount, null, 0);
            foreach (index; 0 .. count)
            {
                const length = DragQueryFileW(cast(HDROP) medium.hGlobal,
                    index, null, 0);
                wchar[] buffer;
                buffer.length = length + 1;
                const written = DragQueryFileW(cast(HDROP) medium.hGlobal,
                    index, buffer.ptr, cast(UINT) buffer.length);
                payload.paths ~= toUTF8(buffer[0 .. written]).dup;
            }
        }

        FORMATETC textFormat;
        textFormat.cfFormat = cast(CLIPFORMAT) CF_UNICODETEXT;
        textFormat.dwAspect = DVASPECT.DVASPECT_CONTENT;
        textFormat.lindex = -1;
        textFormat.tymed = TYMED.TYMED_HGLOBAL;
        medium = STGMEDIUM.init;
        if (data.GetData(&textFormat, &medium) == S_OK)
        {
            scope(exit) ReleaseStgMedium(&medium);
            auto text = cast(const(wchar)*) GlobalLock(medium.hGlobal);
            if (text !is null)
            {
                scope(exit) GlobalUnlock(medium.hGlobal);
                try payload.text = toUTF32(fromStringz(text)).idup;
                catch (Exception) {}
            }
        }

        IEnumFORMATETC enumerator;
        if (data.EnumFormatEtc(DATADIR.DATADIR_GET, &enumerator) == S_OK &&
            enumerator !is null)
        {
            scope(exit) enumerator.Release();
            FORMATETC format;
            ULONG fetched;
            while (enumerator.Next(1, &format, &fetched) == S_OK && fetched == 1)
            {
                if (format.cfFormat == CF_HDROP ||
                    format.cfFormat == CF_UNICODETEXT ||
                    (format.tymed & TYMED.TYMED_HGLOBAL) == 0)
                    continue;
                wchar[256] nameBuffer;
                const length = GetClipboardFormatNameW(format.cfFormat,
                    nameBuffer.ptr, cast(int) nameBuffer.length);
                if (length <= 0) continue;
                const nativeName = toUTF8(nameBuffer[0 .. length]);
                string mimeType;
                if (nativeName.startsWith("Aurora MIME "))
                    mimeType = nativeName[12 .. $].dup;
                else if (nativeName == "text/uri-list")
                    mimeType = "text/uri-list";
                else if (nativeName == "HTML Format")
                    mimeType = "text/html";
                else
                    continue;

                STGMEDIUM richMedium;
                if (data.GetData(&format, &richMedium) != S_OK) continue;
                scope(exit) ReleaseStgMedium(&richMedium);
                const lengthBytes = GlobalSize(richMedium.hGlobal);
                auto raw = cast(const(ubyte)*) GlobalLock(richMedium.hGlobal);
                if (raw is null || lengthBytes == 0) continue;
                scope(exit) GlobalUnlock(richMedium.hGlobal);
                auto bytes = raw[0 .. lengthBytes].dup;
                payload.formats ~= DragFormat(mimeType, bytes);
                if (mimeType == "text/uri-list")
                {
                    const text = cast(string) bytes;
                    foreach (line; text.split("\n"))
                    {
                        const uri = line.strip();
                        if (uri.length != 0 && uri[0] != '#')
                            payload.uris ~= uri.dup;
                    }
                }
            }
        }
        return payload;
    }

    private final class WindowsDropTarget : IDropTarget
    {
        private PlatformWindow _owner;
        private IDataObject _data;
        private DragPayload _payload;
        private ULONG _references = 1;

        this(PlatformWindow owner) { _owner = owner; }

        override HRESULT QueryInterface(IID* iid, void** output)
        {
            if (output is null) return cast(HRESULT) E_POINTER;
            *output = null;
            if (!sameIid(iid, IID_IUnknown) && !sameIid(iid, IID_IDropTarget))
                return cast(HRESULT) E_NOINTERFACE;
            *output = cast(void*) cast(IDropTarget) this;
            AddRef();
            return S_OK;
        }
        override ULONG AddRef() { return ++_references; }
        override ULONG Release()
        {
            if (_references != 0) --_references;
            return _references;
        }

        override HRESULT DragEnter(IDataObject data, DWORD keyState,
            POINTL point, PDWORD effect)
        {
            releaseData();
            _data = data;
            if (_data !is null) _data.AddRef();
            _payload = payloadFromDataObject(data);
            return emit(EventType.dragEntered, keyState, point, effect, _payload);
        }

        override HRESULT DragOver(DWORD keyState, POINTL point, PDWORD effect)
        {
            return emit(EventType.dragMoved, keyState, point, effect, _payload);
        }

        override HRESULT DragLeave()
        {
            if (_owner !is null) _owner.emitNativeDragLeave(_payload);
            releaseData();
            return S_OK;
        }

        override HRESULT Drop(IDataObject data, DWORD keyState,
            POINTL point, PDWORD effect)
        {
            auto payload = payloadFromDataObject(data);
            const result = emit(EventType.dropped, keyState, point, effect,
                payload);
            releaseData();
            return result;
        }

        private HRESULT emit(EventType type, DWORD keyState, POINTL point,
            PDWORD effect, DragPayload payload)
        {
            if (effect is null) return cast(HRESULT) E_POINTER;
            const allowed = actionsFromDropEffect(*effect);
            const action = _owner is null ? DragAction.none :
                _owner.emitNativeDrag(type, payload, allowed, keyState, point);
            *effect = dropEffectFromAction(action);
            return S_OK;
        }

        private void releaseData()
        {
            if (_data !is null) _data.Release();
            _data = null;
            _payload = DragPayload.init;
        }
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
        private bool _visible = true;
        private bool _inSizeMove;
        private bool _fullscreen;
        private bool _minimized;
        private bool _hasWindowedPlacement;
        private LONG_PTR _windowedStyle;
        private LONG_PTR _windowedExStyle;
        private WINDOWPLACEMENT _windowedPlacement;
        private HCURSOR _cursor;
        private HICON _largeIcon;
        private HICON _smallIcon;
        private HBRUSH _startupBrush;
        private bool _startupBackgroundPending;
        private bool _pointerVisible = true;
        private int _wheelRemainderX;
        private int _wheelRemainderY;
        private bool _gesturePanActive;
        private int _gestureLastY;
        private int _gestureWheelPixelRemainder;
        private wchar _pendingHighSurrogate;
        private bool _oleInitialized;
        private bool _oleDropRegistered;
        private WindowsDropTarget _dropTarget;

        this(WindowOptions options, NativeWindowSink sink)
        {
            super(options, sink);
            initializeDpiAwareness();
            registerAuroraWindowClass();

            _dpi = querySystemDpi();
            _displayScale = DisplayScale.fromDpi(_dpi);

            DWORD style = options.decorated ? WS_OVERLAPPEDWINDOW : WS_POPUP;
            // Frameless windows still carry WS_MINIMIZEBOX/WS_MAXIMIZEBOX so the
            // taskbar button and the Alt+Space system menu can minimize/restore
            // them; only the drawn caption is custom. Without WS_MINIMIZEBOX
            // the taskbar click-to-minimize is ignored by the shell.
            if (!options.decorated)
                style |= WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
            if (!options.decorated && options.resizable)
                style |= WS_THICKFRAME;
            if (!options.resizable)
                style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
            if (options.nativeVerticalScrollHost)
                style |= WS_VSCROLL;
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
            if (options.extendedScrollInput)
                initializeExtendedScrollInput();
            // Frameless resizable windows carry WS_THICKFRAME so DWM would
            // otherwise draw the system-light 1px frame (white on light
            // themes) around them. Apply the same dark frame styling as a
            // decorated dark title bar so the border is stable and matches the
            // Aurora surface instead of flashing on activation changes.
            if (options.darkTitleBar || !options.decorated)
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
            initializeDragDrop();
            setCursor(CursorKind.arrow);
        }

        override bool prepareFirstFrame(Color background)
        {
            setStartupBackground(background);
            seedStartupBackground();

            // A newly-created Win32 swapchain normally has an image available
            // immediately. Keep retries bounded for low-latency configurations
            // that use a zero-timeout acquire after the initial attempt.
            foreach (_; 0 .. 4)
            {
                paintNow();
                if (!_needsPaint) return true;
                SwitchToThread();
            }
            return false;
        }

        override void show()
        {
            if (options.startFullscreen && !_fullscreen)
                setFullscreen(true);
            // Seed the Win32 redirection surface as a final safety net. The
            // prepared Vulkan frame normally replaces this before the first
            // composition; drivers that defer hidden presentation show the
            // application theme color instead of the system's white default.
            seedStartupBackground();
            _shown = true;
            const command = options.startNoActivate ? SW_SHOWNOACTIVATE :
                (_fullscreen ? SW_SHOWNORMAL :
                    (options.startMaximized ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL));
            ShowWindow(_hwnd, command);
            UpdateWindow(_hwnd);
            // Re-publish the icons after the window becomes visible so the
            // taskbar button (created at show time) picks up the application
            // icon instead of a generic class default, and schedule a second
            // pass once Explorer has processed the taskbar-created notification.
            applyWindowIcons();
            if (_largeIcon !is null || _smallIcon !is null)
                SetTimer(_hwnd, iconRefreshTimerId, 1500, null);
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
            shutdownDragDrop();
            if (_hwnd !is null && IsWindow(_hwnd))
                DestroyWindow(_hwnd);
            releaseWindowIcons();
            releaseStartupBrush();
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

        override bool presentScaledResizeFrame(const(uint)[] pixels, int sourceWidth,
            int sourceHeight, int targetWidth, int targetHeight)
        {
            if (_closed || _hwnd is null || pixels.length == 0 ||
                sourceWidth <= 0 || sourceHeight <= 0 ||
                targetWidth <= 0 || targetHeight <= 0)
                return false;

            const requiredPixels = cast(size_t) sourceWidth * cast(size_t) sourceHeight;
            if (pixels.length < requiredPixels)
                return false;

            HDC dc = GetDC(_hwnd);
            if (dc is null) return false;
            scope(exit) ReleaseDC(_hwnd, dc);

            BITMAPINFO info;
            info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            info.bmiHeader.biWidth = sourceWidth;
            info.bmiHeader.biHeight = -sourceHeight;
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;

            SetStretchBltMode(dc, auroraColorOnColor);
            const result = StretchDIBits(
                dc,
                0,
                0,
                targetWidth,
                targetHeight,
                0,
                0,
                sourceWidth,
                sourceHeight,
                cast(const(void)*) pixels.ptr,
                &info,
                DIB_RGB_COLORS,
                auroraSrcCopy);
            return result != 0;
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
            if (large is null && small is null) return;
            _largeIcon = large;
            _smallIcon = small;
            applyWindowIcons();
        }

        /// Publish the loaded icons to both the window and its class so the
        /// taskbar, alt-tab, and the frame always use them.
        private void applyWindowIcons()
        {
            if (_hwnd is null) return;
            if (_largeIcon !is null)
            {
                SendMessageW(_hwnd, WM_SETICON, ICON_BIG,
                    cast(LPARAM) _largeIcon);
                SetClassLongPtrW(_hwnd, GCLP_HICON,
                    cast(LONG_PTR) _largeIcon);
            }
            if (_smallIcon !is null)
            {
                SendMessageW(_hwnd, WM_SETICON, ICON_SMALL,
                    cast(LPARAM) _smallIcon);
                SetClassLongPtrW(_hwnd, GCLP_HICONSM,
                    cast(LONG_PTR) _smallIcon);
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
                shutdownDragDrop();
                if (_hwnd !is null) DestroyWindow(_hwnd);
            }
        }

        override bool minimize()
        {
            if (_hwnd is null) return false;
            if (_fullscreen) setFullscreen(false);
            return ShowWindow(_hwnd, SW_MINIMIZE) != FALSE;
        }

        override bool restore()
        {
            if (_hwnd is null) return false;
            return ShowWindow(_hwnd, SW_RESTORE) != FALSE;
        }

        override bool isMinimized()
        {
            // Cached from WM_SIZE (SIZE_MINIMIZED) so callers can check it every
            // tick without a user32 round trip; starts false before show.
            return _minimized;
        }

        override bool setVisible(bool visible)
        {
            if (_hwnd is null) return false;
            if (!visible && _fullscreen) setFullscreen(false);
            _visible = visible;
            ShowWindow(_hwnd, visible ? SW_SHOW : SW_HIDE);
            if (visible)
            {
                // Make the restored surface present immediately instead of
                // waiting for the next queued frame.
                _needsPaint = true;
                invalidate();
                paintNow();
            }
            return true;
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

        override bool setWindowPosition(Point logicalPosition)
        {
            if (_hwnd is null || _fullscreen) return false;
            const physical = _displayScale.logicalToPhysical(logicalPosition);
            return SetWindowPos(_hwnd, null, physical.x, physical.y, 0, 0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE) != FALSE;
        }

        override bool redrawWindow()
        {
            if (_hwnd is null || _closed) return false;
            // Synchronously invalidate and repaint without erasing the
            // background (RDW_NOERASE): erasing the whole window here would
            // flash the background brush on every drag step. The paint below
            // presents the full surface, covering freshly exposed regions.
            RedrawWindow(_hwnd, null, null,
                RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN | RDW_NOERASE);
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

        override bool queryPointerScreenPosition(out PointF position)
        {
            position = PointF.init;
            if (_hwnd is null) return false;
            POINT point;
            if (!GetCursorPos(&point)) return false;
            position = _displayScale.physicalToLogicalPrecise(Point(point.x, point.y));
            return true;
        }

        override void setVerticalScrollInfo(int position, int maximum,
            int pageSize)
        {
            if (_hwnd is null || !options.nativeVerticalScrollHost) return;
            const range = maximum > 0 ? maximum : 0;
            const page = pageSize > 0 ? pageSize : 1;
            const current = position < 0 ? 0 :
                (position > range ? range : position);
            AuroraScrollInfo info;
            info.size = AuroraScrollInfo.sizeof;
            info.mask = scrollInfoRange | scrollInfoPage | scrollInfoPosition |
                scrollInfoDisableNoScroll;
            info.minimum = 0;
            info.maximum = range + page - 1;
            info.page = cast(UINT) page;
            info.position = current;
            SetScrollInfo(_hwnd, scrollBarVertical, &info, TRUE);
        }

        override DragAction beginDrag(DragPayload payload,
            DragActions allowedActions)
        {
            if (!_oleInitialized || payload.empty() || allowedActions == 0)
                return DragAction.none;
            auto data = new WindowsDragDataObject(payload);
            auto source = new WindowsDropSource();
            DWORD performed;
            const result = DoDragDrop(cast(IDataObject) data,
                cast(IDropSource) source, dropEffectFromActions(allowedActions),
                &performed);
            if (result != DRAGDROP_S_DROP) return DragAction.none;
            if ((performed & DROPEFFECT.DROPEFFECT_MOVE) != 0)
                return DragAction.move;
            if ((performed & DROPEFFECT.DROPEFFECT_COPY) != 0)
                return DragAction.copy;
            if ((performed & DROPEFFECT.DROPEFFECT_LINK) != 0)
                return DragAction.link;
            return DragAction.none;
        }

        private void initializeDragDrop()
        {
            const initialized = OleInitialize(null);
            _oleInitialized = initialized >= 0;
            if (_oleInitialized)
            {
                _dropTarget = new WindowsDropTarget(this);
                const registered = RegisterDragDrop(_hwnd,
                    cast(IDropTarget) _dropTarget);
                _oleDropRegistered = registered >= 0;
            }
            // WM_DROPFILES preserves compatibility on hosts where OLE cannot
            // initialize because the embedding thread selected another COM mode.
            DragAcceptFiles(_hwnd, _oleDropRegistered ? FALSE : TRUE);
        }

        private void shutdownDragDrop()
        {
            if (_oleDropRegistered && _hwnd !is null && IsWindow(_hwnd))
                RevokeDragDrop(_hwnd);
            _oleDropRegistered = false;
            _dropTarget = null;
            if (_oleInitialized) OleUninitialize();
            _oleInitialized = false;
        }

        private DragAction emitNativeDrag(EventType type, DragPayload payload,
            DragActions allowedActions, DWORD keyState, POINTL screenPoint)
        {
            POINT point = POINT(screenPoint.x, screenPoint.y);
            ScreenToClient(_hwnd, &point);
            Event event;
            event.type = type;
            const physical = Point(point.x, point.y);
            event.position = _displayScale.physicalToLogical(physical);
            event.globalPosition = event.position;
            event.precisePosition = _displayScale.physicalToLogicalPrecise(physical);
            event.preciseGlobalPosition = event.precisePosition;
            event.hasPrecisePosition = true;
            event.dragPayload = payload.duplicate();
            event.paths = event.dragPayload.paths;
            event.allowedDragActions = allowedActions;
            event.suggestedDragAction = suggestedAction(allowedActions, keyState);
            event.modifiers = currentModifiers();
            if ((keyState & MK_SHIFT) != 0)
                event.modifiers |= cast(uint) KeyModifier.shift;
            if ((keyState & MK_CONTROL) != 0)
                event.modifiers |= cast(uint) KeyModifier.control;
            event.timestampMs = cast(long) GetTickCount();
            sink.onNativeEvent(event);
            return event.dragAction;
        }

        private void emitNativeDragLeave(DragPayload payload)
        {
            const point = cursorClientPoint();
            POINTL screenPoint;
            POINT screen = point;
            ClientToScreen(_hwnd, &screen);
            screenPoint.x = screen.x;
            screenPoint.y = screen.y;
            emitNativeDrag(EventType.dragLeft, payload, 0, 0, screenPoint);
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
                    // Return from the native sizing loop before rebuilding the
                    // exact scene. The next queued paint replaces the stretched
                    // final image without making border release synchronous.
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
                    if (wParam == iconRefreshTimerId)
                    {
                        KillTimer(_hwnd, iconRefreshTimerId);
                        // Explorer creates the taskbar button asynchronously
                        // after the window is shown; re-publishing the icons a
                        // moment later ensures the button shows the application
                        // icon instead of a generic class default.
                        applyWindowIcons();
                        return 0;
                    }
                    break;
                case WM_NCCALCSIZE:
                    if (!options.decorated)
                        return 0;
                    if (options.nativeVerticalScrollHost)
                    {
                        const result = DefWindowProcW(_hwnd, message, wParam, lParam);
                        const scrollbarWidth = GetSystemMetrics(SM_CXVSCROLL);
                        if (wParam != 0)
                        {
                            auto parameters = cast(NCCALCSIZE_PARAMS*) lParam;
                            parameters.rgrc[0].right += scrollbarWidth;
                        }
                        else
                        {
                            auto client = cast(RECT*) lParam;
                            client.right += scrollbarWidth;
                        }
                        return result;
                    }
                    break;
                case WM_NCACTIVATE:
                    // The Aurora surface paints active/inactive state itself.
                    // Prevent DefWindowProc from repainting the DWM frame on
                    // every activation change, which flashed the default
                    // (system-light) border around frameless windows.
                    if (!options.decorated)
                        return TRUE;
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
                    event.dragPayload.paths = paths;
                    event.allowedDragActions = cast(DragActions) DragAction.copy;
                    event.dragAction = DragAction.copy;
                    event.modifiers = currentModifiers();
                    event.timestampMs = cast(long) GetTickCount();
                    sink.onNativeEvent(event);
                    return 0;
                }
                case WM_PAINT:
                {
                    PAINTSTRUCT paint;
                    BeginPaint(_hwnd, &paint);
                    if (paint.fErase)
                        paintStartupBackground(paint.hdc, &paint.rcPaint);
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
                    paintStartupBackground(cast(HDC) wParam);
                    return 1;
                case WM_SIZE:
                {
                    _minimized = cast(DWORD) wParam == SIZE_MINIMIZED;
                    if (_minimized)
                    {
                        // Keep the last full-size framebuffer and content while
                        // minimized instead of shrinking to 1x1. A 1x1 frame
                        // would be scaled up as a solid box during the restore
                        // animation (distorted content). Rendering is paused by
                        // paintNow until SIZE_RESTORED arrives.
                        _needsPaint = false;
                        return 0;
                    }
                    updateClientSize(cast(int) unsignedLowWord(lParam),
                        cast(int) unsignedHighWord(lParam));
                    if (!_inDpiChange)
                    {
                        notifyResize();
                        _needsPaint = true;
                        // WM_SIZE is sent synchronously by SetWindowPos. Keep
                        // programmatic/maximize changes non-blocking; interactive
                        // sizing uses the cheap WSI/proxy frame immediately.
                        if (_inSizeMove)
                            paintNow();
                        else
                            InvalidateRect(_hwnd, null, FALSE);
                    }
                    else
                    {
                        _needsPaint = true;
                    }
                    return 0;
                }
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
                case WM_MOUSEACTIVATE:
                    // Wheel messages are routed to the focused/foreground
                    // window by Windows and by some precision-touchpad drivers.
                    // Make a real pointer press establish native activation;
                    // never change foreground focus merely because of hover.
                    activateFromPointerInteraction();
                    return MA_ACTIVATE;
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
                case WM_LBUTTONDBLCLK:
                case WM_MBUTTONDBLCLK:
                case WM_RBUTTONDBLCLK:
                case WM_XBUTTONDBLCLK:
                    // WM_MOUSEACTIVATE is normally sent first. Repeat the
                    // activation here as a defensive path for synthesized or
                    // device-specific button input that skips that message.
                    activateFromPointerInteraction();
                    SetCapture(_hwnd);
                    event.type = EventType.mouseDown;
                    event.nativeDoubleClick =
                        message == WM_LBUTTONDBLCLK ||
                        message == WM_MBUTTONDBLCLK ||
                        message == WM_RBUTTONDBLCLK ||
                        message == WM_XBUTTONDBLCLK;
                    fillMouseEvent(event, lParam);
                    event.button = buttonForMessage(message, wParam);
                    sink.onNativeEvent(event);
                    return (message == WM_XBUTTONDOWN ||
                        message == WM_XBUTTONDBLCLK) ? TRUE : 0;
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
                    emitWheelFromRawDelta(message == WM_MOUSEWHEEL,
                        cast(int) highWordSigned(wParam), point);
                    return 0;
                }
                case wmPointerWheel:
                case wmPointerHWheel:
                {
                    POINT point = POINT(signedLowWord(lParam), signedHighWord(lParam));
                    ScreenToClient(_hwnd, &point);
                    emitWheelFromRawDelta(message == wmPointerWheel,
                        cast(int) highWordSigned(wParam), point);
                    return 0;
                }
                case wmGesture:
                    if (options.extendedScrollInput)
                    {
                        handlePanGesture(cast(HGESTUREINFO) lParam);
                        return 0;
                    }
                    break;
                case wmVScroll:
                    if (options.nativeVerticalScrollHost || options.extendedScrollInput)
                    {
                        handleVerticalScrollCommand(wParam);
                        return 0;
                    }
                    break;
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
                    // Over a non-client area (resize border, caption, frame,
                    // scrollbar) let DefWindowProc pick the native cursor so
                    // decorated and frameless windows both show the OS resize
                    // arrows on their edges and corners. Only the client area
                    // uses Aurora's cached cursor. A hidden synchronized-drag
                    // pointer must stay hidden even over the frame.
                    if (unsignedLowWord(lParam) != HTCLIENT && _pointerVisible)
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
                    releaseStartupBrush();
                    _hwnd = null;
                    return 0;
                default:
                    break;
            }
            return DefWindowProcW(_hwnd, message, wParam, lParam);
        }

        private void paintNow()
        {
            if (!_visible || _minimized || !_needsPaint || _closed || _painting) return;
            _needsPaint = false;
            _painting = true;
            scope (exit) _painting = false;
            const completed = sink.onNativePaint();
            _needsPaint = !completed;
            if (completed && _shown && _startupBackgroundPending)
            {
                // Stop re-seeding, but keep the brush alive so exposed regions
                // (dragged back from off-screen) are filled with the app
                // background instead of the system's white.
                _startupBackgroundPending = false;
            }
        }

        private void setStartupBackground(Color background) nothrow
        {
            releaseStartupBrush();
            const color = cast(COLORREF) background.r |
                (cast(COLORREF) background.g << 8) |
                (cast(COLORREF) background.b << 16);
            _startupBrush = CreateSolidBrush(color);
            _startupBackgroundPending = _startupBrush !is null;
        }

        private void seedStartupBackground() nothrow
        {
            if (!_startupBackgroundPending || _startupBrush is null ||
                _hwnd is null)
                return;
            HDC dc = GetDC(_hwnd);
            if (dc is null) return;
            scope (exit) ReleaseDC(_hwnd, dc);
            paintStartupBackground(dc);
        }

        private void paintStartupBackground(HDC dc,
            const(RECT)* dirty = null) nothrow
        {
            // Fill ONLY the region being erased/exposed with the application
            // background for the whole window lifetime. The window class has no
            // background brush, so without this DWM/GDI shows white in regions
            // newly exposed when the window is dragged back from off-screen.
            // Filling the whole client (rather than just the dirty rect) would
            // flash the background on every drag step.
            if (_startupBrush is null || dc is null || _hwnd is null)
                return;
            RECT area;
            if (dirty !is null)
                area = *dirty;
            else if (!GetUpdateRect(_hwnd, &area, FALSE))
                return;
            if (area.right > area.left && area.bottom > area.top)
                FillRect(dc, &area, _startupBrush);
        }

        private void releaseStartupBrush() nothrow
        {
            if (_startupBrush !is null)
            {
                DeleteObject(cast(HGDIOBJ) _startupBrush);
                _startupBrush = null;
            }
            _startupBackgroundPending = false;
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
                case wmPointerWheel:
                case wmPointerHWheel:
                case wmGesture:
                case wmVScroll:
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
                case WM_LBUTTONDBLCLK:
                case WM_LBUTTONUP:
                    return MouseButton.left;
                case WM_MBUTTONDOWN:
                case WM_MBUTTONDBLCLK:
                case WM_MBUTTONUP:
                    return MouseButton.middle;
                case WM_RBUTTONDOWN:
                case WM_RBUTTONDBLCLK:
                case WM_RBUTTONUP:
                    return MouseButton.right;
                case WM_XBUTTONDOWN:
                case WM_XBUTTONDBLCLK:
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

        private void initializeExtendedScrollInput() nothrow
        {
            AuroraGestureConfig pan;
            pan.id = gestureIdPan;
            pan.want = gesturePanConfiguration;
            SetGestureConfig(_hwnd, 0, 1, &pan, AuroraGestureConfig.sizeof);
        }

        private POINT cursorClientPoint() nothrow
        {
            POINT point;
            GetCursorPos(&point);
            ScreenToClient(_hwnd, &point);
            return point;
        }

        private void emitWheelFromRawDelta(bool vertical, int rawDelta,
            POINT clientPoint)
        {
            int units;
            if (vertical)
                units = wheelUnitsFromRawDelta(rawDelta, _wheelRemainderY);
            else
                units = wheelUnitsFromRawDelta(rawDelta, _wheelRemainderX);
            emitWheelUnits(vertical, units, clientPoint);
        }

        private void emitWheelUnits(bool vertical, int units, POINT clientPoint)
        {
            if (units == 0) return;
            Event event;
            event.type = EventType.mouseWheel;
            const physical = Point(clientPoint.x, clientPoint.y);
            event.position = _displayScale.physicalToLogical(physical);
            event.globalPosition = event.position;
            event.precisePosition = _displayScale.physicalToLogicalPrecise(physical);
            event.preciseGlobalPosition = event.precisePosition;
            event.hasPrecisePosition = true;
            event.modifiers = currentModifiers();
            if (vertical)
                event.wheelY = units;
            else
                event.wheelX = units;
            event.timestampMs = cast(long) GetTickCount();
            sink.onNativeEvent(event);
        }

        private void handlePanGesture(HGESTUREINFO handle)
        {
            AuroraGestureInfo info;
            info.size = AuroraGestureInfo.sizeof;
            if (!GetGestureInfo(handle, &info))
            {
                CloseGestureInfoHandle(handle);
                return;
            }

            if (info.id == gestureIdPan)
            {
                POINT point = POINT(info.x, info.y);
                ScreenToClient(_hwnd, &point);
                if ((info.flags & gestureFlagBegin) != 0 || !_gesturePanActive)
                {
                    _gesturePanActive = true;
                    _gestureLastY = point.y;
                    _gestureWheelPixelRemainder = 0;
                }
                else
                {
                    const delta = point.y - _gestureLastY;
                    _gestureLastY = point.y;
                    const logicalDelta = _displayScale.physicalToLogical(
                        Point(0, delta)).y;
                    _gestureWheelPixelRemainder += logicalDelta;
                    const units = _gestureWheelPixelRemainder / 8;
                    _gestureWheelPixelRemainder -= units * 8;
                    emitWheelUnits(true, units, point);
                }
                if ((info.flags & gestureFlagEnd) != 0)
                    _gesturePanActive = false;
            }
            CloseGestureInfoHandle(handle);
        }

        private void handleVerticalScrollCommand(WPARAM wParam)
        {
            const cursor = cursorClientPoint();
            sink.onNativeScrollTarget(_displayScale.physicalToLogicalPrecise(
                Point(cursor.x, cursor.y)));
            AuroraScrollInfo info;
            info.size = AuroraScrollInfo.sizeof;
            info.mask = scrollInfoRange | scrollInfoPage | scrollInfoPosition |
                scrollInfoTrackPosition;
            if (!GetScrollInfo(_hwnd, scrollBarVertical, &info)) return;

            const maxPosition = maxIntLocal(0,
                info.maximum - cast(int) info.page + 1);
            const line = maxIntLocal(1, cast(int) info.page / 12);
            const command = cast(uint) (cast(size_t) wParam & 0xffff);
            int target = info.position;
            switch (command)
            {
                case 0: target -= line; break;                  // SB_LINEUP
                case 1: target += line; break;                  // SB_LINEDOWN
                case 2: target -= cast(int) info.page; break;   // SB_PAGEUP
                case 3: target += cast(int) info.page; break;   // SB_PAGEDOWN
                case 4: target = info.trackPosition; break;     // SB_THUMBPOSITION
                case 5: target = info.trackPosition; break;     // SB_THUMBTRACK
                case 6: target = 0; break;                      // SB_TOP
                case 7: target = maxPosition; break;            // SB_BOTTOM
                default: return;                                // SB_ENDSCROLL
            }
            if (target < 0) target = 0;
            if (target > maxPosition) target = maxPosition;
            emitVerticalScrollPosition(target);
        }

        private void emitVerticalScrollPosition(int position)
        {
            Event event;
            event.type = EventType.mouseWheel;
            const point = cursorClientPoint();
            const physical = Point(point.x, point.y);
            event.position = _displayScale.physicalToLogical(physical);
            event.globalPosition = event.position;
            event.precisePosition = _displayScale.physicalToLogicalPrecise(physical);
            event.preciseGlobalPosition = event.precisePosition;
            event.hasPrecisePosition = true;
            event.verticalScrollPosition = position;
            event.hasVerticalScrollPosition = true;
            event.timestampMs = cast(long) GetTickCount();
            sink.onNativeEvent(event);
        }

        private void activateFromPointerInteraction() nothrow
        {
            if (GetForegroundWindow() !is _hwnd)
                SetForegroundWindow(_hwnd);
            if (GetActiveWindow() !is _hwnd)
                SetActiveWindow(_hwnd);
            if (GetFocus() !is _hwnd)
                SetFocus(_hwnd);
        }

    }

    unittest
    {
        DragPayload source;
        source.paths = ["C:\\Aurora drag test.txt"];
        source.text = "Aurora Unicode ✓"d;
        source.uris = ["https://example.com/aurora"];
        source.formats ~= DragFormat("application/x-aurora-test",
            cast(const(ubyte)[]) "rich-data");
        auto data = new WindowsDragDataObject(source);
        auto decoded = payloadFromDataObject(cast(IDataObject) data);
        assert(decoded.paths == source.paths);
        assert(decoded.text == source.text);
        assert(decoded.uris == source.uris);
        assert(decoded.hasFormat("application/x-aurora-test"));
        assert(decoded.formatData("application/x-aurora-test")[0 .. 9] ==
            cast(const(ubyte)[]) "rich-data");
    }
}
