module aurora.platform.gdi;

/**
 * Shared Win32 GDI helpers — the single "GDI way" in Aurora.
 *
 * Aurora renders its own UI with a cross-platform engine, but several programs
 * legitimately need GDI for jobs the toolkit does not cover: capturing the
 * screen or a window into pixels, drawing text through the OS font engine, and
 * filling rectangles. This module is the one place that talks to GDI for those
 * jobs, so no program has to reinvent device contexts, DIB sections, font
 * handles, or the DIB->RGBA byte swap.
 *
 * The public API never leaks Win32 handles: device contexts and window handles
 * are passed as `void*`, and colors are plain 0x00BBGGRR words (Win32 COLORREF
 * byte order). On non-Windows platforms the types and methods exist but report
 * failure, so portable callers compile and degrade cleanly.
 */

import core.stdc.string : memcpy, memset;
import core.stdc.stdlib : malloc, free;
import aurora.image : RgbaImage;

/// Rectangle in screen or client coordinates.
struct GdiRect
{
    int x;
    int y;
    int width;
    int height;

    int right() const @safe pure nothrow @nogc { return x + width; }
    int bottom() const @safe pure nothrow @nogc { return y + height; }
}

/// Subset of the Win32 DT_* text-format flags, named portably.
enum GdiTextFormat : uint
{
    left = 0x00000000,
    center = 0x00000001,
    right = 0x00000002,
    vcenter = 0x00000004,
    singleLine = 0x00000020,
    endEllipsis = 0x00008000,
}

/// A 0x00BBGGRR color (Win32 COLORREF byte order) from RGB components.
uint gdiColor(ubyte r, ubyte g, ubyte b) @safe pure nothrow @nogc
{
    return cast(uint) r | (cast(uint) g << 8) | (cast(uint) b << 16);
}

/**
 * Convert one 32bpp DIB pixel word to an RGBA word.
 *
 * A bottom/top-down DIB stores bytes as B,G,R,X on little-endian, so a word
 * reads (X<<24)|(R<<16)|(G<<8)|B. The canvas consumes bytes R,G,B,A, so the
 * red and blue channels are swapped and the alpha byte is forced opaque (GDI
 * leaves the DIB alpha byte undefined).
 */
uint dibBgrxToRgba(uint value) @safe pure nothrow @nogc
{
    return 0xff000000 |
        ((value & 0xff) << 16) |
        (((value >> 8) & 0xff) << 8) |
        ((value >> 16) & 0xff);
}

