module aurora.image;

import aurora.types : Rect;
import std.conv : text;
import std.exception : enforce;
import std.file : read;
import std.zlib : uncompress;

/** Immutable-size, revisioned straight-alpha RGBA8 image data. */
final class RgbaImage
{
    private __gshared ulong nextImageId = 1;

    private ulong _id;
    private ulong _revision = 1;
    private int _width;
    private int _height;
    private ubyte[] _pixels;

    this(int width, int height, const(ubyte)[] rgba)
    {
        _id = allocateImageId();
        reset(width, height, rgba);
    }

    ulong id() const @safe pure nothrow @nogc { return _id; }
    ulong revision() const @safe pure nothrow @nogc { return _revision; }
    int width() const @safe pure nothrow @nogc { return _width; }
    int height() const @safe pure nothrow @nogc { return _height; }
    Rect bounds() const @safe pure nothrow @nogc { return Rect(0, 0, _width, _height); }
    const(ubyte)[] pixels() const @safe pure nothrow @nogc { return _pixels; }

    void reset(int width, int height, const(ubyte)[] rgba)
    {
        enforce(width > 0 && height > 0, "Image dimensions must be positive");
        const required = cast(size_t) width * cast(size_t) height * 4;
        enforce(rgba.length >= required, "RGBA pixel buffer is too small");
        _width = width;
        _height = height;
        _pixels = rgba[0 .. required].dup;
        ++_revision;
        if (_revision == 0) _revision = 1;
    }

    private static ulong allocateImageId()
    {
        const result = nextImageId == 0 ? 1 : nextImageId;
        nextImageId = result + 1;
        if (nextImageId == 0) nextImageId = 1;
        return result;
    }
}

/** Load a non-interlaced 8-bit PNG into straight-alpha RGBA8 pixels. */
RgbaImage loadPngImage(string path)
{
    return decodePngImage(cast(const(ubyte)[]) read(path), path);
}

RgbaImage decodePngImage(const(ubyte)[] bytes, string label = "PNG")
{
    immutable ubyte[8] signature = [137, 80, 78, 71, 13, 10, 26, 10];
    enforce(bytes.length >= signature.length && bytes[0 .. signature.length] == signature[],
        label ~ " has an invalid PNG signature");

    int width;
    int height;
    ubyte bitDepth;
    ubyte colorType;
    ubyte compressionMethod;
    ubyte filterMethod;
    ubyte interlaceMethod;
    ubyte[] idat;
    ubyte[] palette;
    ubyte[] transparency;

    size_t offset = signature.length;
    bool sawHeader;
    bool sawEnd;
    while (offset + 12 <= bytes.length)
    {
        const length = readU32(bytes, offset);
        offset += 4;
        enforce(offset + 4 <= bytes.length, label ~ " has a truncated chunk header");
        const chunkType = cast(string) bytes[offset .. offset + 4];
        offset += 4;
        enforce(offset + length + 4 <= bytes.length, label ~ " has a truncated " ~ chunkType ~ " chunk");
        const chunk = bytes[offset .. offset + length];
        offset += length + 4; // Skip CRC; zlib validation and bounds checks cover decode safety here.

        switch (chunkType)
        {
            case "IHDR":
                enforce(length == 13, label ~ " has an invalid IHDR length");
                width = cast(int) readU32(chunk, 0);
                height = cast(int) readU32(chunk, 4);
                bitDepth = chunk[8];
                colorType = chunk[9];
                compressionMethod = chunk[10];
                filterMethod = chunk[11];
                interlaceMethod = chunk[12];
                sawHeader = true;
                break;
            case "PLTE":
                palette = chunk.dup;
                break;
            case "IDAT":
                idat ~= chunk;
                break;
            case "tRNS":
                transparency = chunk.dup;
                break;
            case "IEND":
                sawEnd = true;
                break;
            default:
                break;
        }
        if (sawEnd) break;
    }

    enforce(sawHeader, label ~ " is missing IHDR");
    enforce(sawEnd, label ~ " is missing IEND");
    enforce(width > 0 && height > 0, label ~ " has invalid dimensions");
    enforce(bitDepth == 8, label ~ " uses unsupported PNG bit depth " ~ text(bitDepth));
    enforce(compressionMethod == 0 && filterMethod == 0,
        label ~ " uses unsupported PNG compression or filter method");
    enforce(interlaceMethod == 0, label ~ " uses unsupported PNG interlacing");
    enforce(idat.length > 0, label ~ " is missing IDAT data");

    const channels = channelCount(colorType, label);
    const stride = cast(size_t) width * cast(size_t) channels;
    const expected = (stride + 1) * cast(size_t) height;
    auto inflated = cast(ubyte[]) uncompress(idat);
    enforce(inflated.length >= expected, label ~ " has truncated pixel data");

    ubyte[] scanlines;
    scanlines.length = stride * cast(size_t) height;
    foreach (row; 0 .. height)
    {
        const filter = inflated[cast(size_t) row * (stride + 1)];
        const sourceStart = cast(size_t) row * (stride + 1) + 1;
        const targetStart = cast(size_t) row * stride;
        const previousStart = row == 0 ? size_t.max : targetStart - stride;
        foreach (index; 0 .. stride)
        {
            const raw = inflated[sourceStart + index];
            const left = index >= channels ? scanlines[targetStart + index - channels] : 0;
            const up = row > 0 ? scanlines[previousStart + index] : 0;
            const upperLeft = row > 0 && index >= channels
                ? scanlines[previousStart + index - channels] : 0;
            scanlines[targetStart + index] = cast(ubyte) ((cast(uint) raw +
                reconstructedFilterByte(filter, left, up, upperLeft, label)) & 0xffu);
        }
    }

    ubyte[] rgba;
    rgba.length = cast(size_t) width * cast(size_t) height * 4;
    foreach (pixel; 0 .. cast(size_t) width * cast(size_t) height)
    {
        const source = pixel * channels;
        const target = pixel * 4;
        switch (colorType)
        {
            case 0:
            {
                const value = scanlines[source];
                rgba[target + 0] = value;
                rgba[target + 1] = value;
                rgba[target + 2] = value;
                rgba[target + 3] = grayscaleAlpha(value, transparency);
                break;
            }
            case 2:
                rgba[target + 0] = scanlines[source + 0];
                rgba[target + 1] = scanlines[source + 1];
                rgba[target + 2] = scanlines[source + 2];
                rgba[target + 3] = rgbAlpha(rgba[target + 0], rgba[target + 1],
                    rgba[target + 2], transparency);
                break;
            case 3:
            {
                const index = scanlines[source];
                const paletteOffset = cast(size_t) index * 3;
                enforce(paletteOffset + 2 < palette.length,
                    label ~ " contains a palette index outside PLTE");
                rgba[target + 0] = palette[paletteOffset + 0];
                rgba[target + 1] = palette[paletteOffset + 1];
                rgba[target + 2] = palette[paletteOffset + 2];
                rgba[target + 3] = index < transparency.length ? transparency[index] : 255;
                break;
            }
            case 4:
                rgba[target + 0] = scanlines[source + 0];
                rgba[target + 1] = scanlines[source + 0];
                rgba[target + 2] = scanlines[source + 0];
                rgba[target + 3] = scanlines[source + 1];
                break;
            case 6:
                rgba[target + 0] = scanlines[source + 0];
                rgba[target + 1] = scanlines[source + 1];
                rgba[target + 2] = scanlines[source + 2];
                rgba[target + 3] = scanlines[source + 3];
                break;
            default:
                throw new Exception(label ~ " uses unsupported PNG color type " ~ text(colorType));
        }
    }
    return new RgbaImage(width, height, rgba);
}

