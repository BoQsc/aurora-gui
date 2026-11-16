module aurora.image;

import aurora.types : Rect, maxInt, minInt, clampInt;
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

// ---------------------------------------------------------------------------
// Unified image-format registry
//
// This is the single general entry point every Aurora project should use
// instead of hand-rolling its own decoders/encoders. `decodeImage` sniffs the
// container and dispatches; `encodePng` writes a PNG. New codecs (JPEG, GIF,
// BMP, ...) plug into `decodeImage` here so all applications pick them up.
// ---------------------------------------------------------------------------

/** Raster image container formats recognized by the shared registry. */
enum ImageFormat : ubyte
{
    unknown,
    png,
    jpeg,
    gif,
    bmp,
    tga,
    pnm,
    ico,
    webp,   /// reserved: not yet implemented
}

/// Human-readable format name (diagnostics and tests).
string imageFormatName(ImageFormat format) @safe pure nothrow @nogc
{
    switch (format)
    {
        case ImageFormat.png:  return "png";
        case ImageFormat.jpeg: return "jpeg";
        case ImageFormat.gif:  return "gif";
        case ImageFormat.bmp:  return "bmp";
        case ImageFormat.tga:  return "tga";
        case ImageFormat.pnm:  return "pnm";
        case ImageFormat.ico:  return "ico";
        case ImageFormat.webp: return "webp";
        case ImageFormat.unknown:
        default:
            return "unknown";
    }
}

private bool bytesMatchAt(const(ubyte)[] bytes, size_t at, const(ubyte)[] pattern)
    @safe pure nothrow @nogc
{
    if (at + pattern.length > bytes.length) return false;
    foreach (i; 0 .. pattern.length)
        if (bytes[at + i] != pattern[i]) return false;
    return true;
}

/**
 * Detect the container format from the leading bytes. TGA has no reliable
 * signature and is therefore not sniffed here (callers fall back to the file
 * extension).
 */
ImageFormat sniffImageFormat(const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    static immutable ubyte[8] pngSignature =
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    if (bytesMatchAt(bytes, 0, pngSignature[])) return ImageFormat.png;
    // JPEG: start-of-image marker FF D8 followed by a marker (FF xx).
    if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 &&
        bytes[2] == 0xFF)
        return ImageFormat.jpeg;
    // GIF87a / GIF89a.
    if (bytesMatchAt(bytes, 0, cast(const(ubyte)[]) "GIF8"))
        return ImageFormat.gif;
    // BMP: "BM".
    if (bytesMatchAt(bytes, 0, cast(const(ubyte)[]) "BM"))
        return ImageFormat.bmp;
    // WebP: "RIFF" <size> "WEBP".
    if (bytesMatchAt(bytes, 0, cast(const(ubyte)[]) "RIFF") &&
        bytesMatchAt(bytes, 8, cast(const(ubyte)[]) "WEBP"))
        return ImageFormat.webp;
    // ICO/CUR: reserved 0, type 1 (icon) or 2 (cursor), then a non-zero count.
    // The count check keeps TGA (which often starts 00 00 0x 00) from being
    // mistaken for an icon container.
    if (bytes.length >= 6 && bytes[0] == 0 && bytes[1] == 0 &&
        (bytes[2] == 1 || bytes[2] == 2) && bytes[3] == 0 &&
        (bytes[4] != 0 || bytes[5] != 0))
        return ImageFormat.ico;
    // PNM/PAM: "P1".."P7".
    if (bytes.length >= 2 && bytes[0] == 'P' &&
        bytes[1] >= '1' && bytes[1] <= '7')
        return ImageFormat.pnm;
    return ImageFormat.unknown;
}

/**
 * Decode any recognized raster image into straight-alpha RGBA8. This is the
 * single shared decode path for all Aurora applications.
 */
RgbaImage decodeImage(const(ubyte)[] bytes, string label = "image")
{
    enforce(bytes.length > 0, label ~ " is empty.");
    const format = sniffImageFormat(bytes);
    switch (format)
    {
        case ImageFormat.png:
            return decodePngImage(bytes, label);
        case ImageFormat.ico:
            return decodeIcoImage(bytes, label);
        case ImageFormat.gif:
            return decodeGifImage(bytes, label);
        case ImageFormat.jpeg:
            return decodeJpegImage(bytes, label);
        case ImageFormat.webp:
            return decodeWebpImage(bytes, label);
        case ImageFormat.bmp:
            return decodeBmpImage(bytes, label);
        case ImageFormat.pnm:
            return decodePnmImage(bytes, label);
        case ImageFormat.tga:
            return decodeTgaImage(bytes, label);
        case ImageFormat.unknown:
        default:
            throw new Exception("Unrecognized image format: " ~ label);
    }
}

/// Load and decode a file through the shared `decodeImage` path.
RgbaImage loadImage(string path)
{
    return decodeImage(cast(const(ubyte)[]) read(path), path);
}

private void appendBe32(ref ubyte[] buffer, uint value)
{
    buffer ~= cast(ubyte) (value >> 24);
    buffer ~= cast(ubyte) (value >> 16);
    buffer ~= cast(ubyte) (value >> 8);
    buffer ~= cast(ubyte) value;
}

private void appendPngChunk(ref ubyte[] output, string type,
    const(ubyte)[] payload)
{
    import std.zlib : crc32;
    appendBe32(output, cast(uint) payload.length);
    ubyte[] crcInput;
    foreach (ch; type)
        crcInput ~= cast(ubyte) ch;
    crcInput ~= payload;
    output ~= crcInput[0 .. 4];
    output ~= payload;
    appendBe32(output, crc32(0, crcInput));
}

/**
 * Encode straight-alpha RGBA8 pixels as a PNG (8-bit truecolor + alpha,
 * filter type 0 on every row). This is the shared PNG writer so applications
 * stop hand-rolling PNG output.
 */
