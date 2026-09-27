module auroraremote.desktop;

version (Windows)
{
    import core.stdc.string : memset;
    import core.sys.windows.windows : BITMAPINFO, BITMAPINFOHEADER, BI_RGB,
        COLORONCOLOR, CreateCompatibleDC, CreateDIBSection, DeleteDC,
        DeleteObject, DIB_RGB_COLORS, GetDC, GetSystemMetrics, HBITMAP, HDC,
        HGDIOBJ, ReleaseDC, SelectObject, SetStretchBltMode, SM_CXSCREEN,
        SM_CYSCREEN, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
        SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SRCCOPY, StretchBlt;

    final class DesktopCapturer
    {
        private int _width;
        private int _height;
        private int _screenWidth;
        private int _screenHeight;
        private int _screenX;
        private int _screenY;
        private HDC _memoryDC;
        private HBITMAP _bitmap;
        private HGDIOBJ _previous;
        private void* _bits;

        this(int width, int height)
        {
            _width = width;
            _height = height;
        }

        ~this() { release(); }

        int width() const { return _width; }
        int height() const { return _height; }

        private void release()
        {
            if (_memoryDC !is null && _previous !is null)
                SelectObject(_memoryDC, _previous);
            _previous = null;
            if (_bitmap !is null) DeleteObject(_bitmap);
            _bitmap = null;
            _bits = null;
            if (_memoryDC !is null) DeleteDC(_memoryDC);
            _memoryDC = null;
        }

        private bool ensureReady()
        {
            int screenWidth = GetSystemMetrics(SM_CXVIRTUALSCREEN);
            int screenHeight = GetSystemMetrics(SM_CYVIRTUALSCREEN);
            int screenX = GetSystemMetrics(SM_XVIRTUALSCREEN);
            int screenY = GetSystemMetrics(SM_YVIRTUALSCREEN);
            if (screenWidth <= 0 || screenHeight <= 0)
            {
                screenWidth = GetSystemMetrics(SM_CXSCREEN);
                screenHeight = GetSystemMetrics(SM_CYSCREEN);
                screenX = 0;
                screenY = 0;
            }
            if (screenWidth <= 0 || screenHeight <= 0) return false;
            if (_bitmap !is null && _screenWidth == screenWidth &&
                _screenHeight == screenHeight && _screenX == screenX &&
                _screenY == screenY)
                return true;
            _screenWidth = screenWidth;
            _screenHeight = screenHeight;
            _screenX = screenX;
            _screenY = screenY;
            release();

            auto screenDC = GetDC(null);
            if (screenDC is null) return false;
            scope (exit) ReleaseDC(null, screenDC);
            _memoryDC = CreateCompatibleDC(screenDC);
            if (_memoryDC is null) return false;
            BITMAPINFO info;
            info.bmiHeader.biSize = BITMAPINFOHEADER.sizeof;
            info.bmiHeader.biWidth = _width;
            info.bmiHeader.biHeight = -_height;
            info.bmiHeader.biPlanes = 1;
            info.bmiHeader.biBitCount = 32;
            info.bmiHeader.biCompression = BI_RGB;
            _bitmap = CreateDIBSection(_memoryDC, &info, DIB_RGB_COLORS,
                &_bits, null, 0);
            if (_bitmap is null) return false;
            _previous = SelectObject(_memoryDC, cast(HGDIOBJ) _bitmap);
            SetStretchBltMode(_memoryDC, COLORONCOLOR);
            return true;
        }

        ubyte[] capture()
        {
            if (!ensureReady()) return null;
            auto screenDC = GetDC(null);
            if (screenDC is null) return null;
            scope (exit) ReleaseDC(null, screenDC);
            if (StretchBlt(_memoryDC, 0, 0, _width, _height, screenDC,
                _screenX, _screenY, _screenWidth, _screenHeight, SRCCOPY) == 0)
                return null;

            auto rgba = new ubyte[cast(size_t) _width * _height * 4];
            auto source = cast(uint*) _bits;
            auto target = cast(uint*) rgba.ptr;
            foreach (index; 0 .. _width * _height)
            {
                const value = source[index];
                const red = (value >> 16) & 0xff;
                const green = (value >> 8) & 0xff;
                const blue = value & 0xff;
                target[index] = 0xff000000 | (blue << 16) |
                    (green << 8) | red;
            }
            return rgba;
        }
    }
}
else
{
    final class DesktopCapturer
    {
        this(int width, int height) {}
        int width() const { return 0; }
        int height() const { return 0; }
        ubyte[] capture() { return null; }
    }
}