version (Windows)
{
    private import core.sys.windows.windows;
    private import core.sys.windows.shellapi : SHGetFileInfoW, SHFILEINFOW,
        SHGFI_ICON, SHGFI_LARGEICON;
    private import std.utf : toUTF16;

    // Font quality constants are not always present in the bindings.
    private enum uint gdiClearTypeQuality = 5; // CLEARTYPE_QUALITY

    // PrintWindow flags for capturing a window's own rendered content.
    private enum uint pwClientOnly = 0x00000001;
    private enum uint pwRenderFullContent = 0x00000002;

    /// Bounds of the primary monitor.
    GdiRect primaryScreenRect()
    {
        GdiRect result;
        result.width = GetSystemMetrics(SM_CXSCREEN);
        result.height = GetSystemMetrics(SM_CYSCREEN);
        return result;
    }

    /// Bounds of the whole virtual desktop (all monitors), falling back to the
    /// primary monitor when the virtual metrics are unavailable.
    GdiRect virtualScreenRect()
    {
        GdiRect result;
        result.x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        result.y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        result.width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        result.height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        if (result.width <= 0 || result.height <= 0)
        {
            result.x = 0;
            result.y = 0;
            result.width = GetSystemMetrics(SM_CXSCREEN);
            result.height = GetSystemMetrics(SM_CYSCREEN);
        }
        return result;
    }

    /// Fill `rect` in `dc` with a solid `rgb` color.
    void gdiFillRect(void* dc, GdiRect rect, uint rgb)
    {
        if (dc is null) return;
        HDC hdc = cast(HDC) dc;
        RECT r;
        r.left = rect.x; r.top = rect.y;
        r.right = rect.right; r.bottom = rect.bottom;
        auto brush = CreateSolidBrush(rgb);
        if (brush is null) return;
        FillRect(hdc, &r, brush);
        DeleteObject(brush);
    }

    /**
     * Draw `text` into `dc` inside `rect`. When `fontHandle` is null the DC's
     * current (stock) font is used, so callers that never set a font keep the
     * system default look. Background is transparent.
     */
    bool gdiDrawText(void* dc, string text, GdiRect rect, uint rgb,
        uint format = cast(uint) (GdiTextFormat.left |
            GdiTextFormat.vcenter | GdiTextFormat.singleLine),
        void* fontHandle = null)
    {
        if (dc is null) return false;
        HDC hdc = cast(HDC) dc;
        auto wide = toUTF16(text);
        wide ~= '\0';
        RECT r;
        r.left = rect.x; r.top = rect.y;
        r.right = rect.right; r.bottom = rect.bottom;
        HGDIOBJ previous = null;
        if (fontHandle !is null)
            previous = SelectObject(hdc, cast(HGDIOBJ) fontHandle);
        SetBkMode(hdc, TRANSPARENT);
        SetTextColor(hdc, rgb);
        DrawTextW(hdc, wide.ptr, -1, &r, format);
        if (previous !is null) SelectObject(hdc, previous);
        return true;
    }

    /**
     * Rasterize an HICON (`void*`) into a straight-alpha RGBA image.
     *
     * The icon's own colour bitmap is read first so the anti-aliased edges keep
     * their exact straight-alpha pixels; DrawIconEx is only the fallback for
     * legacy (mask-based) icons, whose alpha is recovered from the AND mask.
     */
    RgbaImage iconToRgba(void* iconHandle)
    {
        if (iconHandle is null) return null;
        HICON icon = cast(HICON) iconHandle;
        ICONINFO info;
        if (!GetIconInfo(icon, &info)) return null;
        scope (exit)
        {
            if (info.hbmColor !is null) DeleteObject(info.hbmColor);
            if (info.hbmMask !is null) DeleteObject(info.hbmMask);
        }

        BITMAP bm;
        if (info.hbmColor !is null)
            GetObjectW(info.hbmColor, BITMAP.sizeof, &bm);
        else
            GetObjectW(info.hbmMask, BITMAP.sizeof, &bm);
        const w = bm.bmWidth > 0 ? bm.bmWidth : 16;
        const h = bm.bmHeight > 0 ? bm.bmHeight : 16;

        if (info.hbmColor !is null)
        {
            auto rawDc = GetDC(null);
            if (rawDc !is null)
            {
                BITMAPINFO rbi;
                rbi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
                rbi.bmiHeader.biWidth = w;
                rbi.bmiHeader.biHeight = -h;
                rbi.bmiHeader.biPlanes = 1;
                rbi.bmiHeader.biBitCount = 32;
                rbi.bmiHeader.biCompression = BI_RGB;
                auto colorPixels = cast(uint*) malloc(cast(size_t) w * h * 4 + 4);
                if (colorPixels !is null)
                {
                    ubyte[] direct;
                    bool directAlpha;
                    if (GetDIBits(rawDc, info.hbmColor, 0, h, colorPixels, &rbi,
                            DIB_RGB_COLORS) > 0)
                    {
                        direct.length = cast(size_t) w * h * 4;
                        const directCount = cast(size_t) w * h;
                        foreach (i; 0 .. directCount)
                        {
                            const argb = colorPixels[i];
                            const t = i * 4;
                            direct[t + 0] = cast(ubyte) ((argb >> 16) & 0xff);
                            direct[t + 1] = cast(ubyte) ((argb >> 8) & 0xff);
                            direct[t + 2] = cast(ubyte) (argb & 0xff);
                            direct[t + 3] = cast(ubyte) ((argb >> 24) & 0xff);
                            if (direct[t + 3] != 0) directAlpha = true;
                        }
                    }
                    free(colorPixels);
                    ReleaseDC(null, rawDc);
                    if (directAlpha) return new RgbaImage(w, h, direct);
                }
                else
                    ReleaseDC(null, rawDc);
            }
        }

        auto dc = GetDC(null);
        if (dc is null) return null;
        auto memDc = CreateCompatibleDC(dc);
        auto bmp = CreateCompatibleBitmap(dc, w, h);
        if (memDc is null || bmp is null)
        {
            ReleaseDC(null, dc);
            if (memDc !is null) DeleteDC(memDc);
            return null;
        }
        auto old = SelectObject(memDc, bmp);
        DrawIconEx(memDc, 0, 0, icon, w, h, 0, null, 3 /* DI_NORMAL */);
        SelectObject(memDc, old);

        BITMAPINFO bi;
        bi.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        auto raw = cast(uint*) malloc(cast(size_t) w * h * 4 + 4);
        if (raw is null)
        {
            DeleteObject(bmp);
            DeleteDC(memDc);
            ReleaseDC(null, dc);
            return null;
        }
        int got = GetDIBits(memDc, bmp, 0, h, raw, &bi, DIB_RGB_COLORS);

        DeleteObject(bmp);
        DeleteDC(memDc);
        ReleaseDC(null, dc);

        if (got <= 0)
        {
            free(raw);
            return null;
        }
        ubyte[] rgba;
        rgba.length = cast(size_t) w * cast(size_t) h * 4;
        const count = cast(size_t) w * cast(size_t) h;
        bool anyAlpha;
        foreach (i; 0 .. count)
        {
            const argb = raw[i];
            const t = i * 4;
            rgba[t + 0] = cast(ubyte) ((argb >> 16) & 0xff);
            rgba[t + 1] = cast(ubyte) ((argb >> 8) & 0xff);
            rgba[t + 2] = cast(ubyte) (argb & 0xff);
            rgba[t + 3] = cast(ubyte) ((argb >> 24) & 0xff);
            if (rgba[t + 3] != 0) anyAlpha = true;
        }
        free(raw);

        // Legacy mask-based icons get no alpha from DrawIconEx; recover it from
        // the AND mask (1 = transparent, 0 = opaque).
        if (!anyAlpha && info.hbmColor !is null && info.hbmMask !is null)
        {
            auto maskDc = GetDC(null);
            if (maskDc !is null)
            {
                auto maskRaw = cast(uint*) malloc(count * 4 + 4);
                if (maskRaw !is null)
                {
                    if (GetDIBits(maskDc, info.hbmMask, 0, h, maskRaw, &bi,
                            DIB_RGB_COLORS) > 0)
                    {
                        foreach (i; 0 .. count)
                            rgba[i * 4 + 3] =
                                (maskRaw[i] & 0x00ffffff) != 0 ? 0 : 255;
                    }
                    free(maskRaw);
                }
                ReleaseDC(null, maskDc);
            }
        }
        return new RgbaImage(w, h, rgba);
    }

    /// The shell's large (32 px) icon for an executable or file path.
    RgbaImage shellIconForPath(string path)
    {
        if (path.length == 0) return null;
        auto wide = toUTF16(path);
        wide ~= '\0';
        SHFILEINFOW info;
        const result = SHGetFileInfoW(wide.ptr, 0, &info,
            SHFILEINFOW.sizeof, SHGFI_ICON | SHGFI_LARGEICON);
        if (result == 0 || info.hIcon is null) return null;
        scope (exit) DestroyIcon(info.hIcon);
        return iconToRgba(cast(void*) info.hIcon);
    }

    /**
     * Captures a window's OWN rendered content via
     * `PrintWindow(PW_RENDERFULLCONTENT)`, so a covered, background, or
     * off-screen window still renders (unlike a screen grab). Output is BGRA8
     * bytes — exactly what FFmpeg's `-pix_fmt bgra` rawvideo input expects, so
     * the buffer is written straight through with no channel swap. A minimized
     * window has no rendered surface, so `capture` returns false and the caller
     * keeps the last good frame.
     */
    final class WindowContentCapture
    {
        private int _width;
        private int _height;
        private HWND _window;
        private HDC _windowDc;
        private HBITMAP _windowBitmap;
        private HGDIOBJ _windowPrevious;
        private void* _windowBits;
        private int _windowWidth;
        private int _windowHeight;
        private HDC _targetDc;
        private HBITMAP _targetBitmap;
        private HGDIOBJ _targetPrevious;
        private void* _targetBits;

        this(int width, int height)
        {
            _width = width < 1 ? 1 : width;
            _height = height < 1 ? 1 : height;
        }

        ~this() { releaseWindow(); }

        int width() const @safe pure nothrow @nogc { return _width; }
        int height() const @safe pure nothrow @nogc { return _height; }

        void setOutputSize(int width, int height)
        {
            if (width <= 0 || height <= 0) return;
            if (width == _width && height == _height) return;
            _width = width;
            _height = height;
            releaseTarget();
        }

        /// Select a window by handle (void*); null reverts to "no window".
        void setWindow(void* window)
        {
            _window = cast(HWND) window;
            releaseWindow();
        }

        bool capture(ref ubyte[] bgra)
        {
            const size_t need = cast(size_t) _width * _height * 4;
            if (bgra.length < need) return false;
            if (_window is null) return false;
            if (IsWindow(_window) == 0) return false;
            if (IsIconic(_window) != 0) return false;
            if (!ensureWindow()) return false;

            // PrintWindow may skip some composited surfaces; clear first so any
            // region it leaves untouched is black, not stale DIB data.
            memset(_windowBits, 0,
                cast(size_t) _windowWidth * _windowHeight * 4);
            if (PrintWindow(_window, _windowDc,
                pwClientOnly | pwRenderFullContent) == 0)
                return false;

            auto target = cast(ubyte*) bgra.ptr;
            if (_windowWidth == _width && _windowHeight == _height)
            {
                memcpy(target, _windowBits, need);
            }
            else
            {
                if (!ensureTarget()) return false;
                ulong scaledWidth = _width;
                ulong scaledHeight = cast(ulong) _width * _windowHeight /
                    _windowWidth;
                if (scaledHeight > _height)
                {
                    scaledHeight = _height;
                    scaledWidth = cast(ulong) _height * _windowWidth /
                        _windowHeight;
                }
                if (scaledWidth == 0 || scaledHeight == 0) return false;
                const offsetX = (_width - cast(int) scaledWidth) / 2;
                const offsetY = (_height - cast(int) scaledHeight) / 2;
                memset(_targetBits, 0, need);
                SetStretchBltMode(_targetDc, HALFTONE);
                if (StretchBlt(_targetDc, offsetX, offsetY,
                    cast(int) scaledWidth, cast(int) scaledHeight,
                    _windowDc, 0, 0, _windowWidth, _windowHeight, SRCCOPY) == 0)
                    return false;
                memcpy(target, _targetBits, need);
            }
            // GDI leaves DIB alpha undefined; force opaque for the encoder.
            for (size_t offset = 3; offset < need; offset += 4)
                target[offset] = 0xff;
            return true;
        }

        private bool ensureWindow()
        {
            if (_window is null) return false;
            RECT rect;
            if (GetClientRect(_window, &rect) == 0) return false;
            const width = rect.right - rect.left;
            const height = rect.bottom - rect.top;
            if (width <= 0 || height <= 0) return false;
            if (_windowDc !is null && width == _windowWidth &&
                height == _windowHeight)
                return _windowBits !is null;
            releaseWindow();
            HDC screenDc = GetDC(null);
            if (screenDc is null) return false;
            scope (exit) ReleaseDC(null, screenDc);
            _windowDc = CreateCompatibleDC(screenDc);
            if (_windowDc is null) return false;
            BITMAPINFO info;
            info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            info.bmiHeader.biWidth = width;
            info.bmiHeader.biHeight = -height;
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            _windowBitmap = CreateDIBSection(_windowDc, &info, DIB_RGB_COLORS,
                &_windowBits, null, 0);
            if (_windowBitmap is null) return false;
            _windowPrevious = SelectObject(_windowDc,
                cast(HGDIOBJ) _windowBitmap);
            _windowWidth = width;
            _windowHeight = height;
            return _windowBits !is null;
        }

        private bool ensureTarget()
        {
            if (_targetDc !is null && _targetBits !is null) return true;
            HDC screenDc = GetDC(null);
            if (screenDc is null) return false;
            scope (exit) ReleaseDC(null, screenDc);
            _targetDc = CreateCompatibleDC(screenDc);
            if (_targetDc is null) return false;
            BITMAPINFO info;
            info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            info.bmiHeader.biWidth = _width;
            info.bmiHeader.biHeight = -_height;
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            _targetBitmap = CreateDIBSection(_targetDc, &info, DIB_RGB_COLORS,
                &_targetBits, null, 0);
            if (_targetBitmap is null) return false;
            _targetPrevious = SelectObject(_targetDc,
                cast(HGDIOBJ) _targetBitmap);
            return _targetBits !is null;
        }

        private void releaseTarget()
        {
            if (_targetDc !is null && _targetPrevious !is null)
                SelectObject(_targetDc, _targetPrevious);
            _targetPrevious = null;
            if (_targetBitmap !is null) DeleteObject(_targetBitmap);
            _targetBitmap = null;
            _targetBits = null;
            if (_targetDc !is null) DeleteDC(_targetDc);
            _targetDc = null;
        }

        private void releaseWindow()
        {
            if (_windowDc !is null && _windowPrevious !is null)
                SelectObject(_windowDc, _windowPrevious);
            _windowPrevious = null;
            if (_windowBitmap !is null) DeleteObject(_windowBitmap);
            _windowBitmap = null;
            _windowBits = null;
            if (_windowDc !is null) DeleteDC(_windowDc);
            _windowDc = null;
            _windowWidth = 0;
            _windowHeight = 0;
            releaseTarget();
        }
    }

    /**
     * Scales an in-memory BGRA frame into a BGRA buffer, aspect-fit, using GDI's
     * HALFTONE resampler. Used by capture paths before handing frames to the
     * encoder; the memory-DC/DIB plumbing is shared here, not per program.
     */
    final class BgraFrameScaler
    {
        private int _width;
        private int _height;
        private HDC _dc;
        private HBITMAP _bitmap;
        private HGDIOBJ _previous;
        private void* _bits;

        this(int width, int height)
        {
            _width = width;
            _height = height;
        }

        ~this() { close(); }

        int width() const @safe pure nothrow @nogc { return _width; }
        int height() const @safe pure nothrow @nogc { return _height; }

        void setOutputSize(int width, int height)
        {
            if (width <= 0 || height <= 0) return;
            if (width == _width && height == _height) return;
            _width = width;
            _height = height;
            close();
        }

        void close()
        {
            if (_dc !is null && _previous !is null) SelectObject(_dc, _previous);
            _previous = null;
            if (_bitmap !is null) DeleteObject(_bitmap);
            _bitmap = null;
            _bits = null;
            if (_dc !is null) DeleteDC(_dc);
            _dc = null;
        }

        private bool ensure()
        {
            if (_dc !is null && _bits !is null) return true;
            HDC screenDc = GetDC(null);
            if (screenDc is null) return false;
            scope (exit) ReleaseDC(null, screenDc);
            _dc = CreateCompatibleDC(screenDc);
            if (_dc is null) return false;
            BITMAPINFO info;
            info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            info.bmiHeader.biWidth = _width;
            info.bmiHeader.biHeight = -_height;
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            _bitmap = CreateDIBSection(_dc, &info, DIB_RGB_COLORS, &_bits,
                null, 0);
            if (_bitmap is null || _bits is null) return false;
            _previous = SelectObject(_dc, cast(HGDIOBJ) _bitmap);
            SetStretchBltMode(_dc, HALFTONE);
            return _previous !is null;
        }

        /// Aspect-fits `source` (srcW*srcH*4 BGRA bytes) into `target`
        /// (_width*_height*4 BGRA bytes). Returns false on bad input.
        bool fit(const(ubyte)[] source, int srcW, int srcH, ubyte[] target)
        {
            const size_t targetBytes = cast(size_t) _width * _height * 4;
            if (srcW <= 0 || srcH <= 0 ||
                source.length < cast(size_t) srcW * srcH * 4 ||
                target.length < targetBytes)
                return false;
            if (srcW == _width && srcH == _height)
            {
                memcpy(target.ptr, source.ptr, targetBytes);
                return true;
            }
            if (!ensure()) return false;
            ulong scaledWidth = _width;
            ulong scaledHeight = cast(ulong) _width * srcH / srcW;
            if (scaledHeight > _height)
            {
                scaledHeight = _height;
                scaledWidth = cast(ulong) _height * srcW / srcH;
            }
            if (scaledWidth == 0 || scaledHeight == 0) return false;
            const offsetX = (_width - cast(int) scaledWidth) / 2;
            const offsetY = (_height - cast(int) scaledHeight) / 2;
            BITMAPINFO sourceInfo;
            sourceInfo.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            sourceInfo.bmiHeader.biWidth = srcW;
            sourceInfo.bmiHeader.biHeight = -srcH;
            sourceInfo.bmiHeader.biPlanes = 1;
            sourceInfo.bmiHeader.biBitCount = 32;
            sourceInfo.bmiHeader.biCompression = BI_RGB;
            memset(_bits, 0, targetBytes);
            const copiedLines = StretchDIBits(_dc, offsetX, offsetY,
                cast(int) scaledWidth, cast(int) scaledHeight, 0, 0,
                srcW, srcH, cast(const(void)*) source.ptr, &sourceInfo,
                DIB_RGB_COLORS, SRCCOPY);
            if (copiedLines == 0 || copiedLines == cast(int) GDI_ERROR)
                return false;
            memcpy(target.ptr, _bits, targetBytes);
            return true;
        }
    }

    /**
     * A reusable OS font drawn through GDI's own text engine.
     *
     * This is the "use the OS renderer" counterpart to Aurora's cross-platform
     * text stack. It is intended for native surfaces (owner-drawn Win32 windows,
     * the pre-launch rebuild splash, tray menus) where matching the OS text look
     * matters more than portability.
     */
    final class GdiFont
    {
        private HFONT _font;

        /// `pixelHeight` is the EM height in pixels (negative = character height).
        this(string family, int pixelHeight, bool bold = false,
            bool italic = false)
        {
            const height = pixelHeight < 1 ? 1 : pixelHeight;
            auto face = toUTF16(family);
            face ~= '\0';
            _font = CreateFontW(-height, 0, 0, 0, bold ? 700 : 400,
                italic ? TRUE : FALSE, FALSE, FALSE, DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, gdiClearTypeQuality,
                DEFAULT_PITCH | FF_DONTCARE, face.ptr);
        }

        ~this()
        {
            if (_font !is null) DeleteObject(_font);
        }

        bool valid() const @safe pure nothrow @nogc { return _font !is null; }

        /// Raw font handle (HFONT) for callers that must pass it to other GDI
        /// calls; prefer `drawText`/`measureWidth`.
        void* handle() const @safe pure nothrow @nogc
        {
            return cast(void*) _font;
        }

        /// Draw `text` into `dc` inside `rect`. The font is selected and
        /// restored around the call. Returns false if `dc` or the font is null.
        bool drawText(void* dc, string text, GdiRect rect, uint rgb,
            uint format = cast(uint) (GdiTextFormat.left |
                GdiTextFormat.vcenter | GdiTextFormat.singleLine))
        {
            if (dc is null || _font is null) return false;
            return gdiDrawText(dc, text, rect, rgb, format, cast(void*) _font);
        }

        /// Width in pixels of `text` in this font (single line).
        int measureWidth(void* dc, string text)
        {
            if (dc is null || _font is null) return 0;
            HDC hdc = cast(HDC) dc;
            auto wide = toUTF16(text);
            auto previous = SelectObject(hdc, cast(HGDIOBJ) _font);
            SIZE size;
            GetTextExtentPoint32W(hdc, wide.ptr, cast(int) wide.length, &size);
            if (previous !is null) SelectObject(hdc, previous);
            return size.cx;
        }
    }

    /**
     * A reusable screen/window capturer backed by a 32bpp top-down DIB section.
     *
     * The memory DC, bitmap, and stretch mode are created once and reused, so a
     * capture loop pays no per-frame GDI object churn. Output is RGBA8 bytes.
     * By default the source is stretched to fill the output; enable aspect-fit
     * to letterbox instead, and window captures can read the client area either
     * from the on-screen pixels or from the window's own device context.
     */
    final class ScreenCapture
    {
        private int _width;
        private int _height;
        private HDC _memDc;
        private HBITMAP _bitmap;
        private HGDIOBJ _previous;
        private void* _bits;
        private bool _useVirtual;
        private bool _aspectFit;
        private HWND _window;
        private bool _windowClient;
        private bool _windowDeviceContext;

        this(int width, int height)
        {
            setOutputSize(width, height);
        }

        ~this() { releaseBuffer(); }

        int width() const @safe pure nothrow @nogc { return _width; }
        int height() const @safe pure nothrow @nogc { return _height; }

        /// Set the output size; the DIB is rebuilt on the next capture.
        void setOutputSize(int width, int height)
        {
            if (width <= 0 || height <= 0) return;
            if (width == _width && height == _height && _bitmap !is null) return;
            _width = width;
            _height = height;
            releaseBuffer();
        }

        /// When true, the source is centered and letterboxed instead of
        /// stretched to fill; the bars are black.
        void setAspectFit(bool value) @safe pure nothrow @nogc
        {
            _aspectFit = value;
        }

        /// Capture the whole virtual desktop (all monitors).
        void captureVirtualScreen()
        {
            _window = null;
            _useVirtual = true;
            releaseBuffer();
        }

        /// Capture the primary monitor.
        void capturePrimaryScreen()
        {
            _window = null;
            _useVirtual = false;
            releaseBuffer();
        }

        /// Capture a window. `clientOnly` limits to the client area;
        /// `useWindowDeviceContext` reads through the window's own DC (so the
        /// result is correct even when the window is occluded) instead of
        /// copying its on-screen pixels.
        void captureWindow(void* window, bool clientOnly = false,
            bool useWindowDeviceContext = false)
        {
            _window = cast(HWND) window;
            _windowClient = clientOnly;
            _windowDeviceContext = useWindowDeviceContext;
            releaseBuffer();
        }

        /// Whether the last capture produced a usable frame.
        bool ready() const @safe pure nothrow @nogc { return _bitmap !is null; }

        /// Capture one frame into `rgba` (length at least width*height*4).
        /// Returns false when the source is unavailable or the buffer is small.
        bool capture(ref ubyte[] rgba)
        {
            const size_t needed = cast(size_t) _width * cast(size_t) _height * 4;
            if (rgba.length < needed) return false;
            if (!ensureBuffer()) return false;

            HDC sourceDc;
            HWND releaseTarget = null;
            int srcX;
            int srcY;
            int srcW;
            int srcH;
            if (_window !is null)
            {
                if (IsIconic(_window)) return false;
                if (_windowDeviceContext)
                {
                    RECT cr;
                    GetClientRect(_window, &cr);
                    srcX = 0; srcY = 0;
                    srcW = cr.right - cr.left;
                    srcH = cr.bottom - cr.top;
                    sourceDc = GetDC(_window);
                    releaseTarget = _window;
                }
                else
                {
                    RECT wr;
                    GetWindowRect(_window, &wr);
                    RECT cr;
                    GetClientRect(_window, &cr);
                    srcW = _windowClient ? cr.right - cr.left : wr.right - wr.left;
                    srcH = _windowClient ? cr.bottom - cr.top : wr.bottom - wr.top;
                    if (_windowClient)
                    {
                        POINT pt;
                        pt.x = 0; pt.y = 0;
                        ClientToScreen(_window, &pt);
                        srcX = pt.x; srcY = pt.y;
                    }
                    else
                    {
                        srcX = wr.left; srcY = wr.top;
                    }
                    sourceDc = GetDC(null);
                }
            }
            else
            {
                if (_useVirtual)
                {
                    const r = virtualScreenRect();
                    srcX = r.x; srcY = r.y;
                    srcW = r.width; srcH = r.height;
                }
                else
                {
                    srcX = 0; srcY = 0;
                    srcW = GetSystemMetrics(SM_CXSCREEN);
                    srcH = GetSystemMetrics(SM_CYSCREEN);
                }
                sourceDc = GetDC(null);
            }
            if (sourceDc is null) return false;
            scope (exit) ReleaseDC(releaseTarget, sourceDc);
            if (srcW <= 0 || srcH <= 0) return false;

            if (_aspectFit)
            {
                int dstW = _width;
                int dstH = cast(int) (cast(long) _width * srcH / srcW);
                if (dstH > _height)
                {
                    dstH = _height;
                    dstW = cast(int) (cast(long) _height * srcW / srcH);
                }
                const dstX = (_width - dstW) / 2;
                const dstY = (_height - dstH) / 2;
                memset(_bits, 0, cast(size_t) _width * _height * 4);
                if (StretchBlt(_memDc, dstX, dstY, dstW, dstH, sourceDc,
                    srcX, srcY, srcW, srcH, SRCCOPY) == 0)
                    return false;
            }
            else if (StretchBlt(_memDc, 0, 0, _width, _height, sourceDc,
                srcX, srcY, srcW, srcH, SRCCOPY) == 0)
                return false;
            return convert(rgba);
        }

        /// Allocate and fill a fresh RGBA buffer for one frame (null on failure).
        ubyte[] captureFrame()
        {
            auto rgba = new ubyte[cast(size_t) _width * cast(size_t) _height * 4];
            return capture(rgba) ? rgba : null;
        }

        private bool ensureBuffer()
        {
            if (_bitmap !is null) return true;
            HDC screenDc = GetDC(null);
            if (screenDc is null) return false;
            scope (exit) ReleaseDC(null, screenDc);
            _memDc = CreateCompatibleDC(screenDc);
            if (_memDc is null) return false;
            BITMAPINFO info;
            info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            info.bmiHeader.biWidth = _width;
            info.bmiHeader.biHeight = -_height; // top-down rows
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            _bitmap = CreateDIBSection(_memDc, &info, DIB_RGB_COLORS, &_bits,
                null, 0);
            if (_bitmap is null)
            {
                DeleteDC(_memDc);
                _memDc = null;
                return false;
            }
            _previous = SelectObject(_memDc, cast(HGDIOBJ) _bitmap);
            SetStretchBltMode(_memDc, COLORONCOLOR);
            return true;
        }

        /// Convert the 32bpp DIB (BGRX) into RGBA8 bytes.
        private bool convert(ubyte[] rgba)
        {
            if (_bits is null) return false;
            const size_t count = cast(size_t) _width * cast(size_t) _height;
            auto source = cast(const(uint)*) _bits;
            auto target = cast(uint*) rgba.ptr;
            foreach (i; 0 .. count)
                target[i] = dibBgrxToRgba(source[i]);
            return true;
        }

        private void releaseBuffer()
        {
            if (_memDc !is null && _previous !is null)
                SelectObject(_memDc, _previous);
            _previous = null;
            if (_bitmap !is null) DeleteObject(_bitmap);
            _bitmap = null;
            _bits = null;
            if (_memDc !is null) DeleteDC(_memDc);
            _memDc = null;
        }
    }
}
else
{
    // Non-Windows stubs: same surface, reports failure.
    GdiRect primaryScreenRect() { return GdiRect(); }
    GdiRect virtualScreenRect() { return GdiRect(); }
    void gdiFillRect(void* dc, GdiRect rect, uint rgb) {}

    final class GdiFont
    {
        this(string family, int pixelHeight, bool bold = false,
            bool italic = false)
        {
        }
        bool valid() const @safe pure nothrow @nogc { return false; }
        void* handle() const @safe pure nothrow @nogc { return null; }
        bool drawText(void* dc, string text, GdiRect rect, uint rgb,
            uint format = 0)
        {
            return false;
        }
        int measureWidth(void* dc, string text) { return 0; }
    }

    final class ScreenCapture
    {
        private int _width;
        private int _height;
        this(int width, int height) { _width = width; _height = height; }
        int width() const @safe pure nothrow @nogc { return _width; }
        int height() const @safe pure nothrow @nogc { return _height; }
        void setOutputSize(int width, int height)
        {
            _width = width;
            _height = height;
        }
        void setAspectFit(bool value) @safe pure nothrow @nogc {}
        void captureVirtualScreen() {}
        void capturePrimaryScreen() {}
        void captureWindow(void* window, bool clientOnly = false,
            bool useWindowDeviceContext = false)
        {
        }
        bool ready() const @safe pure nothrow @nogc { return false; }
        bool capture(ref ubyte[] rgba) { return false; }
        ubyte[] captureFrame() { return null; }
    }

    final class WindowContentCapture
    {
        private int _width;
        private int _height;
        this(int width, int height) { _width = width; _height = height; }
        int width() const @safe pure nothrow @nogc { return _width; }
        int height() const @safe pure nothrow @nogc { return _height; }
        void setOutputSize(int width, int height)
        {
            _width = width;
            _height = height;
        }
        void setWindow(void* window) {}
        bool capture(ref ubyte[] bgra) { return false; }
    }

    final class BgraFrameScaler
    {
        private int _width;
        private int _height;
        this(int width, int height) { _width = width; _height = height; }
        int width() const @safe pure nothrow @nogc { return _width; }
        int height() const @safe pure nothrow @nogc { return _height; }
        void setOutputSize(int width, int height)
        {
            _width = width;
            _height = height;
        }
        void close() {}
        bool fit(const(ubyte)[] source, int srcW, int srcH, ubyte[] target)
        {
            return false;
        }
    }
}

version (unittest)
{
    @safe pure nothrow @nogc unittest
    {
        // A DIB stores bytes B,G,R,X; the canvas needs R,G,B,A. Values below are
        // little-endian 32-bit words, so byte0 is the low byte.
        assert(dibBgrxToRgba(0x00ff0000) == 0xff0000ff); // DIB red   -> RGBA red
        assert(dibBgrxToRgba(0x0000ff00) == 0xff00ff00); // DIB green -> RGBA green
        assert(dibBgrxToRgba(0x000000ff) == 0xffff0000); // DIB blue  -> RGBA blue
        assert(dibBgrxToRgba(0x00505050) == 0xff505050); // gray stays gray
    }
}
