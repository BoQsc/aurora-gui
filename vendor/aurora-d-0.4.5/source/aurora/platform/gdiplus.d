module aurora.platform.gdiplus;

/**
 * Shared GDI+ (gdiplus.dll) access — the single place Aurora talks to GDI+.
 *
 * GDI+ is used only for the few jobs Aurora's own image codec cannot do: JPEG
 * encoding, and OS clipboard/interop conversions. This module owns the DLL load,
 * `GdiplusStartup`/`GdiplusShutdown`, and procedure lookup so programs do not
 * each re-invent that bootstrap, and offers a JPEG encoder built on top.
 *
 * On non-Windows platforms the surface exists but reports failure.
 */

/// A GDI+ GUID (16 bytes).
struct GdiPlusGuid
{
    uint a;
    ushort b;
    ushort c;
    ubyte[8] d;
}

version (Windows)
{
    private import core.sys.windows.windows : LoadLibraryW, FreeLibrary,
        GetProcAddress;
    private import std.file : tempDir, read, remove, exists;
    private import std.path : buildPath;
    private import std.utf : toUTF16z;
    private import std.uuid : randomUUID;

    /// A scoped GDI+ session: loads gdiplus.dll and starts GDI+.
    struct GdiPlus
    {
        private void* _library;
        private size_t _token;
        private bool _started;

        /// Start GDI+. Returns false when gdiplus.dll or startup is missing.
        bool start()
        {
            _library = LoadLibraryW("gdiplus.dll"w.ptr);
            if (_library is null) return false;
            alias Startup = extern(Windows) int function(size_t*, const(void)*,
                void*);
            auto startup = cast(Startup)
                GetProcAddress(_library, "GdiplusStartup");
            if (startup is null)
            {
                stop();
                return false;
            }
            struct StartupInput
            {
                uint version_ = 1;
                void* callback;
                int suppressThread;
                int suppressCodecs;
            }
            StartupInput input;
            if (startup(&_token, &input, null) != 0)
            {
                stop();
                return false;
            }
            _started = true;
            return true;
        }

        /// Shut down and unload. Safe to call more than once.
        void stop()
        {
            if (_library is null) return;
            if (_started)
            {
                alias Shutdown = extern(Windows) void function(size_t);
                auto shutdown = cast(Shutdown)
                    GetProcAddress(_library, "GdiplusShutdown");
                if (shutdown !is null) shutdown(_token);
                _started = false;
            }
            FreeLibrary(_library);
            _library = null;
        }

        /// Resolve a gdiplus.dll procedure by name (null when absent).
        void* proc(string name)
        {
            return _library is null ? null : GetProcAddress(_library, name.ptr);
        }

        bool active() const @safe pure nothrow @nogc { return _started; }
    }

    /// Remove a temporary file, ignoring failures.
    private void removeQuietly(string path)
    {
        try
        {
            if (exists(path)) remove(path);
        }
        catch (Exception) {}
    }

    /// Encode RGB8 pixels as a JPEG. `quality` is 0..100. Returns the bytes.
    ubyte[] encodeJpegRgb(const(ubyte)[] rgb, int width, int height,
        uint quality = 85)
    {
        if (width <= 0 || height <= 0 ||
            cast(size_t) width * height * 3 != rgb.length)
            throw new Exception("Invalid JPEG pixel buffer.");

        GdiPlus gp;
        if (!gp.start())
            throw new Exception("Windows JPEG encoder unavailable.");
        scope (exit) gp.stop();

        alias Create = extern(Windows) int function(int, int, int, int,
            const(ubyte)*, void**);
        alias Save = extern(Windows) int function(void*, const(wchar)*,
            const(GdiPlusGuid)*, const(void)*);
        alias Dispose = extern(Windows) int function(void*);
        auto create = cast(Create) gp.proc("GdipCreateBitmapFromScan0");
        auto save = cast(Save) gp.proc("GdipSaveImageToFile");
        auto dispose = cast(Dispose) gp.proc("GdipDisposeImage");
        if (create is null || save is null || dispose is null)
            throw new Exception("Windows JPEG encoder unavailable.");

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
            throw new Exception("JPEG bitmap could not be created.");
        scope (exit) dispose(bitmap);

        const GdiPlusGuid jpegEncoder = GdiPlusGuid(0x557CF401, 0x1A04,
            0x11D3, [0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E]);
        struct Parameter
        {
            GdiPlusGuid guid;
            uint count;
            uint type;
            void* value;
        }
        struct Parameters
        {
            uint count;
            Parameter[1] items;
        }
        uint qualityValue = quality;
        Parameters parameters;
        parameters.count = 1;
        parameters.items[0] = Parameter(GdiPlusGuid(0x1D5BE4B5, 0xFA4A,
            0x452D, [0x9C, 0xDD, 0x5D, 0xB3, 0x51, 0x05, 0xE7, 0xEB]), 1, 4,
            &qualityValue);

        const path = buildPath(tempDir(), "aurora-jpeg-" ~
            randomUUID().toString() ~ ".jpg");
        scope (exit) removeQuietly(path);
        if (save(bitmap, path.toUTF16z, &jpegEncoder, &parameters) != 0)
            throw new Exception("Image could not be encoded as JPEG.");
        return cast(ubyte[]) read(path);
    }
}
else
{
    struct GdiPlus
    {
        bool start() { return false; }
        void stop() {}
        void* proc(string name) { return null; }
        bool active() const @safe pure nothrow @nogc { return false; }
    }

    ubyte[] encodeJpegRgb(const(ubyte)[] rgb, int width, int height,
        uint quality = 85)
    {
        throw new Exception("JPEG encoding is unavailable.");
    }
}