private int channelCount(ubyte colorType, string label)
{
    switch (colorType)
    {
        case 0: return 1;
        case 2: return 3;
        case 3: return 1;
        case 4: return 2;
        case 6: return 4;
        default:
            throw new Exception(label ~ " uses unsupported PNG color type " ~ text(colorType));
    }
}

private uint reconstructedFilterByte(ubyte filter, ubyte left, ubyte up,
    ubyte upperLeft, string label)
{
    switch (filter)
    {
        case 0:
            return 0;
        case 1:
            return left;
        case 2:
            return up;
        case 3:
            return (cast(uint) left + cast(uint) up) / 2;
        case 4:
            return paeth(left, up, upperLeft);
        default:
            throw new Exception(label ~ " uses unsupported PNG row filter " ~ text(filter));
    }
}

private uint paeth(ubyte left, ubyte up, ubyte upperLeft)
    @safe pure nothrow @nogc
{
    const p = cast(int) left + cast(int) up - cast(int) upperLeft;
    const pa = absolute(p - cast(int) left);
    const pb = absolute(p - cast(int) up);
    const pc = absolute(p - cast(int) upperLeft);
    if (pa <= pb && pa <= pc) return left;
    if (pb <= pc) return up;
    return upperLeft;
}

private ubyte grayscaleAlpha(ubyte value, const(ubyte)[] transparency)
{
    if (transparency.length < 2) return 255;
    const transparent = cast(ubyte) readU16(transparency, 0);
    return value == transparent ? 0 : 255;
}

private ubyte rgbAlpha(ubyte red, ubyte green, ubyte blue,
    const(ubyte)[] transparency)
{
    if (transparency.length < 6) return 255;
    const tr = cast(ubyte) readU16(transparency, 0);
    const tg = cast(ubyte) readU16(transparency, 2);
    const tb = cast(ubyte) readU16(transparency, 4);
    return red == tr && green == tg && blue == tb ? 0 : 255;
}

private uint readU32(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 4 <= bytes.length, "Unexpected end of PNG data");
    return (cast(uint) bytes[offset] << 24) |
        (cast(uint) bytes[offset + 1] << 16) |
        (cast(uint) bytes[offset + 2] << 8) |
        cast(uint) bytes[offset + 3];
}

private ushort readU16(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 2 <= bytes.length, "Unexpected end of PNG data");
    return cast(ushort) ((cast(uint) bytes[offset] << 8) |
        cast(uint) bytes[offset + 1]);
}

private int absolute(int value) @safe pure nothrow @nogc
{
    return value < 0 ? -value : value;
}
