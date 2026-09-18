module auroradesktop.wallpaper;

/**
 * Windows wallpaper integration: read/apply the OS desktop wallpaper and
 * decode an image file (JPEG/PNG/BMP/GIF) into an RgbaImage via GDI+ so the
 * Aurora desktop can paint the real wallpaper behind its icons.
 */

import aurora.image : RgbaImage;
import core.stdc.stdlib : free, malloc;
import std.utf : toUTF8, toUTF16z;
import std.file : exists;

version (Windows)
{
    import core.sys.windows.windef : BOOL, DWORD, HBITMAP, HDC, HINSTANCE,
        HWND, UINT, UINT_PTR, WCHAR, LPCWSTR, LPWSTR, LPVOID, WORD, LPARAM;
    import core.sys.windows.winbase : FreeLibrary, GetModuleHandleW,
        GetProcAddress, LoadLibraryW;
    import core.sys.windows.wingdi : BI_RGB, BITMAP, BITMAPINFO,
        BITMAPINFOHEADER, CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC,
        DeleteObject, GetDIBits, GetObjectW;
    import core.sys.windows.winuser : GetDC, ReleaseDC, SystemParametersInfoW;

    private enum UINT SPI_GETDESKWALLPAPER = 0x0073;
    private enum UINT SPI_SETDESKWALLPAPER = 0x0014;
    private enum UINT SPIF_UPDATEINIFILE = 0x01;
    private enum UINT SPIF_SENDCHANGE = 0x02;

    private enum DWORD OFN_FILEMUSTEXIST = 0x00001000;
    private enum DWORD OFN_PATHMUSTEXIST = 0x00000800;
    private enum DWORD OFN_HIDEREADONLY = 0x00000004;
    private enum DWORD OFN_EXPLORER = 0x00080000;

    private extern (Windows) struct OPENFILENAMEW
    {
        DWORD lStructSize;
        HWND hwndOwner;
        HINSTANCE hInstance;
        LPCWSTR lpstrFilter;
        LPWSTR lpstrCustomFilter;
        DWORD nMaxCustFilter;
        DWORD nFilterIndex;
        LPWSTR lpstrFile;
        DWORD nMaxFile;
        LPWSTR lpstrFileTitle;
        DWORD nMaxFileTitle;
        LPCWSTR lpstrInitialDir;
        LPCWSTR lpstrTitle;
        DWORD Flags;
        WORD nFileOffset;
        WORD nFileExtension;
        LPCWSTR lpstrDefExt;
        LPARAM lCustData;
        LPVOID lpfnHook;
        LPCWSTR lpTemplateName;
        LPVOID pvReserved;
        DWORD dwReserved;
        DWORD FlagsEx;
    }

    private extern (Windows) BOOL GetOpenFileNameW(OPENFILENAMEW*);
}

/// Path of the wallpaper Windows currently uses, or "" when unavailable.
string currentWallpaperPath()
{
    version (Windows)
    {
        WCHAR[1024] buffer;
        if (SystemParametersInfoW(SPI_GETDESKWALLPAPER,
                cast(UINT) buffer.length, buffer.ptr, 0))
            return wcharPathToString(buffer[]);
    }
    return "";
}

version (Windows)
{
    /// Trim a NUL-terminated wide buffer and convert it to UTF-8.
    private static string wcharPathToString(const(WCHAR)[] buffer)
    {
        size_t length;
        while (length < buffer.length && buffer[length] != 0) ++length;
        return toUTF8(buffer[0 .. length]);
    }
}

/// Ask Windows to use `path` as the desktop wallpaper.
bool setWallpaper(string path)
{
    version (Windows)
    {
        return SystemParametersInfoW(SPI_SETDESKWALLPAPER, 0,
            cast(void*) path.toUTF16z,
            SPIF_UPDATEINIFILE | SPIF_SENDCHANGE) != 0;
    }
    return false;
}