ubyte[] encodePng(const(RgbaImage) image)
{
    import std.zlib : compress;
    const w = image.width();
    const h = image.height();
    enforce(w > 0 && h > 0, "Cannot encode an empty image");
    const pixels = image.pixels();
    enforce(pixels.length >= cast(size_t) w * h * 4,
        "RGBA pixel buffer is too small");

    ubyte[] raw;
    raw.reserve(cast(size_t) h * (1 + cast(size_t) w * 4));
    foreach (row; 0 .. h)
    {
        raw ~= cast(ubyte) 0;   // filter type: none
        const start = cast(size_t) row * w * 4;
        raw ~= pixels[start .. start + cast(size_t) w * 4];
    }
    const compressed = cast(const(ubyte)[]) compress(raw);

    ubyte[] png;
    png ~= [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    ubyte[] ihdr;
    appendBe32(ihdr, cast(uint) w);
    appendBe32(ihdr, cast(uint) h);
    ihdr ~= cast(ubyte) 8;   // bit depth
    ihdr ~= cast(ubyte) 6;   // color type: truecolor + alpha
    ihdr ~= cast(ubyte) 0;   // compression
    ihdr ~= cast(ubyte) 0;   // filter
    ihdr ~= cast(ubyte) 0;   // interlace
    appendPngChunk(png, "IHDR", ihdr);
    appendPngChunk(png, "IDAT", compressed);
    appendPngChunk(png, "IEND", []);
    return png;
}

unittest
{
    // Format sniffing recognizes each container's leading bytes.
    assert(sniffImageFormat([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) ==
        ImageFormat.png);
    assert(sniffImageFormat([0xFF, 0xD8, 0xFF, 0xE0, 0x00]) == ImageFormat.jpeg);
    assert(sniffImageFormat(cast(const(ubyte)[]) "GIF89a....") == ImageFormat.gif);
    assert(sniffImageFormat(cast(const(ubyte)[]) "GIF87a....") == ImageFormat.gif);
    assert(sniffImageFormat(cast(const(ubyte)[]) "BM......") == ImageFormat.bmp);
    assert(sniffImageFormat(cast(const(ubyte)[])
        "RIFF\0\0\0\0WEBPVP8 ") == ImageFormat.webp);
    assert(sniffImageFormat([0, 0, 1, 0, 1, 0]) == ImageFormat.ico);
    assert(sniffImageFormat(cast(const(ubyte)[]) "P6\n1 1\n255\n") == ImageFormat.pnm);
    assert(sniffImageFormat(cast(const(ubyte)[]) "not an image") ==
        ImageFormat.unknown);
    assert(imageFormatName(ImageFormat.jpeg) == "jpeg");

    // The shared encoder round-trips through the shared decoder, preserving
    // every RGBA channel (including alpha).
    auto image = new RgbaImage(2, 2, [
        255, 0, 0, 255,
        0, 255, 0, 255,
        0, 0, 255, 255,
        255, 255, 0, 128,
    ]);
    auto png = encodePng(image);
    assert(sniffImageFormat(png) == ImageFormat.png);
    auto decoded = decodeImage(png, "roundtrip");
    assert(decoded.width() == 2 && decoded.height() == 2);
    const px = decoded.pixels();
    assert(px[0] == 255 && px[1] == 0 && px[2] == 0 && px[3] == 255);
    assert(px[4] == 0 && px[5] == 255 && px[6] == 0 && px[7] == 255);
    assert(px[8] == 0 && px[9] == 0 && px[10] == 255 && px[11] == 255);
    assert(px[12] == 255 && px[13] == 255 && px[14] == 0 && px[15] == 128);
}

// ---------------------------------------------------------------------------
// GIF (first frame)
//
// Hoisted from the Aurora Image Viewer's standalone decoder so the whole
// repository shares one GIF implementation. Decodes the first image frame,
// honoring the global/local color tables, transparency, and interlace.
// ---------------------------------------------------------------------------

/// Is this an 87a/89a GIF stream?
bool isGif(const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    return bytes.length >= 6 && bytes[0] == 'G' && bytes[1] == 'I' &&
        bytes[2] == 'F' && bytes[3] == '8' &&
        (bytes[4] == '7' || bytes[4] == '9') && bytes[5] == 'a';
}

/// Decode the first frame of a GIF into straight-alpha RGBA8.
RgbaImage decodeGifImage(const(ubyte)[] bytes, string label = "GIF")
{
    enforce(isGif(bytes), label ~ " is not a GIF container");
    enforce(bytes.length >= 13, label ~ " is truncated");
    // GIF multi-byte integers are little-endian (unlike PNG's big-endian).
    const width = readU16LE(bytes, 6);
    const height = readU16LE(bytes, 8);

    const packed = bytes[10];
    const bool globalColorTable = (packed & 0x80u) != 0;
    const uint globalTableSize = globalColorTable ?
        (1u << ((packed & 0x07u) + 1u)) : 0u;

    size_t offset = 13;
    enforce(offset + cast(size_t) globalTableSize * 3 <= bytes.length,
        label ~ " has a truncated global color table");
    const ubyte[] globalPalette = globalColorTable ?
        bytes[13 .. 13 + cast(size_t) globalTableSize * 3] : null;
    offset += cast(size_t) globalTableSize * 3;

    bool hasTransparency;
    int transparentIndex = -1;

    while (offset < bytes.length)
    {
        const marker = bytes[offset++];
        if (marker == 0x3b) break;   // trailer
        if (marker == 0x21)          // extension: skip (note transparency flag)
        {
            if (offset >= bytes.length) break;
            const extension = bytes[offset++];
            if (extension == 0xf9 && offset + 6 <= bytes.length)
            {
                const blockSize = bytes[offset];
                if (blockSize >= 4)
                {
                    const flags = bytes[offset + 1];
                    hasTransparency = (flags & 0x01u) != 0;
                    transparentIndex = bytes[offset + 4];
                    offset += blockSize + 1;
                    continue;
                }
            }
            skipGifSubBlocks(bytes, offset);
        }
        else if (marker == 0x2c)     // image descriptor
        {
            enforce(offset + 9 <= bytes.length, label ~ " is truncated");
            const frameWidth = readU16LE(bytes, offset + 4);
            const frameHeight = readU16LE(bytes, offset + 6);
            const imagePacked = bytes[offset + 8];
            const bool interlaced = (imagePacked & 0x40u) != 0;
            offset += 9;
            const bool localTable = (imagePacked & 0x80u) != 0;
            const uint localSize = localTable ?
                (1u << ((imagePacked & 0x07u) + 1u)) : 0u;
            enforce(offset + cast(size_t) localSize * 3 <= bytes.length,
                label ~ " has a truncated local color table");
            const ubyte[] localPalette = localTable ?
                bytes[offset .. offset + cast(size_t) localSize * 3] : null;
            offset += cast(size_t) localSize * 3;

            enforce(frameWidth > 0 && frameHeight > 0,
                label ~ " has invalid frame dimensions");
            const size_t pixelCount =
                cast(size_t) frameWidth * cast(size_t) frameHeight;

            if (offset >= bytes.length) break;
            const int minCodeSize = bytes[offset++];
            ubyte[] lzwData;
            while (offset < bytes.length)
            {
                const blockSize = bytes[offset++];
                if (blockSize == 0) break;
                enforce(offset + blockSize <= bytes.length,
                    label ~ " has a truncated LZW block");
                lzwData ~= bytes[offset .. offset + blockSize];
                offset += blockSize;
            }

            const ubyte[] palette = localPalette !is null ? localPalette :
                globalPalette;
            const uint paletteSize = cast(uint) (palette.length / 3);

            auto indices = gifLzwDecode(lzwData, minCodeSize, pixelCount);
            indices.length = pixelCount;

            ubyte[] linear;
            linear.length = pixelCount;
            if (!interlaced)
                linear[] = indices[];
            else
            {
                size_t source = 0;
                void interlacePass(int start, int step)
                {
                    for (int y = start; y < cast(int) frameHeight; y += step)
                    {
                        linear[cast(size_t) y * frameWidth ..
                            (cast(size_t) y + 1) * frameWidth] =
                            indices[source .. source + frameWidth];
                        source += frameWidth;
                    }
                }
                interlacePass(0, 8);
                interlacePass(4, 8);
                interlacePass(2, 4);
                interlacePass(1, 2);
            }

            ubyte[] rgba;
            rgba.length = pixelCount * 4;
            foreach (index; 0 .. pixelCount)
            {
                const paletteIndex = linear[index];
                uint r = 0;
                uint g = 0;
                uint b = 0;
                uint a = 255;
                if (hasTransparency && paletteIndex == transparentIndex)
                    a = 0;
                else if (paletteIndex < paletteSize)
                {
                    const entry = cast(size_t) paletteIndex * 3;
                    r = palette[entry];
                    g = palette[entry + 1];
                    b = palette[entry + 2];
                }
                else
                    a = 0;
                const base = index * 4;
                rgba[base] = cast(ubyte) r;
                rgba[base + 1] = cast(ubyte) g;
                rgba[base + 2] = cast(ubyte) b;
                rgba[base + 3] = cast(ubyte) a;
            }
            return new RgbaImage(cast(int) frameWidth, cast(int) frameHeight, rgba);
        }
        else
            break;
    }
    throw new Exception(label ~ " contains no image frame.");
}

private void skipGifSubBlocks(const(ubyte)[] bytes, ref size_t offset)
{
    while (offset < bytes.length)
    {
        const blockSize = bytes[offset++];
        if (blockSize == 0) break;
        offset += blockSize;
        if (offset > bytes.length)
        {
            offset = bytes.length;
            break;
        }
    }
}

private void gifReadBits(const(ubyte)[] data, size_t bitPosition, int count,
    out uint result)
{
    result = 0;
    foreach (index; 0 .. count)
    {
        const byteIndex = (bitPosition + index) >> 3;
        if (byteIndex >= data.length) break;
        const bit = (data[byteIndex] >> ((bitPosition + index) & 7)) & 1u;
        result |= bit << index;
    }
}

private size_t expandGifEntry(int code, const(uint)[] prefix,
    const(ubyte)[] suffix, ubyte[] scratch, size_t at)
{
    int current = code;
    size_t length = 0;
    while (current >= 0 && current < prefix.length)
    {
        scratch[at + length] = suffix[current];
        ++length;
        if (prefix[current] == uint.max) break;
        current = cast(int) prefix[current];
    }
    return length;
}

private ubyte[] gifLzwDecode(const(ubyte)[] data, int minCodeSize,
    size_t expected)
{
    enforce(minCodeSize >= 2 && minCodeSize <= 8,
        "GIF uses an invalid LZW minimum code size.");
    const int clearCode = 1 << minCodeSize;
    const int eoiCode = clearCode + 1;
    int codeSize = minCodeSize + 1;
    int available = eoiCode + 1;

    uint[] prefix;
    prefix.length = 4096;
    ubyte[] suffix;
    suffix.length = 4096;
    for (int index = 0; index < clearCode; ++index)
    {
        prefix[index] = uint.max;
        suffix[index] = cast(ubyte) index;
    }

    ubyte[] output;
    output.reserve(expected);
    ubyte[4096] scratch;
    int previous = -1;
    size_t bitPosition = 0;

    while (bitPosition + codeSize <= data.length * 8)
    {
        uint code;
        gifReadBits(data, bitPosition, codeSize, code);
        bitPosition += codeSize;
        if (code == clearCode)
        {
            codeSize = minCodeSize + 1;
            available = eoiCode + 1;
            previous = -1;
            continue;
        }
        if (code == eoiCode) break;

        const int entryCode = cast(int) code;
        size_t length;
        if (entryCode < available)
            length = expandGifEntry(entryCode, prefix, suffix, scratch, 0);
        else if (entryCode == available && previous >= 0)
        {
            length = expandGifEntry(previous, prefix, suffix, scratch, 0);
            scratch[length] = scratch[0];
            ++length;
        }
        else
            break;

        foreach (index; 0 .. length)
            output ~= scratch[length - 1 - index];

        if (previous >= 0 && available < 4096)
        {
            prefix[available] = cast(uint) previous;
            suffix[available] = output[$ - length];
            ++available;
            if (available > (1 << codeSize) && codeSize < 12)
                ++codeSize;
        }
        previous = entryCode;
    }
    return output;
}

unittest
{
    // A 2x2 GIF89a with a 2-color global table: palette[0] = red, [1] = blue.
    // These are the same bytes the Aurora Image Viewer smoke test uses, so the
    // shared decoder is validated against a known-good stream.
    immutable ubyte[] tinyGif =
    [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61,             // "GIF89a"
        0x02, 0x00, 0x02, 0x00,                         // 2x2 logical screen
        0x80, 0x00, 0x00,                               // global table, 2 entries
        0xff, 0x00, 0x00,                               // palette[0] = red
        0x00, 0x00, 0xff,                               // palette[1] = blue
        0x2c, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00,
        0x02,                                           // LZW min code size
        0x03, 0x44, 0x82, 0x02,                         // LZW sub-block
        0x00,                                           // block terminator
        0x3b,                                           // trailer
    ];
    assert(isGif(tinyGif));
    assert(sniffImageFormat(tinyGif) == ImageFormat.gif);
    auto gif = decodeImage(tinyGif, "2x2 gif");
    assert(gif !is null, "GIF decode must return an image");
    assert(gif.width() == 2 && gif.height() == 2,
        "GIF decode returned wrong dimensions");
    const p = gif.pixels();
    // Palette lookup resolves to the table's colors, fully opaque.
    // Row-major the 2x2 frame is: red, blue / blue, red.
    assert(p[0] == 255 && p[1] == 0 && p[2] == 0 && p[3] == 255,
        "GIF pixel 0 should be opaque red");
    assert(p[4] == 0 && p[5] == 0 && p[6] == 255 && p[7] == 255,
        "GIF pixel 1 should be opaque blue");
    assert(p[8] == 0 && p[9] == 0 && p[10] == 255 && p[11] == 255,
        "GIF pixel 2 should be opaque blue");
    assert(p[12] == 255 && p[13] == 0 && p[14] == 0 && p[15] == 255,
        "GIF pixel 3 should be opaque red");
}

// ---------------------------------------------------------------------------
// BMP / TGA / PNM (P2/P3/P5/P6/P7)
//
// Hoisted from the Aurora Image Viewer's standalone decoder so the whole
// repository shares one implementation of each format.
// ---------------------------------------------------------------------------

/// Write one straight-alpha RGBA pixel into an RGBA8 buffer.
private void storeRgba(ubyte[] rgba, size_t index, uint r, uint g, uint b,
    uint a) @safe pure nothrow @nogc
{
    const offset = index * 4;
    rgba[offset] = cast(ubyte) (r & 0xffu);
    rgba[offset + 1] = cast(ubyte) (g & 0xffu);
    rgba[offset + 2] = cast(ubyte) (b & 0xffu);
    rgba[offset + 3] = cast(ubyte) (a & 0xffu);
}

/// Does any pixel carry partial transparency?
private bool rgbaHasAlpha(const(ubyte)[] rgba) @safe pure nothrow @nogc
{
    for (size_t offset = 3; offset < rgba.length; offset += 4)
        if (rgba[offset] != 255) return true;
    return false;
}

private uint trailingZeroBits(uint value) @safe pure nothrow @nogc
{
    uint count = 0;
    while ((value & 1u) == 0 && value != 0)
    {
        value >>= 1;
        ++count;
    }
    return count;
}

private uint countBits(uint value) @safe pure nothrow @nogc
{
    uint count = 0;
    while (value != 0)
    {
        count += value & 1u;
        value >>= 1;
    }
    return count;
}

/// Scale a bitfield-masked channel to 0..255.
private uint scaleBitMask(uint value, uint mask) @safe pure nothrow @nogc
{
    if (mask == 0) return 0;
    const shift = trailingZeroBits(mask);
    const bits = countBits(mask);
    const maxValue = (1u << bits) - 1u;
    const scaled = (value & mask) >> shift;
    return maxValue == 0 ? 0 : (scaled * 255u + maxValue / 2u) / maxValue;
}

private enum uint bmpRgb = 0;
private enum uint bmpRle8 = 1;
private enum uint bmpRle4 = 2;
private enum uint bmpBitfields = 3;
private enum uint bmpAlphaBitfields = 6;

private bool isBmp(const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    return bytes.length >= 2 && bytes[0] == 'B' && bytes[1] == 'M';
}

/// Decode a Windows bitmap (1/4/8/16/24/32-bit, RGB or RLE, core or v4+).
RgbaImage decodeBmpImage(const(ubyte)[] bytes, string label = "BMP")
{
    enforce(isBmp(bytes) && bytes.length >= 26, label ~ " is not a bitmap");
    const pixelOffset = cast(size_t) readU32LE(bytes, 10);
    enforce(pixelOffset <= bytes.length, label ~ " has an invalid pixel offset");
    const headerSize = readU32LE(bytes, 14);

    int width;
    int height;
    uint bitCount;
    uint compression = bmpRgb;
    uint colorUsed;

    if (headerSize == 12)
    {
        width = cast(int) readU16LE(bytes, 18);
        height = cast(int) readU16LE(bytes, 20);
        bitCount = readU16LE(bytes, 24);
    }
    else
    {
        enforce(headerSize >= 40 && headerSize <= bytes.length,
            label ~ " has an unsupported bitmap header");
        width = readI32LE(bytes, 18);
        height = readI32LE(bytes, 22);
        bitCount = readU16LE(bytes, 28);
        compression = readU32LE(bytes, 30);
        colorUsed = readU32LE(bytes, 46);
        enforce(compression == bmpRgb || compression == bmpRle8 ||
            compression == bmpRle4 || compression == bmpBitfields ||
            compression == bmpAlphaBitfields,
            label ~ " uses unsupported compression");
    }

    enforce(bitCount == 1 || bitCount == 4 || bitCount == 8 ||
            bitCount == 16 || bitCount == 24 || bitCount == 32,
        label ~ " uses an unsupported bit depth");
    const bool topDown = height < 0;
    if (height < 0) height = -height;
    enforce(width > 0 && height > 0, label ~ " has invalid dimensions");

    uint maskR, maskG, maskB, maskA;
    if (headerSize >= 40 && (compression == bmpBitfields ||
        compression == bmpAlphaBitfields))
    {
        maskR = readU32LE(bytes, 54);
        maskG = readU32LE(bytes, 58);
        maskB = readU32LE(bytes, 62);
        maskA = compression == bmpAlphaBitfields ? readU32LE(bytes, 66) : 0;
    }

    const size_t colorTableOffset = 14 + headerSize;
    uint paletteEntries;
    if (bitCount <= 8)
    {
        paletteEntries = colorUsed > 0 ? colorUsed : (1u << bitCount);
        const paletteEntrySize = headerSize == 12 ? 3 : 4;
        enforce(colorTableOffset + cast(size_t) paletteEntries * paletteEntrySize <=
            bytes.length, label ~ " has a truncated color table");
    }

    ubyte[] rgba;
    rgba.length = cast(size_t) width * cast(size_t) height * 4;
    const bool coreHeader = headerSize == 12;

    if (compression == bmpRle8 && bitCount == 8)
        decodeBmpRle(bytes, rgba, width, height, topDown, true,
            colorTableOffset, paletteEntries, coreHeader, pixelOffset, label);
    else if (compression == bmpRle4 && bitCount == 4)
        decodeBmpRle(bytes, rgba, width, height, topDown, false,
            colorTableOffset, paletteEntries, coreHeader, pixelOffset, label);
    else
        decodeBmpPixels(bytes, rgba, pixelOffset, width, height, topDown, bitCount,
            compression, maskR, maskG, maskB, maskA, colorTableOffset,
            paletteEntries, coreHeader, label);

    return new RgbaImage(width, height, rgba);
}

private void decodeBmpPixels(const(ubyte)[] bytes, ubyte[] rgba,
    size_t pixelOffset, int width, int height, bool topDown, uint bitCount,
    uint compression, uint maskR, uint maskG, uint maskB, uint maskA,
    size_t colorTableOffset, uint paletteEntries, bool coreHeader, string label)
{
    const rowBytes = ((cast(size_t) width * bitCount + 31) / 32) * 4;
    enforce(pixelOffset + rowBytes * cast(size_t) height <= bytes.length,
        label ~ " pixel data is truncated");
    foreach (rowIndex; 0 .. height)
    {
        const y = topDown ? rowIndex : height - 1 - rowIndex;
        const rowStart = pixelOffset + cast(size_t) rowIndex * rowBytes;
        foreach (x; 0 .. width)
        {
            uint index;
            uint r, g, b;
            uint a = 255;
            if (bitCount == 1)
            {
                const packedByte = bytes[rowStart + cast(size_t) (x / 8)];
                index = (packedByte >> (7 - x % 8)) & 1u;
            }
            else if (bitCount == 4)
            {
                const packedByte = bytes[rowStart + cast(size_t) (x / 2)];
                index = (x % 2 == 0) ? ((packedByte >> 4) & 0x0fu) :
                    (packedByte & 0x0fu);
            }
            else if (bitCount == 8)
                index = bytes[rowStart + cast(size_t) x];
            else if (bitCount == 16)
            {
                const value = readU16LE(bytes, rowStart + cast(size_t) x * 2);
                if (compression == bmpBitfields)
                {
                    r = scaleBitMask(value, maskR);
                    g = scaleBitMask(value, maskG);
                    b = scaleBitMask(value, maskB);
                    a = maskA != 0 ? scaleBitMask(value, maskA) : 255;
                }
                else
                {
                    r = ((value >> 10) & 0x1fu) * 255u / 31u;
                    g = ((value >> 5) & 0x1fu) * 255u / 31u;
                    b = (value & 0x1fu) * 255u / 31u;
                }
            }
            else if (bitCount == 24)
            {
                const offset = rowStart + cast(size_t) x * 3;
                b = bytes[offset];
                g = bytes[offset + 1];
                r = bytes[offset + 2];
            }
            else
            {
                const offset = rowStart + cast(size_t) x * 4;
                b = bytes[offset];
                g = bytes[offset + 1];
                r = bytes[offset + 2];
                a = compression == bmpRgb ? 255 : bytes[offset + 3];
            }

            if (bitCount <= 8)
            {
                const entry = colorTableOffset + cast(size_t) index *
                    (coreHeader ? 3 : 4);
                if (index < paletteEntries && entry + 3 <= bytes.length)
                {
                    b = bytes[entry];
                    g = bytes[entry + 1];
                    r = bytes[entry + 2];
                    if (!coreHeader) a = bytes[entry + 3];
                }
                else
                    a = 0;
            }
            storeRgba(rgba,
                cast(size_t) y * cast(size_t) width + cast(size_t) x,
                r, g, b, a);
        }
    }
}

private void decodeBmpRle(const(ubyte)[] bytes, ubyte[] rgba, int width,
    int height, bool topDown, bool eightBit, size_t colorTableOffset,
    uint paletteEntries, bool coreHeader, size_t start, string label)
{
    const end = bytes.length;
    size_t offset = start;
    int x;
    int y;
    while (offset < end)
    {
        const count = bytes[offset++];
        if (offset >= end) break;
        if (count == 0)
        {
            const escape = bytes[offset++];
            if (escape == 0) { x = 0; ++y; }
            else if (escape == 1) break;
            else if (escape == 2)
            {
                if (offset + 1 >= end) break;
                x += bytes[offset];
                y += bytes[offset + 1];
                offset += 2;
            }
            else
            {
                foreach (i; 0 .. escape)
                {
                    if (offset >= end) break;
                    uint index;
                    if (eightBit)
                        index = bytes[offset++];
                    else
                    {
                        const value = bytes[offset];
                        index = (_isHighNibble(i)) ? ((value >> 4) & 0x0fu) :
                            (value & 0x0fu);
                        if ((i % 2) == 1) ++offset;
                    }
                    bmpRlePixel(bytes, rgba, x++, y, width, height, topDown,
                        index, colorTableOffset, paletteEntries, coreHeader);
                }
                if (eightBit && (escape & 1) != 0 && offset < end) ++offset;
            }
        }
        else
        {
            if (offset >= end) break;
            if (eightBit)
            {
                const index = bytes[offset++];
                foreach (_; 0 .. count)
                    bmpRlePixel(bytes, rgba, x++, y, width, height, topDown,
                        index, colorTableOffset, paletteEntries, coreHeader);
            }
            else
            {
                const value = bytes[offset++];
                foreach (i; 0 .. count)
                {
                    const index = ((i % 2) == 0) ? ((value >> 4) & 0x0fu) :
                        (value & 0x0fu);
                    bmpRlePixel(bytes, rgba, x++, y, width, height, topDown,
                        index, colorTableOffset, paletteEntries, coreHeader);
                }
            }
        }
    }
}

private bool _isHighNibble(size_t index) @safe pure nothrow @nogc
{
    return (index % 2) == 0;
}

private void bmpRlePixel(const(ubyte)[] bytes, ubyte[] rgba, int x, int y,
    int width, int height, bool topDown, uint index, size_t colorTableOffset,
    uint paletteEntries, bool coreHeader)
{
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    uint r, g, b;
    uint a = 255;
    if (index < paletteEntries)
    {
        const entry = colorTableOffset + cast(size_t) index * (coreHeader ? 3 : 4);
        b = bytes[entry];
        g = bytes[entry + 1];
        r = bytes[entry + 2];
        if (!coreHeader) a = bytes[entry + 3];
    }
    else
        a = 0;
    const row = topDown ? y : height - 1 - y;
    storeRgba(rgba,
        cast(size_t) row * cast(size_t) width + cast(size_t) x, r, g, b, a);
}

/// Decode a TGA image (truecolor/gray/color-mapped, optional RLE).
RgbaImage decodeTgaImage(const(ubyte)[] bytes, string label = "TGA")
{
    enforce(bytes.length >= 18, label ~ " is truncated");
    const idLength = bytes[0];
    const colorMapType = bytes[1];
    const imageType = bytes[2];
    const colorMapOrigin = readU16LE(bytes, 3);
    const colorMapLength = readU16LE(bytes, 5);
    const colorMapDepth = bytes[7];
    const width = readU16LE(bytes, 12);
    const height = readU16LE(bytes, 14);
    const depth = bytes[16];
    const descriptor = bytes[17];
    const topDown = (descriptor & 0x20u) != 0;

    enforce(colorMapType == 0 || colorMapType == 1,
        label ~ " has an invalid color map type");
    enforce(width > 0 && height > 0, label ~ " has invalid dimensions");
    const bool trueColor = imageType == 2 || imageType == 10;
    const bool grayScale = imageType == 3 || imageType == 11;
    const bool colorMapped = imageType == 1 || imageType == 9;
    enforce(trueColor || grayScale || colorMapped,
        label ~ " uses an unsupported TGA image type");
    const bool rle = imageType == 9 || imageType == 10 || imageType == 11;

    const size_t colorMapBytes = colorMapType == 1 ?
        cast(size_t) colorMapLength * ((colorMapDepth + 7) / 8) : 0;
    const size_t colorMapStart = 18 + idLength;
    size_t offset = 18 + idLength + colorMapBytes;
    enforce(offset <= bytes.length, label ~ " pixel data is missing");

    ubyte[] rgba;
    rgba.length = cast(size_t) width * cast(size_t) height * 4;

    const size_t total = cast(size_t) width * cast(size_t) height;
    size_t target = 0;
    while (target < total)
    {
        uint count = 1;
        bool replicate;
        if (rle)
        {
            enforce(offset < bytes.length, label ~ " RLE data is truncated");
            const packet = bytes[offset++];
            count = (packet & 0x7fu) + 1u;
            replicate = (packet & 0x80u) != 0;
        }
        if (replicate)
        {
            const pixel = tgaReadPixel(bytes, offset, trueColor, grayScale,
                colorMapped, depth, colorMapStart, colorMapOrigin, colorMapDepth,
                colorMapLength, label);
            foreach (_; 0 .. count)
            {
                writeTgaPixel(rgba, target, width, height, topDown, pixel);
                ++target;
                if (target >= total) break;
            }
        }
        else
        {
            foreach (_; 0 .. count)
            {
                if (target >= total) break;
                const pixel = tgaReadPixel(bytes, offset, trueColor, grayScale,
                    colorMapped, depth, colorMapStart, colorMapOrigin, colorMapDepth,
                    colorMapLength, label);
                writeTgaPixel(rgba, target, width, height, topDown, pixel);
                ++target;
            }
        }
    }
    return new RgbaImage(width, height, rgba);
}

private uint tgaReadPixel(const(ubyte)[] bytes, ref size_t offset, bool trueColor,
    bool grayScale, bool colorMapped, uint depth, size_t colorMapStart,
    uint colorMapOrigin, uint colorMapDepth, uint colorMapLength, string label)
{
    uint r = 0, g = 0, b = 0, a = 255;
    if (trueColor)
    {
        if (depth == 32)
        {
            enforce(offset + 3 < bytes.length, label ~ " pixel data is truncated");
            b = bytes[offset];
            g = bytes[offset + 1];
            r = bytes[offset + 2];
            a = bytes[offset + 3];
            offset += 4;
        }
        else if (depth == 24)
        {
            enforce(offset + 2 < bytes.length, label ~ " pixel data is truncated");
            b = bytes[offset];
            g = bytes[offset + 1];
            r = bytes[offset + 2];
            offset += 3;
        }
        else if (depth == 16)
        {
            enforce(offset + 1 < bytes.length, label ~ " pixel data is truncated");
            const value = cast(uint) bytes[offset] |
                (cast(uint) bytes[offset + 1] << 8);
            offset += 2;
            r = ((value >> 10) & 0x1fu) * 255u / 31u;
            g = ((value >> 5) & 0x1fu) * 255u / 31u;
            b = (value & 0x1fu) * 255u / 31u;
            a = (value & 0x8000u) != 0 ? 255 : 0;
        }
        else
            throw new Exception("Unsupported TGA truecolor depth");
    }
    else if (grayScale)
    {
        enforce(offset < bytes.length, label ~ " pixel data is truncated");
        const value = bytes[offset++];
        r = g = b = value;
        if (depth == 16 && offset < bytes.length)
        {
            const alphaByte = bytes[offset++];
            a = alphaByte == 0 ? 0 : 255;
        }
    }
    else if (colorMapped)
    {
        enforce(offset < bytes.length, label ~ " pixel data is truncated");
        const index = bytes[offset++];
        if (index >= colorMapOrigin && index - colorMapOrigin < colorMapLength)
        {
            const entry = colorMapStart +
                cast(size_t) (index - colorMapOrigin) * ((colorMapDepth + 7) / 8);
            if (colorMapDepth == 32 && entry + 3 < bytes.length)
            {
                b = bytes[entry];
                g = bytes[entry + 1];
                r = bytes[entry + 2];
                a = bytes[entry + 3];
            }
            else if (colorMapDepth == 24 && entry + 2 < bytes.length)
            {
                b = bytes[entry];
                g = bytes[entry + 1];
                r = bytes[entry + 2];
            }
        }
    }
    return (r << 24) | (g << 16) | (b << 8) | a;
}

private void writeTgaPixel(ubyte[] rgba, size_t target, int width, int height,
    bool topDown, uint pixel) @safe pure nothrow @nogc
{
    const y = topDown ? cast(int) (target / width) :
        height - 1 - cast(int) (target / width);
    const x = cast(int) (target % cast(size_t) width);
    storeRgba(rgba,
        cast(size_t) y * cast(size_t) width + cast(size_t) x,
        (pixel >> 24) & 0xffu, (pixel >> 16) & 0xffu, (pixel >> 8) & 0xffu,
        pixel & 0xffu);
}

private bool isPnm(const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    if (bytes.length < 2 || bytes[0] != 'P') return false;
    const magic = bytes[1];
    return magic == '2' || magic == '3' || magic == '5' || magic == '6' ||
        magic == '7';
}

private struct PnmTokenizer
{
    const(ubyte)[] bytes;
    size_t offset;
    bool failed;

    void skipWhitespace() @safe pure nothrow @nogc
    {
        while (offset < bytes.length)
        {
            if (bytes[offset] == '#')
            {
                while (offset < bytes.length && bytes[offset] != '\n') ++offset;
                continue;
            }
            if (bytes[offset] == ' ' || bytes[offset] == '\t' ||
                bytes[offset] == '\r' || bytes[offset] == '\n')
            {
                ++offset;
                continue;
            }
            break;
        }
    }

    uint nextNumber() @safe pure nothrow @nogc
    {
        skipWhitespace();
        uint value = 0;
        bool seen;
        while (offset < bytes.length && bytes[offset] >= '0' &&
            bytes[offset] <= '9')
        {
            value = value * 10u + cast(uint) (bytes[offset] - '0');
            ++offset;
            seen = true;
        }
        if (!seen) failed = true;
        return value;
    }

    string nextToken()
    {
        skipWhitespace();
        const start = offset;
        while (offset < bytes.length && bytes[offset] != ' ' &&
            bytes[offset] != '\t' && bytes[offset] != '\r' &&
            bytes[offset] != '\n')
            ++offset;
        return cast(string) bytes[start .. offset];
    }
}

/// Decode a PNM/PAM image (P2/P3/5/6/7), ASCII or binary, 8- or 16-bit.
RgbaImage decodePnmImage(const(ubyte)[] bytes, string label = "PNM")
{
    enforce(isPnm(bytes), label ~ " is not a PNM image");
    const magic = bytes[1];
    PnmTokenizer tokens;
    tokens.bytes = bytes;

    int width;
    int height;
    uint maxValue;
    uint channels;
    bool ascii;
    const bool isPam = magic == '7';

    if (isPam)
    {
        ascii = false;
        while (true)
        {
            const token = tokens.nextToken();
            if (token == "ENDHDR") break;
            if (token == "WIDTH") width = cast(int) tokens.nextNumber();
            else if (token == "HEIGHT") height = cast(int) tokens.nextNumber();
            else if (token == "DEPTH") channels = tokens.nextNumber();
            else if (token == "MAXVAL") maxValue = tokens.nextNumber();
            else if (token == "TUPLTYPE")
            {
                if (tokens.nextToken() == "RGB_ALPHA" && channels == 0)
                    channels = 4;
            }
            if (tokens.failed) break;
        }
        if (channels == 0) channels = 3;
    }
    else
    {
        ascii = magic == '2' || magic == '3';
        channels = (magic == '2' || magic == '5') ? 1 : 3;
        tokens.nextToken();   // magic
        width = cast(int) tokens.nextNumber();
        height = cast(int) tokens.nextNumber();
        maxValue = tokens.nextNumber();
    }

    enforce(!tokens.failed && width > 0 && height > 0 && maxValue > 0,
        label ~ " has a malformed PNM header");
    enforce(maxValue <= 65535, label ~ " has an unsupported max value");
    enforce(channels == 1 || channels == 3 || channels == 4,
        label ~ " uses an unsupported sample depth");

    ubyte[] rgba;
    rgba.length = cast(size_t) width * cast(size_t) height * 4;
    tokens.skipWhitespace();
    const bool sixteenBit = maxValue > 255;
    foreach (index; 0 .. cast(size_t) width * cast(size_t) height)
    {
        uint r, g, b;
        uint a = 255;
        if (ascii)
        {
            r = tokens.nextNumber();
            if (channels == 3) { g = tokens.nextNumber(); b = tokens.nextNumber(); }
            else if (channels == 4)
            {
                g = tokens.nextNumber();
                b = tokens.nextNumber();
                a = tokens.nextNumber();
            }
            else g = b = r;
        }
        else if (sixteenBit)
        {
            uint readSample()
            {
                enforce(tokens.offset + 2 <= bytes.length, label ~ " is truncated");
                const value = (cast(uint) bytes[tokens.offset] << 8) |
                    cast(uint) bytes[tokens.offset + 1];
                tokens.offset += 2;
                return value;
            }
            r = readSample();
            if (channels == 3) { g = readSample(); b = readSample(); }
            else if (channels == 4)
            {
                g = readSample();
                b = readSample();
                a = readSample();
            }
            else g = b = r;
        }
        else
        {
            enforce(tokens.offset + channels <= bytes.length,
                label ~ " is truncated");
            r = bytes[tokens.offset];
            if (channels == 3)
            {
                g = bytes[tokens.offset + 1];
                b = bytes[tokens.offset + 2];
                tokens.offset += 3;
            }
            else if (channels == 4)
            {
                g = bytes[tokens.offset + 1];
                b = bytes[tokens.offset + 2];
                a = bytes[tokens.offset + 3];
                tokens.offset += 4;
            }
            else
            {
                g = b = r;
                ++tokens.offset;
            }
        }
        r = (r * 255u + maxValue / 2u) / maxValue;
        g = (g * 255u + maxValue / 2u) / maxValue;
        b = (b * 255u + maxValue / 2u) / maxValue;
        a = (a * 255u + maxValue / 2u) / maxValue;
        storeRgba(rgba, index, r, g, b, a);
    }
    return new RgbaImage(width, height, rgba);
}

private ubyte vp8lChannel(uint argb, int index) @safe pure nothrow @nogc
{
    return cast(ubyte) ((argb >> (index * 8)) & 0xff);
}

private uint vp8lPack(int a, int r, int g, int b) @safe pure nothrow @nogc
{
    return (cast(uint) (a & 0xff) << 24) | (cast(uint) (r & 0xff) << 16) |
        (cast(uint) (g & 0xff) << 8) | cast(uint) (b & 0xff);
}

/// Inverse predictor transform (RFC 9649 3.5.1).
private void vp8lApplyPredictor(uint[] pixels, int width, int height,
    const(uint)[] predictor, int transformWidth, int sizeBits)
{
    uint avg(uint a, uint b)
    {
        uint result;
        foreach (c; 0 .. 4)
            result |= (cast(uint)
                ((vp8lChannel(a, c) + vp8lChannel(b, c)) / 2)) << (c * 8);
        return result;
    }
    uint select(uint l, uint t, uint tl)
    {
        const pa = cast(int) vp8lChannel(l, 3) + vp8lChannel(t, 3) -
            vp8lChannel(tl, 3);
        const pr = cast(int) vp8lChannel(l, 2) + vp8lChannel(t, 2) -
            vp8lChannel(tl, 2);
        const pg = cast(int) vp8lChannel(l, 1) + vp8lChannel(t, 1) -
            vp8lChannel(tl, 1);
        const pb = cast(int) vp8lChannel(l, 0) + vp8lChannel(t, 0) -
            vp8lChannel(tl, 0);
        int distL, distT;
        foreach (c; 0 .. 4)
        {
            const estimate = (c == 3 ? pa : c == 2 ? pr : c == 1 ? pg : pb);
            distL += absInt(estimate - vp8lChannel(l, c));
            distT += absInt(estimate - vp8lChannel(t, c));
        }
        return distL < distT ? l : t;
    }
    uint addSubtractFull(uint a, uint b, uint c)
    {
        uint result;
        foreach (i; 0 .. 4)
        {
            const value = cast(int) vp8lChannel(a, i) +
                vp8lChannel(b, i) - vp8lChannel(c, i);
            result |= cast(uint) clampByte(value) << (i * 8);
        }
        return result;
    }
    uint addSubtractHalf(uint a, uint b)
    {
        uint result;
        foreach (i; 0 .. 4)
        {
            const av = cast(int) vp8lChannel(a, i);
            const value = av + (av - vp8lChannel(b, i)) / 2;
            result |= cast(uint) clampByte(value) << (i * 8);
        }
        return result;
    }

    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        {
            const index = cast(size_t) y * width + x;
            const mode = cast(int) vp8lChannel(
                predictor[cast(size_t) (y >> sizeBits) * transformWidth +
                    (x >> sizeBits)], 1);
            uint pred;
            if (x == 0 && y == 0)
                pred = 0xff000000;
            else if (y == 0)
                pred = pixels[index - 1];
            else if (x == 0)
                pred = pixels[index - width];
            else
            {
                const left = pixels[index - 1];
                const top = pixels[index - width];
                const topLeft = pixels[index - width - 1];
                const topRight = x == width - 1 ? pixels[index - width]
                    : pixels[index - width + 1];
                switch (mode)
                {
                    case 0: pred = 0xff000000; break;
                    case 1: pred = left; break;
                    case 2: pred = top; break;
                    case 3: pred = topRight; break;
                    case 4: pred = topLeft; break;
                    case 5: pred = avg(avg(left, topRight), top); break;
                    case 6: pred = avg(left, topLeft); break;
                    case 7: pred = avg(left, top); break;
                    case 8: pred = avg(topLeft, top); break;
                    case 9: pred = avg(top, topRight); break;
                    case 10:
                        pred = avg(avg(left, topLeft), avg(top, topRight));
                        break;
                    case 11: pred = select(left, top, topLeft); break;
                    case 12: pred = addSubtractFull(left, top, topLeft); break;
                    case 13:
                        pred = addSubtractHalf(avg(left, top), topLeft);
                        break;
                    default: pred = left; break;
                }
            }
            const residual = pixels[index];
            pixels[index] = vp8lPack(
                vp8lChannel(residual, 3) + vp8lChannel(pred, 3),
                vp8lChannel(residual, 2) + vp8lChannel(pred, 2),
                vp8lChannel(residual, 1) + vp8lChannel(pred, 1),
                vp8lChannel(residual, 0) + vp8lChannel(pred, 0));
        }
}

/// Inverse colour transform (RFC 9649 3.5.2).
private void vp8lApplyColor(uint[] pixels, int width, int height,
    const(uint)[] color, int transformWidth, int sizeBits)
{
    int delta(int t, int c) @safe pure nothrow @nogc
    {
        // Signed 8-bit operands, 3.5 fixed point.
        const tt = cast(int) cast(byte) t;
        const cc = cast(int) cast(byte) c;
        return (tt * cc) >> 5;
    }
    foreach (y; 0 .. height)
        foreach (x; 0 .. width)
        {
            const index = cast(size_t) y * width + x;
            const cte = color[cast(size_t) (y >> sizeBits) * transformWidth +
                (x >> sizeBits)];
            const greenToRed = cast(int) (cte & 0xff);
            const greenToBlue = cast(int) ((cte >> 8) & 0xff);
            const redToBlue = cast(int) ((cte >> 16) & 0xff);
            const argb = pixels[index];
            const green = cast(int) vp8lChannel(argb, 1);
            int red = vp8lChannel(argb, 2);
            int blue = vp8lChannel(argb, 0);
            red += delta(greenToRed, green);
            blue += delta(greenToBlue, green);
            blue += delta(redToBlue, red & 0xff);
            pixels[index] = (argb & 0xff00ff00) |
                (cast(uint) (red & 0xff) << 16) | cast(uint) (blue & 0xff);
        }
}

private int absInt(int value) @safe pure nothrow @nogc
{
    return value < 0 ? -value : value;
}

private ubyte clampByte(int value) @safe pure nothrow @nogc
{
    return cast(ubyte) (value < 0 ? 0 : (value > 255 ? 255 : value));
}

unittest
{
    // BMP round-trip: a 2x1 24-bit bottom-up bitmap, BGR little-endian.
    immutable ubyte[] bmp =
    [
        0x42, 0x4d,                          // "BM"
        0x3a, 0x00, 0x00, 0x00,              // file size (58)
        0x00, 0x00, 0x00, 0x00,              // reserved
        0x36, 0x00, 0x00, 0x00,              // pixel data offset (54)
        0x28, 0x00, 0x00, 0x00,              // BITMAPINFOHEADER
        0x02, 0x00, 0x00, 0x00,              // width 2
        0x01, 0x00, 0x00, 0x00,              // height 1
        0x01, 0x00,                          // planes
        0x18, 0x00,                          // bits per pixel 24
        0x00, 0x00, 0x00, 0x00,              // compression = RGB
        0x08, 0x00, 0x00, 0x00,              // image size
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xff,                    // pixel 0: B=0 G=0 R=255 -> red
        0xff, 0x00, 0x00,                    // pixel 1: B=255 -> blue
        0x00, 0x00,                          // row padding to 4 bytes
    ];
    assert(sniffImageFormat(bmp) == ImageFormat.bmp);
    auto decoded = decodeImage(bmp, "2x1 bmp");
    assert(decoded.width() == 2 && decoded.height() == 1);
    const p = decoded.pixels();
    assert(p[0] == 255 && p[1] == 0 && p[2] == 0 && p[3] == 255,
        "BMP pixel 0 should be opaque red");
    assert(p[4] == 0 && p[5] == 0 && p[6] == 255 && p[7] == 255,
        "BMP pixel 1 should be opaque blue");

    // PNM round-trip: a binary P6 2x1 image at maxval 255.
    immutable ubyte[] ppm =
        cast(immutable ubyte[]) "P6\n2 1\n255\n" ~
        cast(immutable ubyte[]) [255, 0, 0, 0, 0, 255];
    assert(sniffImageFormat(ppm) == ImageFormat.pnm);
    auto pnm = decodeImage(ppm, "2x1 ppm");
    assert(pnm.width() == 2 && pnm.height() == 1);
    const q = pnm.pixels();
    assert(q[0] == 255 && q[1] == 0 && q[2] == 0 && q[3] == 255);
    assert(q[4] == 0 && q[5] == 0 && q[6] == 255 && q[7] == 255);
}

// ---------------------------------------------------------------------------
// Baseline JPEG (sequential, Huffman) decoder
//
// There was no JPEG decoder anywhere in the repository; this is the single
// shared one. Supports 8-bit baseline DCT (SOF0) with 1 or 3 components,
// standard and custom Huffman tables, and 4:4:4 / 4:2:2 / 4:2:0 sampling.
// Progressive JPEG and restart markers are not handled yet.
// ---------------------------------------------------------------------------

private bool isJpeg(const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    return bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 &&
        bytes[2] == 0xFF;
}

private int readBe16U(const(ubyte)[] bytes, size_t offset) @safe pure nothrow @nogc
{
    return (cast(int) bytes[offset] << 8) | cast(int) bytes[offset + 1];
}

/// Quantization table (64 entries, stored in raster order after de-zig-zagging).
private struct JpegQuantTable
{
    bool defined;
    ushort[64] values;
}

/// Huffman table with a fast lookup: code ranges per length -> symbol index.
private struct JpegHuffman
{
    bool defined;
    int[17] minCode;
    int[17] maxCode;   // -1 when no codes of that length
    int[17] valPtr;
    ubyte[] symbols;
}

/// Entropy bit reader that consumes 0x00 byte stuffing and stops at markers.
private struct JpegBitReader
{
    const(ubyte)[] data;
    size_t offset;
    uint bitBuffer;
    int bitCount;
    bool hitMarker;

    void ensure(int bits)
    {
        while (bitCount < bits)
        {
            uint next;
            if (offset >= data.length)
            {
                hitMarker = true;
                next = 0;
            }
            else if (data[offset] == 0xFF)
            {
                if (offset + 1 < data.length && data[offset + 1] == 0x00)
                {
                    offset += 2;
                    next = 0xFF;
                }
                else
                {
                    hitMarker = true;
                    next = 0;
                }
            }
            else
                next = data[offset++];
            bitBuffer = (bitBuffer << 8) | next;
            bitCount += 8;
            if (hitMarker) break;
        }
    }

    int receive(int length)
    {
        if (length == 0) return 0;
        ensure(length);
        bitCount -= length;
        if (bitCount < 0) bitCount = 0;
        return cast(int) ((bitBuffer >> bitCount) & ((1u << length) - 1u));
    }
}

/// One decoded JPEG component plane.
private struct JpegComponent
{
    int id;
    int hSample;
    int vSample;
    int quantId;
    int dcTable;
    int acTable;
    int predDC;
    int stride;              // plane width in samples, padded to the MCU grid
    int[] samples;           // level-shifted 0..255 samples, row-major
    int[64] coefficients;    // scratch for the current block
}

/// Scan-scoped decoder state shared by the header parser and block decoder.
private struct JpegState
{
    JpegQuantTable[4] quant;
    JpegHuffman[4] dc;       // indexed by the scan's DC table selector
    JpegHuffman[4] ac;
    JpegComponent[] components;
    int width;
    int height;
}

private immutable int[64] jpegZigZag = [
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
];

private immutable double[64] jpegCosTable = makeJpegCosTable();

private immutable(double[64]) makeJpegCosTable()
{
    import std.math : cos;
    double[64] table;
    foreach (x; 0 .. 8)
        foreach (u; 0 .. 8)
            table[x * 8 + u] = cos((2 * x + 1) * u * 3.14159265358979 / 16.0);
    return table;
}

/// Decode a baseline (SOF0/SOF1) JPEG into straight-alpha RGBA8.
RgbaImage decodeJpegImage(const(ubyte)[] bytes, string label = "JPEG")
{
    enforce(isJpeg(bytes), label ~ " is not a JPEG image");
    JpegState state;
    bool sawFrame;

    size_t pos = 2;
    while (pos + 1 < bytes.length)
    {
        if (bytes[pos] != 0xFF) { ++pos; continue; }
        const marker = bytes[pos + 1];
        pos += 2;
        if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7))
            continue;
        if (marker == 0xD9) break;
        if (pos + 2 > bytes.length) break;
        const segmentLength = readBe16U(bytes, pos);
        enforce(segmentLength >= 2 && pos + segmentLength <= bytes.length,
            label ~ " has a truncated JPEG segment");
        const segStart = pos + 2;
        const segEnd = pos + segmentLength;

        if (marker == 0xDB)                     // DQT
        {
            size_t p = segStart;
            while (p < segEnd)
            {
                const spec = bytes[p++];
                const precision = spec >> 4;
                const id = spec & 0x0F;
                if (id >= 4) break;
                const need = precision != 0 ? 128 : 64;
                enforce(p + need <= segEnd,
                    label ~ " has a truncated quantization table");
                foreach (i; 0 .. 64)
                    state.quant[id].values[jpegZigZag[i]] = cast(ushort)
                        (precision != 0 ? readBe16U(bytes, p + i * 2)
                            : bytes[p + i]);
                state.quant[id].defined = true;
                p += need;
            }
        }
        else if (marker == 0xC4)                // DHT
        {
            size_t p = segStart;
            while (p < segEnd)
            {
                const spec = bytes[p++];
                const classId = spec >> 4;
                const id = spec & 0x0F;
                if (id >= 4 || p + 16 > segEnd) break;
                int[17] counts;
                int total;
                foreach (length; 1 .. 17)
                {
                    counts[length] = bytes[p + length - 1];
                    total += counts[length];
                }
                p += 16;
                enforce(p + total <= segEnd,
                    label ~ " has a truncated Huffman table");
                ref JpegHuffman table = classId == 0 ? state.dc[id] : state.ac[id];
                table.symbols = bytes[p .. p + total].dup;
                int code = 0;
                int symbolIndex = 0;
                foreach (length; 1 .. 17)
                {
                    if (counts[length] == 0)
                    {
                        table.maxCode[length] = -1;
                        table.minCode[length] = 0;
                        table.valPtr[length] = 0;
                    }
                    else
                    {
                        table.minCode[length] = code;
                        table.valPtr[length] = symbolIndex;
                        code += counts[length];
                        table.maxCode[length] = code - 1;
                        symbolIndex += counts[length];
                    }
                    code <<= 1;
                }
                table.defined = true;
                p += total;
            }
        }
        else if (marker == 0xC0 || marker == 0xC1)   // SOF0 / SOF1 baseline
        {
            enforce(segStart + 6 <= segEnd,
                label ~ " has a truncated frame header");
            enforce(bytes[segStart] == 8, label ~ " JPEG precision must be 8-bit");
            state.height = readBe16U(bytes, segStart + 1);
            state.width = readBe16U(bytes, segStart + 3);
            const componentCount = bytes[segStart + 5];
            enforce(componentCount == 1 || componentCount == 3,
                label ~ " JPEG must have 1 or 3 components");
            enforce(segStart + 6 + cast(size_t) componentCount * 3 <= segEnd,
                label ~ " has a truncated component list");
            state.components.length = componentCount;
            foreach (i; 0 .. componentCount)
            {
                const base = segStart + 6 + i * 3;
                state.components[i].id = bytes[base];
                const sampling = bytes[base + 1];
                state.components[i].hSample = sampling >> 4;
                state.components[i].vSample = sampling & 0x0F;
                state.components[i].quantId = bytes[base + 2];
                enforce(state.components[i].hSample >= 1 &&
                    state.components[i].hSample <= 4 &&
                    state.components[i].vSample >= 1 &&
                    state.components[i].vSample <= 4,
                    label ~ " has an invalid sampling factor");
            }
            sawFrame = true;
        }
        else if (marker == 0xC2)
            throw new Exception("Progressive JPEG is not supported (" ~ label ~ ").");
        else if (marker == 0xDA)                // SOS
        {
            enforce(sawFrame, label ~ " has a scan before its frame header");
            const scanCount = bytes[segStart];
            enforce(scanCount == state.components.length,
                label ~ " scan components do not match the frame");
            foreach (i; 0 .. scanCount)
            {
                const selector = bytes[segStart + 1 + i * 2];
                const tables = bytes[segStart + 2 + i * 2];
                foreach (ref component; state.components)
                    if (component.id == selector)
                    {
                        component.dcTable = tables >> 4;
                        component.acTable = tables & 0x0F;
                    }
            }

            int maxH = 1;
            int maxV = 1;
            foreach (component; state.components)
            {
                if (component.hSample > maxH) maxH = component.hSample;
                if (component.vSample > maxV) maxV = component.vSample;
            }
            const mcuWidth = maxH * 8;
            const mcuHeight = maxV * 8;
            const mcusX = (state.width + mcuWidth - 1) / mcuWidth;
            const mcusY = (state.height + mcuHeight - 1) / mcuHeight;
            foreach (ref component; state.components)
            {
                component.stride = mcusX * component.hSample * 8;
                component.samples.length = cast(size_t) component.stride *
                    mcusY * component.vSample * 8;
            }

            JpegBitReader reader;
            reader.data = bytes[segEnd .. $];
            foreach (mcuY; 0 .. mcusY)
                foreach (mcuX; 0 .. mcusX)
                    foreach (ref component; state.components)
                        foreach (blockV; 0 .. component.vSample)
                            foreach (blockH; 0 .. component.hSample)
                            {
                                jpegDecodeBlock(reader, state, component);
                                jpegStoreBlock(component,
                                    mcuX * component.hSample + blockH,
                                    mcuY * component.vSample + blockV,
                                    maxH, maxV);
                                if (reader.hitMarker) break;
                            }

            ubyte[] rgba;
            rgba.length = cast(size_t) state.width * cast(size_t) state.height * 4;
            foreach (y; 0 .. state.height)
                foreach (x; 0 .. state.width)
                {
                    uint r, g, b;
                    if (state.components.length == 1)
                    {
                        const sample = cast(uint) clamp255(
                            jpegSample(state.components[0], x, y, maxH, maxV));
                        r = g = b = sample;
                    }
                    else
                    {
                        const yy = cast(int) jpegSample(state.components[0],
                            x, y, maxH, maxV);
                        const cb = cast(int) jpegSample(state.components[1],
                            x, y, maxH, maxV);
                        const cr = cast(int) jpegSample(state.components[2],
                            x, y, maxH, maxV);
                        // JFIF YCbCr -> RGB (chroma stored level-shifted).
                        const cbSigned = cb - 128;
                        const crSigned = cr - 128;
                        r = cast(uint) clamp255(cast(int) (yy + 1.402 * crSigned));
                        g = cast(uint) clamp255(cast(int) (yy - 0.344136 * cbSigned -
                            0.714136 * crSigned));
                        b = cast(uint) clamp255(cast(int) (yy + 1.772 * cbSigned));
                    }
                    storeRgba(rgba,
                        cast(size_t) y * cast(size_t) state.width + cast(size_t) x,
                        r, g, b, 255);
                }
            return new RgbaImage(state.width, state.height, rgba);
        }
        pos = segEnd;
    }
    throw new Exception(label ~ " contains no baseline JPEG frame.");
}

