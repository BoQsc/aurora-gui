module auroraimageviewer.decoder;

import aurora.image : decodePngImage;
import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.exception : enforce;
import std.file : read;
import std.path : extension;
import std.string : toLower;

/**
 * Standalone image decoding for Aurora Image Viewer.
 *
 * No external programs are required: PNG uses Aurora's built-in decoder, and
 * BMP, TGA, PNM (P2/P3/P5/P6/P7) and GIF (first frame) are decoded entirely
 * inside this process from raw bytes.
 */
struct DecodedImage
{
    int width;
    int height;
    ubyte[] rgba;
    bool hasAlpha;
    string format;
}

private enum size_t maximumPixels = 134_217_728;
private enum int maximumDimension = 65536;

DecodedImage decodeImageFile(string path)
{
    enforce(path.length > 0, "No image path was given.");
    const data = cast(const(ubyte)[]) read(path);
    return decodeImageBytes(data, path);
}

DecodedImage decodeImageBytes(const(ubyte)[] bytes, string label)
{
    enforce(bytes.length > 0, label ~ " is empty.");
    if (isPng(bytes))
        return decodePng(bytes, label);
    if (isBmp(bytes))
        return decodeBmp(bytes, label);
    if (isGif(bytes))
        return decodeGif(bytes, label);
    if (isPnm(bytes))
        return decodePnm(bytes, label);
    if (extension(label).toLower() == ".tga")
        return decodeTga(bytes, label);
    throw new Exception("Unsupported image format: " ~ label);
}

private void enforceDimensions(int width, int height, string label)
{
    enforce(width > 0 && height > 0, label ~ " has invalid dimensions.");
    enforce(width <= maximumDimension && height <= maximumDimension,
        label ~ " is too large (" ~ to!string(width) ~ "x" ~ to!string(height) ~ ").");
    enforce(cast(size_t) width * cast(size_t) height <= maximumPixels,
        label ~ " has too many pixels.");
}

private void putPixel(ref ubyte[] rgba, size_t index, uint r, uint g, uint b,
    uint a)
{
    const offset = index * 4;
    rgba[offset] = cast(ubyte) (r & 0xffu);
    rgba[offset + 1] = cast(ubyte) (g & 0xffu);
    rgba[offset + 2] = cast(ubyte) (b & 0xffu);
    rgba[offset + 3] = cast(ubyte) (a & 0xffu);
}

private bool isPng(const(ubyte)[] bytes)
{
    immutable ubyte[8] signature = [137, 80, 78, 71, 13, 10, 26, 10];
    return bytes.length >= signature.length && bytes[0 .. signature.length] == signature[];
}

private DecodedImage decodePng(const(ubyte)[] bytes, string label)
{
    if (bytes.length >= 8 + 16)
    {
        const width = (cast(uint) bytes[16] << 24) |
            (cast(uint) bytes[17] << 16) |
            (cast(uint) bytes[18] << 8) |
            cast(uint) bytes[19];
        const height = (cast(uint) bytes[20] << 24) |
            (cast(uint) bytes[21] << 16) |
            (cast(uint) bytes[22] << 8) |
            cast(uint) bytes[23];
        enforceDimensions(cast(int) width, cast(int) height, label);
    }
    auto image = decodePngImage(bytes, label);
    const pixels = image.pixels();
    bool alpha;
    for (size_t offset = 3; offset < pixels.length; offset += 4)
    {
        if (pixels[offset] != 255)
        {
            alpha = true;
            break;
        }
    }
    DecodedImage result;
    result.width = image.width();
    result.height = image.height();
    result.rgba = pixels.dup;
    result.hasAlpha = alpha;
    result.format = "PNG";
    return result;
}

// ---------------------------------------------------------------------------
// BMP
// ---------------------------------------------------------------------------

private bool isBmp(const(ubyte)[] bytes)
{
    return bytes.length >= 2 && bytes[0] == 'B' && bytes[1] == 'M';
}

private enum uint bmpRgb = 0;
private enum uint bmpRle8 = 1;
private enum uint bmpRle4 = 2;
private enum uint bmpBitfields = 3;
private enum uint bmpAlphaBitfields = 6;

