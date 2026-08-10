module auroraimageviewer.scaler;

import aurora.color : Color;
import std.algorithm : min, max;

/**
 * Straight-alpha RGBA8 image with a precomputed box-filtered mip pyramid.
 *
 * Rendering a viewport picks the mip level whose pixels are closest to screen
 * pixels (level zoom in [1, 2)) and then bilinear-samples only that level.
 * Zooming out therefore reads from a small pre-filtered level instead of
 * re-filtering every source pixel, which keeps both quality and latency flat
 * for multi-megapixel photos.
 */
final class MipImage
{
    private int _width;
    private int _height;
    private int _levels;
    private int[] _levelWidth;
    private int[] _levelHeight;
    private size_t[] _levelStart;
    private int[] _levelStride;
    private ubyte[] _pixels;
    private bool _hasAlpha;

    this(int width, int height, const(ubyte)[] rgba, bool hasAlpha)
    {
        build(width, height, rgba, hasAlpha);
    }

    int width() const @safe pure nothrow @nogc { return _width; }
    int height() const @safe pure nothrow @nogc { return _height; }
    int levelCount() const @safe pure nothrow @nogc { return _levels; }
    bool hasAlpha() const @safe pure nothrow @nogc { return _hasAlpha; }

    int levelWidth(int level) const @safe pure nothrow @nogc
    {
        return _levelWidth[level];
    }

    int levelHeight(int level) const @safe pure nothrow @nogc
    {
        return _levelHeight[level];
    }

    /**
     * Render the visible source region into an RGB24 viewport buffer.
     *
     * Params:
     *   rgb = output buffer, at least `viewWidth * viewHeight * 3` bytes.
     *   viewWidth / viewHeight = destination size in pixels.
     *   zoom = screen pixels per base source pixel.
     *   srcX / srcY = base source coordinate of the viewport top-left pixel.
     *   background = color of the letterbox area outside the image bounds.
     *   checkerA / checkerB = checkerboard colors shown behind transparency.
     */
    void render(ubyte[] rgb, int viewWidth, int viewHeight, double zoom,
        double srcX, double srcY, Color background, Color checkerA,
        Color checkerB) const
    {
        if (rgb.length < cast(size_t) viewWidth * cast(size_t) viewHeight * 3 ||
            viewWidth <= 0 || viewHeight <= 0)
            return;

        int level = 0;
        double levelZoom = zoom;
        while (levelZoom < 1.0 && level + 1 < _levels)
        {
            levelZoom *= 2.0;
            ++level;
        }
        const double baseToLevel = cast(double) (1 << level);

        const uint bgR = background.r;
        const uint bgG = background.g;
        const uint bgB = background.b;
        auto output = rgb.ptr;
        const size_t pixelCount = cast(size_t) viewWidth * cast(size_t) viewHeight;
        for (size_t index = 0; index < pixelCount; ++index)
        {
            const size_t o = index * 3;
            output[o] = cast(ubyte) bgR;
            output[o + 1] = cast(ubyte) bgG;
            output[o + 2] = cast(ubyte) bgB;
        }

        const double left = max(0.0, srcX);
        const double top = max(0.0, srcY);
        const double right = min(cast(double) _width, srcX + cast(double) viewWidth / zoom);
        const double bottom = min(cast(double) _height, srcY + cast(double) viewHeight / zoom);
        if (right <= left || bottom <= top) return;

        int destX0 = cast(int) floor((left - srcX) * zoom);
        int destY0 = cast(int) floor((top - srcY) * zoom);
        int destX1 = cast(int) ceil((right - srcX) * zoom) - 1;
        int destY1 = cast(int) ceil((bottom - srcY) * zoom) - 1;
        destX0 = max(0, min(destX0, viewWidth - 1));
        destY0 = max(0, min(destY0, viewHeight - 1));
        destX1 = max(0, min(destX1, viewWidth - 1));
        destY1 = max(0, min(destY1, viewHeight - 1));
        if (destX1 < destX0 || destY1 < destY0) return;

        const int lw = _levelWidth[level];
        const int lh = _levelHeight[level];
        const ubyte[] levelPixels = _pixels[_levelStart[level] ..
            _levelStart[level] + cast(size_t) lw * cast(size_t) lh * 4];

        enum long fixedOne = 1L << 32;
        const double levelSrcX = srcX / baseToLevel;
        const double levelSrcY = srcY / baseToLevel;
        const long uStep = cast(long) (fixedOne / levelZoom);
        const long vStep = cast(long) (fixedOne / levelZoom);
        const long uOrigin = cast(long) ((levelSrcX + 0.5 / levelZoom - 0.5) * fixedOne);
        const long vOrigin = cast(long) ((levelSrcY + 0.5 / levelZoom - 0.5) * fixedOne);
        const long uStart = uOrigin + (cast(long) destX0) * uStep;
        const long vStart = vOrigin + (cast(long) destY0) * vStep;

        if (_hasAlpha)
            renderAlpha(levelPixels, lw, lh, output, viewWidth, destX0, destY0,
                destX1, destY1, uStart, vStart, uStep, vStep, checkerA, checkerB);
        else
            renderOpaque(levelPixels, lw, lh, output, viewWidth, destX0, destY0,
                destX1, destY1, uStart, vStart, uStep, vStep);
    }

