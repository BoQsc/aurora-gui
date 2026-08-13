module aurorastream.desktoppreview;

import aurora.image : RgbaImage;

version (Windows)
{
    import core.sys.windows.windows : BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, DIB_RGB_COLORS,
        GetDC, GetSystemMetrics, HALFTONE, HBITMAP, HDC, HGDIOBJ, POINT, ReleaseDC,
        SelectObject, SetBrushOrgEx, SetStretchBltMode, SM_CXSCREEN, SM_CYSCREEN,
        SRCCOPY, StretchBlt;
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

/// Captures the primary monitor scaled into a small RGBA8 preview image, or
/// null when the screen cannot be captured (locked session, no desktop, ...).
/// This is the live "what we are recording" source preview shown beside the
/// broadcaster controls; it mirrors the ddagrab output_idx=0 primary-monitor
/// capture used by the live stream.
version (Windows)
RgbaImage captureDesktopPreview(int targetWidth = 480, int targetHeight = 270)
{
    const screenWidth = GetSystemMetrics(SM_CXSCREEN);
    const screenHeight = GetSystemMetrics(SM_CYSCREEN);
    if (screenWidth <= 0 || screenHeight <= 0 ||
        targetWidth <= 0 || targetHeight <= 0)
        return null;

    HDC screenDC = GetDC(null);
    if (screenDC is null) return null;
    scope (exit) ReleaseDC(null, screenDC);

    HDC memoryDC = CreateCompatibleDC(screenDC);
    if (memoryDC is null) return null;
    scope (exit) DeleteDC(memoryDC);

    BITMAPINFOHEADER header;
    header.biSize = BITMAPINFOHEADER.sizeof;
    header.biWidth = targetWidth;
    header.biHeight = -targetHeight; // Top-down rows for a natural y order.
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = BI_RGB;
    BITMAPINFO info;
    info.bmiHeader = header;

    void* bits;
    HBITMAP bitmap = CreateDIBSection(memoryDC, &info, DIB_RGB_COLORS, &bits,
        null, 0);
    if (bitmap is null || bits is null) return null;
    scope (exit) DeleteObject(bitmap);

    HGDIOBJ previous = SelectObject(memoryDC, cast(HGDIOBJ) bitmap);
    scope (exit) SelectObject(memoryDC, previous);

    // HALFTONE smooths the downscale instead of nearest-neighbor. MSDN
    // requires a SetBrushOrgEx call after selecting HALFTONE mode.
    SetStretchBltMode(memoryDC, HALFTONE);
    POINT brushOrigin;
    SetBrushOrgEx(memoryDC, 0, 0, &brushOrigin);
    if (StretchBlt(memoryDC, 0, 0, targetWidth, targetHeight,
        screenDC, 0, 0, screenWidth, screenHeight, SRCCOPY) == 0)
        return null;

    const pixelCount = targetWidth * targetHeight;
    auto rgba = new ubyte[cast(size_t) pixelCount * 4];
    auto source = cast(uint*) bits;
    auto target = cast(uint*) rgba.ptr;
    foreach (index; 0 .. pixelCount)
    {
        // 32bpp DIB rows are BGRA bytes on little-endian; the canvas consumes
        // RGBA bytes, so rebuild each word and force an opaque alpha (GDI
        // leaves the DIB alpha byte undefined).
        target[index] = dibPixelToRgbaWord(source[index]);
    }
    return new RgbaImage(targetWidth, targetHeight, rgba);
}

version (Windows)
unittest
{
    // A DIB stores byte0=blue, byte1=green, byte2=red; the canvas needs
    // byte0=red, byte1=green, byte2=blue. RGBA words below are shown as
    // little-endian 32-bit values (byte0 is the low byte, byte3 the alpha).
    // Pure red DIB (0x00FF0000) must become 0xFF0000FF (R=0xFF,A=0xFF),
    // pure green (0x0000FF00) becomes 0xFF00FF00, and pure blue (0x000000FF)
    // becomes 0xFFFF0000 (B=0xFF in byte2).
    assert(dibPixelToRgbaWord(0x00ff0000) == 0xff0000ff);
    assert(dibPixelToRgbaWord(0x0000ff00) == 0xff00ff00);
    assert(dibPixelToRgbaWord(0x000000ff) == 0xffff0000);
    // A neutral gray must stay neutral (no channel swap visible).
    assert(dibPixelToRgbaWord(0x00505050) == 0xff505050);
}

version (Windows)
unittest
{
    // On an interactive desktop session a real capture must return the
    // requested 16:9 image; headless/service sessions may fail and return null.
    auto frame = captureDesktopPreview(480, 270);
    if (frame !is null)
    {
        assert(frame.width() == 480);
        assert(frame.height() == 270);
    }
}
