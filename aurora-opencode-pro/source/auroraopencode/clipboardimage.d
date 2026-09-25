module auroraopencode.clipboardimage;

/// Read a Windows clipboard image as PNG bytes for an inline chat attachment.
/// An empty result means the clipboard has no supported image format.
public ubyte[] clipboardImagePng(size_t maxBytes)
{
    version (Windows)
        return readWindowsClipboardImage(maxBytes);
    else
        return null;
}

version (Windows)
{
    import core.sys.windows.windows : CF_DIB, CloseClipboard, FreeLibrary,
        GetClipboardData, GetProcAddress, GlobalLock, GlobalSize, GlobalUnlock,
        IsClipboardFormatAvailable, LoadLibraryW, OpenClipboard,
        RegisterClipboardFormatW;
    import std.file : exists, getSize, read, remove, tempDir;
    import std.path : buildPath;
    import std.utf : toUTF16z;
    import std.uuid : randomUUID;

    private enum size_t maxDibBytes = 128 * 1024 * 1024;

    private uint read16(const(ubyte)[] bytes, size_t offset)
    {
        if (offset + 2 > bytes.length)
            throw new Exception("Clipboard bitmap header is truncated.");
        return cast(uint) bytes[offset] | (cast(uint) bytes[offset + 1] << 8);
    }

    private uint read32(const(ubyte)[] bytes, size_t offset)
    {
        if (offset + 4 > bytes.length)
            throw new Exception("Clipboard bitmap header is truncated.");
        return cast(uint) bytes[offset] |
            (cast(uint) bytes[offset + 1] << 8) |
            (cast(uint) bytes[offset + 2] << 16) |
            (cast(uint) bytes[offset + 3] << 24);
    }

    /// A CF_DIB block starts with a bitmap header, optional masks/palette,
    /// then pixel data. GDI+ needs separate pointers to the header and pixels.
    private size_t dibPixelOffset(const(ubyte)[] dib)
    {
        const headerSize = read32(dib, 0);
        if (headerSize == 12)
        {
            const bitCount = read16(dib, 10);
            const colors = bitCount <= 8 ? 1u << bitCount : 0u;
            return headerSize + cast(size_t) colors * 3;
        }
        if (headerSize < 40 || headerSize > dib.length)
            throw new Exception("Clipboard bitmap header is unsupported.");
        const bitCount = read16(dib, 14);
        const compression = read32(dib, 16);
        const used = read32(dib, 32);
        const colors = bitCount <= 8 ? (used > 0 ? used : 1u << bitCount)
            : used;
        const masks = headerSize == 40 && compression == 3 ? 12 :
            headerSize == 40 && compression == 6 ? 16 : 0;
        return headerSize + masks + cast(size_t) colors * 4;
    }

    private struct GdiGuid
    {
        uint data1;
        ushort data2;
        ushort data3;
        ubyte[8] data4;
    }

    private void removeTempFile(string path)
    {
        try { if (exists(path)) remove(path); }
        catch (Exception) {}
    }

    private ubyte[] dibToPng(const(ubyte)[] dib, size_t maxBytes)
    {
        const pixelOffset = dibPixelOffset(dib);
        if (pixelOffset >= dib.length)
            throw new Exception("Clipboard bitmap pixels are missing.");

        auto library = LoadLibraryW("gdiplus.dll"w.ptr);
        if (library is null)
            throw new Exception("Windows image conversion is unavailable.");
        scope (exit) FreeLibrary(library);

        alias Startup = extern(Windows) int function(size_t*, const(void)*,
            void*);
        alias Shutdown = extern(Windows) void function(size_t);
        alias CreateBitmap = extern(Windows) int function(const(void)*,
            void*, void**);
        alias SaveImage = extern(Windows) int function(void*, const(wchar)*,
            const(GdiGuid)*, const(void)*);
        alias DisposeImage = extern(Windows) int function(void*);

        auto startup = cast(Startup) GetProcAddress(library, "GdiplusStartup");
        auto shutdown = cast(Shutdown) GetProcAddress(library, "GdiplusShutdown");
        auto createBitmap = cast(CreateBitmap)
            GetProcAddress(library, "GdipCreateBitmapFromGdiDib");
        auto saveImage = cast(SaveImage)
            GetProcAddress(library, "GdipSaveImageToFile");
        auto disposeImage = cast(DisposeImage)
            GetProcAddress(library, "GdipDisposeImage");
        if (startup is null || shutdown is null || createBitmap is null ||
            saveImage is null || disposeImage is null)
            throw new Exception("Windows image conversion is unavailable.");

        struct StartupInput
        {
            uint version_;
            void* debugCallback;
            int suppressBackgroundThread;
            int suppressExternalCodecs;
        }
        StartupInput input;
        input.version_ = 1;
        size_t token;
        ubyte[32] output;
        if (startup(&token, &input, output.ptr) != 0)
            throw new Exception("Windows image conversion could not start.");
        scope (exit) shutdown(token);

        void* bitmap;
        if (createBitmap(dib.ptr, cast(void*) (dib.ptr + pixelOffset),
            &bitmap) != 0 || bitmap is null)
            throw new Exception("Clipboard bitmap could not be decoded.");
        scope (exit) disposeImage(bitmap);

        // Windows' built-in GDI+ PNG encoder.
        const GdiGuid pngEncoder = GdiGuid(0x557CF406, 0x1A04, 0x11D3,
            [0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E]);
        const path = buildPath(tempDir(), "aurora-clipboard-" ~
            randomUUID().toString() ~ ".png");
        scope (exit) removeTempFile(path);
        if (saveImage(bitmap, path.toUTF16z, &pngEncoder, null) != 0)
            throw new Exception("Clipboard bitmap could not be saved as PNG.");
        if (getSize(path) > maxBytes)
            throw new Exception("Clipboard image exceeds the attachment size limit.");
        return cast(ubyte[]) read(path);
    }

    private ubyte[] readWindowsClipboardImage(size_t maxBytes)
    {
        const pngFormat = RegisterClipboardFormatW("PNG"w.ptr);
        const hasPng = pngFormat != 0 &&
            IsClipboardFormatAvailable(pngFormat) != 0;
        const hasDib = IsClipboardFormatAvailable(CF_DIB) != 0;
        if (!hasPng && !hasDib) return null;
        if (!OpenClipboard(null))
            throw new Exception("Windows clipboard could not be opened.");

        ubyte[] image;
        bool png;
        try
        {
            const format = hasPng ? pngFormat : CF_DIB;
            auto memory = GetClipboardData(format);
            if (memory is null)
                throw new Exception("Clipboard image could not be read.");
            const size = cast(size_t) GlobalSize(memory);
            if (size == 0)
                throw new Exception("Clipboard image is empty.");
            if (size > (hasPng ? maxBytes : maxDibBytes))
                throw new Exception("Clipboard image exceeds the attachment size limit.");
            auto source = cast(const(ubyte)*) GlobalLock(memory);
            if (source is null)
                throw new Exception("Clipboard image could not be locked.");
            image = source[0 .. size].dup;
            GlobalUnlock(memory);
            png = hasPng;
        }
        finally CloseClipboard();

        if (png)
        {
            static immutable ubyte[8] signature =
                [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A];
            if (image.length < signature.length ||
                image[0 .. signature.length] != signature[])
                throw new Exception("Clipboard PNG data is invalid.");
            return image;
        }
        return dibToPng(image, maxBytes);
    }
}