private DecodedImage decodeBmp(const(ubyte)[] bytes, string label)
{
    enforce(bytes.length >= 26, label ~ " is truncated.");
    const pixelOffset = cast(size_t) readU32(bytes, 10);
    enforce(pixelOffset <= bytes.length, label ~ " has an invalid pixel offset.");
    const headerSize = readU32(bytes, 14);

    int width;
    int height;
    uint bitCount;
    uint compression = bmpRgb;
    uint colorUsed;

    if (headerSize == 12)
    {
        enforce(bytes.length >= 26, label ~ " has a truncated core header.");
        width = readU16(bytes, 18);
        height = readU16(bytes, 20);
        bitCount = readU16(bytes, 24);
    }
    else
    {
        enforce(headerSize >= 40 && headerSize <= bytes.length,
            label ~ " has an unsupported bitmap header.");
        width = readI32(bytes, 18);
        height = readI32(bytes, 22);
        bitCount = readU16(bytes, 28);
        compression = readU32(bytes, 30);
        colorUsed = readU32(bytes, 46);
        const bool allowedCompression = compression == bmpRgb ||
            compression == bmpRle8 || compression == bmpRle4 ||
            compression == bmpBitfields || compression == bmpAlphaBitfields;
        enforce(allowedCompression,
            label ~ " uses unsupported compression " ~ to!string(compression));
    }

    enforce(bitCount == 1 || bitCount == 4 || bitCount == 8 ||
            bitCount == 16 || bitCount == 24 || bitCount == 32,
        label ~ " uses unsupported bit depth " ~ to!string(bitCount));
    const topDown = height < 0;
    if (height < 0) height = -height;
    enforceDimensions(width, height, label);

    uint maskR;
    uint maskG;
    uint maskB;
    uint maskA;
    if (headerSize >= 40 && (compression == bmpBitfields ||
        compression == bmpAlphaBitfields))
    {
        maskR = readU32(bytes, 54);
        maskG = readU32(bytes, 58);
        maskB = readU32(bytes, 62);
        maskA = compression == bmpAlphaBitfields ? readU32(bytes, 66) : 0;
    }

    size_t colorTableOffset = 14 + headerSize;
    uint paletteEntries;
    if (bitCount <= 8)
    {
        paletteEntries = colorUsed > 0 ? colorUsed : (1u << bitCount);
        const paletteEntrySize = headerSize == 12 ? 3 : 4;
        enforce(colorTableOffset + cast(size_t) paletteEntries * paletteEntrySize <=
            bytes.length, label ~ " has a truncated color table.");
    }

    DecodedImage result;
    result.width = width;
    result.height = height;
    result.rgba.length = cast(size_t) width * cast(size_t) height * 4;

    const rowBytes = ((cast(size_t) width * bitCount + 31) / 32) * 4;
    enforce(pixelOffset + cast(size_t) rowBytes * cast(size_t) height <= bytes.length,
        label ~ " pixel data is truncated.");

    if (compression == bmpRle8 && bitCount == 8)
        decodeBmpRle(bytes, result, pixelOffset, width, height, topDown, true,
            colorTableOffset, paletteEntries, headerSize == 12, label);
    else if (compression == bmpRle4 && bitCount == 4)
        decodeBmpRle(bytes, result, pixelOffset, width, height, topDown, false,
            colorTableOffset, paletteEntries, headerSize == 12, label);
    else
        decodeBmpPixels(bytes, result, pixelOffset, width, height, topDown, bitCount,
            compression, maskR, maskG, maskB, maskA, colorTableOffset,
            paletteEntries, headerSize == 12, label);

    result.hasAlpha = scanAlpha(result.rgba);
    result.format = "BMP";
    return result;
}

