module aurora.image;

import aurora.types : Rect;
import std.conv : text;
import std.exception : enforce;
import std.file : read;
import std.zlib : uncompress, UnCompress;
import core.stdc.stdlib : malloc, free;
import core.stdc.string : memcpy;
import etc.c.zlib : z_stream, Z_OK, Z_STREAM_END, Z_NO_FLUSH,
    inflateInit2, inflate, inflateEnd;

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

/// RAII ubyte[] backed by malloc/free so large transient decode buffers never
/// touch the GC heap. Background thumbnail decoding allocates ~8MB per image;
/// on-the-GC buffers force stop-the-world collections that freeze the UI thread.
private struct MallocBytes
{
    void* _ptr;
    size_t _len;

    @disable this(this);
    ~this() @trusted { if (_ptr !is null) free(_ptr); }

    static MallocBytes allocate(size_t length) @trusted
    {
        MallocBytes result;
        result._len = length;
        result._ptr = malloc(length == 0 ? 1 : length);
        enforce(result._ptr !is null, "out of memory allocating image buffer");
        return result;
    }

    @property ubyte* ptr() const @trusted { return cast(ubyte*) _ptr; }
    @property size_t length() const { return _len; }
    @property bool empty() const { return _len == 0; }
}

/// GC-free zlib inflate of `idat` exactly `expectedSize` bytes into a malloc'd
/// buffer. Returns null if the stream does not end cleanly.
private MallocBytes inflateNogc(const(ubyte)[] idat, size_t expectedSize,
    string label)
{
    // A little slack so zlib can emit Z_STREAM_END without needing one extra
    // output byte (avail_out reaching 0 returns Z_BUF_ERROR, not Z_STREAM_END).
    auto inflated = MallocBytes.allocate(expectedSize + 4096);
    z_stream zs;
    const initErr = inflateInit2(&zs, 15);
    enforce(initErr == Z_OK, label ~ " failed to initialize zlib");
    scope (exit) inflateEnd(&zs);
    zs.next_in = cast(ubyte*) idat.ptr;
    zs.avail_in = cast(uint) idat.length;
    zs.next_out = inflated.ptr;
    zs.avail_out = cast(uint) (expectedSize + 4096);
    const err = inflate(&zs, Z_NO_FLUSH);
    enforce(err == Z_STREAM_END,
        label ~ " has corrupt or truncated compressed data");
    return inflated;
}

/// GC-free scan of the PNG chunks to concatenate the IDAT payload into a
/// malloc'd buffer (avoids the GC append/realloc of parsePngHeader).
private MallocBytes gatherIdatNogc(const(ubyte)[] bytes)
{
    immutable ubyte[8] signature = [137, 80, 78, 71, 13, 10, 26, 10];
    enforce(bytes.length >= signature.length && bytes[0 .. signature.length] == signature[],
        "PNG has an invalid signature");

    size_t idatLength;
    size_t offset = signature.length;
    bool sawEnd;
    while (offset + 12 <= bytes.length)
    {
        const length = readU32(bytes, offset);
        const chunkType = cast(string) bytes[offset + 4 .. offset + 8];
        if (chunkType == "IDAT") idatLength += length;
        else if (chunkType == "IEND") { sawEnd = true; }
        offset += 12 + length;
        if (sawEnd) break;
    }
    enforce(idatLength > 0, "PNG is missing IDAT data");

    auto idat = MallocBytes.allocate(idatLength);
    size_t idatPos = 0;
    offset = signature.length;
    sawEnd = false;
    while (offset + 12 <= bytes.length)
    {
        const length = readU32(bytes, offset);
        const chunkType = cast(string) bytes[offset + 4 .. offset + 8];
        if (chunkType == "IDAT")
        {
            memcpy(idat.ptr + idatPos, bytes.ptr + offset + 8, length);
            idatPos += length;
        }
        else if (chunkType == "IEND") { sawEnd = true; }
        offset += 12 + length;
        if (sawEnd || idatPos >= idatLength) break;
    }
    idat._len = idatPos;
    return idat;
}

/** Load a PNG and box-downscale it to `targetSide` (longer edge) in a single
 * pass, never materializing the full-resolution RGBA buffer. */
