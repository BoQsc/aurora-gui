module auroraopencode.screenshotimage;

/// Upgrade retained frames from older sessions once, after history pruning.
public ubyte[] pngScreenshotToJpeg(const(ubyte)[] png)
{
    import aurora.image : decodePngImage;
    auto image = decodePngImage(png, "saved screenshot");
    auto rgb = new ubyte[cast(size_t) image.width * image.height * 3];
    const rgba = image.pixels;
    foreach (i; 0 .. rgb.length / 3)
        rgb[i * 3 .. i * 3 + 3] = rgba[i * 4 .. i * 4 + 3];
    return encodeScreenshotJpeg(image.width, image.height, rgb);
}

/// Encode screen pixels at native dimensions. JPEG quality 85 keeps UI text
/// readable without repeatedly uploading lossless multi-megabyte frames.
public ubyte[] encodeScreenshotJpeg(int width, int height,
    const(ubyte)[] rgb)
{
    if (width <= 0 || height <= 0 || width > 32768 || height > 32768 ||
        cast(size_t) width * height * 3 != rgb.length)
        throw new Exception("Invalid screenshot pixels.");
    version (Windows)
        return windowsJpeg(width, height, rgb);
    else
        throw new Exception("Screenshot JPEG encoding is unavailable.");
}

/// Longest edge Aurora sends inline. Vision models downscale to roughly this
/// size anyway, so a bigger frame only inflates the request body and can push a
/// gateway past its per-message limit.
public enum int inlineImageMaxEdge = 1400;

/// Decode a PNG, downscale it by whole-pixel steps until its longest edge fits
/// `maxEdge`, and re-encode it as JPEG. Returns null when the bytes are not a
/// PNG this build can decode, so the caller keeps the original payload instead
/// of failing the attachment.
public ubyte[] pngToInlineJpeg(const(ubyte)[] png,
    int maxEdge = inlineImageMaxEdge)
{
    import aurora.image : decodePngImage, RgbaImage;
    RgbaImage image;
    try image = decodePngImage(png, "inline image");
    catch (Exception) return null;
    const width = image.width;
    const height = image.height;
    if (width <= 0 || height <= 0) return null;
    const rgba = image.pixels;
    const longest = width > height ? width : height;
    int factor = 1;
    if (maxEdge > 0 && longest > maxEdge)
        factor = (longest + maxEdge - 1) / maxEdge;
    const outWidth = (width + factor - 1) / factor;
    const outHeight = (height + factor - 1) / factor;
    auto rgb = new ubyte[cast(size_t) outWidth * outHeight * 3];
    foreach (y; 0 .. outHeight)
    {
        const sy = y * factor < height ? y * factor : height - 1;
        foreach (x; 0 .. outWidth)
        {
            const sx = x * factor < width ? x * factor : width - 1;
            const src = (cast(size_t) sy * width + sx) * 4;
            const dst = (cast(size_t) y * outWidth + x) * 3;
            rgb[dst] = rgba[src];
            rgb[dst + 1] = rgba[src + 1];
            rgb[dst + 2] = rgba[src + 2];
        }
    }
    return encodeScreenshotJpeg(outWidth, outHeight, rgb);
}

version (Windows)
{
    import core.sys.windows.windows : LoadLibraryW, FreeLibrary, GetProcAddress;
    import std.file : tempDir, read, remove, exists;
    import std.path : buildPath;
    import std.utf : toUTF16z;
    import std.uuid : randomUUID;

    private struct Guid
    {
        uint a;
        ushort b, c;
        ubyte[8] d;
    }

    private void removeTemporaryImage(string path)
    {
        try { if (exists(path)) remove(path); }
        catch (Exception) {}
    }

    private ubyte[] windowsJpeg(int width, int height, const(ubyte)[] rgb)
    {
        auto library = LoadLibraryW("gdiplus.dll"w.ptr);
        if (library is null) throw new Exception("Windows JPEG encoder unavailable.");
        scope (exit) FreeLibrary(library);
        alias Startup = extern(Windows) int function(size_t*, const(void)*, void*);
        alias Shutdown = extern(Windows) void function(size_t);
        alias Create = extern(Windows) int function(int, int, int, int,
            const(ubyte)*, void**);
        alias Save = extern(Windows) int function(void*, const(wchar)*,
            const(Guid)*, const(void)*);
        alias Dispose = extern(Windows) int function(void*);
        auto startup = cast(Startup) GetProcAddress(library, "GdiplusStartup");
        auto shutdown = cast(Shutdown) GetProcAddress(library, "GdiplusShutdown");
        auto create = cast(Create) GetProcAddress(library, "GdipCreateBitmapFromScan0");
        auto save = cast(Save) GetProcAddress(library, "GdipSaveImageToFile");
        auto dispose = cast(Dispose) GetProcAddress(library, "GdipDisposeImage");
        if (startup is null || shutdown is null || create is null ||
            save is null || dispose is null)
            throw new Exception("Windows JPEG encoder unavailable.");
        struct StartupInput
        {
            uint version_ = 1;
            void* callback;
            int suppressThread, suppressCodecs;
        }
        StartupInput input;
        size_t token;
        if (startup(&token, &input, null) != 0)
            throw new Exception("Windows JPEG encoder could not start.");
        scope (exit) shutdown(token);

        // GDI+ expects BGR rows aligned to four bytes, including odd-width crops.
        const stride = (width * 3 + 3) & ~3;
        auto bgr = new ubyte[cast(size_t) stride * height];
        foreach (y; 0 .. height)
            foreach (x; 0 .. width)
            {
                const src = (cast(size_t) y * width + x) * 3;
                const dst = cast(size_t) y * stride + x * 3;
                bgr[dst] = rgb[src + 2];
                bgr[dst + 1] = rgb[src + 1];
                bgr[dst + 2] = rgb[src];
            }
        void* bitmap;
        enum pixelFormat24bppRGB = 0x21808;
        if (create(width, height, stride, pixelFormat24bppRGB, bgr.ptr,
                &bitmap) != 0 || bitmap is null)
            throw new Exception("Screenshot JPEG bitmap could not be created.");
        scope (exit) dispose(bitmap);
        const Guid encoder = Guid(0x557CF401, 0x1A04, 0x11D3,
            [0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E]);
        struct Parameter
        {
            Guid guid;
            uint count, type;
            void* value;
        }
        struct Parameters { uint count; Parameter[1] items; }
        uint quality = 85;
        Parameters parameters;
        parameters.count = 1;
        parameters.items[0] = Parameter(Guid(0x1D5BE4B5, 0xFA4A, 0x452D,
            [0x9C, 0xDD, 0x5D, 0xB3, 0x51, 0x05, 0xE7, 0xEB]), 1, 4, &quality);
        const path = buildPath(tempDir(), "aurora-screen-" ~
            randomUUID().toString() ~ ".jpg");
        scope (exit) removeTemporaryImage(path);
        if (save(bitmap, path.toUTF16z, &encoder, &parameters) != 0)
            throw new Exception("Screenshot could not be encoded as JPEG.");
        return cast(ubyte[]) read(path);
    }
}