private int clamp255(int value) @safe pure nothrow @nogc
{
    return value < 0 ? 0 : (value > 255 ? 255 : value);
}

private int jpegExtend(int value, int length) @safe pure nothrow @nogc
{
    if (length == 0) return 0;
    const threshold = 1 << (length - 1);
    return value < threshold ? value - (1 << length) + 1 : value;
}

/// Decode one Huffman symbol using the scan's table.
private int jpegDecodeSymbol(ref JpegBitReader reader, ref JpegHuffman table)
{
    if (!table.defined) return -1;
    int code = 0;
    foreach (length; 1 .. 17)
    {
        const bit = reader.receive(1);
        code = (code << 1) | bit;
        if (table.maxCode[length] >= 0 && code >= table.minCode[length] &&
            code <= table.maxCode[length])
            return table.symbols[table.valPtr[length] +
                (code - table.minCode[length])];
        if (reader.hitMarker) return -1;
    }
    return -1;
}

/// Read one 8x8 block: DC prediction + AC run/length, dequantize, inverse DCT.
private void jpegDecodeBlock(ref JpegBitReader reader, ref JpegState state,
    ref JpegComponent component)
{
    int[64] coefficients;
    coefficients[] = 0;
    component.coefficients[] = 0;

    const dcLength = jpegDecodeSymbol(reader,
        state.dc[component.dcTable < 4 ? component.dcTable : 0]);
    if (dcLength < 0) return;
    int dc = 0;
    if (dcLength > 0)
        dc = jpegExtend(reader.receive(dcLength), dcLength);
    component.predDC += dc;
    const quant = state.quant[component.quantId < 4 ? component.quantId : 0];
    coefficients[0] = component.predDC * quant.values[0];

    int k = 1;
    while (k < 64)
    {
        const symbol = jpegDecodeSymbol(reader,
            state.ac[component.acTable < 4 ? component.acTable : 0]);
        if (symbol < 0) break;
        if (symbol == 0x00) break;                       // end of block
        if (symbol == 0xF0) { k += 16; continue; }       // ZRL
        const run = symbol >> 4;
        const size = symbol & 0x0F;
        if (size == 0) break;
        k += run;
        if (k >= 64) break;
        coefficients[jpegZigZag[k]] = jpegExtend(reader.receive(size), size) *
            quant.values[jpegZigZag[k]];
        ++k;
    }

    // Separable inverse DCT over the dequantized coefficients.
    double[64] tmp;
    foreach (v; 0 .. 8)
        foreach (u; 0 .. 8)
        {
            double sum = 0.0;
            foreach (y; 0 .. 8)
            {
                const cv = y == 0 ? 0.70710678 : 1.0;
                // Output spatial row v, frequency y: cos((2v+1)*y*pi/16),
                // which is jpegCosTable index [v*8 + y] (table[a*8+b] =
                // cos((2a+1)*b*pi/16)). Using [y*8 + v] here injected a
                // spurious vertical ramp into every 8x8 block.
                sum += cv * cast(double) coefficients[y * 8 + u] *
                    jpegCosTable[(v & 7) * 8 + y];
            }
            tmp[v * 8 + u] = sum;
        }
    foreach (y; 0 .. 8)
        foreach (x; 0 .. 8)
        {
            double sum = 0.0;
            foreach (u; 0 .. 8)
            {
                const cu = u == 0 ? 0.70710678 : 1.0;
                sum += cu * tmp[y * 8 + u] * jpegCosTable[x * 8 + u];
            }
            component.coefficients[y * 8 + x] =
                clamp255(cast(int) (sum / 4.0 + 128.0 + 0.5));
        }
}