RgbaImage loadPngScaled(string path, int targetSide)
{
    return decodePngScaled(cast(const(ubyte)[]) read(path), path, targetSide);
}

/// GC-free load for the file-manager thumbnail worker: file bytes, IDAT, and the
/// inflated scanline buffer are all malloc-backed, so a large folder decode never
/// triggers stop-the-world GC that freezes the UI thread.
RgbaImage loadPngScaledNogc(string path, int targetSide)
{
    auto file = readFileNogc(path);
    const(ubyte)[] bytes = file.ptr[0 .. file.length];
    return decodePngScaled(bytes, path, targetSide);
}

/// GC-free read of a whole file into a malloc'd buffer.
private MallocBytes readFileNogc(string path)
{
    import std.file : getSize;
    const size = getSize(path);
    auto buf = MallocBytes.allocate(size);
    import std.stdio : File;
    auto f = File(path, "rb");
    scope (exit) f.close();
    const read = f.rawRead(buf.ptr[0 .. size]);
    enforce(read.length == size, "file '" ~ path ~ "' changed while reading");
    return buf;
}

/**
 * Load an ICO container, preferring a square entry closest to `targetSize`.
 *
 * Entries may be PNG-compressed (the common Vista+ form) or classic 24/32-bit
 * bitmaps with an AND mask; both are decoded.
 */
RgbaImage loadIcoImage(string path, int targetSize = 32)
{
    return decodeIcoImage(cast(const(ubyte)[]) read(path), path, targetSize);
}

RgbaImage decodeIcoImage(const(ubyte)[] bytes, string label = "ICO",
    int targetSize = 32)
{
    enforce(bytes.length >= 6, label ~ " is truncated");
    enforce(bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 1 && bytes[3] == 0,
        label ~ " is not an ICO container");
    const count = readU16LE(bytes, 4);
    enforce(count > 0, label ~ " contains no images");
    enforce(6 + cast(size_t) count * 16 <= bytes.length,
        label ~ " has a truncated image directory");

    int bestScore = int.max;
    size_t bestOffset;
    size_t bestLength;
    foreach (index; 0 .. count)
    {
        const entry = 6 + cast(size_t) index * 16;
        const entryWidth = bytes[entry] == 0 ? 256 : cast(int) bytes[entry];
        const offset = cast(size_t) readU32LE(bytes, entry + 12);
        const length = cast(size_t) readU32LE(bytes, entry + 8);
        if (offset + length > bytes.length) continue;
        // Prefer the entry closest to the target size; entries smaller than
        // the target are penalized so a sharp nearest-size is chosen.
        int score = entryWidth - targetSize;
        if (score < 0) score = -score * 2;
        if (score < bestScore)
        {
            bestScore = score;
            bestOffset = offset;
            bestLength = length;
        }
    }
    enforce(bestLength > 0, label ~ " contains no usable image");

    const data = bytes[bestOffset .. bestOffset + bestLength];
    if (data.length >= 8 && data[0] == 137 && data[1] == 80 && data[2] == 78 &&
        data[3] == 71)
        return decodePngImage(data, label ~ " icon entry");
    return decodeIcoBmp(data, label ~ " icon entry");
}

