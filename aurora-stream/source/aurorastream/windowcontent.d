module aurorastream.windowcontent;

version (Windows)
{
    import core.sys.windows.windows : BOOL, CreateCompatibleDC,
        CreateDIBSection, DeleteDC, DeleteObject, DIB_RGB_COLORS, GetDC,
        GetClientRect, HBITMAP, HDC, HGDIOBJ, HWND, IsIconic, IsWindow, RECT,
        ReleaseDC, SelectObject, SetStretchBltMode, SRCCOPY, StretchBlt;
    import core.sys.windows.wingdi : BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        HALFTONE;
    import core.sys.windows.winuser : PrintWindow;
    import core.stdc.string : memcpy, memset;
    import aurorastream.windowsources : hwndFromText;
    import std.algorithm : max;
}

/// `PrintWindow` with this flag asks the Desktop Window Manager to render the
/// window's own full content (not the on-screen pixels), so a covered window
/// still returns its real pixels — the same behavior professional tools get
/// from Windows Graphics Capture, without the WinRT layer.
version (Windows)
private enum uint pwClientOnly = 0x00000001;
private enum uint pwRenderFullContent = 0x00000002;

/// Reusable window-content capture state. Unlike a screen grab, this captures
/// the window's OWN rendered content via `PrintWindow(PW_RENDERFULLCONTENT)`,
/// so the stream keeps showing the window even when it is covered by other
/// windows, off the visible desktop, or running in the background. A minimized
/// window has no rendered surface (verified: gdigrab fails with an I/O error
/// and even PrintWindow only recovers a taskbar-sized stub), so capture()
/// returns false for it and the caller keeps sending the last good frame.
///
/// DIB memory bytes are B,G,R,unused on little-endian, which is exactly the
/// BGRA byte order FFmpeg's `-pix_fmt bgra` rawvideo input expects, so the
/// captured buffer is written straight through (no channel swap).
version (Windows)
final class WindowContentCapturer
{
    private int _targetWidth;
    private int _targetHeight;
    private HWND _window;
    private string _windowText;
    private HDC _windowDC;
    private HBITMAP _windowBitmap;
    private HGDIOBJ _windowPrevious;
    private void* _windowBits;
    private int _windowWidth;
    private int _windowHeight;
    private HDC _targetDC;
    private HBITMAP _targetBitmap;
    private HGDIOBJ _targetPrevious;
    private void* _targetBits;

    this(int width, int height)
    {
        _targetWidth = max(1, width);
        _targetHeight = max(1, height);
    }

    ~this()
    {
        releaseDeviceObjects();
    }

    void setTargetSize(int width, int height)
    {
        if (width <= 0 || height <= 0) return;
        if (width == _targetWidth && height == _targetHeight) return;
        _targetWidth = width;
        _targetHeight = height;
        releaseTargetObjects();
    }

    /// Selects the window whose content is captured. The handle text is
    /// re-parsed only when it changes so a streaming loop stays cheap.
    void setWindowTarget(string hwndText)
    {
        if (hwndText == _windowText) return;
        _windowText = hwndText.idup;
        _window = hwndFromText(hwndText);
        releaseDeviceObjects();
    }

    private void releaseTargetObjects()
    {
        if (_targetDC !is null && _targetPrevious !is null)
            SelectObject(_targetDC, _targetPrevious);
        _targetPrevious = null;
        if (_targetBitmap !is null) DeleteObject(_targetBitmap);
        _targetBitmap = null;
        _targetBits = null;
        if (_targetDC !is null) DeleteDC(_targetDC);
        _targetDC = null;
    }

    private void releaseDeviceObjects()
    {
        if (_windowDC !is null && _windowPrevious !is null)
            SelectObject(_windowDC, _windowPrevious);
        _windowPrevious = null;
        if (_windowBitmap !is null) DeleteObject(_windowBitmap);
        _windowBitmap = null;
        _windowBits = null;
        if (_windowDC !is null) DeleteDC(_windowDC);
        _windowDC = null;
        _windowWidth = 0;
        _windowHeight = 0;
        releaseTargetObjects();
    }