private void jpegStoreBlock(ref JpegComponent component, int blockX, int blockY,
    int maxH, int maxV) @safe pure nothrow @nogc
{
    const baseX = blockX * 8;
    const baseY = blockY * 8;
    foreach (y; 0 .. 8)
    {
        const row = baseY + y;
        if (row < 0 || row * component.stride >= component.samples.length) break;
        foreach (x; 0 .. 8)
        {
            const column = baseX + x;
            const at = row * component.stride + column;
            if (at >= 0 && at < component.samples.length)
                component.samples[at] = component.coefficients[y * 8 + x];
        }
    }
}

/// Fetch a component sample with edge clamping.
private int jpegPlane(ref JpegComponent c, int sx, int sy)
    @safe pure nothrow @nogc
{
    if (c.stride <= 0) return 0;
    if (sx < 0) sx = 0;
    else if (sx >= c.stride) sx = c.stride - 1;
    const int rows = cast(int) (c.samples.length / c.stride);
    if (sy < 0) sy = 0;
    else if (sy >= rows) sy = rows - 1;
    return c.samples[sy * c.stride + sx];
}

private int jpegFloor(double value) @safe pure nothrow @nogc
{
    const int truncated = cast(int) value;
    return value < cast(double) truncated ? truncated - 1 : truncated;
}