    private static void renderOpaque(const(ubyte)[] pixels, int lw, int lh,
        ubyte* output, int viewWidth, int x0, int y0, int x1, int y1,
        long uStart, long vStart, long uStep, long vStep)
    {
        long vFixed = vStart;
        foreach (y; y0 .. y1 + 1)
        {
            int sy0;
            int sy1;
            uint fy;
            sampleAxis(vFixed, lh, sy0, sy1, fy);
            const uint inverseY = 256u - fy;
            long uFixed = uStart;
            auto o = output + (cast(size_t) y * cast(size_t) viewWidth + cast(size_t) x0) * 3;
            foreach (x; x0 .. x1 + 1)
            {
                int sx0;
                int sx1;
                uint fx;
                sampleAxis(uFixed, lw, sx0, sx1, fx);
                const uint inverseX = 256u - fx;

                const size_t p00 = (cast(size_t) sy0 * cast(size_t) lw + cast(size_t) sx0) * 4;
                const size_t p10 = (cast(size_t) sy0 * cast(size_t) lw + cast(size_t) sx1) * 4;
                const size_t p01 = (cast(size_t) sy1 * cast(size_t) lw + cast(size_t) sx0) * 4;
                const size_t p11 = (cast(size_t) sy1 * cast(size_t) lw + cast(size_t) sx1) * 4;

                const uint topR = cast(uint) pixels[p00] * inverseX + cast(uint) pixels[p10] * fx;
                const uint topG = cast(uint) pixels[p00 + 1] * inverseX + cast(uint) pixels[p10 + 1] * fx;
                const uint topB = cast(uint) pixels[p00 + 2] * inverseX + cast(uint) pixels[p10 + 2] * fx;
                const uint bottomR = cast(uint) pixels[p01] * inverseX + cast(uint) pixels[p11] * fx;
                const uint bottomG = cast(uint) pixels[p01 + 1] * inverseX + cast(uint) pixels[p11 + 1] * fx;
                const uint bottomB = cast(uint) pixels[p01 + 2] * inverseX + cast(uint) pixels[p11 + 2] * fx;

                o[0] = cast(ubyte) ((topR * inverseY + bottomR * fy + 32_768u) >> 16);
                o[1] = cast(ubyte) ((topG * inverseY + bottomG * fy + 32_768u) >> 16);
                o[2] = cast(ubyte) ((topB * inverseY + bottomB * fy + 32_768u) >> 16);
                o += 3;
                uFixed += uStep;
            }
            vFixed += vStep;
        }
    }

