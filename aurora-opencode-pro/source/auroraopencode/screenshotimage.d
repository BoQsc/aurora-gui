module auroraopencode.screenshotimage;

import aurora.platform.gdiplus : encodeJpegRgb;

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
    // Centralized in aurora.platform.gdiplus (throws when unavailable).
    return encodeJpegRgb(rgb, width, height, 85);
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
    import aurora.image : decodePngImage, fitImage, RgbaImage;
    RgbaImage image;
    try image = decodePngImage(png, "inline image");
    catch (Exception) return null;
    const width = image.width();
    const height = image.height();
    if (width <= 0 || height <= 0) return null;

    // Use the repository's shared resampler rather than a private downscale
    // loop: fitImage preserves aspect ratio and box-averages on shrink.
    auto scaled = maxEdge > 0 && (width > maxEdge || height > maxEdge)
        ? fitImage(image, maxEdge) : image;
    const outWidth = scaled.width();
    const outHeight = scaled.height();
    const rgba = scaled.pixels();
    auto rgb = new ubyte[cast(size_t) outWidth * outHeight * 3];
    foreach (y; 0 .. outHeight)
        foreach (x; 0 .. outWidth)
        {
            const src = (cast(size_t) y * outWidth + x) * 4;
            const dst = (cast(size_t) y * outWidth + x) * 3;
            rgb[dst] = rgba[src];
            rgb[dst + 1] = rgba[src + 1];
            rgb[dst + 2] = rgba[src + 2];
        }
    return encodeScreenshotJpeg(outWidth, outHeight, rgb);
}