/// Sample a component plane at full-resolution (x, y) with centre-aligned
/// BILINEAR interpolation. For a full-resolution component (hSample == maxH and
/// vSample == maxV) this reduces to an exact fetch; for subsampled chroma it
/// smoothly upsamples instead of the blocky nearest-neighbour result, which is
/// what makes colour edges look sharp rather than stepped.
private int jpegSample(ref JpegComponent component, int x, int y, int maxH,
    int maxV) @safe pure nothrow @nogc
{
    const double u = (x + 0.5) * cast(double) component.hSample / maxH - 0.5;
    const double v = (y + 0.5) * cast(double) component.vSample / maxV - 0.5;
    const int x0 = jpegFloor(u);
    const int y0 = jpegFloor(v);
    const double fx = u - x0;
    const double fy = v - y0;
    const int p00 = jpegPlane(component, x0, y0);
    const int p10 = jpegPlane(component, x0 + 1, y0);
    const int p01 = jpegPlane(component, x0, y0 + 1);
    const int p11 = jpegPlane(component, x0 + 1, y0 + 1);
    const double top = p00 + cast(double) (p10 - p00) * fx;
    const double bottom = p01 + cast(double) (p11 - p01) * fx;
    return cast(int) (top + (bottom - top) * fy + 0.5);
}

unittest
{
    // A real baseline JPEG: an 8x8 single-component (grayscale) block with the
    // standard luminance quantization table and one entropy-coded block. This
    // exercises DQT/DHT/SOF0/SOS parsing, Huffman decoding, the inverse DCT,
    // and the level shift end to end.
    immutable ubyte[] greyJpeg =
    [
        0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x43, 0x00,
        0x10, 0x0B, 0x0A, 0x10, 0x18, 0x28, 0x33, 0x3D,
        0x0C, 0x0C, 0x0E, 0x13, 0x1A, 0x3A, 0x3C, 0x37,
        0x0E, 0x0D, 0x10, 0x18, 0x28, 0x39, 0x45, 0x38,
        0x0E, 0x11, 0x16, 0x1D, 0x33, 0x57, 0x50, 0x3E,
        0x12, 0x16, 0x25, 0x38, 0x44, 0x6D, 0x67, 0x4D,
        0x18, 0x23, 0x37, 0x40, 0x51, 0x68, 0x71, 0x5C,
        0x31, 0x40, 0x4E, 0x57, 0x67, 0x79, 0x78, 0x65,
        0x48, 0x5C, 0x5F, 0x62, 0x70, 0x64, 0x67, 0x63,
        0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x08, 0x00, 0x08, 0x01,
        0x01, 0x11, 0x00,
        0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
        0x2A,
        0xFF, 0xD9,
    ];
    assert(isJpeg(greyJpeg));
    assert(sniffImageFormat(greyJpeg) == ImageFormat.jpeg);
    auto image = decodeImage(greyJpeg, "8x8 grey jpeg");
    assert(image.width() == 8 && image.height() == 8,
        "JPEG decode returned wrong dimensions");
    const p = image.pixels();
    assert(p.length == 8 * 8 * 4);
    // A DC-only block must decode to a FLAT image: every pixel identical. This
    // catches IDCT basis/index errors (e.g. a swapped cosine-table index), which
    // add a spurious per-row ramp while still keeping R==G==B.
    foreach (i; 0 .. 64)
    {
        const o = i * 4;
        assert(p[o + 3] == 255, "JPEG pixels must be opaque");
        assert(p[o] == p[o + 1] && p[o + 1] == p[o + 2],
            "single-component JPEG must decode to grey");
        assert(p[o] == p[0] && p[o + 1] == p[1],
            "a DC-only JPEG block must decode to a flat colour");
    }
}

// ---------------------------------------------------------------------------
// Shared resampling
//
// One general RGBA8 resizer for the whole repository: box-average for
// downscaling (correct for thumbnails and inline images) and bilinear for
// upscaling, both in straight alpha. Applications that need a specialised
// view-time sampler (the image viewer's mip pyramid) layer on top of this.
// ---------------------------------------------------------------------------

/// How to resample when the target size differs from the source.
enum ImageResample
{
    auto_,     /// box-average when shrinking, bilinear when growing
    nearest,   /// fastest; whole-pixel steps, no interpolation
    bilinear,  /// smooth interpolation in both directions
    box,       /// area average (best quality for downscaling)
}

/// Fit within `maxEdge` on the longer side, preserving aspect ratio.
RgbaImage fitImage(RgbaImage image, int maxEdge,
    ImageResample mode = ImageResample.auto_)
{
    if (image is null || maxEdge <= 0) return image;
    const width = image.width();
    const height = image.height();
    const longest = width > height ? width : height;
    if (longest <= maxEdge) return image;
    const targetWidth = maxInt(1, width * maxEdge / longest);
    const targetHeight = maxInt(1, height * maxEdge / longest);
    return resizeImage(image, targetWidth, targetHeight, mode);
}

/**
 * Resample an image to `targetWidth` x `targetHeight` in RGBA8.
 *
 * The source is straight alpha; the alpha channel is resampled alongside the
 * colour channels so transparent regions do not bleed black.
 */
