module aurorarecorder.capture;

/**
 * Win32 desktop capture: one GDI `BitBlt` per frame into a top-down 32-bit
 * DIB.
 *
 * The DIB is `BI_RGB` (BGRA, 4 bytes per pixel), so a whole frame is handed
 * to ffmpeg as `-pix_fmt bgra` with no conversion in D.
 *
 * `CAPTUREBLT` is deliberately *not* used: it forces DWM to include layered
 * and translucent windows, which is slower and flattens some surfaces. A
 * locked workstation or secure desktop simply yields a black frame and
 * capture keeps running.
 *
 * The surface is created, captured and closed on the encoder's own thread so
 * the GDI device context is never shared between threads.
 */

import aurorarecorder.settings : CaptureRect;

version (Windows)
{
    import core.sys.windows.windows : BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        BitBlt, CreateCompatibleDC, CreateDIBSection, CURSORINFO,
        CURSOR_SHOWING, DrawIconEx, DI_NORMAL, DIB_RGB_COLORS,
        DeleteDC, DeleteObject, GdiFlush, GetCursorInfo, GetDC,
        GetSystemMetrics, HBITMAP, HDC, HGDIOBJ, ReleaseDC, SRCCOPY,
        SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
        SM_YVIRTUALSCREEN, SelectObject;
}

/// A screen-sized top-down BGRA surface shared with GDI. Create once per
/// recording and reuse for every frame; `captureInto` overwrites it whole.
version (Windows)
final class ScreenSurface
{
    private HDC _screenDc;
    private HDC _memoryDc;
    private HBITMAP _bitmap;
    private HGDIOBJ _previousBitmap;
    private void* _pixels;
    private CaptureRect _rect;

    /// Create the surface for `rect`. False (object left closed) when the
    /// memory DC or the DIB could not be created.
    bool open(CaptureRect rect)
    {
        close();
        if (!rect.valid()) return false;

        _rect = rect;
        _screenDc = GetDC(null);
        if (_screenDc is null) return false;

        _memoryDc = CreateCompatibleDC(_screenDc);
        if (_memoryDc is null)
        {
            close();
            return false;
        }

        BITMAPINFO info;
        info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
        info.bmiHeader.biWidth = rect.width;
        // Negative height selects a top-down DIB, matching rawvideo's row
        // order, so ffmpeg needs no vertical flip.
        info.bmiHeader.biHeight = -rect.height;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;

        _bitmap = CreateDIBSection(_screenDc, &info, DIB_RGB_COLORS, &_pixels,
            null, 0);
        if (_bitmap is null || _pixels is null)
        {
            close();
            return false;
        }

        _previousBitmap = SelectObject(_memoryDc, _bitmap);
        return true;
    }

    bool active() const { return _memoryDc !is null && _pixels !is null; }

    CaptureRect rect() const { return _rect; }

    /// Bytes in one frame (width * height * 4).
    size_t frameBytes() const
    {
        return cast(size_t) _rect.width * cast(size_t) _rect.height * 4;
    }

    /// The BGRA pixel buffer; valid until `close()`.
    void* pixels() { return _pixels; }

    /// Copy the screen region into the buffer. False on GDI failure.
    bool captureInto()
    {
        if (!active()) return false;
        if (BitBlt(_memoryDc, 0, 0, _rect.width, _rect.height, _screenDc,
            _rect.x, _rect.y, SRCCOPY) == 0)
            return false;
        if (_drawCursor) drawCursor();
        // GDI flushes lazily; the pixels are read right after this returns,
        // from the same thread, so wait for the copy to land.
        GdiFlush();
        return true;
    }

    /// Include the mouse pointer in captured frames.
    void setDrawCursor(bool value) { _drawCursor = value; }

    private bool _drawCursor;

    /**
     * Composite the current pointer into the frame with `DrawIconEx`.
     *
     * `BitBlt` never includes the pointer, and asking ffmpeg's gdigrab to draw
     * it would hand the capture to a child process that cannot be stopped
     * without losing the MP4 trailer. Drawing it here keeps capture in this
     * process, where closing stdin ends the recording cleanly.
     */
    private void drawCursor()
    {
        CURSORINFO info;
        info.cbSize = CURSORINFO.sizeof;
        if (GetCursorInfo(&info) == 0) return;
        if ((info.flags & CURSOR_SHOWING) == 0) return;
        if (info.hCursor is null) return;

        // Screen coordinates to frame coordinates.
        int x = cast(int) info.ptScreenPos.x - _rect.x;
        int y = cast(int) info.ptScreenPos.y - _rect.y;
        if (x < 0 || y < 0 || x >= _rect.width || y >= _rect.height) return;
        DrawIconEx(_memoryDc, x, y, info.hCursor, 0, 0, 0, null, DI_NORMAL);
    }

    void close()
    {
        if (_memoryDc !is null && _previousBitmap !is null)
        {
            SelectObject(_memoryDc, _previousBitmap);
            _previousBitmap = null;
        }
        if (_bitmap !is null)
        {
            DeleteObject(_bitmap);
            _bitmap = null;
        }
        if (_memoryDc !is null)
        {
            DeleteDC(_memoryDc);
            _memoryDc = null;
        }
        if (_screenDc !is null)
        {
            ReleaseDC(null, _screenDc);
            _screenDc = null;
        }
        _pixels = null;
        _rect = CaptureRect.init;
    }
}

else
final class ScreenSurface
{
    bool open(CaptureRect) { return false; }
    bool active() const { return false; }
    CaptureRect rect() const { return CaptureRect.init; }
    size_t frameBytes() const { return 0; }
    void* pixels() const { return null; }
    bool captureInto() { return false; }
    void close() {}
}

/// Virtual-desktop origin and size in physical pixels.
void virtualScreenBounds(out int x, out int y, out int width, out int height)
{
    version (Windows)
    {
        x = GetSystemMetrics(SM_XVIRTUALSCREEN);
        y = GetSystemMetrics(SM_YVIRTUALSCREEN);
        width = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        height = GetSystemMetrics(SM_CYVIRTUALSCREEN);
    }
    else
    {
        x = y = width = height = 0;
    }
}