/// Load a wallpaper image file into an RgbaImage (null on failure).
RgbaImage loadWallpaperImage(string path)
{
    version (Windows)
    {
        if (path.length == 0 || !exists(path)) return null;
        auto gdiplus = LoadLibraryW("gdiplus.dll"w.ptr);
        if (gdiplus is null) return null;
        scope (exit) FreeLibrary(gdiplus);

        alias GdiplusStartupFn = extern(Windows) int function(UINT_PTR*,
            const(void)*, void*);
        alias GdipCreateBitmapFromFileFn = extern(Windows) int function(
            LPCWSTR, void**);
        alias GdipCreateHBITMAPFromBitmapFn = extern(Windows) int function(
            void*, HBITMAP*, uint);
        alias GdipDisposeImageFn = extern(Windows) int function(void*);
        alias GdiplusShutdownFn = extern(Windows) void function(UINT_PTR);

        auto startup = cast(GdiplusStartupFn)
            GetProcAddress(gdiplus, "GdiplusStartup");
        auto createBitmap = cast(GdipCreateBitmapFromFileFn)
            GetProcAddress(gdiplus, "GdipCreateBitmapFromFile");
        auto createHbmp = cast(GdipCreateHBITMAPFromBitmapFn)
            GetProcAddress(gdiplus, "GdipCreateHBITMAPFromBitmap");
        auto disposeImage = cast(GdipDisposeImageFn)
            GetProcAddress(gdiplus, "GdipDisposeImage");
        auto shutdown = cast(GdiplusShutdownFn)
            GetProcAddress(gdiplus, "GdiplusShutdown");
        if (startup is null || createBitmap is null || createHbmp is null ||
            shutdown is null)
            return null;

        struct GdiplusStartupInput
        {
            UINT GdiplusVersion;
            void* DebugEventCallback;
            BOOL SuppressBackgroundThread;
            BOOL SuppressExternalCodecs;
        }

        UINT_PTR token;
        GdiplusStartupInput input;
        input.GdiplusVersion = 1;
        // GdiplusStartup requires a non-null output buffer on this GDI+ build;
        // passing null makes it fail with InvalidParameter.
        ubyte[32] output;
        if (startup(&token, &input, output.ptr) != 0) return null;
        scope (exit) shutdown(token);

        void* bitmap;
        if (createBitmap(path.toUTF16z, &bitmap) != 0) return null;
        scope (exit) if (disposeImage !is null) disposeImage(bitmap);

        HBITMAP hbmp;
        if (createHbmp(bitmap, &hbmp, 0xFF000000) != 0) return null;
        scope (exit) DeleteObject(hbmp);

        return hbmpToRgba(hbmp);
    }
    else
    {
        return null;
    }
}

version (Windows)
{
    private RgbaImage hbmpToRgba(HBITMAP bitmap)
    {
        // Dimensions come from GetObjectW: GetDIBits' zero-line query returns
        // nothing for the HBITMAPs GDI+ produces.
        BITMAP bitmapInfo;
        if (GetObjectW(bitmap, BITMAP.sizeof, &bitmapInfo) == 0) return null;
        const int w = bitmapInfo.bmWidth;
        const int h = bitmapInfo.bmHeight;
        if (w <= 0 || h <= 0) return null;

        BITMAPINFO info;
        info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
        info.bmiHeader.biPlanes = 1;
        info.bmiHeader.biBitCount = 32;
        info.bmiHeader.biCompression = BI_RGB;
        info.bmiHeader.biWidth = w;
        info.bmiHeader.biHeight = -h; // top-down
        info.bmiHeader.biSizeImage = 0;

        HDC screenDc = GetDC(null);
        if (screenDc is null) return null;
        scope (exit) ReleaseDC(null, screenDc);
        HDC memDc = CreateCompatibleDC(screenDc);
        if (memDc is null) return null;
        scope (exit) DeleteDC(memDc);

        auto raw = cast(uint*) malloc(cast(size_t) w * cast(size_t) h * 4 + 4);
        if (raw is null) return null;
        scope (exit) free(raw);
        if (GetDIBits(memDc, bitmap, 0, cast(UINT) h, raw, &info,
                DIB_RGB_COLORS) <= 0)
            return null;

        ubyte[] rgba;
        rgba.length = cast(size_t) w * cast(size_t) h * 4;
        const count = cast(size_t) w * cast(size_t) h;
        foreach (i; 0 .. count)
        {
            const argb = raw[i];
            const offset = i * 4;
            rgba[offset + 0] = cast(ubyte) ((argb >> 16) & 0xff);
            rgba[offset + 1] = cast(ubyte) ((argb >> 8) & 0xff);
            rgba[offset + 2] = cast(ubyte) (argb & 0xff);
            rgba[offset + 3] = 255;
        }
        return new RgbaImage(w, h, rgba);
    }
}

/// Show the OS Open-file dialog and return the chosen image path, or "".
string chooseWallpaperFile(HWND owner)
{
    version (Windows)
    {
        WCHAR[1024] fileBuffer;
        const wstring filter = "Image files\0*.jpg;*.jpeg;*.png;*.bmp;*.gif\0"w ~
            "All files\0*.*\0\0"w;
        OPENFILENAMEW settings;
        settings.lStructSize = OPENFILENAMEW.sizeof;
        settings.hwndOwner = owner;
        settings.lpstrFilter = filter.ptr;
        settings.lpstrFile = fileBuffer.ptr;
        settings.nMaxFile = cast(DWORD) fileBuffer.length;
        settings.lpstrTitle = "Choose a wallpaper"w.ptr;
        settings.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST |
            OFN_HIDEREADONLY | OFN_EXPLORER;
        if (GetOpenFileNameW(&settings) == 0) return "";
        return wcharPathToString(fileBuffer[]);
    }
    else
    {
        return "";
    }
}