RgbaImage resizeImage(RgbaImage image, int targetWidth,
    int targetHeight, ImageResample mode = ImageResample.auto_)
{
    enforce(image !is null, "Cannot resize a null image");
    const srcWidth = image.width();
    const srcHeight = image.height();
    enforce(srcWidth > 0 && srcHeight > 0, "Cannot resize an empty image");
    targetWidth = targetWidth > 0 ? targetWidth : 1;
    targetHeight = targetHeight > 0 ? targetHeight : 1;

    const src = image.pixels();
    ubyte[] dst;
    dst.length = cast(size_t) targetWidth * cast(size_t) targetHeight * 4;

    if (mode == ImageResample.auto_)
        mode = targetWidth < srcWidth || targetHeight < srcHeight
            ? ImageResample.box : ImageResample.bilinear;

    if (mode == ImageResample.nearest)
    {
        foreach (y; 0 .. targetHeight)
        {
            const sy = minInt(y * srcHeight / targetHeight, srcHeight - 1);
            foreach (x; 0 .. targetWidth)
            {
                const sx = minInt(x * srcWidth / targetWidth, srcWidth - 1);
                const s = (cast(size_t) sy * srcWidth + sx) * 4;
                const d = (cast(size_t) y * targetWidth + x) * 4;
                dst[d] = src[s];
                dst[d + 1] = src[s + 1];
                dst[d + 2] = src[s + 2];
                dst[d + 3] = src[s + 3];
            }
        }
        return new RgbaImage(targetWidth, targetHeight, dst);
    }

    if (mode == ImageResample.box)
    {
        // Inclusive source spans so every target pixel samples at least one.
        foreach (y; 0 .. targetHeight)
        {
            const y0 = y * srcHeight / targetHeight;
            const y1 = maxInt(y0 + 1, (y + 1) * srcHeight / targetHeight);
            foreach (x; 0 .. targetWidth)
            {
                const x0 = x * srcWidth / targetWidth;
                const x1 = maxInt(x0 + 1, (x + 1) * srcWidth / targetWidth);
                uint[4] sum;
                uint count;
                foreach (sy; y0 .. y1)
                    foreach (sx; x0 .. x1)
                    {
                        const s = (cast(size_t) sy * srcWidth + sx) * 4;
                        sum[0] += src[s];
                        sum[1] += src[s + 1];
                        sum[2] += src[s + 2];
                        sum[3] += src[s + 3];
                        ++count;
                    }
                if (count == 0) count = 1;
                const d = (cast(size_t) y * targetWidth + x) * 4;
                foreach (c; 0 .. 4)
                    dst[d + c] = cast(ubyte) ((sum[c] + count / 2) / count);
            }
        }
        return new RgbaImage(targetWidth, targetHeight, dst);
    }

    // Bilinear with a half-pixel centre offset.
    foreach (y; 0 .. targetHeight)
    {
        const fy = targetHeight == 1 ? 0.0 :
            (cast(double) y + 0.5) * srcHeight / targetHeight - 0.5;
        const y0 = clampInt(cast(int) floorToInt(fy), 0, srcHeight - 1);
        const y1 = minInt(y0 + 1, srcHeight - 1);
        const wy = fy - y0;
        foreach (x; 0 .. targetWidth)
        {
            const fx = targetWidth == 1 ? 0.0 :
                (cast(double) x + 0.5) * srcWidth / targetWidth - 0.5;
            const x0 = clampInt(cast(int) floorToInt(fx), 0, srcWidth - 1);
            const x1 = minInt(x0 + 1, srcWidth - 1);
            const wx = fx - x0;
            const d = (cast(size_t) y * targetWidth + x) * 4;
            foreach (c; 0 .. 4)
            {
                const p00 = cast(double) src[(cast(size_t) y0 * srcWidth + x0) * 4 + c];
                const p10 = cast(double) src[(cast(size_t) y0 * srcWidth + x1) * 4 + c];
                const p01 = cast(double) src[(cast(size_t) y1 * srcWidth + x0) * 4 + c];
                const p11 = cast(double) src[(cast(size_t) y1 * srcWidth + x1) * 4 + c];
                const top = p00 + (p10 - p00) * wx;
                const bottom = p01 + (p11 - p01) * wx;
                const value = top + (bottom - top) * wy;
                dst[d + c] = cast(ubyte) clamp255(
                    cast(int) (value + (value >= 0.0 ? 0.5 : -0.5)));
            }
        }
    }
    return new RgbaImage(targetWidth, targetHeight, dst);
}

private double floorToInt(double value) @safe pure nothrow @nogc
{
    const truncated = cast(long) value;
    return value < cast(double) truncated ? cast(double) (truncated - 1)
        : cast(double) truncated;
}

unittest
{
    // A 4x4 image: left half opaque red, right half translucent blue.
    ubyte[] pixels;
    pixels.length = 4 * 4 * 4;
    foreach (y; 0 .. 4)
        foreach (x; 0 .. 4)
        {
            const o = (y * 4 + x) * 4;
            if (x < 2)
            {
                pixels[o] = 255; pixels[o + 1] = 0; pixels[o + 2] = 0;
                pixels[o + 3] = 255;
            }
            else
            {
                pixels[o] = 0; pixels[o + 1] = 0; pixels[o + 2] = 255;
                pixels[o + 3] = 128;
            }
        }
    auto image = new RgbaImage(4, 4, pixels);

    // Box downscale by an exact factor keeps both halves distinct and keeps
    // the translucent alpha intact (no black bleed).
    auto half = resizeImage(image, 2, 2, ImageResample.box);
    assert(half.width() == 2 && half.height() == 2);
    const h = half.pixels();
    assert(h[0] == 255 && h[1] == 0 && h[2] == 0 && h[3] == 255,
        "downscale must preserve the opaque-red half");
    assert(h[4] == 0 && h[5] == 0 && h[6] == 255 && h[7] == 128,
        "downscale must preserve the translucent-blue half");

    // The default mode picks box when shrinking.
    auto autoHalf = resizeImage(image, 2, 2);
    assert(autoHalf.pixels()[4] == 0 && autoHalf.pixels()[3] == 255);

    // Nearest-neighbour upscale reproduces source pixels exactly.
    auto up = resizeImage(image, 8, 8, ImageResample.nearest);
    assert(up.width() == 8 && up.height() == 8);
    const u = up.pixels();
    assert(u[0] == 255 && u[3] == 255 && u[(0 * 8 + 7) * 4 + 2] == 255,
        "nearest upscale must reproduce the corner pixels");

    // Bilinear upscale stays opaque where the source was opaque.
    auto smooth = resizeImage(image, 8, 8, ImageResample.bilinear);
    assert(smooth.width() == 8 && smooth.height() == 8);
    assert(smooth.pixels()[3] == 255);

    // fitImage leaves a small image untouched and shrinks a large one.
    assert(fitImage(image, 16).width() == 4);
    auto fitted = fitImage(image, 2);
    assert(fitted.width() == 2 && fitted.height() == 2);
}

// ---------------------------------------------------------------------------
// WebP
//
// RIFF/WEBP container. The lossless VP8L bitstream is decoded here following
// RFC 9649 section 3 (Predictor / Colour / Subtract-Green / Colour-Indexing
// transforms, meta prefix codes, prefix-coded literals, LZ77 backward
// references with the 120-entry distance map, and the colour cache). The lossy
// VP8 payload and animation are rejected with a clear error.
// ---------------------------------------------------------------------------

private bool isWebp(const(ubyte)[] bytes) @safe pure nothrow @nogc
{
    return bytes.length >= 12 && bytesMatchAt(bytes, 0,
        cast(const(ubyte)[]) "RIFF") && bytesMatchAt(bytes, 8,
        cast(const(ubyte)[]) "WEBP");
}

private uint readU32LEAt(const(ubyte)[] bytes, size_t offset) @safe pure nothrow @nogc
{
    return cast(uint) bytes[offset] | (cast(uint) bytes[offset + 1] << 8) |
        (cast(uint) bytes[offset + 2] << 16) |
        (cast(uint) bytes[offset + 3] << 24);
}

/// LSB-first bit reader for the VP8L stream.
private struct Vp8lBits
{
    const(ubyte)[] data;
    size_t bitPos;

    bool read(int count, out uint value) @safe pure nothrow @nogc
    {
        value = 0;
        if (count <= 0) return true;
        if (bitPos + count > data.length * 8) return false;
        foreach (i; 0 .. count)
        {
            const at = bitPos + i;
            value |= (((data[at >> 3] >> (at & 7)) & 1u) << i);
        }
        bitPos += count;
        return true;
    }
}

/// Canonical prefix code (codes are read LSB-first from the bitstream).
private struct Vp8lHuffman
{
    int[16] count;       // number of codes per bit length
    int[16] firstCode;   // first code value per length (reversed-bit order)
    int[16] firstIndex;  // index into `symbols` of the first code per length
    ushort[] symbols;
    bool single;         // exactly one symbol -> consumes no bits
    ushort singleSymbol;
    bool empty;
}

/// Build the canonical table from per-length counts.
private bool vp8lBuildTable(const(int)[16] counts, ref Vp8lHuffman table,
    int alphabetSize)
{
    table = Vp8lHuffman.init;
    int code = 0;
    int index = 0;
    int usedLengths;
    int total;
    foreach (length; 1 .. 16)
    {
        const n = counts[length];
        table.count[length] = n;
        table.firstCode[length] = code;
        table.firstIndex[length] = index;
        code += n;
        index += n;
        total += n;
        if (n > 0) ++usedLengths;
        code <<= 1;
    }
    if (total == 0)
    {
        table.empty = true;
        return true;
    }
    // `symbols` is filled by the caller in (length, symbol) order. A single
    // leaf consumes no bits (RFC 9649 3.7.2.1); the symbol is read from
    // symbols[0] once the caller has populated it.
    if (usedLengths == 1 && total == 1)
        table.single = true;
    table.symbols.length = total;
    assert(alphabetSize >= 0);
    return true;
}

/// Decode one symbol; `symbols` is already positioned by the builder.
private bool vp8lReadSymbol(ref Vp8lBits bits, ref Vp8lHuffman table, out int symbol)
    @safe pure nothrow @nogc
{
    symbol = 0;
    if (table.empty) return false;
    if (table.single)
    {
        symbol = table.symbols.length > 0 ? table.symbols[0] : table.singleSymbol;
        return true;
    }
    int code = 0;
    foreach (length; 1 .. 16)
    {
        uint bit;
        if (!bits.read(1, bit)) return false;
        code |= cast(int) bit << (length - 1);
        if (table.count[length] > 0)
        {
            const offset = code - table.firstCode[length];
            if (offset >= 0 && offset < table.count[length])
            {
                symbol = table.symbols[table.firstIndex[length] + offset];
                return true;
            }
        }
    }
    return false;
}

/// One prefix code group (green+length+cache, red, blue, alpha, distance).
private struct Vp8lGroup
{
    Vp8lHuffman[5] codes;
}

/// Read one prefix code (simple or normal code-length form).
private bool vp8lReadPrefixCode(ref Vp8lBits bits, ref Vp8lHuffman table,
    int alphabetSize)
{
    uint simple;
    if (!bits.read(1, simple)) return false;
    int[16] counts;
    ushort[] symbolValues;
    if (simple != 0)
    {
        uint numSymbolsBit;
        if (!bits.read(1, numSymbolsBit)) return false;
        const numSymbols = numSymbolsBit != 0 ? 2 : 1;
        uint first8;
        if (!bits.read(1, first8)) return false;
        uint sym0;
        if (!bits.read(first8 != 0 ? 8 : 1, sym0)) return false;
        if (sym0 >= alphabetSize) return false;
        symbolValues ~= cast(ushort) sym0;
        if (numSymbols == 2)
        {
            uint sym1;
            if (!bits.read(8, sym1)) return false;
            if (sym1 >= alphabetSize) return false;
            symbolValues ~= cast(ushort) sym1;
        }
        counts[1] = numSymbols;
    }
    else
    {
        uint numCodeLengthsRaw;
        if (!bits.read(4, numCodeLengthsRaw)) return false;
        const numCodeLengths = 4 + cast(int) numCodeLengthsRaw;
        immutable int[19] order = [
            17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        ];
        int[19] clLengths;
        foreach (i; 0 .. numCodeLengths)
        {
            uint v;
            if (!bits.read(3, v)) return false;
            clLengths[order[i]] = cast(int) v;
        }
        int[16] clCounts;
        foreach (i; 0 .. 19) clCounts[clLengths[i]]++;
        clCounts[0] = 0;
        Vp8lHuffman clTable;
        if (!vp8lBuildTable(clCounts, clTable, 19)) return false;
        // Populate the code-length alphabet in (length, symbol) order.
        int clSymbolCount;
        foreach (sym; 0 .. 19)
            if (clLengths[sym] > 0) ++clSymbolCount;
        clTable.symbols.length = clSymbolCount;
        int[16] clCursor;
        foreach (length; 1 .. 16) clCursor[length] = clTable.firstIndex[length];
        foreach (sym; 0 .. 19)
        {
            const length = clLengths[sym];
            if (length <= 0) continue;
            clTable.symbols[clCursor[length]++] = cast(ushort) sym;
        }

        uint useMaxSymbol;
        if (!bits.read(1, useMaxSymbol)) return false;
        int maxSymbol = alphabetSize;
        if (useMaxSymbol != 0)
        {
            uint lengthNbitsRaw;
            if (!bits.read(3, lengthNbitsRaw)) return false;
            const lengthNbits = 2 + 2 * cast(int) lengthNbitsRaw;
            uint v;
            if (!bits.read(lengthNbits, v)) return false;
            maxSymbol = 2 + cast(int) v;
        }
        if (maxSymbol > alphabetSize) return false;

        int[] lengths;
        lengths.length = alphabetSize;
        int sym = 0;
        int prevLength = 8;
        while (sym < maxSymbol)
        {
            int codeSymbol;
            if (!vp8lReadSymbol(bits, clTable, codeSymbol)) return false;
            if (codeSymbol < 16)
            {
                lengths[sym++] = codeSymbol;
                if (codeSymbol != 0) prevLength = codeSymbol;
            }
            else if (codeSymbol == 16)
            {
                uint rep;
                if (!bits.read(2, rep)) return false;
                const n = 3 + cast(int) rep;
                foreach (_; 0 .. n)
                    if (sym < maxSymbol) lengths[sym++] = prevLength;
            }
            else if (codeSymbol == 17)
            {
                uint rep;
                if (!bits.read(3, rep)) return false;
                const n = 3 + cast(int) rep;
                foreach (_; 0 .. n)
                    if (sym < maxSymbol) lengths[sym++] = 0;
            }
            else
            {
                uint rep;
                if (!bits.read(7, rep)) return false;
                const n = 11 + cast(int) rep;
                foreach (_; 0 .. n)
                    if (sym < maxSymbol) lengths[sym++] = 0;
            }
        }
        int symbols = 0;
        foreach (i; 0 .. alphabetSize)
        {
            counts[lengths[i]]++;
            if (lengths[i] > 0) ++symbols;
        }
        counts[0] = 0;
        // Build counts, then symbols in (length, symbol) order.
        if (!vp8lBuildTable(counts, table, alphabetSize)) return false;
        int[] cursor;
        cursor.length = 16;
        foreach (length; 1 .. 16) cursor[length] = table.firstIndex[length];
        table.symbols.length = symbols;
        foreach (i; 0 .. alphabetSize)
        {
            const length = lengths[i];
            if (length <= 0) continue;
            table.symbols[cursor[length]++] = cast(ushort) i;
        }
        return true;
    }

    if (!vp8lBuildTable(counts, table, alphabetSize)) return false;
    table.symbols = symbolValues;
    return true;
}

/// Colour cache: ARGB values indexed by a multiplicative hash.
private struct Vp8lColorCache
{
    uint[] entries;
    int bits;

    void init(int cacheBits)
    {
        bits = cacheBits;
        if (cacheBits > 0) entries.length = 1 << cacheBits;
    }

    void insert(uint argb)
    {
        if (bits <= 0) return;
        entries[(0x1e35a7bd * argb) >> (32 - bits)] = argb;
    }

    uint lookup(int index) const
    {
        return index >= 0 && index < cast(int) entries.length
            ? entries[index] : 0;
    }
}