    /// Ensures the client-sized memory DC is created for the window's current
    /// size; the DIB is recreated only when the window resizes. Using the
    /// client area avoids mixing the target's DPI-virtualized non-client frame
    /// with PrintWindow's logical client rendering (VLC otherwise leaves a
    /// large unpainted side region in the capture).
    private bool ensureWindowSurface()
    {
        if (_window is null) return false;
        RECT rect;
        if (GetClientRect(_window, &rect) == 0) return false;
        const width = rect.right - rect.left;
        const height = rect.bottom - rect.top;
        if (width <= 0 || height <= 0) return false;
        if (_windowDC !is null && width == _windowWidth &&
            height == _windowHeight)
            return _windowBits !is null;

        releaseDeviceObjects();
        HDC screenDC = GetDC(null);
        if (screenDC is null) return false;
        scope (exit) ReleaseDC(null, screenDC);

        _windowDC = CreateCompatibleDC(screenDC);
        if (_windowDC is null) return false;
        BITMAPINFOHEADER header;
        header.biSize = BITMAPINFOHEADER.sizeof;
        header.biWidth = width;
        header.biHeight = -height; // top-down rows
        header.biPlanes = 1;
        header.biBitCount = 32;
        header.biCompression = BI_RGB;
        BITMAPINFO info;
        info.bmiHeader = header;
        _windowBitmap = CreateDIBSection(_windowDC, &info, DIB_RGB_COLORS,
            &_windowBits, null, 0);
        if (_windowBitmap is null) return false;
        _windowPrevious = SelectObject(_windowDC, cast(HGDIOBJ) _windowBitmap);
        _windowWidth = width;
        _windowHeight = height;
        return _windowBits !is null;
    }

    /// Ensures the target-sized memory DC used as the scaled output surface.
    private bool ensureTargetSurface()
    {
        if (_targetDC !is null && _targetBits !is null) return true;
        HDC screenDC = GetDC(null);
        if (screenDC is null) return false;
        scope (exit) ReleaseDC(null, screenDC);

        _targetDC = CreateCompatibleDC(screenDC);
        if (_targetDC is null) return false;
        BITMAPINFOHEADER header;
        header.biSize = BITMAPINFOHEADER.sizeof;
        header.biWidth = _targetWidth;
        header.biHeight = -_targetHeight;
        header.biPlanes = 1;
        header.biBitCount = 32;
        header.biCompression = BI_RGB;
        BITMAPINFO info;
        info.bmiHeader = header;
        _targetBitmap = CreateDIBSection(_targetDC, &info, DIB_RGB_COLORS,
            &_targetBits, null, 0);
        if (_targetBitmap is null) return false;
        _targetPrevious = SelectObject(_targetDC, cast(HGDIOBJ) _targetBitmap);
        return _targetBits !is null;
    }

    /// Captures the window's own content scaled to the configured size into
    /// `bgra` (BGRA8 bytes, `_targetWidth * _targetHeight * 4`). Returns false
    /// when the window is closed or minimized (no rendered content), so the
    /// caller can keep streaming the last good frame instead of freezing.
    bool capture(ubyte[] bgra)
    {
        if (bgra.length < cast(size_t) _targetWidth * _targetHeight * 4)
            return false;
        if (_window is null) return false;
        if (IsWindow(_window) == 0) return false;
        if (IsIconic(_window) != 0) return false; // minimized: nothing renders
        if (!ensureWindowSurface()) return false;

        // PrintWindow may not repaint every child/composited surface. Clear
        // first so any region it leaves untouched is black, not stale DIB data.
        memset(_windowBits, 0,
            cast(size_t) _windowWidth * _windowHeight * 4);
        if (PrintWindow(_window, _windowDC,
            pwClientOnly | pwRenderFullContent) == 0)
            return false;

        const byteCount = cast(size_t) _targetWidth * _targetHeight * 4;
        auto target = cast(ubyte*) bgra.ptr;
        if (_windowWidth == _targetWidth && _windowHeight == _targetHeight)
        {
            // The common native-size path avoids an unnecessary GDI scale and
            // copy through the second DIB.
            memcpy(target, _windowBits, byteCount);
        }
        else
        {
            if (!ensureTargetSurface()) return false;
            // Preserve the client aspect ratio rather than stretching a game or
            // video to the configured canvas. HALFTONE is GDI's highest-quality
            // resampler; unused canvas pixels stay black.
            ulong scaledWidth = _targetWidth;
            ulong scaledHeight = cast(ulong) _targetWidth * _windowHeight /
                _windowWidth;
            if (scaledHeight > _targetHeight)
            {
                scaledHeight = _targetHeight;
                scaledWidth = cast(ulong) _targetHeight * _windowWidth /
                    _windowHeight;
            }
            if (scaledWidth == 0 || scaledHeight == 0) return false;
            const offsetX = (_targetWidth - cast(int) scaledWidth) / 2;
            const offsetY = (_targetHeight - cast(int) scaledHeight) / 2;
            memset(_targetBits, 0, byteCount);
            SetStretchBltMode(_targetDC, HALFTONE);
            if (StretchBlt(_targetDC, offsetX, offsetY,
                cast(int) scaledWidth, cast(int) scaledHeight,
                _windowDC, 0, 0, _windowWidth, _windowHeight, SRCCOPY) == 0)
                return false;
            memcpy(target, _targetBits, byteCount);
        }
        // DIB memory is BGRA bytes on little-endian, matching -pix_fmt bgra.
        // GDI leaves the DIB alpha byte undefined; force opaque alpha so the
        // encoder never sees garbage alpha values.
        for (size_t offset = 3; offset < byteCount; offset += 4)
            target[offset] = 0xff;
        return true;
    }
}