private RgbaImage decodeIcoBmp(const(ubyte)[] bytes, string label)
{
    enforce(bytes.length >= 12, label ~ " has a truncated icon bitmap");
    const headerSize = readU32LE(bytes, 0);
    enforce(headerSize >= 12 && headerSize <= bytes.length,
        label ~ " has an unsupported icon bitmap header");

    int width;
    int combinedHeight;
    uint bitCount;
    uint compression;
    if (headerSize == 12)
    {
        width = readU16LE(bytes, 4);
        combinedHeight = readU16LE(bytes, 6);
        bitCount = readU16LE(bytes, 10);
        compression = 0;
    }
    else
    {
        width = cast(int) readI32LE(bytes, 4);
        combinedHeight = cast(int) readI32LE(bytes, 8);
        bitCount = readU16LE(bytes, 14);
        compression = readU32LE(bytes, 16);
    }
    enforce(width > 0 && combinedHeight > 0,
        label ~ " has invalid icon dimensions");
    enforce(combinedHeight % 2 == 0, label ~ " has an odd combined icon height");
    const imageHeight = combinedHeight / 2;
    enforce(bitCount == 8 || bitCount == 24 || bitCount == 32,
        label ~ " uses unsupported icon bit depth " ~ text(bitCount));
    enforce(compression == 0 || compression == 3,
        label ~ " uses unsupported icon bitmap compression");

    size_t cursor = headerSize;
    if (headerSize >= 40 && compression == 3)
    {
        // BI_BITFIELDS: four DWORD channel masks follow the header.
        enforce(cursor + 16 <= bytes.length, label ~ " is truncated");
        cursor += 16;
    }
    const rowBytes = ((cast(size_t) width * bitCount + 31) / 32) * 4;
    const andRowBytes = ((cast(size_t) width + 31) / 32) * 4;
    enforce(cursor + rowBytes * cast(size_t) imageHeight +
        andRowBytes * cast(size_t) imageHeight <= bytes.length,
        label ~ " pixel data is truncated");

    ubyte[] rgba;
    rgba.length = cast(size_t) width * cast(size_t) imageHeight * 4;
    // ICO bitmaps are stored bottom-up; the first scanline is the bottom row.
    foreach (y; 0 .. imageHeight)
    {
        const srcRow = imageHeight - 1 - y;
        const rowStart = cursor + cast(size_t) srcRow * rowBytes;
        const andRowStart = cursor + cast(size_t) imageHeight * rowBytes +
            cast(size_t) srcRow * andRowBytes;
        foreach (x; 0 .. width)
        {
            uint r = 0;
            uint g = 0;
            uint b = 0;
            uint a = 255;
            if (bitCount == 32)
            {
                const px = rowStart + cast(size_t) x * 4;
                b = bytes[px];
                g = bytes[px + 1];
                r = bytes[px + 2];
                a = bytes[px + 3];
            }
            else if (bitCount == 24)
            {
                const px = rowStart + cast(size_t) x * 3;
                b = bytes[px];
                g = bytes[px + 1];
                r = bytes[px + 2];
            }
            else
            {
                const index = bytes[rowStart + cast(size_t) x];
                const pal = cursor + cast(size_t) index * 4;
                enforce(pal + 3 < bytes.length, label ~ " has a truncated palette");
                b = bytes[pal];
                g = bytes[pal + 1];
                r = bytes[pal + 2];
                a = bytes[pal + 3];
            }
            if (a != 0)
            {
                const byteIndex = x / 8;
                const bitIndex = 7 - (x % 8);
                if ((bytes[andRowStart + byteIndex] & (1 << bitIndex)) != 0)
                    a = 0;
            }
            const target = (cast(size_t) y * cast(size_t) width + cast(size_t) x) * 4;
            rgba[target + 0] = cast(ubyte) r;
            rgba[target + 1] = cast(ubyte) g;
            rgba[target + 2] = cast(ubyte) b;
            rgba[target + 3] = cast(ubyte) a;
        }
    }
    return new RgbaImage(width, imageHeight, rgba);
}

/// Parsed PNG IHDR/chunk header shared by the full and scaled decoders.
private struct PngHeader
{
    int width;
    int height;
    ubyte colorType;
    ubyte[] idat;
    ubyte[] palette;
    ubyte[] transparency;
}

/// Parse the PNG signature + chunks, returning the header fields and the
/// concatenated IDAT payload. All structural checks (bit depth, compression,
/// filter, interlace, IHDR/IEND presence) are enforced here.
private PngHeader parsePngHeader(const(ubyte)[] bytes, string label)
{
    immutable ubyte[8] signature = [137, 80, 78, 71, 13, 10, 26, 10];
    enforce(bytes.length >= signature.length && bytes[0 .. signature.length] == signature[],
        label ~ " has an invalid PNG signature");

    PngHeader header;
    ubyte bitDepth;
    ubyte compressionMethod;
    ubyte filterMethod;
    ubyte interlaceMethod;

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
                header.width = cast(int) readU32(chunk, 0);
                header.height = cast(int) readU32(chunk, 4);
                bitDepth = chunk[8];
                header.colorType = chunk[9];
                compressionMethod = chunk[10];
                filterMethod = chunk[11];
                interlaceMethod = chunk[12];
                sawHeader = true;
                break;
            case "PLTE":
                header.palette = chunk.dup;
                break;
            case "IDAT":
                header.idat ~= chunk;
                break;
            case "tRNS":
                header.transparency = chunk.dup;
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
    enforce(header.width > 0 && header.height > 0, label ~ " has invalid dimensions");
    enforce(bitDepth == 8, label ~ " uses unsupported PNG bit depth " ~ text(bitDepth));
    enforce(compressionMethod == 0 && filterMethod == 0,
        label ~ " uses unsupported PNG compression or filter method");
    enforce(interlaceMethod == 0, label ~ " uses unsupported PNG interlacing");
    enforce(header.idat.length > 0, label ~ " is missing IDAT data");
    return header;
}