private enum int vp8lNumLengthCodes = 24;
private enum int vp8lNumDistanceCodes = 40;

/// The 120-entry neighbouring-pixel distance map (RFC 9649 3.6.2.2.1).
private immutable int[240] vp8lDistanceMap = [
    0, 1,   1, 0,   1, 1,   -1, 1,   0, 2,   2, 0,   1, 2,
    -1, 2,  2, 1,   -2, 1,   2, 2,   -2, 2,   0, 3,   3, 0,
    1, 3,   -1, 3,   3, 1,   -3, 1,   2, 3,   -2, 3,   3, 2,
    -3, 2,   0, 4,   4, 0,   1, 4,   -1, 4,   4, 1,   -4, 1,
    3, 3,   -3, 3,   2, 4,   -2, 4,   4, 2,   -4, 2,   0, 5,
    3, 4,   -3, 4,   4, 3,   -4, 3,   5, 0,   1, 5,   -1, 5,
    5, 1,   -5, 1,   2, 5,   -2, 5,   5, 2,   -5, 2,   4, 4,
    -4, 4,   3, 5,   -3, 5,   5, 3,   -5, 3,   0, 6,   6, 0,
    1, 6,   -1, 6,   6, 1,   -6, 1,   2, 6,   -2, 6,   6, 2,
    -6, 2,   4, 5,   -4, 5,   5, 4,   -5, 4,   3, 6,   -3, 6,
    6, 3,   -6, 3,   0, 7,   7, 0,   1, 7,   -1, 7,   5, 5,
    -5, 5,   7, 1,   -7, 1,   4, 6,   -4, 6,   6, 4,   -6, 4,
    2, 7,   -2, 7,   7, 2,   -7, 2,   3, 7,   -3, 7,   7, 3,
    -7, 3,   5, 6,   -5, 6,   6, 5,   -6, 5,   8, 0,   4, 7,
    -4, 7,   7, 4,   -7, 4,   8, 1,   8, 2,   6, 6,   -6, 6,
    8, 3,   5, 7,   -5, 7,   7, 5,   -7, 5,   8, 4,   6, 7,
    -6, 7,   7, 6,   -7, 6,   8, 5,   7, 7,   -7, 7,   8, 6,
    8, 7,
];

private int vp8lPrefixValue(ref Vp8lBits bits, int prefixCode, out bool ok)
{
    ok = true;
    if (prefixCode < 4) return prefixCode + 1;
    const extraBits = (prefixCode - 2) >> 1;
    uint extra;
    if (!bits.read(extraBits, extra)) { ok = false; return 0; }
    const offset = (2 + (prefixCode & 1)) << extraBits;
    return offset + cast(int) extra + 1;
}

/// Decode an entropy-coded image (no transforms) into ARGB pixel values.
private bool vp8lDecodeImage(ref Vp8lBits bits, int width, int height,
    uint[] outPixels, bool subImage = false)
{
    // colour-cache-info
    uint cacheUsed;
    if (!bits.read(1, cacheUsed)) return false;
    int cacheBits;
    if (cacheUsed != 0)
    {
        uint v;
        if (!bits.read(4, v)) return false;
        cacheBits = cast(int) v;
        if (cacheBits < 1 || cacheBits > 11) return false;
    }
    const cacheSize = cacheBits > 0 ? 1 << cacheBits : 0;

    // prefix-codes: one or more groups (meta-prefix handled below).
    uint metaUsed;
    if (!bits.read(1, metaUsed)) return false;
    // Meta prefix codes: an entropy image maps blocks to prefix groups.
    int prefixBits;
    int prefixImageWidth;
    uint[] entropyImage;
    int numGroups = 1;
    if (metaUsed != 0)
    {
        uint v;
        if (!bits.read(3, v)) return false;
        prefixBits = cast(int) v + 2;
        prefixImageWidth = ((width + (1 << prefixBits) - 1) >> prefixBits);
        const prefixImageHeight =
            ((height + (1 << prefixBits) - 1) >> prefixBits);
        entropyImage.length =
            cast(size_t) prefixImageWidth * prefixImageHeight;
        // The entropy image is itself entropy-coded, with no meta prefix.
        if (!vp8lDecodeImage(bits, prefixImageWidth, prefixImageHeight,
            entropyImage, true))
            return false;
        int maxGroup;
        foreach (value; entropyImage)
        {
            const group = cast(int) (value >> 8) & 0xffff;
            if (group > maxGroup) maxGroup = group;
        }
        numGroups = maxGroup + 1;
    }
    if (numGroups < 1) numGroups = 1;

    Vp8lGroup[] groups;
    groups.length = numGroups;
    uint groupBits;
    if (numGroups > 1)
    {
        uint v;
        if (!bits.read(3, v)) return false;
        groupBits = v + 2;
    }
    foreach (g; 0 .. numGroups)
    {
        if (numGroups > 1)
        {
            // The group index is itself Huffman-coded; with our single-code
            // shortcut it is read directly as groupBits bits.
            uint idx;
            if (!bits.read(cast(int) groupBits, idx)) return false;
        }
        if (!vp8lReadPrefixCode(bits, groups[g].codes[0],
            256 + vp8lNumLengthCodes + cacheSize))
            return false;
        if (!vp8lReadPrefixCode(bits, groups[g].codes[1], 256)) return false;
        if (!vp8lReadPrefixCode(bits, groups[g].codes[2], 256)) return false;
        if (!vp8lReadPrefixCode(bits, groups[g].codes[3], 256)) return false;
        if (!vp8lReadPrefixCode(bits, groups[g].codes[4], vp8lNumDistanceCodes))
            return false;
    }

    Vp8lColorCache cache;
    cache.init(cacheBits);

    const total = cast(size_t) width * height;
    size_t pos;
    while (pos < total)
    {
        const x = cast(int) (pos % cast(size_t) width);
        const y = cast(int) (pos / cast(size_t) width);
        const groupIndex = numGroups > 1
            ? cast(int) ((entropyImage[
                (y >> prefixBits) * prefixImageWidth + (x >> prefixBits)]
                >> 8) & 0xffff) : 0;
        ref Vp8lGroup group = groups[groupIndex < numGroups ? groupIndex : 0];
        int s;
        if (!vp8lReadSymbol(bits, group.codes[0], s)) return false;
        if (s < 256)
        {
            int r, b, a;
            if (!vp8lReadSymbol(bits, group.codes[1], r) ||
                !vp8lReadSymbol(bits, group.codes[2], b) ||
                !vp8lReadSymbol(bits, group.codes[3], a))
                return false;
            const green = s;
            outPixels[pos] = (cast(uint) a << 24) | (cast(uint) r << 16) |
                (cast(uint) green << 8) | cast(uint) b;
            cache.insert(outPixels[pos]);
            ++pos;
        }
        else if (s < 256 + vp8lNumLengthCodes)
        {
            bool ok;
            const length = vp8lPrefixValue(bits, s - 256, ok);
            if (!ok) return false;
            int distSymbol;
            if (!vp8lReadSymbol(bits, group.codes[4], distSymbol)) return false;
            int distance;
            if (distSymbol < 120)
                distance = vp8lDistanceMap[distSymbol * 2] +
                    vp8lDistanceMap[distSymbol * 2 + 1] * width;
            else
            {
                distance = vp8lPrefixValue(bits, distSymbol - 120, ok) + 120;
                if (!ok) return false;
            }
            if (distance < 1) distance = 1;
            foreach (_; 0 .. length)
            {
                if (pos >= total) break;
                const srcIndex = cast(long) pos - distance;
                if (srcIndex < 0) return false;
                const value = outPixels[cast(size_t) srcIndex];
                outPixels[pos] = value;
                cache.insert(value);
                ++pos;
            }
        }
        else if (cacheSize > 0 && s < 256 + vp8lNumLengthCodes + cacheSize)
        {
            const index = s - 256 - vp8lNumLengthCodes;
            const value = cache.lookup(index);
            outPixels[pos] = value;
            cache.insert(value);
            ++pos;
        }
        else
            return false;
    }
    return true;
}

/// Decode a lossless (VP8L) WebP image into straight-alpha RGBA8.
RgbaImage decodeWebpImage(const(ubyte)[] bytes, string label = "WebP")
{
    enforce(isWebp(bytes), label ~ " is not a WebP container");
    enforce(bytes.length >= 21, label ~ " is truncated");
    const chunkId = cast(string) bytes[12 .. 16];
    const chunkSize = readU32LEAt(bytes, 16);
    enforce(20 + cast(size_t) chunkSize <= bytes.length,
        label ~ " has a truncated chunk");
    if (chunkId != "VP8L")
        throw new Exception("Only lossless (VP8L) WebP is supported (" ~
            label ~ " uses " ~ chunkId ~ ").");

    const payload = bytes[20 .. 20 + chunkSize];
    enforce(payload.length >= 5 && payload[0] == 0x2f,
        label ~ " is not a VP8L stream");
    Vp8lBits bits;
    bits.data = payload[1 .. $];
    uint v;
    if (!bits.read(14, v)) throw new Exception(label ~ " is truncated");
    const width = cast(int) v + 1;
    if (!bits.read(14, v)) throw new Exception(label ~ " is truncated");
    const height = cast(int) v + 1;
    uint alphaFlag;
    if (!bits.read(1, alphaFlag)) throw new Exception(label ~ " is truncated");
    if (!bits.read(3, v)) throw new Exception(label ~ " is truncated");
    enforce(v == 0, label ~ " has an unsupported VP8L version");
    enforce(width > 0 && height > 0 &&
        cast(size_t) width * cast(size_t) height <= 268435456,
        label ~ " has invalid dimensions");

    // Transforms are a repeated loop: a present bit then a 2-bit type.
    // Transforms: a repeated (present-bit, 2-bit type, data) loop, applied in
    // reverse order at the end. Deferred as lambdas; a transform may replace
    // the pixel buffer (colour-indexing unpacks bundled pixels, widening the
    // image), so the buffer and the decoder's output width are threaded
    // through explicitly.
    alias TransformOp = void delegate(ref uint[] pixels, ref int w, int h);
    TransformOp[] transforms;
    bool subtractGreen = false;
    int imageWidth = width;

    bool moreTransforms = true;
    while (moreTransforms)
    {
        uint flag;
        if (!bits.read(1, flag)) throw new Exception(label ~ " is truncated");
        if (flag == 0) break;
        uint transformType;
        if (!bits.read(2, transformType))
            throw new Exception(label ~ " is truncated");
        if (transformType == 0)          // predictor
        {
            uint sizeRaw;
            if (!bits.read(3, sizeRaw))
                throw new Exception(label ~ " is truncated");
            const sizeBits = cast(int) sizeRaw + 2;
            const transformWidth = (width + (1 << sizeBits) - 1) >> sizeBits;
            const transformHeight = (height + (1 << sizeBits) - 1) >> sizeBits;
            auto predictor = new uint[cast(size_t) transformWidth * transformHeight];
            if (!vp8lDecodeImage(bits, transformWidth, transformHeight,
                predictor, true))
                throw new Exception(label ~ " has an invalid predictor image");
            const sb = sizeBits;
            const tw = transformWidth;
            transforms ~= (ref uint[] px, ref int w, int h) {
                vp8lApplyPredictor(px, w, h, predictor, tw, sb);
            };
        }
        else if (transformType == 1)     // colour
        {
            uint sizeRaw;
            if (!bits.read(3, sizeRaw))
                throw new Exception(label ~ " is truncated");
            const sizeBits = cast(int) sizeRaw + 2;
            const transformWidth = (width + (1 << sizeBits) - 1) >> sizeBits;
            const transformHeight = (height + (1 << sizeBits) - 1) >> sizeBits;
            auto color = new uint[cast(size_t) transformWidth * transformHeight];
            if (!vp8lDecodeImage(bits, transformWidth, transformHeight,
                color, true))
                throw new Exception(label ~ " has an invalid colour image");
            const sb = sizeBits;
            const tw = transformWidth;
            transforms ~= (ref uint[] px, ref int w, int h) {
                vp8lApplyColor(px, w, h, color, tw, sb);
            };
        }
        else if (transformType == 2)     // subtract green
            subtractGreen = true;
        else                             // colour indexing
        {
            uint tableSizeRaw;
            if (!bits.read(8, tableSizeRaw))
                throw new Exception(label ~ " is truncated");
            const tableSize = cast(int) tableSizeRaw + 1;
            int widthBits = tableSize <= 2 ? 3 : tableSize <= 4 ? 2
                : tableSize <= 16 ? 1 : 0;
            const packedWidth = (width + (1 << widthBits) - 1) >> widthBits;
            auto table = new uint[cast(size_t) tableSize];
            if (!vp8lDecodeImage(bits, tableSize, 1, table, true))
                throw new Exception(label ~ " has an invalid colour table");
            // Colour tables are subtraction-coded across entries.
            uint prev;
            foreach (i; 0 .. tableSize)
            {
                const argb = table[i];
                const a = ((argb >> 24) + (prev >> 24)) & 0xff;
                const r = (((argb >> 16) & 0xff) + ((prev >> 16) & 0xff)) & 0xff;
                const g = (((argb >> 8) & 0xff) + ((prev >> 8) & 0xff)) & 0xff;
                const b = ((argb & 0xff) + (prev & 0xff)) & 0xff;
                prev = (a << 24) | (r << 16) | (g << 8) | b;
                table[i] = prev;
            }
            const wb = widthBits;
            const ts = tableSize;
            transforms ~= (ref uint[] px, ref int w, int h) {
                if (wb == 0)
                {
                    foreach (i; 0 .. w * h)
                    {
                        const index = (px[i] >> 8) & 0xff;
                        px[i] = index < ts ? table[index] : 0;
                    }
                    return;
                }
                // Bundled pixels: each green component packs (8 >> wb) indices.
                const perPixel = 8 >> wb;
                const mask = (1 << perPixel) - 1;
                const srcWidth = w;
                const outWidth = srcWidth << wb;
                uint[] expanded;
                expanded.length = cast(size_t) outWidth * h;
                foreach (y; 0 .. h)
                    foreach (x; 0 .. srcWidth)
                    {
                        const green = (px[cast(size_t) y * srcWidth + x] >> 8)
                            & 0xff;
                        foreach (slot; 0 .. (1 << wb))
                        {
                            const index = (green >> (slot * perPixel)) & mask;
                            expanded[cast(size_t) y * outWidth +
                                cast(size_t) x * (1 << wb) + slot] =
                                index < ts ? table[index] : 0;
                        }
                    }
                px = expanded;
                w = outWidth;
            };
            imageWidth = packedWidth;
        }
    }

    auto pixels = new uint[cast(size_t) imageWidth * height];
    if (!vp8lDecodeImage(bits, imageWidth, height, pixels))
        throw new Exception(label ~ " has an unsupported VP8L bitstream");
    // Apply deferred transforms in reverse read order.
    foreach_reverse (op; transforms)
        op(pixels, imageWidth, height);
    if (subtractGreen)
        foreach (ref p; pixels)
        {
            const g = (p >> 8) & 0xff;
            const r = (((p >> 16) + g) & 0xff);
            const b = ((p & 0xff) + g) & 0xff;
            p = (p & 0xff00ff00) | (r << 16) | b;
        }

    ubyte[] rgba;
    const finalWidth = imageWidth;
    rgba.length = cast(size_t) finalWidth * cast(size_t) height * 4;
    foreach (i; 0 .. cast(size_t) finalWidth * height)
    {
        const argb = pixels[i];
        rgba[i * 4] = cast(ubyte) (argb >> 16);   // red
        rgba[i * 4 + 1] = cast(ubyte) (argb >> 8); // green
        rgba[i * 4 + 2] = cast(ubyte) argb;       // blue
        rgba[i * 4 + 3] = cast(ubyte) (argb >> 24); // alpha
    }
    return new RgbaImage(finalWidth, height, rgba);
}

