module aurorastream.desktoppreview;

import aurora.image : RgbaImage;

version (Windows)
{
    import core.sys.windows.windows : BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        COLORONCOLOR, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject,
        DIB_RGB_COLORS, GetClientRect, GetDC, GetSystemMetrics, HBITMAP, HDC,
        HGDIOBJ, HWND, IsIconic, RECT, ReleaseDC, SelectObject, SetStretchBltMode,
        SM_CXSCREEN, SM_CYSCREEN, SRCCOPY, StretchBlt;
    import aurorastream.windowsources : hwndFromText;
}

/// Maps one 32bpp DIB pixel word (memory bytes B,G,R,undefined alpha on
/// little-endian) into the RGBA word the canvas consumes (memory bytes R,G,B,A).
private uint dibPixelToRgbaWord(uint value) @safe pure nothrow @nogc
{
    const red = (value >> 16) & 0xff;
    const green = (value >> 8) & 0xff;
    const blue = value & 0xff;
    return 0xff000000 | (blue << 16) | (green << 8) | red;
}

/// Reusable GDI screen-capture state for the live source preview. The memory
/// DC, DIB section, and stretch mode are created once and reused across frames
/// so a 30 FPS preview never pays per-frame GDI object churn, and COLORONCOLOR
/// avoids the expensive software dithering that HALFTONE performs on every
/// downscale.
version (Windows)
final class DesktopPreviewCapturer
{
    private int _width;
    private int _height;
    private HDC _memoryDC;
    private HBITMAP _bitmap;
    private HGDIOBJ _previous;
    private void* _bits;
    private int _screenWidth;
    private int _screenHeight;
    private string _windowTargetText;
    private HWND _windowTarget;

    this(int width, int height)
    {
        _width = width;
        _height = height;
    }

    ~this()
    {
        releaseDeviceObjects();
    }

    /// Changes the captured output size. The DIB is recreated on the next
    /// capture so the preview can track its panel size for a sharp 1:1 view.
    void setTargetSize(int width, int height)
    {
        if (width <= 0 || height <= 0) return;
        if (width == _width && height == _height) return;
        _width = width;
        _height = height;
        releaseDeviceObjects();
    }

    /// Captures a single window (game/window capture) instead of the desktop.
    /// An empty or stale handle reverts to the primary monitor. The handle text
    /// is re-parsed only when it changes, so a 30 FPS loop stays cheap.
    void setWindowTarget(string hwndText)
    {
        if (hwndText == _windowTargetText) return;
        _windowTargetText = hwndText.idup;
        _windowTarget = hwndFromText(hwndText);
        releaseDeviceObjects();
    }

    private void releaseDeviceObjects()
    {
        if (_memoryDC !is null && _previous !is null)
            SelectObject(_memoryDC, _previous);
        _previous = null;
        if (_bitmap !is null)
            DeleteObject(_bitmap);
        _bitmap = null;
        _bits = null;
        if (_memoryDC !is null)
            DeleteDC(_memoryDC);
        _memoryDC = null;
    }

    private void ensureScreen()
    {
        const screenWidth = GetSystemMetrics(SM_CXSCREEN);
        const screenHeight = GetSystemMetrics(SM_CYSCREEN);
        if (_bitmap !is null && screenWidth == _screenWidth &&
            screenHeight == _screenHeight)
            return;
        _screenWidth = screenWidth;
        _screenHeight = screenHeight;
        releaseDeviceObjects();
        if (screenWidth <= 0 || screenHeight <= 0) return;

        HDC screenDC = GetDC(null);
        if (screenDC is null) return;
        scope (exit) ReleaseDC(null, screenDC);

        _memoryDC = CreateCompatibleDC(screenDC);
        if (_memoryDC is null) return;

        BITMAPINFOHEADER header;
        header.biSize = BITMAPINFOHEADER.sizeof;
        header.biWidth = _width;
        header.biHeight = -_height; // Top-down rows for a natural y order.
        header.biPlanes = 1;
        header.biBitCount = 32;
        header.biCompression = BI_RGB;
        BITMAPINFO info;
        info.bmiHeader = header;

        _bitmap = CreateDIBSection(_memoryDC, &info, DIB_RGB_COLORS, &_bits,
            null, 0);
        if (_bitmap is null) return;
        _previous = SelectObject(_memoryDC, cast(HGDIOBJ) _bitmap);
        SetStretchBltMode(_memoryDC, COLORONCOLOR);
    }