    private static void renderAlpha(const(ubyte)[] pixels, int lw, int lh,
        ubyte* output, int viewWidth, int x0, int y0, int x1, int y1,
        long uStart, long vStart, long uStep, long vStep,
        Color checkerA, Color checkerB)
    {
        const uint caR = checkerA.r;
        const uint caG = checkerA.g;
        const uint caB = checkerA.b;
        const uint cbR = checkerB.r;
        const uint cbG = checkerB.g;
        const uint cbB = checkerB.b;
        long vFixed = vStart;
        foreach (y; y0 .. y1 + 1)
        {
            int sy0;
            int sy1;
            uint fy;
            sampleAxis(vFixed, lh, sy0, sy1, fy);
            const uint inverseY = 256u - fy;
            long uFixed = uStart;
            auto o = output + (cast(size_t) y * cast(size_t) viewWidth + cast(size_t) x0) * 3;
            foreach (x; x0 .. x1 + 1)
            {
                int sx0;
                int sx1;
                uint fx;
                sampleAxis(uFixed, lw, sx0, sx1, fx);
                const uint inverseX = 256u - fx;

                const size_t p00 = (cast(size_t) sy0 * cast(size_t) lw + cast(size_t) sx0) * 4;
                const size_t p10 = (cast(size_t) sy0 * cast(size_t) lw + cast(size_t) sx1) * 4;
                const size_t p01 = (cast(size_t) sy1 * cast(size_t) lw + cast(size_t) sx0) * 4;
                const size_t p11 = (cast(size_t) sy1 * cast(size_t) lw + cast(size_t) sx1) * 4;

                const uint topR = cast(uint) pixels[p00] * inverseX + cast(uint) pixels[p10] * fx;
                const uint topG = cast(uint) pixels[p00 + 1] * inverseX + cast(uint) pixels[p10 + 1] * fx;
                const uint topB = cast(uint) pixels[p00 + 2] * inverseX + cast(uint) pixels[p10 + 2] * fx;
                const uint topA = cast(uint) pixels[p00 + 3] * inverseX + cast(uint) pixels[p10 + 3] * fx;
                const uint bottomR = cast(uint) pixels[p01] * inverseX + cast(uint) pixels[p11] * fx;
                const uint bottomG = cast(uint) pixels[p01 + 1] * inverseX + cast(uint) pixels[p11 + 1] * fx;
                const uint bottomB = cast(uint) pixels[p01 + 2] * inverseX + cast(uint) pixels[p11 + 2] * fx;
                const uint bottomA = cast(uint) pixels[p01 + 3] * inverseX + cast(uint) pixels[p11 + 3] * fx;

                const uint red = (topR * inverseY + bottomR * fy + 32_768u) >> 16;
                const uint green = (topG * inverseY + bottomG * fy + 32_768u) >> 16;
                const uint blue = (topB * inverseY + bottomB * fy + 32_768u) >> 16;
                const uint alpha = (topA * inverseY + bottomA * fy + 32_768u) >> 16;

                if (alpha >= 255)
                {
                    o[0] = cast(ubyte) red;
                    o[1] = cast(ubyte) green;
                    o[2] = cast(ubyte) blue;
                }
                else if (alpha == 0)
                {
                    const bool dark = ((x >> 4) + (y >> 4)) & 1;
                    if (dark)
                    {
                        o[0] = cast(ubyte) cbR;
                        o[1] = cast(ubyte) cbG;
                        o[2] = cast(ubyte) cbB;
                    }
                    else
                    {
                        o[0] = cast(ubyte) caR;
                        o[1] = cast(ubyte) caG;
                        o[2] = cast(ubyte) caB;
                    }
                }
                else
                {
                    const bool dark = ((x >> 4) + (y >> 4)) & 1;
                    const uint chkR = dark ? cbR : caR;
                    const uint chkG = dark ? cbG : caG;
                    const uint chkB = dark ? cbB : caB;
                    const uint inverse = 255u - alpha;
                    o[0] = cast(ubyte) ((red * alpha + chkR * inverse + 127u) / 255u);
                    o[1] = cast(ubyte) ((green * alpha + chkG * inverse + 127u) / 255u);
                    o[2] = cast(ubyte) ((blue * alpha + chkB * inverse + 127u) / 255u);
                }
                o += 3;
                uFixed += uStep;
            }
            vFixed += vStep;
        }
    }

