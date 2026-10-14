module auroradesktop.wallpaper;

/**
 * Windows wallpaper integration: read/apply the OS desktop wallpaper and
 * decode an image file (JPEG/PNG/BMP/GIF) into an RgbaImage through Aurora's
 * own shared image codec (aurora.image) so the desktop can paint the real
 * wallpaper behind its icons.
 */

import aurora.image : RgbaImage, loadImage;
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
    if (path.length == 0 || !exists(path)) return null;
    // Aurora's own shared codec (aurora.image) replaces gdiplus here.
    try return loadImage(path);
    catch (Exception) return null;
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