RgbaImage decodePngImage(const(ubyte)[] bytes, string label = "PNG")
{
    PngHeader header = parsePngHeader(bytes, label);
    const int width = header.width;
    const int height = header.height;
    const ubyte colorType = header.colorType;
    const ubyte[] palette = header.palette;
    const ubyte[] transparency = header.transparency;

    const channels = channelCount(colorType, label);
    const stride = cast(size_t) width * cast(size_t) channels;
    const expected = (stride + 1) * cast(size_t) height;
    auto inflated = cast(ubyte[]) uncompress(header.idat);
    enforce(inflated.length >= expected, label ~ " has truncated pixel data");

    // Fuse PNG unfilter + channel expansion into a single pass. Filters only
    // reference the previous row (and the left/upper-left bytes within the
    // current row), so a one-row lookback is sufficient -- we never need to
    // materialize the full unfiltered scanline plane. This avoids a full-image
    // intermediate buffer and a second full-image pass, which is the dominant
    // cost for large images (thumbnails decode the source at full resolution).
    ubyte[] rgba;
    rgba.length = cast(size_t) width * cast(size_t) height * 4;
    ubyte[] prevRow;
    prevRow.length = stride;
    ubyte[] currRow;
    currRow.length = stride;

    size_t src = 0;
    foreach (row; 0 .. height)
    {
        const filter = inflated[src];
        ++src;
        // Dispatch the PNG row filter type ONCE per row and run a tight,
        // branch-free loop per filter. The tiny full-image decompress time for
        // thumbnails is dominated by per-byte filter reconstruction, so this
        // replaces the generic reconstructedFilterByte() call (which re-dispatched
        // the switch + carried a string for every one of the width*height*channels
        // bytes) with a single dispatch + straight-line inner loops.
        switch (filter)
        {
            case 0:
                foreach (index; 0 .. stride)
                    currRow[index] = inflated[src + index];
                break;
            case 1:
                foreach (index; 0 .. stride)
                {
                    const left = index >= channels ? currRow[index - channels] : 0;
                    currRow[index] = cast(ubyte)
                        ((cast(uint) inflated[src + index] + left) & 0xffu);
                }
                break;
            case 2:
                if (row == 0)
                {
                    foreach (index; 0 .. stride)
                        currRow[index] = inflated[src + index];
                }
                else
                {
                    foreach (index; 0 .. stride)
                    {
                        const up = prevRow[index];
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + up) & 0xffu);
                    }
                }
                break;
            case 3:
                if (row == 0)
                {
                    foreach (index; 0 .. stride)
                    {
                        const left = index >= channels ? currRow[index - channels] : 0;
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + (left + 0) / 2) & 0xffu);
                    }
                }
                else
                {
                    foreach (index; 0 .. stride)
                    {
                        const left = index >= channels ? currRow[index - channels] : 0;
                        const up = prevRow[index];
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + (left + up) / 2) & 0xffu);
                    }
                }
                break;
            case 4:
                if (row == 0)
                {
                    foreach (index; 0 .. stride)
                    {
                        const left = index >= channels ? currRow[index - channels] : 0;
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + left) & 0xffu);
                    }
                }
                else
                {
                    foreach (index; 0 .. stride)
                    {
                        const left = index >= channels ? currRow[index - channels] : 0;
                        const up = prevRow[index];
                        const ul = index >= channels ? prevRow[index - channels] : 0;
                        const p = cast(int) left + cast(int) up - cast(int) ul;
                        const pa = p - left; const pab = pa < 0 ? -pa : pa;
                        const pb = p - up;   const pbb = pb < 0 ? -pb : pb;
                        const pc = p - ul;   const pcb = pc < 0 ? -pc : pc;
                        const recon = cast(uint)
                            ((pab <= pbb && pab <= pcb) ? left :
                             (pbb <= pcb ? up : ul));
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + recon) & 0xffu);
                    }
                }
                break;
            default:
                throw new Exception(label ~ " uses unsupported PNG row filter " ~ text(filter));
        }
        src += stride;

        const pixelStart = cast(size_t) row * cast(size_t) width;
        switch (colorType)
        {
            case 0:
                foreach (x; 0 .. cast(size_t) width)
                {
                    const value = currRow[x];
                    const t = (pixelStart + x) * 4;
                    rgba[t + 0] = value;
                    rgba[t + 1] = value;
                    rgba[t + 2] = value;
                    rgba[t + 3] = grayscaleAlpha(value, transparency);
                }
                break;
            case 2:
                foreach (x; 0 .. cast(size_t) width)
                {
                    const cs = x * channels;
                    const t = (pixelStart + x) * 4;
                    const r = currRow[cs + 0];
                    const g = currRow[cs + 1];
                    const b = currRow[cs + 2];
                    rgba[t + 0] = r;
                    rgba[t + 1] = g;
                    rgba[t + 2] = b;
                    rgba[t + 3] = rgbAlpha(r, g, b, transparency);
                }
                break;
            case 3:
                foreach (x; 0 .. cast(size_t) width)
                {
                    const index = currRow[x];
                    const paletteOffset = cast(size_t) index * 3;
                    enforce(paletteOffset + 2 < palette.length,
                        label ~ " contains a palette index outside PLTE");
                    const t = (pixelStart + x) * 4;
                    rgba[t + 0] = palette[paletteOffset + 0];
                    rgba[t + 1] = palette[paletteOffset + 1];
                    rgba[t + 2] = palette[paletteOffset + 2];
                    rgba[t + 3] = index < transparency.length ? transparency[index] : 255;
                }
                break;
            case 4:
                foreach (x; 0 .. cast(size_t) width)
                {
                    const cs = x * channels;
                    const t = (pixelStart + x) * 4;
                    const value = currRow[cs + 0];
                    rgba[t + 0] = value;
                    rgba[t + 1] = value;
                    rgba[t + 2] = value;
                    rgba[t + 3] = currRow[cs + 1];
                }
                break;
            case 6:
                foreach (x; 0 .. cast(size_t) width)
                {
                    const cs = x * channels;
                    const t = (pixelStart + x) * 4;
                    rgba[t + 0] = currRow[cs + 0];
                    rgba[t + 1] = currRow[cs + 1];
                    rgba[t + 2] = currRow[cs + 2];
                    rgba[t + 3] = currRow[cs + 3];
                }
                break;
            default:
                throw new Exception(label ~ " uses unsupported PNG color type " ~ text(colorType));
        }

        auto swap = prevRow;
        prevRow = currRow;
        currRow = swap;
    }
    return new RgbaImage(width, height, rgba);
}