    private static void sampleAxis(long fixed, int size, out int index0,
        out int index1, out uint fraction)
    {
        if (fixed <= 0)
        {
            index0 = 0;
            index1 = size > 1 ? 1 : 0;
            fraction = 0;
            return;
        }
        index0 = cast(int) (fixed >> 32);
        if (index0 >= size - 1)
        {
            index0 = size - 1;
            index1 = index0;
            fraction = 0;
            return;
        }
        index1 = index0 + 1;
        fraction = cast(uint) ((fixed >> 24) & 0xff);
    }

    private void build(int width, int height, const(ubyte)[] rgba, bool hasAlpha)
    {
        _width = width;
        _height = height;
        _hasAlpha = hasAlpha;

        int w = width;
        int h = height;
        while (true)
        {
            _levelWidth ~= w;
            _levelHeight ~= h;
            if (w <= 8 || h <= 8) break;
            w = max(1, (w + 1) >> 1);
            h = max(1, (h + 1) >> 1);
        }
        _levels = cast(int) _levelWidth.length;
        _levelStart.length = cast(size_t) _levels;
        _levelStride.length = cast(size_t) _levels;
        size_t total = 0;
        foreach (index; 0 .. _levels)
        {
            _levelStart[index] = total;
            _levelStride[index] = _levelWidth[index] * 4;
            total += cast(size_t) _levelWidth[index] * cast(size_t) _levelHeight[index] * 4;
        }
        _pixels.length = total;
        const size_t baseBytes = cast(size_t) width * cast(size_t) height * 4;
        _pixels[0 .. baseBytes] = rgba[0 .. baseBytes];
        foreach (index; 0 .. _levels - 1)
            downsample(index, _levelWidth[index], _levelHeight[index],
                _levelWidth[index + 1], _levelHeight[index + 1]);
    }

    private void downsample(int srcLevel, int srcW, int srcH, int dstW, int dstH)
    {
        const ubyte[] source = _pixels[_levelStart[srcLevel] ..
            _levelStart[srcLevel] + cast(size_t) srcW * cast(size_t) srcH * 4];
        ubyte[] destination = _pixels[_levelStart[srcLevel + 1] ..
            _levelStart[srcLevel + 1] + cast(size_t) dstW * cast(size_t) dstH * 4];

        foreach (dy; 0 .. dstH)
        {
            const sy0 = dy * 2;
            const sy1 = sy0 + 2 < srcH ? sy0 + 2 : srcH;
            foreach (dx; 0 .. dstW)
            {
                const sx0 = dx * 2;
                const sx1 = sx0 + 2 < srcW ? sx0 + 2 : srcW;
                uint rSum = 0;
                uint gSum = 0;
                uint bSum = 0;
                uint aSum = 0;
                uint count = 0;
                foreach (sy; sy0 .. sy1)
                {
                    foreach (sx; sx0 .. sx1)
                    {
                        const size_t o = (cast(size_t) sy * cast(size_t) srcW +
                            cast(size_t) sx) * 4;
                        const uint a = source[o + 3];
                        rSum += cast(uint) source[o] * a;
                        gSum += cast(uint) source[o + 1] * a;
                        bSum += cast(uint) source[o + 2] * a;
                        aSum += a;
                        ++count;
                    }
                }
                const size_t o = (cast(size_t) dy * cast(size_t) dstW +
                    cast(size_t) dx) * 4;
                if (aSum == 0)
                {
                    destination[o] = 0;
                    destination[o + 1] = 0;
                    destination[o + 2] = 0;
                    destination[o + 3] = 0;
                }
                else
                {
                    destination[o] = cast(ubyte) ((rSum + aSum / 2) / aSum);
                    destination[o + 1] = cast(ubyte) ((gSum + aSum / 2) / aSum);
                    destination[o + 2] = cast(ubyte) ((bSum + aSum / 2) / aSum);
                    destination[o + 3] = cast(ubyte) ((aSum + count / 2) / count);
                }
            }
        }
    }

    private static double floor(double value) @safe pure nothrow @nogc
    {
        const long integer = cast(long) value;
        return value < cast(double) integer ? integer - 1.0 : cast(double) integer;
    }

    private static double ceil(double value) @safe pure nothrow @nogc
    {
        const long integer = cast(long) value;
        return value > cast(double) integer ? integer + 1.0 : cast(double) integer;
    }
}