private void decodeBmpPixels(const(ubyte)[] bytes, ref DecodedImage result,
    size_t pixelOffset, int width, int height, bool topDown, uint bitCount,
    uint compression, uint maskR, uint maskG, uint maskB, uint maskA,
    size_t colorTableOffset, uint paletteEntries, bool coreHeader, string label)
{
    const rowBytes = ((cast(size_t) width * bitCount + 31) / 32) * 4;
    foreach (rowIndex; 0 .. height)
    {
        const y = topDown ? rowIndex : height - 1 - rowIndex;
        const rowStart = pixelOffset + cast(size_t) rowIndex * rowBytes;
        foreach (x; 0 .. width)
        {
            uint index;
            uint r;
            uint g;
            uint b;
            uint a = 255;
            if (bitCount == 1)
            {
                const packedByte = bytes[rowStart + cast(size_t) (x / 8)];
                index = (packedByte >> (7 - x % 8)) & 1u;
            }
            else if (bitCount == 4)
            {
                const packedByte = bytes[rowStart + cast(size_t) (x / 2)];
                index = (x % 2 == 0) ? ((packedByte >> 4) & 0x0fu) : (packedByte & 0x0fu);
            }
            else if (bitCount == 8)
            {
                index = bytes[rowStart + cast(size_t) x];
            }
            else if (bitCount == 16)
            {
                const value = readU16(bytes, rowStart + cast(size_t) x * 2);
                if (compression == bmpBitfields)
                {
                    r = scaleMask(value, maskR);
                    g = scaleMask(value, maskG);
                    b = scaleMask(value, maskB);
                    a = maskA != 0 ? scaleMask(value, maskA) : 255;
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
                    if (!coreHeader)
                        a = bytes[entry + 3];
                }
                else
                    a = 0;
            }
            putPixel(result.rgba, cast(size_t) y * cast(size_t) width + cast(size_t) x,
                r, g, b, a);
        }
    }
}

private void decodeBmpRle(const(ubyte)[] bytes, ref DecodedImage result,
    size_t offset, int width, int height, bool topDown, bool eightBit,
    size_t colorTableOffset, uint paletteEntries, bool coreHeader, string label)
{
    const end = bytes.length;
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
                foreach (_; 0 .. escape)
                {
                    if (offset >= end) break;
                    uint index;
                    if (eightBit)
                        index = bytes[offset++];
                    else
                    {
                        const value = bytes[offset];
                        index = ((escape % 2 == 0 && _ % 2 == 0) ||
                                (escape % 2 == 1 && _ % 2 == 0)) ?
                            ((value >> 4) & 0x0fu) : (value & 0x0fu);
                        if ((_ % 2) == 1) ++offset;
                    }
                    bmpRlePixel(bytes, result, x++, y, width, height, topDown,
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
                    bmpRlePixel(bytes, result, x++, y, width, height, topDown,
                        index, colorTableOffset, paletteEntries, coreHeader);
            }
            else
            {
                const value = bytes[offset++];
                foreach (_; 0 .. count)
                {
                    const index = (_ % 2 == 0) ? ((value >> 4) & 0x0fu) :
                        (value & 0x0fu);
                    bmpRlePixel(bytes, result, x++, y, width, height, topDown,
                        index, colorTableOffset, paletteEntries, coreHeader);
                }
            }
        }
    }
}

private void bmpRlePixel(const(ubyte)[] bytes, ref DecodedImage result, int x,
    int y, int width, int height, bool topDown, uint index,
    size_t colorTableOffset, uint paletteEntries, bool coreHeader)
{
    if (x < 0 || x >= width || y < 0 || y >= height) return;
    uint r;
    uint g;
    uint b;
    uint a = 255;
    if (index < paletteEntries)
    {
        const entry = colorTableOffset + cast(size_t) index * (coreHeader ? 3 : 4);
        b = bytes[entry];
        g = bytes[entry + 1];
        r = bytes[entry + 2];
        if (!coreHeader)
            a = bytes[entry + 3];
    }
    else
        a = 0;
    const row = topDown ? y : height - 1 - y;
    putPixel(result.rgba, cast(size_t) row * cast(size_t) width + cast(size_t) x,
        r, g, b, a);
}

private uint scaleMask(uint value, uint mask)
{
    if (mask == 0) return 0;
    const shift = trailingZeroes(mask);
    const bits = bitCount(mask);
    const maxValue = (1u << bits) - 1u;
    const scaled = (value & mask) >> shift;
    return maxValue == 0 ? 0 : (scaled * 255u + maxValue / 2u) / maxValue;
}

private uint trailingZeroes(uint value) @safe pure nothrow @nogc
{
    uint count = 0;
    while ((value & 1u) == 0 && value != 0)
    {
        value >>= 1;
        ++count;
    }
    return count;
}