/**
 * Decode a non-interlaced 8-bit PNG directly into a downscaled RGBA image whose
 * longer side is `targetSide` (aspect preserved), without ever materializing the
 * full-resolution RGBA pixel buffer. This is the thumbnail path: the full-height
 * inflate is unavoidable, but we fuse unfilter + box-downscale into one pass over
 * the unfiltered scanline rows, so only the small output buffer and a 1-row
 * lookback are allocated instead of width*height*4 bytes.
 */
RgbaImage decodePngScaled(const(ubyte)[] bytes, string label,
    int targetSide)
{
    enforce(targetSide > 0, "scaled PNG target side must be positive");
    PngHeader header = parsePngHeader(bytes, label);
    const int width = header.width;
    const int height = header.height;
    const ubyte colorType = header.colorType;
    const ubyte[] palette = header.palette;
    const ubyte[] transparency = header.transparency;

    const channels = channelCount(colorType, label);
    const stride = cast(size_t) width * cast(size_t) channels;

    // Target dimensions, same aspect-preserving rule as boxDownscale:
    // match `targetSide` on the longer edge.
    int outWidth = targetSide;
    int outHeight = cast(int) ((cast(long) targetSide * height + width / 2) / width);
    if (outHeight > targetSide)
    {
        outHeight = targetSide;
        outWidth = cast(int) ((cast(long) targetSide * width + height / 2) / height);
    }
    outWidth = outWidth < 1 ? 1 : outWidth;
    outHeight = outHeight < 1 ? 1 : outHeight;

    // Inflate the IDAT into a malloc'd buffer (never the GC heap). This is the
    // ~8MB per-thumbnail allocation that, on the GC heap, would force stop-the-
    // world collections which freeze the UI thread on a busy image folder.
    // The IDAT payload is gathered into a malloc'd buffer too (no GC append).
    MallocBytes idatBuf = gatherIdatNogc(bytes);
    const(ubyte)[] idat = idatBuf.ptr[0 .. idatBuf.length];
    MallocBytes inflatedBuf = inflateNogc(idat,
        (stride + 1) * cast(size_t) height, label);
    const(ubyte)[] inflated = inflatedBuf.ptr[0 .. inflatedBuf.length];
    enforce(inflated.length >= (stride + 1) * cast(size_t) height,
        label ~ " has truncated pixel data");
    scope (exit) { /* idatBuf/inflatedBuf free via RAII */ }

    ubyte[] outPixels;
    outPixels.length = cast(size_t) outWidth * cast(size_t) outHeight * 4;
    ulong[] sums;
    sums.length = cast(size_t) outWidth * 4;
    uint[] counts;
    counts.length = cast(size_t) outWidth;

    // Map each source column to the box-downscale output column it belongs to.
    // This reproduces the contiguous binning of boxDownscale exactly:
    // outX covers source columns [outX*inW/outW, (outX+1)*inW/outW).
    int[] colMap;
    colMap.length = cast(size_t) width;
    for (int outX = 0; outX < outWidth; ++outX)
    {
        const startX = cast(int) ((cast(long) outX * width) / outWidth);
        const endX = cast(int) (((cast(long) (outX + 1) * width) / outWidth));
        for (int x = startX; x < endX; ++x)
            colMap[x] = outX;
    }
    for (int x = 0; x < width; ++x)
        if (colMap[x] < 0 || colMap[x] >= outWidth) colMap[x] = outWidth - 1;

    ubyte[] prevRow;
    prevRow.length = stride;
    ubyte[] currRow;
    currRow.length = stride;

    int outY = 0;
    size_t src = 0;
    foreach (row; 0 .. height)
    {
        const filter = inflated[src];
        ++src;
        switch (filter)
        {
            case 0:
                foreach (index; 0 .. stride)
                    currRow[index] = inflated[src + index];
                break;
            case 1:
                foreach (index; 0 .. stride)
                {
                    const left = index >= channels ? currRow[index - channels] : 0;
                    currRow[index] = cast(ubyte)
                        ((cast(uint) inflated[src + index] + left) & 0xffu);
                }
                break;
            case 2:
                if (row == 0)
                {
                    foreach (index; 0 .. stride)
                        currRow[index] = inflated[src + index];
                }
                else
                {
                    foreach (index; 0 .. stride)
                    {
                        const up = prevRow[index];
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + up) & 0xffu);
                    }
                }
                break;
            case 3:
                if (row == 0)
                {
                    foreach (index; 0 .. stride)
                    {
                        const left = index >= channels ? currRow[index - channels] : 0;
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + (left + 0) / 2) & 0xffu);
                    }
                }
                else
                {
                    foreach (index; 0 .. stride)
                    {
                        const left = index >= channels ? currRow[index - channels] : 0;
                        const up = prevRow[index];
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + (left + up) / 2) & 0xffu);
                    }
                }
                break;
            case 4:
                if (row == 0)
                {
                    foreach (index; 0 .. stride)
                    {
                        const left = index >= channels ? currRow[index - channels] : 0;
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + left) & 0xffu);
                    }
                }
                else
                {
                    foreach (index; 0 .. stride)
                    {
                        const left = index >= channels ? currRow[index - channels] : 0;
                        const up = prevRow[index];
                        const ul = index >= channels ? prevRow[index - channels] : 0;
                        const p = cast(int) left + cast(int) up - cast(int) ul;
                        const pa = p - left; const pab = pa < 0 ? -pa : pa;
                        const pb = p - up;   const pbb = pb < 0 ? -pb : pb;
                        const pc = p - ul;   const pcb = pc < 0 ? -pc : pc;
                        const recon = cast(uint)
                            ((pab <= pbb && pab <= pcb) ? left :
                             (pbb <= pcb ? up : ul));
                        currRow[index] = cast(ubyte)
                            ((cast(uint) inflated[src + index] + recon) & 0xffu);
                    }
                }
                break;
            default:
                throw new Exception(label ~ " uses unsupported PNG row filter " ~ text(filter));
        }
        src += stride;

        // Accumulate this source row's pixels into the box-downscaled output.
        foreach (x; 0 .. cast(size_t) width)
        {
            const cs = x * channels;
            const outX = colMap[x];
            const so = outX * 4;
            ubyte r, g, b, a;
            switch (colorType)
            {
                case 0:
                    r = currRow[cs]; g = r; b = r;
                    a = grayscaleAlpha(r, transparency);
                    break;
                case 2:
                    r = currRow[cs]; g = currRow[cs+1]; b = currRow[cs+2];
                    a = rgbAlpha(r, g, b, transparency);
                    break;
                case 3:
                    {
                        const index = currRow[cs];
                        const p = cast(size_t) index * 3;
                        r = palette[p]; g = palette[p+1]; b = palette[p+2];
                        a = index < transparency.length ? transparency[index] : 255;
                    }
                    break;
                case 4:
                    r = currRow[cs]; g = r; b = r; a = currRow[cs+1];
                    break;
                case 6:
                    r = currRow[cs]; g = currRow[cs+1]; b = currRow[cs+2];
                    a = currRow[cs+3];
                    break;
                default:
                    throw new Exception(label ~ " uses unsupported PNG color type " ~ text(colorType));
            }
            sums[so] += r;
            sums[so + 1] += g;
            sums[so + 2] += b;
            sums[so + 3] += a;
            ++counts[outX];
        }

        // Finalize output row `outY` once `row` is the last source row that
        // maps to it (the next source row belongs to the next output row).
        const outEndY = cast(int) ((cast(long) (outY + 1) * height) / outHeight);
        if (row + 1 >= outEndY)
        {
            const oy = outY;
            foreach (ox; 0 .. cast(size_t) outWidth)
            {
                const c = counts[ox];
                const so = ox * 4;
                const cv = c ? cast(uint) c : 1;
                const o = (cast(size_t) oy * outWidth + ox) * 4;
                outPixels[o] = cast(ubyte)(sums[so] / cv);
                outPixels[o+1] = cast(ubyte)(sums[so+1] / cv);
                outPixels[o+2] = cast(ubyte)(sums[so+2] / cv);
                outPixels[o+3] = cast(ubyte)(sums[so+3] / cv);
            }
            foreach (i; 0 .. sums.length) sums[i] = 0;
            foreach (i; 0 .. counts.length) counts[i] = 0;
            ++outY;
            if (outY >= outHeight) break;
        }

        auto swap = prevRow;
        prevRow = currRow;
        currRow = swap;
    }
    return new RgbaImage(outWidth, outHeight, outPixels);
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

private int readI32(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 4 <= bytes.length, "Unexpected end of icon data");
    return cast(int) ((cast(uint) bytes[offset]) |
        (cast(uint) bytes[offset + 1] << 8) |
        (cast(uint) bytes[offset + 2] << 16) |
        (cast(uint) bytes[offset + 3] << 24));
}

// ICO/Windows data is little-endian, unlike the big-endian PNG readers above.

private ushort readU16LE(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 2 <= bytes.length, "Unexpected end of icon data");
    return cast(ushort) (cast(uint) bytes[offset] |
        (cast(uint) bytes[offset + 1] << 8));
}

private uint readU32LE(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 4 <= bytes.length, "Unexpected end of icon data");
    return cast(uint) bytes[offset] |
        (cast(uint) bytes[offset + 1] << 8) |
        (cast(uint) bytes[offset + 2] << 16) |
        (cast(uint) bytes[offset + 3] << 24);
}

private int readI32LE(const(ubyte)[] bytes, size_t offset)
{
    return cast(int) readU32LE(bytes, offset);
}

private int absolute(int value) @safe pure nothrow @nogc
{
    return value < 0 ? -value : value;
}
