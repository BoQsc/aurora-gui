module auroraopencode.imagenormalization;

public enum size_t inlineImageByteBudget = 512 * 1024;
public enum int inlineImageEdge = 1600;
public enum size_t imageInputByteLimit = 32 * 1024 * 1024;

public struct ImageCrop { int x, y, width, height; }
public struct NormalizedImage
{
    ubyte[] bytes;
    string mimeType;
    int width, height, originalWidth, originalHeight;
}

/// One policy for pasted files and tool reads. Originals are archived by the
/// caller; the derivative can therefore favor a bounded request over fidelity.
public NormalizedImage normalizeImage(const(ubyte)[] bytes, string mimeType,
    bool original = false, ImageCrop crop = ImageCrop.init)
{
    if (!bytes.length || bytes.length > imageInputByteLimit)
        throw new Exception("Image input must be between 1 byte and 32 MiB.");
    if (original && crop.width == 0 && bytes.length > 4 * 1024 * 1024)
        throw new Exception("Original image exceeds 4 MiB. Inspect a crop instead.");
    version (Windows)
        return windowsNormalize(bytes, mimeType, original, crop);
    else
    {
        if ((!original && bytes.length > inlineImageByteBudget) || crop.width > 0)
            throw new Exception("Image conversion unavailable; resize or convert this image first.");
        return NormalizedImage(bytes.dup, mimeType);
    }
}