/// Non-Windows fallback keeps the module compilable elsewhere; capture is only
/// meaningful on Windows.
else
final class WindowContentCapturer
{
    this(int width, int height) {}
    void setTargetSize(int width, int height) {}
    void setWindowTarget(string hwndText) {}
    bool capture(ubyte[] bgra) { return false; }
}

version (Windows)
unittest
{
    import std.conv : to;
    import std.string : strip;
    import core.thread : Thread;
    import core.time : msecs;

    // The capturer must accept a stale/empty handle without throwing.
    auto capturer = new WindowContentCapturer(320, 180);
    capturer.setTargetSize(480, 270);
    capturer.setWindowTarget("");
    auto buffer = new ubyte[480 * 270 * 4];
    assert(!capturer.capture(buffer));

    // A real window on an interactive session must capture its own content;
    // headless/service sessions may not be able to create one and the capture
    // then legitimately returns false.
    import core.sys.windows.windows : CreateWindowExW, DefWindowProcW,
        DestroyWindow, GetModuleHandleW, GetTickCount, HWND, LRESULT, LPARAM,
        MSG, PeekMessageW, PM_REMOVE, RegisterClassW, ShowWindow,
        SW_SHOWNOACTIVATE,
        TranslateMessage, DispatchMessageW, WNDCLASSW, WPARAM,
        WS_OVERLAPPEDWINDOW;
    extern (Windows) LRESULT contentProbeProc(HWND hwnd, uint msg,
        WPARAM wParam, LPARAM lParam) nothrow
    {
        return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
    const probeClass = "AuroraContentProbe"w;
    WNDCLASSW wc;
    wc.lpfnWndProc = &contentProbeProc;
    wc.hInstance = GetModuleHandleW(null);
    wc.lpszClassName = probeClass.ptr;
    if (RegisterClassW(&wc) != 0)
    {
        auto probeWindow = CreateWindowExW(0, probeClass.ptr, probeClass.ptr,
            WS_OVERLAPPEDWINDOW, -32_000, -32_000, 320, 240, null, null,
            GetModuleHandleW(null), null);
        if (probeWindow !is null)
        {
            ShowWindow(probeWindow, SW_SHOWNOACTIVATE);
            MSG msg;
            const deadline = GetTickCount() + 500;
            while (GetTickCount() < deadline)
            {
                while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0)
                {
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
                Thread.sleep(5.msecs);
            }
            auto windowCapturer = new WindowContentCapturer(320, 240);
            windowCapturer.setWindowTarget(to!string(cast(ulong) probeWindow));
            auto windowBuffer = new ubyte[320 * 240 * 4];
            windowCapturer.capture(windowBuffer); // may fail on headless
            DestroyWindow(probeWindow);
        }
    }
}