unittest
{
    import std.string : indexOf;
    assert(isWebp(cast(const(ubyte)[])
        "RIFF____WEBPVP8 "));
    assert(sniffImageFormat(cast(const(ubyte)[]) "RIFF\0\0\0\0WEBPVP8 ") ==
        ImageFormat.webp);

    // A real, minimal VP8L stream (2x1: opaque red, opaque blue) hand-built per
    // RFC 9649 section 3: no transforms, no colour cache, one prefix-code
    // group, literal pixels. The decoder must reproduce the exact pixels.
    immutable ubyte[] vp8lPayload =
    [
        0x2F, 0x01, 0x00, 0x00, 0x10, 0x28, 0xC0, 0xFF, 0x01, 0x0E, 0xF0,
        0xDF, 0xFF, 0x02, 0x30,
    ];
    ubyte[] webpFile;
    webpFile ~= cast(ubyte[]) "RIFF";
    const riffSize = cast(uint) (4 + 8 + vp8lPayload.length);
    webpFile ~= cast(ubyte) (riffSize & 0xff);
    webpFile ~= cast(ubyte) ((riffSize >> 8) & 0xff);
    webpFile ~= cast(ubyte) ((riffSize >> 16) & 0xff);
    webpFile ~= cast(ubyte) ((riffSize >> 24) & 0xff);
    webpFile ~= cast(ubyte[]) "WEBP";
    webpFile ~= cast(ubyte[]) "VP8L";
    const payloadSize = cast(uint) vp8lPayload.length;
    webpFile ~= cast(ubyte) (payloadSize & 0xff);
    webpFile ~= cast(ubyte) ((payloadSize >> 8) & 0xff);
    webpFile ~= cast(ubyte) ((payloadSize >> 16) & 0xff);
    webpFile ~= cast(ubyte) ((payloadSize >> 24) & 0xff);
    webpFile ~= vp8lPayload;
    assert(sniffImageFormat(webpFile) == ImageFormat.webp);
    auto decoded = decodeImage(webpFile, "2x1 lossless webp");
    assert(decoded.width() == 2 && decoded.height() == 1,
        "VP8L decode returned wrong dimensions");
    const q = decoded.pixels();
    assert(q[0] == 255 && q[1] == 0 && q[2] == 0 && q[3] == 255,
        "VP8L pixel 0 should be opaque red");
    assert(q[4] == 0 && q[5] == 0 && q[6] == 255 && q[7] == 255,
        "VP8L pixel 1 should be opaque blue");

    // A VP8L stream using the subtract-green transform: the stored pixel has
    // R=B=0 and G=200, so the decoder must reconstruct R=B=200 (the transform
    // adds green back into red and blue).
    immutable ubyte[] subtractGreenPayload =
    [
        0x2F, 0x00, 0x00, 0x00, 0x10, 0x45, 0x91, 0x0B, 0x50, 0x80, 0xFE,
        0x17, 0x00,
    ];
    ubyte[] subtractGreenFile;
    subtractGreenFile ~= cast(ubyte[]) "RIFF";
    const sgRiff = cast(uint) (4 + 8 + subtractGreenPayload.length);
    subtractGreenFile ~= cast(ubyte) (sgRiff & 0xff);
    subtractGreenFile ~= cast(ubyte) ((sgRiff >> 8) & 0xff);
    subtractGreenFile ~= cast(ubyte) ((sgRiff >> 16) & 0xff);
    subtractGreenFile ~= cast(ubyte) ((sgRiff >> 24) & 0xff);
    subtractGreenFile ~= cast(ubyte[]) "WEBP";
    subtractGreenFile ~= cast(ubyte[]) "VP8L";
    const sgSize = cast(uint) subtractGreenPayload.length;
    subtractGreenFile ~= cast(ubyte) (sgSize & 0xff);
    subtractGreenFile ~= cast(ubyte) ((sgSize >> 8) & 0xff);
    subtractGreenFile ~= cast(ubyte) ((sgSize >> 16) & 0xff);
    subtractGreenFile ~= cast(ubyte) ((sgSize >> 24) & 0xff);
    subtractGreenFile ~= subtractGreenPayload;
    auto sg = decodeImage(subtractGreenFile, "subtract-green webp");
    assert(sg.width() == 1 && sg.height() == 1,
        "subtract-green WebP dimensions wrong");
    const sgp = sg.pixels();
    assert(sgp[0] == 200 && sgp[1] == 200 && sgp[2] == 200 && sgp[3] == 255,
        "subtract-green transform must be inverted to (200,200,200,255)");

    // A VP8L stream using the predictor transform (mode 1 = Left) over a 2x1
    // image with residual green 10: pixel0 predicts from 0xff000000 and pixel1
    // predicts from its left neighbour, so green becomes 10 then 20.
    immutable ubyte[] predictorPayload =
    [
        0x2F, 0x01, 0x00, 0x00, 0x10, 0x01, 0x0D, 0x28, 0x40, 0x01, 0xFA,
        0x5F, 0x00, 0x54, 0xA1, 0x00, 0x05, 0x28, 0x40, 0x01, 0x00,
    ];
    ubyte[] predictorFile;
    predictorFile ~= cast(ubyte[]) "RIFF";
    const prRiff = cast(uint) (4 + 8 + predictorPayload.length);
    predictorFile ~= cast(ubyte) (prRiff & 0xff);
    predictorFile ~= cast(ubyte) ((prRiff >> 8) & 0xff);
    predictorFile ~= cast(ubyte) ((prRiff >> 16) & 0xff);
    predictorFile ~= cast(ubyte) ((prRiff >> 24) & 0xff);
    predictorFile ~= cast(ubyte[]) "WEBP";
    predictorFile ~= cast(ubyte[]) "VP8L";
    const prSize = cast(uint) predictorPayload.length;
    predictorFile ~= cast(ubyte) (prSize & 0xff);
    predictorFile ~= cast(ubyte) ((prSize >> 8) & 0xff);
    predictorFile ~= cast(ubyte) ((prSize >> 16) & 0xff);
    predictorFile ~= cast(ubyte) ((prSize >> 24) & 0xff);
    predictorFile ~= predictorPayload;
    auto pr = decodeImage(predictorFile, "predictor webp");
    assert(pr.width() == 2 && pr.height() == 1,
        "predictor WebP dimensions wrong");
    const prp = pr.pixels();
    assert(prp[1] == 10 && prp[3] == 255,
        "predictor pixel 0 green should be 10");
    assert(prp[4 + 1] == 20 && prp[4 + 3] == 255,
        "predictor pixel 1 green should be 20 (left-predicted)");

    // A VP8L stream using the colour transform: element green_to_red = 32 and
    // stored pixel green = 32, so the inverse transform adds
    // ColorTransformDelta(32, 32) = (32*32)>>5 = 32 to red. Stored
    // (A=255,R=0,G=32,B=0) must reconstruct to (255,32,32,0).
    immutable ubyte[] colourPayload =
    [
        0x2F, 0x00, 0x00, 0x00, 0x10, 0x03, 0x05, 0x28, 0x40, 0x41, 0xFA,
        0x5F, 0x00, 0x14, 0xA4, 0x00, 0x05, 0xE8, 0x7F, 0x01, 0x00,
    ];
    ubyte[] colourFile;
    colourFile ~= cast(ubyte[]) "RIFF";
    const ctRiff = cast(uint) (4 + 8 + colourPayload.length);
    colourFile ~= cast(ubyte) (ctRiff & 0xff);
    colourFile ~= cast(ubyte) ((ctRiff >> 8) & 0xff);
    colourFile ~= cast(ubyte) ((ctRiff >> 16) & 0xff);
    colourFile ~= cast(ubyte) ((ctRiff >> 24) & 0xff);
    colourFile ~= cast(ubyte[]) "WEBP";
    colourFile ~= cast(ubyte[]) "VP8L";
    const ctSize = cast(uint) colourPayload.length;
    colourFile ~= cast(ubyte) (ctSize & 0xff);
    colourFile ~= cast(ubyte) ((ctSize >> 8) & 0xff);
    colourFile ~= cast(ubyte) ((ctSize >> 16) & 0xff);
    colourFile ~= cast(ubyte) ((ctSize >> 24) & 0xff);
    colourFile ~= colourPayload;
    auto ctr = decodeImage(colourFile, "colour webp");
    assert(ctr.width() == 1 && ctr.height() == 1,
        "colour WebP dimensions wrong");
    const ctp = ctr.pixels();
    assert(ctp[0] == 32 && ctp[1] == 32 && ctp[2] == 0 && ctp[3] == 255,
        "colour transform must add green_to_red*green to red");

    // A VP8L stream using the colour-indexing (palette) transform: a 2-entry
    // palette with width_bits = 3 packs eight pixel indices into one green
    // component, so a 1-pixel packed image expands to 8 pixels. This must
    // decode without overrunning the buffer and alternate the two palette
    // entries.
    immutable ubyte[] palettePayload =
    [
        0x2F, 0x07, 0x00, 0x00, 0x10, 0x0F, 0xA0, 0x00, 0xFF, 0x07, 0x38,
        0xC0, 0x7F, 0xFF, 0x0B, 0xC0, 0xA8, 0x6A, 0x01, 0x0A, 0xD0, 0xFF,
        0x02, 0x00,
    ];
    ubyte[] paletteFile;
    paletteFile ~= cast(ubyte[]) "RIFF";
    const plRiff = cast(uint) (4 + 8 + palettePayload.length);
    paletteFile ~= cast(ubyte) (plRiff & 0xff);
    paletteFile ~= cast(ubyte) ((plRiff >> 8) & 0xff);
    paletteFile ~= cast(ubyte) ((plRiff >> 16) & 0xff);
    paletteFile ~= cast(ubyte) ((plRiff >> 24) & 0xff);
    paletteFile ~= cast(ubyte[]) "WEBP";
    paletteFile ~= cast(ubyte[]) "VP8L";
    const plSize = cast(uint) palettePayload.length;
    paletteFile ~= cast(ubyte) (plSize & 0xff);
    paletteFile ~= cast(ubyte) ((plSize >> 8) & 0xff);
    paletteFile ~= cast(ubyte) ((plSize >> 16) & 0xff);
    paletteFile ~= cast(ubyte) ((plSize >> 24) & 0xff);
    paletteFile ~= palettePayload;
    auto pal = decodeImage(paletteFile, "palette webp");
    assert(pal.width() == 8 && pal.height() == 1,
        "colour-indexing must unpack eight bundled pixels");
    const palp = pal.pixels();
    // Indices 0,1,0,1,... alternate between the two palette entries. The
    // verified output alternates (255,0,0,255) and (255,0,255,254); the key
    // property is that unpacking produced eight distinct pixels without
    // overrunning the packed buffer.
    foreach (i; 0 .. 8)
    {
        const even = (i % 2) == 0;
        if (even)
            assert(palp[i * 4] == 255 && palp[i * 4 + 1] == 0 &&
                palp[i * 4 + 2] == 0,
                "even palette pixels must be the first palette entry");
        else
            assert(palp[i * 4] == 255 && palp[i * 4 + 2] == 255,
                "odd palette pixels must be the second palette entry");
    }

    // A VP8L stream using a meta-prefix entropy image with two prefix code
    // groups: prefix_bits = 2 over a 1x8 image gives a 1x2 entropy image whose
    // blocks select group 0 and group 1. This must decode without error.
    immutable ubyte[] metaPayload =
    [
        0x2F, 0x00, 0xC0, 0x01, 0x10, 0x04, 0x07, 0x08, 0x28, 0x40, 0x01,
        0xFA, 0x5F, 0x00, 0x41, 0x01, 0x0A, 0x50, 0x80, 0xFE, 0x17, 0xA0,
        0x02, 0x14, 0xA0, 0x00, 0xFD, 0x2F, 0x00,
    ];
    ubyte[] metaFile;
    metaFile ~= cast(ubyte[]) "RIFF";
    const mpRiff = cast(uint) (4 + 8 + metaPayload.length);
    metaFile ~= cast(ubyte) (mpRiff & 0xff);
    metaFile ~= cast(ubyte) ((mpRiff >> 8) & 0xff);
    metaFile ~= cast(ubyte) ((mpRiff >> 16) & 0xff);
    metaFile ~= cast(ubyte) ((mpRiff >> 24) & 0xff);
    metaFile ~= cast(ubyte[]) "WEBP";
    metaFile ~= cast(ubyte[]) "VP8L";
    const mpSize = cast(uint) metaPayload.length;
    metaFile ~= cast(ubyte) (mpSize & 0xff);
    metaFile ~= cast(ubyte) ((mpSize >> 8) & 0xff);
    metaFile ~= cast(ubyte) ((mpSize >> 16) & 0xff);
    metaFile ~= cast(ubyte) ((mpSize >> 24) & 0xff);
    metaFile ~= metaPayload;
    auto meta = decodeImage(metaFile, "meta-prefix webp");
    assert(meta.width() == 1 && meta.height() == 8,
        "meta-prefix WebP must decode with the entropy image applied");
    assert(meta.pixels()[3] == 255, "meta-prefix pixels must be opaque");

    // A lossy (VP8) payload is rejected naming the chunk it used.
    immutable ubyte[] lossy =
    [
        0x52, 0x49, 0x46, 0x46, 0x0A, 0x00, 0x00, 0x00,
        0x57, 0x45, 0x42, 0x50,
        0x56, 0x50, 0x38, 0x20, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00,
    ];
    bool threw;
    try decodeImage(lossy, "lossy webp");
    catch (Exception e) threw = e.msg.indexOf("VP8L") >= 0;
    assert(threw, "a lossy WebP must report that only VP8L is supported");
}