    /// Copies the current frame (the selected window, or the primary monitor
    /// when no window is selected) scaled to the configured preview size into
    /// `rgba` as RGBA8 bytes. Returns false when the source cannot be captured
    /// or the buffer is too small.
    bool capture(ubyte[] rgba)
    {
        if (rgba.length < cast(size_t) _width * _height * 4) return false;
        ensureScreen();
        if (_bitmap is null || _memoryDC is null || _bits is null) return false;

        HDC sourceDC;
        int sourceWidth;
        int sourceHeight;
        if (_windowTarget !is null)
        {
            // A minimized window cannot be captured (its client area is 0×0);
            // skip the frame so the preview keeps the last good one instead of
            // showing a stale or broken capture.
            if (IsIconic(_windowTarget) != 0) return false;
            sourceDC = GetDC(_windowTarget);
            if (sourceDC is null) return false;
            RECT client;
            if (GetClientRect(_windowTarget, &client) == 0)
            {
                ReleaseDC(_windowTarget, sourceDC);
                return false;
            }
            sourceWidth = client.right;
            sourceHeight = client.bottom;
        }
        else
        {
            sourceDC = GetDC(null);
            if (sourceDC is null) return false;
            sourceWidth = _screenWidth;
            sourceHeight = _screenHeight;
        }
        scope (exit) ReleaseDC(_windowTarget, sourceDC);

        if (sourceWidth <= 0 || sourceHeight <= 0) return false;
        if (StretchBlt(_memoryDC, 0, 0, _width, _height,
            sourceDC, 0, 0, sourceWidth, sourceHeight,
            SRCCOPY) == 0)
            return false;

        const pixelCount = _width * _height;
        auto source = cast(uint*) _bits;
        auto target = cast(uint*) rgba.ptr;
        foreach (index; 0 .. pixelCount)
        {
            // 32bpp DIB rows are BGRA bytes on little-endian; the canvas
            // consumes RGBA bytes, so rebuild each word and force an opaque
            // alpha (GDI leaves the DIB alpha byte undefined).
            target[index] = dibPixelToRgbaWord(source[index]);
        }
        return true;
    }
}

/// One-shot capture convenience used by tests; the live preview keeps a
/// persistent `DesktopPreviewCapturer` instead so no GDI objects are recreated
/// per frame.
version (Windows)
RgbaImage captureDesktopPreview(int targetWidth = 480, int targetHeight = 270)
{
    if (targetWidth <= 0 || targetHeight <= 0) return null;
    auto capturer = new DesktopPreviewCapturer(targetWidth, targetHeight);
    auto rgba = new ubyte[cast(size_t) targetWidth * targetHeight * 4];
    if (!capturer.capture(rgba)) return null;
    return new RgbaImage(targetWidth, targetHeight, rgba);
}

version (Windows)
unittest
{
    // A DIB stores byte0=blue, byte1=green, byte2=red; the canvas needs
    // byte0=red, byte1=green, byte2=blue. RGBA words below are shown as
    // little-endian 32-bit values (byte0 is the low byte, byte3 the alpha).
    assert(dibPixelToRgbaWord(0x00ff0000) == 0xff0000ff); // DIB red -> RGBA red
    assert(dibPixelToRgbaWord(0x0000ff00) == 0xff00ff00); // DIB green -> RGBA green
    assert(dibPixelToRgbaWord(0x000000ff) == 0xffff0000); // DIB blue -> RGBA blue
    assert(dibPixelToRgbaWord(0x00505050) == 0xff505050); // gray stays gray

    // On an interactive desktop session a real capture must return the
    // requested 16:9 image; headless/service sessions may fail and return null.
    auto frame = captureDesktopPreview(480, 270);
    if (frame !is null)
    {
        assert(frame.width() == 480);
        assert(frame.height() == 270);
    }
}
