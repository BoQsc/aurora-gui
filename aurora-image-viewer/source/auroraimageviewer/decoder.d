module auroraimageviewer.decoder;

import aurora.image : ImageFormat, RgbaImage, decodeImage, decodeTgaImage,
    imageFormatName, sniffImageFormat;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import std.conv : to;
import std.exception : enforce;
import std.file : read;
import std.path : extension;
import std.string : toLower, toUpper;

/**
 * Image decoding for Aurora Image Viewer.
 *
 * The actual format work lives in the shared `aurora.image` module
 * (`decodeImage` + `sniffImageFormat`), which now owns PNG, ICO, GIF, BMP,
 * TGA, PNM/PAM and baseline JPEG for the whole repository. This module keeps
 * only the viewer's own facade (`DecodedImage`) and its off-UI-thread worker,
 * so no format implementation is duplicated here.
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

private void enforceDimensions(int width, int height, string label)
{
    enforce(width > 0 && height > 0, label ~ " has invalid dimensions.");
    enforce(width <= maximumDimension && height <= maximumDimension,
        label ~ " is too large (" ~ to!string(width) ~ "x" ~
        to!string(height) ~ ").");
    enforce(cast(size_t) width * cast(size_t) height <= maximumPixels,
        label ~ " has too many pixels.");
}

private bool scanAlpha(const(ubyte)[] rgba)
{
    for (size_t offset = 3; offset < rgba.length; offset += 4)
        if (rgba[offset] != 255) return true;
    return false;
}

DecodedImage decodeImageFile(string path)
{
    enforce(path.length > 0, "No image path was given.");
    const data = cast(const(ubyte)[]) read(path);
    return decodeImageBytes(data, path);
}

DecodedImage decodeImageBytes(const(ubyte)[] bytes, string label)
{
    enforce(bytes.length > 0, label ~ " is empty.");
    const format = sniffImageFormat(bytes);
    enforce(format != ImageFormat.unknown ||
        extension(label).toLower() == ".tga",
        "Unsupported image format: " ~ label);
    // Guard the reported dimensions before handing the bytes to the shared
    // decoder so an enormous header can never start a huge allocation.
    enforceDimensionsFor(format, bytes, label);

    RgbaImage image;
    if (format == ImageFormat.unknown)
        image = decodeTgaImage(bytes, label);   // TGA has no reliable magic
    else
        image = decodeImage(bytes, label);
    enforceDimensions(image.width(), image.height(), label);
    DecodedImage result;
    result.width = image.width();
    result.height = image.height();
    result.rgba = image.pixels().dup;
    result.hasAlpha = scanAlpha(result.rgba);
    result.format = formatLabel(format);
    return result;
}

/// Read the pixel dimensions out of the header for the shared size guard.
private void enforceDimensionsFor(ImageFormat format, const(ubyte)[] bytes,
    string label)
{
    int width;
    int height;
    switch (format)
    {
        case ImageFormat.png:
            if (bytes.length >= 24)
            {
                width = be32(bytes, 16);
                height = be32(bytes, 20);
            }
            break;
        case ImageFormat.gif:
            if (bytes.length >= 10)
            {
                width = le16(bytes, 6);
                height = le16(bytes, 8);
            }
            break;
        case ImageFormat.bmp:
            if (bytes.length >= 26)
            {
                width = le32(bytes, 18);
                height = le32(bytes, 22);
                if (height < 0) height = -height;
            }
            break;
        case ImageFormat.jpeg:
            // Scan to the first SOF marker for the frame size.
            size_t pos = 2;
            while (pos + 9 < bytes.length)
            {
                if (bytes[pos] != 0xFF) { ++pos; continue; }
                const marker = bytes[pos + 1];
                if (marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 &&
                    marker != 0xC8 && marker != 0xCC)
                {
                    height = be16(bytes, pos + 5);
                    width = be16(bytes, pos + 7);
                    break;
                }
                if (marker == 0xD8 || marker == 0x01 ||
                    (marker >= 0xD0 && marker <= 0xD7)) { pos += 2; continue; }
                if (pos + 4 > bytes.length) break;
                pos += 2 + be16(bytes, pos + 2);
            }
            break;
        default:
            return;   // TGA/PNM/ICO validate their own headers.
    }
    if (width > 0 && height > 0)
        enforceDimensions(width, height, label);
}

private int be16(const(ubyte)[] bytes, size_t offset)
{
    return (cast(int) bytes[offset] << 8) | cast(int) bytes[offset + 1];
}

private int be32(const(ubyte)[] bytes, size_t offset)
{
    return (cast(int) bytes[offset] << 24) | (cast(int) bytes[offset + 1] << 16) |
        (cast(int) bytes[offset + 2] << 8) | cast(int) bytes[offset + 3];
}

private int le16(const(ubyte)[] bytes, size_t offset)
{
    return cast(int) bytes[offset] | (cast(int) bytes[offset + 1] << 8);
}

private int le32(const(ubyte)[] bytes, size_t offset)
{
    return cast(int) bytes[offset] | (cast(int) bytes[offset + 1] << 8) |
        (cast(int) bytes[offset + 2] << 16) |
        (cast(int) bytes[offset + 3] << 24);
}

private string formatLabel(ImageFormat format)
{
    switch (format)
    {
        case ImageFormat.pnm: return "PNM";
        case ImageFormat.ico: return "ICO";
        default: return imageFormatName(format).toUpper();
    }
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
        synchronized (_mutex)
        {
            _pendingPath = path;
            _hasPending = true;
            _condition.notifyAll();
        }
    }

    bool takeResult(out string path, out DecodedImage image, out string error)
    {
        synchronized (_mutex)
        {
            if (!_hasResult) return false;
            path = _resultPath;
            image = _resultImage;
            error = _resultError;
            _hasResult = false;
            return true;
        }
    }

    void shutdown()
    {
        synchronized (_mutex)
        {
            _shutdown = true;
            _condition.notifyAll();
        }
        _worker.join();
    }

    private void workerLoop()
    {
        while (true)
        {
            string path;
            synchronized (_mutex)
            {
                while (!_shutdown && !_hasPending)
                    _condition.wait();
                if (_shutdown && !_hasPending) return;
                path = _pendingPath;
                _hasPending = false;
            }

            DecodedImage image;
            string error;
            try
                image = decodeImageFile(path);
            catch (Exception exception)
                error = exception.msg;

            synchronized (_mutex)
            {
                _resultPath = path;
                _resultImage = image;
                _resultError = error;
                _hasResult = true;
            }
        }
    }
}