private uint bitCount(uint value) @safe pure nothrow @nogc
{
    uint count = 0;
    while (value != 0)
    {
        count += value & 1u;
        value >>= 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// TGA
// ---------------------------------------------------------------------------

private enum uint tgaColorMapped = 1;
private enum uint tgaTrueColor = 2;
private enum uint tgaGrayScale = 3;
private enum uint tgaRleColorMapped = 9;
private enum uint tgaRleTrueColor = 10;
private enum uint tgaRleGrayScale = 11;

private DecodedImage decodeTga(const(ubyte)[] bytes, string label)
{
    enforce(bytes.length >= 18, label ~ " is truncated.");
    const idLength = bytes[0];
    const colorMapType = bytes[1];
    const imageType = bytes[2];
    const colorMapOrigin = readU16(bytes, 3);
    const colorMapLength = readU16(bytes, 5);
    const colorMapDepth = bytes[7];
    const width = readU16(bytes, 12);
    const height = readU16(bytes, 14);
    const depth = bytes[16];
    const descriptor = bytes[17];
    const topDown = (descriptor & 0x20u) != 0;

    enforce(colorMapType == 0 || colorMapType == 1,
        label ~ " has an invalid color map type.");
    enforceDimensions(width, height, label);
    const bool trueColor = imageType == tgaTrueColor || imageType == tgaRleTrueColor;
    const bool grayScale = imageType == tgaGrayScale || imageType == tgaRleGrayScale;
    const bool colorMapped = imageType == tgaColorMapped ||
        imageType == tgaRleColorMapped;
    enforce(trueColor || grayScale || colorMapped,
        label ~ " uses unsupported TGA image type " ~ to!string(imageType));

    const size_t colorMapBytes = colorMapType == 1 ?
        cast(size_t) colorMapLength * ((colorMapDepth + 7) / 8) : 0;
    const size_t colorMapStart = 18 + idLength;
    size_t offset = 18 + idLength + colorMapBytes;
    enforce(offset <= bytes.length, label ~ " pixel data is missing.");

    const bool rle = imageType == tgaRleColorMapped ||
        imageType == tgaRleTrueColor || imageType == tgaRleGrayScale;

    DecodedImage result;
    result.width = width;
    result.height = height;
    result.rgba.length = cast(size_t) width * cast(size_t) height * 4;

    const size_t total = cast(size_t) width * cast(size_t) height;
    size_t target = 0;
    while (target < total)
    {
        uint count = 1;
        bool replicate;
        if (rle)
        {
            enforce(offset < bytes.length, label ~ " RLE data is truncated.");
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
                writeTgaPixel(result, target, width, height, topDown, pixel);
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
                writeTgaPixel(result, target, width, height, topDown, pixel);
                ++target;
            }
        }
    }

    result.hasAlpha = scanAlpha(result.rgba);
    result.format = "TGA";
    return result;
}

private uint tgaReadPixel(const(ubyte)[] bytes, ref size_t offset, bool trueColor,
    bool grayScale, bool colorMapped, uint depth, size_t colorMapStart,
    uint colorMapOrigin, uint colorMapDepth, uint colorMapLength, string label)
{
    uint r = 0;
    uint g = 0;
    uint b = 0;
    uint a = 255;

    if (trueColor)
    {
        if (depth == 32)
        {
            enforce(offset + 3 < bytes.length, label ~ " pixel data is truncated.");
            b = bytes[offset];
            g = bytes[offset + 1];
            r = bytes[offset + 2];
            a = bytes[offset + 3];
            offset += 4;
        }
        else if (depth == 24)
        {
            enforce(offset + 2 < bytes.length, label ~ " pixel data is truncated.");
            b = bytes[offset];
            g = bytes[offset + 1];
            r = bytes[offset + 2];
            offset += 3;
        }
        else if (depth == 16)
        {
            enforce(offset + 1 < bytes.length, label ~ " pixel data is truncated.");
            const value = cast(uint) bytes[offset] |
                (cast(uint) bytes[offset + 1] << 8);
            offset += 2;
            r = ((value >> 10) & 0x1fu) * 255u / 31u;
            g = ((value >> 5) & 0x1fu) * 255u / 31u;
            b = (value & 0x1fu) * 255u / 31u;
            a = (value & 0x8000u) != 0 ? 255 : 0;
        }
        else
            throw new Exception("Unsupported TGA truecolor depth " ~ to!string(depth));
    }
    else if (grayScale)
    {
        enforce(offset < bytes.length, label ~ " pixel data is truncated.");
        const value = bytes[offset++];
        r = value;
        g = value;
        b = value;
        if (depth == 16 && offset < bytes.length)
        {
            const alphaByte = bytes[offset++];
            a = alphaByte == 0 ? 0 : 255;
        }
    }
    else if (colorMapped)
    {
        enforce(offset < bytes.length, label ~ " pixel data is truncated.");
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

private void writeTgaPixel(ref DecodedImage result, size_t target, int width,
    int height, bool topDown, uint pixel)
{
    const y = topDown ? cast(int) (target / width) :
        height - 1 - cast(int) (target / width);
    const x = cast(int) (target % cast(size_t) width);
    putPixel(result.rgba, cast(size_t) y * cast(size_t) width + cast(size_t) x,
        (pixel >> 24) & 0xffu, (pixel >> 16) & 0xffu, (pixel >> 8) & 0xffu,
        pixel & 0xffu);
}

// ---------------------------------------------------------------------------
// PNM (P2/P3/P5/P6/P7)
// ---------------------------------------------------------------------------

private bool isPnm(const(ubyte)[] bytes)
{
    if (bytes.length < 2) return false;
    if (bytes[0] != 'P') return false;
    const magic = bytes[1];
    return magic == '2' || magic == '3' || magic == '5' || magic == '6' ||
        magic == '7';
}

private struct PnmTokens
{
    const(ubyte)[] bytes;
    size_t offset;
    bool failed;

    void skipWhitespace()
    {
        while (offset < bytes.length)
        {
            if (bytes[offset] == '#')
            {
                while (offset < bytes.length && bytes[offset] != '\n')
                    ++offset;
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

    uint nextNumber()
    {
        skipWhitespace();
        uint value = 0;
        bool seen;
        while (offset < bytes.length &&
            bytes[offset] >= '0' && bytes[offset] <= '9')
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
        while (offset < bytes.length &&
            bytes[offset] != ' ' && bytes[offset] != '\t' &&
            bytes[offset] != '\r' && bytes[offset] != '\n')
            ++offset;
        return cast(string) bytes[start .. offset];
    }
}

private DecodedImage decodePnm(const(ubyte)[] bytes, string label)
{
    const magic = bytes[1];
    PnmTokens tokens;
    tokens.bytes = bytes;
    tokens.offset = 0;

    int width;
    int height;
    uint maxValue;
    uint channels;
    bool ascii;
    bool isPam = magic == '7';

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
        }
        if (channels == 0) channels = 3;
    }
    else
    {
        ascii = magic == '2' || magic == '3';
        channels = (magic == '2' || magic == '5') ? 1 : 3;
        tokens.nextToken();
        width = cast(int) tokens.nextNumber();
        height = cast(int) tokens.nextNumber();
        maxValue = tokens.nextNumber();
        enforce(!tokens.failed, label ~ " has a malformed PNM header.");
    }

    enforce(!tokens.failed && width > 0 && height > 0 && maxValue > 0,
        label ~ " has a malformed PNM header.");
    enforceDimensions(width, height, label);
    enforce(maxValue <= 65535, label ~ " has an unsupported max value.");
    enforce(channels == 1 || channels == 3 || channels == 4,
        label ~ " uses an unsupported sample depth.");

    DecodedImage result;
    result.width = width;
    result.height = height;
    result.rgba.length = cast(size_t) width * cast(size_t) height * 4;
    result.hasAlpha = channels == 4;
    result.format = isPam ? "PAM" : "PNM";

    tokens.skipWhitespace();
    const bool sixteenBit = maxValue > 255;
    foreach (index; 0 .. cast(size_t) width * cast(size_t) height)
    {
        uint r;
        uint g;
        uint b;
        uint a = 255;
        if (ascii)
        {
            r = tokens.nextNumber();
            if (channels == 3)
            {
                g = tokens.nextNumber();
                b = tokens.nextNumber();
            }
            else if (channels == 4)
            {
                g = tokens.nextNumber();
                b = tokens.nextNumber();
                a = tokens.nextNumber();
            }
            else
                g = b = r;
        }
        else if (sixteenBit)
        {
            uint readSample()
            {
                enforce(tokens.offset + 2 <= bytes.length,
                    label ~ " is truncated.");
                const value = (cast(uint) bytes[tokens.offset] << 8) |
                    cast(uint) bytes[tokens.offset + 1];
                tokens.offset += 2;
                return value;
            }
            r = readSample();
            if (channels == 3)
            {
                g = readSample();
                b = readSample();
            }
            else if (channels == 4)
            {
                g = readSample();
                b = readSample();
                a = readSample();
            }
            else
                g = b = r;
        }
        else
        {
            enforce(tokens.offset + channels <= bytes.length,
                label ~ " is truncated.");
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
                g = r;
                b = r;
                ++tokens.offset;
            }
        }
        r = (r * 255u + maxValue / 2u) / maxValue;
        g = (g * 255u + maxValue / 2u) / maxValue;
        b = (b * 255u + maxValue / 2u) / maxValue;
        a = (a * 255u + maxValue / 2u) / maxValue;
        putPixel(result.rgba, index, r, g, b, a);
    }
    return result;
}

// ---------------------------------------------------------------------------
// GIF (first frame)
// ---------------------------------------------------------------------------

private bool isGif(const(ubyte)[] bytes)
{
    return bytes.length >= 6 && bytes[0] == 'G' && bytes[1] == 'I' &&
        bytes[2] == 'F' && bytes[3] == '8' &&
        (bytes[4] == '7' || bytes[4] == '9') && bytes[5] == 'a';
}

private DecodedImage decodeGif(const(ubyte)[] bytes, string label)
{
    enforce(bytes.length >= 13, label ~ " is truncated.");
    const width = readU16(bytes, 6);
    const height = readU16(bytes, 8);
    enforceDimensions(width, height, label);
    const packed = bytes[10];
    const bool globalColorTable = (packed & 0x80u) != 0;
    const uint globalTableSize = globalColorTable ?
        (1u << ((packed & 0x07u) + 1u)) : 0u;

    size_t offset = 13;
    enforce(offset + cast(size_t) globalTableSize * 3 <= bytes.length,
        label ~ " has a truncated global color table.");
    const ubyte[] globalPalette = globalColorTable ?
        bytes[13 .. 13 + cast(size_t) globalTableSize * 3] : null;
    offset += cast(size_t) globalTableSize * 3;

    bool hasTransparency;
    int transparentIndex = -1;

    while (offset < bytes.length)
    {
        const marker = bytes[offset++];
        if (marker == 0x3b) break;
        if (marker == 0x21)
        {
            if (offset >= bytes.length) break;
            const extension = bytes[offset++];
            if (extension == 0xf9)
            {
                if (offset + 6 <= bytes.length)
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
            else
                skipGifSubBlocks(bytes, offset);
        }
        else if (marker == 0x2c)
        {
            enforce(offset + 9 <= bytes.length, label ~ " is truncated.");
            const frameWidth = readU16(bytes, offset + 4);
            const frameHeight = readU16(bytes, offset + 6);
            const imagePacked = bytes[offset + 8];
            const bool interlaced = (imagePacked & 0x40u) != 0;
            offset += 9;
            const bool localTable = (imagePacked & 0x80u) != 0;
            const uint localSize = localTable ?
                (1u << ((imagePacked & 0x07u) + 1u)) : 0u;
            enforce(offset + cast(size_t) localSize * 3 <= bytes.length,
                label ~ " has a truncated local color table.");
            const ubyte[] localPalette = localTable ?
                bytes[offset .. offset + cast(size_t) localSize * 3] : null;
            offset += cast(size_t) localSize * 3;

            enforceDimensions(cast(int) frameWidth, cast(int) frameHeight, label);
            const size_t pixelCount = cast(size_t) frameWidth * cast(size_t) frameHeight;

            if (offset >= bytes.length) break;
            const int minCodeSize = bytes[offset++];
            ubyte[] lzwData;
            while (offset < bytes.length)
            {
                const blockSize = bytes[offset++];
                if (blockSize == 0) break;
                enforce(offset + blockSize <= bytes.length,
                    label ~ " has a truncated LZW block.");
                lzwData ~= bytes[offset .. offset + blockSize];
                offset += blockSize;
            }

            const ubyte[] framePalette = localPalette !is null ? localPalette :
                globalPalette;
            const uint paletteSize = cast(uint) (framePalette.length / 3);

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
                        linear[cast(size_t) y * frameWidth .. (cast(size_t) y + 1) * frameWidth] =
                            indices[source .. source + frameWidth];
                        source += frameWidth;
                    }
                }
                interlacePass(0, 8);
                interlacePass(4, 8);
                interlacePass(2, 4);
                interlacePass(1, 2);
            }

            DecodedImage result;
            result.width = cast(int) frameWidth;
            result.height = cast(int) frameHeight;
            result.rgba.length = pixelCount * 4;
            result.hasAlpha = hasTransparency;
            result.format = "GIF";
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
                    r = framePalette[entry];
                    g = framePalette[entry + 1];
                    b = framePalette[entry + 2];
                }
                else
                    a = 0;
                putPixel(result.rgba, index, r, g, b, a);
            }
            return result;
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
        const code = readBits(data, bitPosition, codeSize);
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
            length = expandEntry(entryCode, prefix, suffix, scratch, 0);
        else if (entryCode == available && previous >= 0)
        {
            length = expandEntry(previous, prefix, suffix, scratch, 0);
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

private size_t expandEntry(int code, const(uint)[] prefix, const(ubyte)[] suffix,
    ubyte[] scratch, size_t at)
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

private uint readBits(const(ubyte)[] data, size_t bitPosition, int count)
{
    uint result = 0;
    foreach (index; 0 .. count)
    {
        const byteIndex = (bitPosition + index) >> 3;
        if (byteIndex >= data.length) break;
        const bit = (data[byteIndex] >> ((bitPosition + index) & 7)) & 1u;
        result |= bit << index;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Common helpers
// ---------------------------------------------------------------------------

private uint readU16(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 2 <= bytes.length, "Unexpected end of image data.");
    return cast(uint) bytes[offset] | (cast(uint) bytes[offset + 1] << 8);
}

private uint readU32(const(ubyte)[] bytes, size_t offset)
{
    enforce(offset + 4 <= bytes.length, "Unexpected end of image data.");
    return cast(uint) bytes[offset] |
        (cast(uint) bytes[offset + 1] << 8) |
        (cast(uint) bytes[offset + 2] << 16) |
        (cast(uint) bytes[offset + 3] << 24);
}

private int readI32(const(ubyte)[] bytes, size_t offset)
{
    return cast(int) readU32(bytes, offset);
}

private bool scanAlpha(const(ubyte)[] rgba)
{
    for (size_t offset = 3; offset < rgba.length; offset += 4)
    {
        if (rgba[offset] != 255)
            return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Background decode worker
// ---------------------------------------------------------------------------

/**
 * Single persistent worker that decodes image files off the UI thread.
 *
 * Each requested path replaces the pending one; the latest finished decode is
 * handed back to the caller on the next takeResult().
 */
final class ImageLoader
{
    private Mutex _mutex;
    private Condition _condition;
    private Thread _worker;
    private bool _shutdown;
    private string _pendingPath;
    private bool _hasPending;
    private string _resultPath;
    private DecodedImage _resultImage;
    private string _resultError;
    private bool _hasResult;

    this()
    {
        _mutex = new Mutex();
        _condition = new Condition(_mutex);
        _worker = new Thread(&workerLoop);
        _worker.isDaemon = true;
        _worker.start();
    }

    void request(string path)
    {
        _mutex.lock();
        _pendingPath = path;
        _hasPending = true;
        _condition.notify();
        _mutex.unlock();
    }

    bool takeResult(out string path, out DecodedImage image, out string error)
    {
        _mutex.lock();
        scope (exit) _mutex.unlock();
        if (!_hasResult) return false;
        path = _resultPath;
        image = _resultImage;
        error = _resultError;
        _hasResult = false;
        return true;
    }

    void shutdown()
    {
        _mutex.lock();
        _shutdown = true;
        _condition.notifyAll();
        _mutex.unlock();
        if (_worker !is null)
        {
            try { _worker.join(); }
            catch (Exception) {}
        }
    }

    private void workerLoop()
    {
        while (true)
        {
            string path;
            _mutex.lock();
            while (!_shutdown && !_hasPending)
                _condition.wait();
            if (_shutdown)
            {
                _mutex.unlock();
                break;
            }
            path = _pendingPath;
            _hasPending = false;
            _mutex.unlock();

            DecodedImage image;
            string error;
            try
                image = decodeImageFile(path);
            catch (Exception exception)
                error = exception.msg;

            _mutex.lock();
            _resultPath = path;
            _resultImage = image;
            _resultError = error;
            _hasResult = true;
            _mutex.unlock();
        }
    }
}

