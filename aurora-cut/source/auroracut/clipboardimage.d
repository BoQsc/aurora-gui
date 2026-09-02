module auroracut.clipboardimage;

import auroracut.util : absoluteNormalized, appLog, applicationStateDirectory,
    ensureParentDirectory;
import std.file : exists, mkdirRecurse, write;
import std.path : buildPath;
import std.uuid : randomUUID;

version (Windows)
{
    import core.sys.windows.winbase : GlobalLock, GlobalSize, GlobalUnlock;
    import core.sys.windows.winuser : CF_DIB, CF_DIBV5, CloseClipboard,
        GetClipboardData, GetClipboardSequenceNumber, IsClipboardFormatAvailable,
        OpenClipboard;
}

private enum uint bitmapCompressionBitfields = 3;
private enum uint bitmapCompressionAlphaBitfields = 6;
private enum size_t bitmapFileHeaderSize = 14;

private bool delegate() _testClipboardImageAvailable;
private string delegate() _testClipboardImageSaver;
private ulong delegate() _testClipboardSequence;

void setClipboardImageProviderForTesting(bool delegate() available,
    string delegate() saver, ulong delegate() sequence)
{
    _testClipboardImageAvailable = available;
    _testClipboardImageSaver = saver;
    _testClipboardSequence = sequence;
}

private string pastedScreenshotsDirectory()
{
    const directory = absoluteNormalized(buildPath(applicationStateDirectory(),
        "Pasted Screenshots"));
    if (!exists(directory)) mkdirRecurse(directory);
    return directory;
}

private uint readUInt16LE(const(ubyte)[] data, size_t offset)
{
    if (offset + 2 > data.length)
        throw new Exception("Clipboard DIB is truncated.");
    return cast(uint) data[offset] | (cast(uint) data[offset + 1] << 8);
}

private uint readUInt32LE(const(ubyte)[] data, size_t offset)
{
    if (offset + 4 > data.length)
        throw new Exception("Clipboard DIB is truncated.");
    return cast(uint) data[offset] |
        (cast(uint) data[offset + 1] << 8) |
        (cast(uint) data[offset + 2] << 16) |
        (cast(uint) data[offset + 3] << 24);
}

private void appendUInt16LE(ref ubyte[] data, uint value)
{
    data ~= cast(ubyte) (value & 0xff);
    data ~= cast(ubyte) ((value >> 8) & 0xff);
}

private void appendUInt32LE(ref ubyte[] data, uint value)
{
    data ~= cast(ubyte) (value & 0xff);
    data ~= cast(ubyte) ((value >> 8) & 0xff);
    data ~= cast(ubyte) ((value >> 16) & 0xff);
    data ~= cast(ubyte) ((value >> 24) & 0xff);
}

private size_t dibPixelOffset(const(ubyte)[] dib)
{
    if (dib.length < 4)
        throw new Exception("Clipboard DIB is missing its bitmap header.");

    const headerSize = readUInt32LE(dib, 0);
    if (headerSize == 12)
    {
        if (dib.length < 12)
            throw new Exception("Clipboard DIB core header is truncated.");
        const bitCount = readUInt16LE(dib, 10);
        const paletteEntries = bitCount <= 8 ? (1u << bitCount) : 0u;
        return headerSize + cast(size_t) paletteEntries * 3;
    }

    if (headerSize < 40 || headerSize > dib.length)
        throw new Exception("Clipboard DIB has an unsupported bitmap header.");

    const bitCount = readUInt16LE(dib, 14);
    const compression = readUInt32LE(dib, 16);
    const colorUsed = readUInt32LE(dib, 32);
    const paletteEntries = bitCount <= 8
        ? (colorUsed > 0 ? colorUsed : (1u << bitCount))
        : colorUsed;
    const masksBytes = headerSize == 40 &&
        compression == bitmapCompressionBitfields ? 12 :
        headerSize == 40 && compression == bitmapCompressionAlphaBitfields ? 16 : 0;
    return headerSize + masksBytes + cast(size_t) paletteEntries * 4;
}

void writeDibAsBmpFile(string path, const(ubyte)[] dib)
{
    if (dib.length == 0)
        throw new Exception("Clipboard image data is empty.");
    const pixelOffset = dibPixelOffset(dib);
    if (pixelOffset > dib.length)
        throw new Exception("Clipboard DIB pixel data is truncated.");

    const totalSize = bitmapFileHeaderSize + dib.length;
    if (totalSize > uint.max)
        throw new Exception("Clipboard image is too large to save as BMP.");

    ubyte[] output;
    output.reserve(totalSize);
    output ~= cast(ubyte) 'B';
    output ~= cast(ubyte) 'M';
    appendUInt32LE(output, cast(uint) totalSize);
    appendUInt16LE(output, 0);
    appendUInt16LE(output, 0);
    appendUInt32LE(output, cast(uint) (bitmapFileHeaderSize + pixelOffset));
    output ~= dib;

    ensureParentDirectory(path);
    write(path, output);
}

bool clipboardImageAvailable()
{
    if (_testClipboardImageAvailable !is null)
        return _testClipboardImageAvailable();
    version (Windows)
        return IsClipboardFormatAvailable(CF_DIBV5) ||
            IsClipboardFormatAvailable(CF_DIB);
    else
        return false;
}

ulong clipboardSequenceNumber()
{
    if (_testClipboardSequence !is null)
        return _testClipboardSequence();
    version (Windows)
        return cast(ulong) GetClipboardSequenceNumber();
    else
        return 0;
}

string saveClipboardImageAsBmp()
{
    if (_testClipboardImageSaver !is null)
        return _testClipboardImageSaver();

    version (Windows)
    {
        const format = IsClipboardFormatAvailable(CF_DIBV5) ? CF_DIBV5 :
            (IsClipboardFormatAvailable(CF_DIB) ? CF_DIB : 0);
        if (format == 0) return "";
        if (!OpenClipboard(null))
            throw new Exception("The Windows clipboard could not be opened.");
        scope (exit) CloseClipboard();

        auto memory = GetClipboardData(format);
        if (memory is null)
            throw new Exception("The Windows clipboard image could not be read.");
        const size = cast(size_t) GlobalSize(memory);
        if (size == 0)
            throw new Exception("The Windows clipboard image is empty.");
        auto source = cast(const(ubyte)*) GlobalLock(memory);
        if (source is null)
            throw new Exception("The Windows clipboard image could not be locked.");
        scope (exit) GlobalUnlock(memory);

        const dib = source[0 .. size].dup;
        const path = buildPath(pastedScreenshotsDirectory(),
            "pasted-screenshot-" ~ randomUUID().toString() ~ ".bmp");
        writeDibAsBmpFile(path, dib);
        return path;
    }
    else
    {
        appLog("Clipboard image paste is not implemented on this platform.");
        return "";
    }
}