version (Windows)
{
    import core.sys.windows.windows : LoadLibraryW, FreeLibrary, GetProcAddress;
    import std.file : read, write, exists, remove, tempDir;
    import std.path : buildPath;
    import std.utf : toUTF16z;
    import std.uuid : randomUUID;

    private struct Guid { uint a; ushort b, c; ubyte[8] d; }
    private void removeTemporary(string path)
    {
        try { if (exists(path)) remove(path); } catch (Exception) {}
    }

    private NormalizedImage windowsNormalize(const(ubyte)[] bytes,
        string mimeType, bool original, ImageCrop crop)
    {
        // Shared GDI+ session (aurora.platform.gdiplus) instead of a private
        // LoadLibrary/GdiplusStartup bootstrap.
        import aurora.platform.gdiplus : GdiPlus;
        GdiPlus gp;
        if (!gp.start()) throw new Exception("Windows image conversion unavailable.");
        scope (exit) gp.stop();
        alias Load = extern(Windows) int function(const(wchar)*, void**);
        alias Dimension = extern(Windows) int function(void*, uint*);
        alias Dispose = extern(Windows) int function(void*);
        alias Create = extern(Windows) int function(int, int, int, int, const(ubyte)*, void**);
        alias Graphics = extern(Windows) int function(void*, void**);
        alias Clear = extern(Windows) int function(void*, uint);
        alias Mode = extern(Windows) int function(void*, int);
        alias Draw = extern(Windows) int function(void*, void*, int, int, int, int,
            int, int, int, int, int, void*, void*, void*);
        alias Save = extern(Windows) int function(void*, const(wchar)*, const(Guid)*, const(void)*);
        alias PropertySize = extern(Windows) int function(void*, uint, uint*);
        alias Property = extern(Windows) int function(void*, uint, uint, void*);
        auto load = cast(Load) gp.proc("GdipLoadImageFromFile");
        auto getWidth = cast(Dimension) gp.proc("GdipGetImageWidth");
        auto getHeight = cast(Dimension) gp.proc("GdipGetImageHeight");
        auto dispose = cast(Dispose) gp.proc("GdipDisposeImage");
        auto create = cast(Create) gp.proc("GdipCreateBitmapFromScan0");
        auto graphics = cast(Graphics) gp.proc("GdipGetImageGraphicsContext");
        auto deleteGraphics = cast(Dispose) gp.proc("GdipDeleteGraphics");
        auto clear = cast(Clear) gp.proc("GdipGraphicsClear");
        auto interpolation = cast(Mode) gp.proc("GdipSetInterpolationMode");
        auto draw = cast(Draw) gp.proc("GdipDrawImageRectRectI");
        auto save = cast(Save) gp.proc("GdipSaveImageToFile");
        auto propertySize = cast(PropertySize) gp.proc("GdipGetPropertyItemSize");
        auto property = cast(Property) gp.proc("GdipGetPropertyItem");
        auto rotate = cast(Mode) gp.proc("GdipImageRotateFlip");
        if (load is null || getWidth is null ||
            getHeight is null || dispose is null || create is null || graphics is null ||
            deleteGraphics is null || clear is null || interpolation is null || draw is null || save is null)
            throw new Exception("Windows image converter is incomplete.");
        const path = buildPath(tempDir(), "aurora-image-" ~ randomUUID().toString());
        scope (exit) removeTemporary(path);
        write(path, bytes);
        void* source;
        if (load(path.toUTF16z, &source) != 0 || source is null)
        {
            // Some Windows installations lack a WebP codec. Small WebP images
            // still work with providers that support them; large ones must not
            // silently bypass the payload budget.
            if (mimeType == "image/webp" && bytes.length <= inlineImageByteBudget && crop.width == 0)
                return NormalizedImage(bytes.dup, mimeType);
            throw new Exception("Cannot decode this image. Convert it to PNG or JPEG first.");
        }
        scope (exit) dispose(source);
        // JPEG re-encoding strips EXIF metadata. Apply its orientation before
        // resizing/cropping so the derivative and its coordinates stay upright.
        if (propertySize !is null && property !is null && rotate !is null)
        {
            uint size;
            if (propertySize(source, 0x112, &size) == 0 && size > 0 && size <= 65536)
            {
                auto storage = new ubyte[size];
                if (property(source, 0x112, size, storage.ptr) == 0)
                {
                    struct Item { uint id, length; ushort type; void* value; }
                    auto item = cast(Item*) storage.ptr;
                    if (size >= Item.sizeof && item.type == 3 && item.length >= 2 && item.value !is null)
                    {
                        const orientation = *cast(ushort*) item.value;
                        if (orientation >= 2 && orientation <= 8)
                        {
                            immutable int[9] modes = [0, 0, 4, 2, 6, 5, 1, 7, 3];
                            if (rotate(source, modes[orientation]) != 0)
                                throw new Exception("Could not apply image orientation.");
                        }
                    }
                }
            }
        }
        uint sourceWidth, sourceHeight;
        if (getWidth(source, &sourceWidth) != 0 || getHeight(source, &sourceHeight) != 0 ||
            !sourceWidth || !sourceHeight || sourceWidth > 32768 || sourceHeight > 32768 ||
            cast(ulong) sourceWidth * sourceHeight > 64 * 1024 * 1024)
            throw new Exception("Image dimensions exceed the 64 megapixel decoding limit.");
        const cropped = crop.width != 0;
        if (!cropped) crop = ImageCrop(0, 0, sourceWidth, sourceHeight);
        if (crop.x < 0 || crop.y < 0 || crop.width <= 0 || crop.height <= 0 ||
            cast(long) crop.x + crop.width > sourceWidth || cast(long) crop.y + crop.height > sourceHeight)
            throw new Exception("Crop lies outside the original image dimensions.");
        if (!cropped && (original || (sourceWidth <= inlineImageEdge && sourceHeight <= inlineImageEdge &&
            bytes.length <= inlineImageByteBudget)))
            return NormalizedImage(bytes.dup, mimeType, sourceWidth, sourceHeight, sourceWidth, sourceHeight);
        const longest = crop.width > crop.height ? crop.width : crop.height;
        int edge = original ? longest : (longest < inlineImageEdge ? longest : inlineImageEdge);
        const outputPath = path ~ ".jpg";
        scope (exit) removeTemporary(outputPath);
        const Guid encoder = Guid(0x557CF401, 0x1A04, 0x11D3,
            [0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E]);
        struct Parameter { Guid guid; uint count, type; void* value; }
        struct Parameters { uint count; Parameter[1] items; }
        uint quality = 85;
        Parameters parameters;
        parameters.count = 1;
        parameters.items[0] = Parameter(Guid(0x1D5BE4B5, 0xFA4A, 0x452D,
            [0x9C, 0xDD, 0x5D, 0xB3, 0x51, 0x05, 0xE7, 0xEB]), 1, 4, &quality);
        foreach (_; 0 .. 9)
        {
            const width = cast(int) (cast(long) crop.width * edge / longest);
            const height = cast(int) (cast(long) crop.height * edge / longest);
            void* target;
            if (create(width > 0 ? width : 1, height > 0 ? height : 1, 0, 0x26200A, null, &target) != 0)
                throw new Exception("Could not allocate the normalized image.");
            scope (exit) dispose(target);
            void* context;
            if (graphics(target, &context) != 0) throw new Exception("Could not create image graphics.");
            {
                scope (exit) deleteGraphics(context);
                clear(context, 0xFFFFFFFF); // Flatten transparency onto white.
                interpolation(context, 7); // High-quality bicubic, proportional scaling.
                if (draw(context, source, 0, 0, width > 0 ? width : 1, height > 0 ? height : 1,
                    crop.x, crop.y, crop.width, crop.height, 2, null, null, null) != 0)
                    throw new Exception("Image resize failed.");
            }
            removeTemporary(outputPath);
            if (save(target, outputPath.toUTF16z, &encoder, &parameters) != 0)
                throw new Exception("Image JPEG encoding failed.");
            auto result = cast(ubyte[]) read(outputPath);
            if (result.length <= (original ? 4 * 1024 * 1024 : inlineImageByteBudget))
                return NormalizedImage(result, "image/jpeg", width > 0 ? width : 1, height > 0 ? height : 1, sourceWidth, sourceHeight);
            if (original) break;
            edge = edge * 3 / 4;
            if (edge < 64) break;
        }
        throw new Exception("Image cannot fit the request budget. Inspect a smaller crop.");
    }
}
