module aurora.text.colr;

/**
 * Pure-D COLR (color glyph) support: COLR v0 base/layer records and COLR v1
 * paint trees, with CPAL palette resolution, rendered into an RGBA buffer.
 *
 * The renderer composites layers bottom-up with straight-alpha source-over,
 * following the OpenType 1.9 COLR specification. Paint formats 1..32 are
 * implemented (layers, solid, gradients, glyph clip, colrGlyph, transforms,
 * scale/rotate/skew, composite). Alpha values are F2DOT14 (1.0 = 0x4000).
 */

import aurora.types : Rect;
import aurora.image : decodePngImage;
import std.math : abs, atan2, cos, sin, sqrt, tan;
import std.algorithm : sort;

private enum uint tag(string value) =
    (cast(uint) value[0] << 24) | (cast(uint) value[1] << 16) |
    (cast(uint) value[2] << 8) | cast(uint) value[3];

private ushort be16(const(ubyte)[] data, size_t offset)
{
    if (offset + 2 > data.length) return 0;
    return cast(ushort) ((cast(uint) data[offset] << 8) | data[offset + 1]);
}

private short beS16(const(ubyte)[] data, size_t offset)
{
    return cast(short) be16(data, offset);
}

private uint be24(const(ubyte)[] data, size_t offset)
{
    if (offset + 3 > data.length) return 0;
    return (cast(uint) data[offset] << 16) | (cast(uint) data[offset + 1] << 8) |
        data[offset + 2];
}

private uint be32(const(ubyte)[] data, size_t offset)
{
    if (offset + 4 > data.length) return 0;
    return (cast(uint) data[offset] << 24) | (cast(uint) data[offset + 1] << 16) |
        (cast(uint) data[offset + 2] << 8) | cast(uint) data[offset + 3];
}

private int beS32(const(ubyte)[] data, size_t offset)
{
    return cast(int) be32(data, offset);
}

/// A resolved RGBA8 color.
struct RgbaColor
{
    ubyte r;
    ubyte g;
    ubyte b;
    ubyte a;
}

/// RGBA8 surface with straight alpha.
struct ColorSurface
{
    int width;
    int height;
    ubyte[] pixels; // RGBA, straight alpha.

    static ColorSurface create(int width, int height)
    {
        ColorSurface surface;
        surface.width = width;
        surface.height = height;
        surface.pixels.length = cast(size_t) width * height * 4;
        return surface;
    }

    void clear()
    {
        pixels[] = 0;
    }

    RgbaColor pixel(int x, int y) const
    {
        RgbaColor result;
        if (x < 0 || y < 0 || x >= width || y >= height) return result;
        const index = (cast(size_t) y * width + x) * 4;
        result.r = pixels[index];
        result.g = pixels[index + 1];
        result.b = pixels[index + 2];
        result.a = pixels[index + 3];
        return result;
    }

    void setPixel(int x, int y, RgbaColor color)
    {
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        const index = (cast(size_t) y * width + x) * 4;
        pixels[index] = color.r;
        pixels[index + 1] = color.g;
        pixels[index + 2] = color.b;
        pixels[index + 3] = color.a;
    }

    /// Source-over composite of a straight-alpha color onto this surface.
    void composite(int x, int y, RgbaColor source)
    {
        if (x < 0 || y < 0 || x >= width || y >= height) return;
        const index = (cast(size_t) y * width + x) * 4;
        const double sa = source.a / 255.0;
        const double da = pixels[index + 3] / 255.0;
        const double outA = sa + da * (1.0 - sa);
        if (outA <= 0.0) return;
        const double sr = source.r / 255.0;
        const double sg = source.g / 255.0;
        const double sb = source.b / 255.0;
        const double dr = pixels[index] / 255.0;
        const double dg = pixels[index + 1] / 255.0;
        const double db = pixels[index + 2] / 255.0;
        const double cr = (sr * sa + dr * da * (1.0 - sa)) / outA;
        const double cg = (sg * sa + dg * da * (1.0 - sa)) / outA;
        const double cb = (sb * sa + db * da * (1.0 - sa)) / outA;
        pixels[index] = cast(ubyte) (cr * 255.0 + 0.5);
        pixels[index + 1] = cast(ubyte) (cg * 255.0 + 0.5);
        pixels[index + 2] = cast(ubyte) (cb * 255.0 + 0.5);
        pixels[index + 3] = cast(ubyte) (outA * 255.0 + 0.5);
    }
}

/// COLR + CPAL color glyph renderer.
final class ColrRenderer
{
    private const(ubyte)[] _data;
    private size_t _faceOffset;
    private const(ubyte)[] _colr;
    private const(ubyte)[] _cpal;
    private bool _hasV1;

    // COLR v0.
    private uint _numBaseGlyphs;
    private uint _baseGlyphRecordsOffset;
    private uint _layerRecordsOffset;
    private uint _numLayers;

    // COLR v1.
    private uint _baseGlyphListOffset;
    private uint _layerListOffset;
    private uint _clipListOffset;

    // CBDT / CBLC bitmap color data.
    private const(ubyte)[] _cbdt;
    private const(ubyte)[] _cblc;
    private const(ubyte)[] _sbix;
    private uint _numGlyphs;

    /// When set, renders a layer glyph (outline or bitmap) at the origin
    /// using the resolved palette color.
    public alias LayerGlyphRenderer = void delegate(uint glyphID, int x, int y,
        ref ColorSurface surface, int pixelSize, RgbaColor color);
    public LayerGlyphRenderer layerGlyphRenderer;

    // CPAL.
    private uint _numPalettes;
    private uint _numPaletteEntries;
    private uint _numColorRecords;
    private uint _colorRecordsArrayOffset;

    /// Callback to rasterize a monochrome glyph outline into an alpha mask.
    /// The renderer calls this to fill a glyph's alpha into a buffer.
    public alias OutlineRasterizer = void delegate(uint glyphID, int x, int y,
        ref ColorSurface surface, ubyte alpha);
    public OutlineRasterizer outlineRasterizer;

    this(const(ubyte)[] data, size_t faceOffset)
    {
        _data = data;
        _faceOffset = faceOffset;
        _colr = table(tag!"COLR");
        _cpal = table(tag!"CPAL");
        _cbdt = table(tag!"CBDT");
        _cblc = table(tag!"CBLC");
        _sbix = table(tag!"sbix");
        parseColr();
        parseCpal();
        const maxp = table(tag!"maxp");
        if (maxp !is null && maxp.length >= 6)
            _numGlyphs = be16(maxp, 4);
    }

    bool isColorFont() const @safe pure nothrow @nogc
    {
        return _colr !is null && _cpal !is null;
    }

    /// Whether a glyph has a COLR paint definition.
    bool hasGlyph(uint glyphID)
    {
        if (_colr is null) return false;
        // v1 base glyph list.
        if (_hasV1 && _baseGlyphListOffset < _colr.length)
        {
            const listOffset = _baseGlyphListOffset;
            const numRecords = be32(_colr, listOffset);
            size_t low;
            size_t high = numRecords;
            while (low < high)
            {
                const middle = low + (high - low) / 2;
                const entry = listOffset + 4 + middle * 6;
                const id = be16(_colr, entry);
                if (glyphID < id) high = middle;
                else if (glyphID > id) low = middle + 1;
                else return true;
            }
        }
        // v0 base glyph records.
        if (_numBaseGlyphs > 0 && _baseGlyphRecordsOffset < _colr.length)
        {
            size_t low;
            size_t high = _numBaseGlyphs;
            while (low < high)
            {
                const middle = low + (high - low) / 2;
                const entry = _baseGlyphRecordsOffset + middle * 6;
                const id = be16(_colr, entry);
                if (glyphID < id) high = middle;
                else if (glyphID > id) low = middle + 1;
                else return true;
            }
        }
        return false;
    }

    /**
     * Render a color glyph into a surface at the given origin. The surface
     * must already be the right size; the glyph is composited onto it.
     */
    bool render(uint glyphID, ref ColorSurface surface, int originX, int originY,
        int pixelSize)
    {
        if (!isColorFont()) return false;
        bool drewColor;
        // Prefer v1 paint tree.
        if (_hasV1 && _baseGlyphListOffset < _colr.length)
        {
            const listOffset = _baseGlyphListOffset;
            const numRecords = be32(_colr, listOffset);
            size_t low;
            size_t high = numRecords;
            while (low < high)
            {
                const middle = low + (high - low) / 2;
                const entry = listOffset + 4 + middle * 6;
                const id = be16(_colr, entry);
                if (glyphID < id) high = middle;
                else if (glyphID > id) low = middle + 1;
                else
                {
                    const paintOffset = be32(_colr, entry + 2);
                    const paintPos = listOffset + paintOffset;
                    renderPaint(surface, paintPos, originX, originY,
                        pixelSize, Transform.identity, 0);
                    drewColor = true;
                    break;
                }
            }
        }
        // v0 base glyph records.
        if (!drewColor && _numBaseGlyphs > 0 && _baseGlyphRecordsOffset < _colr.length)
        {
            size_t low;
            size_t high = _numBaseGlyphs;
            while (low < high)
            {
                const middle = low + (high - low) / 2;
                const entry = _baseGlyphRecordsOffset + middle * 6;
                const id = be16(_colr, entry);
                if (glyphID < id) high = middle;
                else if (glyphID > id) low = middle + 1;
                else
                {
                    const firstLayer = be16(_colr, entry + 2);
                    const numLayers = be16(_colr, entry + 4);
                    const layerStart = _layerRecordsOffset + cast(size_t) firstLayer * 4;
                    for (uint layer = 0; layer < numLayers; ++layer)
                    {
                        const rec = layerStart + cast(size_t) layer * 4;
                        const layerGlyph = be16(_colr, rec);
                        const paletteIndex = be16(_colr, rec + 2);
                        RgbaColor color = paletteColor(paletteIndex, 0x4000);
                        if (color.a == 0) continue;
                        if (layerGlyphRenderer !is null)
                        {
                            layerGlyphRenderer(layerGlyph, originX, originY,
                                surface, pixelSize, color);
                        }
                        else if (outlineRasterizer !is null)
                        {
                            // Render the layer glyph outline into the surface.
                            outlineRasterizer(layerGlyph, originX, originY,
                                surface, color.a);
                        }
                    }
                    drewColor = true;
                    break;
                }
            }
        }
        // If COLR produced nothing, fall back to CBDT/sbix bitmap strikes.
        if (!drewColor)
        {
            int width, height, bearingX, bearingY;
            const png = cbdtBitmap(glyphID, pixelSize, width, height,
                bearingX, bearingY);
            if (png !is null && png.length > 0)
            {
                drawPng(png, originX + bearingX, originY - height + bearingY,
                    width, height, surface);
                drewColor = true;
            }
            else
            {
                const sbixPng = sbixBitmap(glyphID, pixelSize);
                if (sbixPng !is null && sbixPng.length > 0)
                {
                    // sbix PNGs are at the strike ppem; draw at the origin.
                    drawPng(sbixPng, originX, originY, pixelSize, pixelSize,
                        surface);
                    drewColor = true;
                }
            }
        }
        return drewColor;
    }

    /// Decode and draw a PNG bitmap onto the surface at the given top-left.
    private void drawPng(const(ubyte)[] png, int x, int y, int width, int height,
        ref ColorSurface surface)
    {
        try
        {
            auto image = decodePngImage(png, "CBDT/sbix glyph");
            foreach (py; 0 .. image.height())
            {
                const sy = y + py;
                if (sy < 0 || sy >= surface.height) continue;
                foreach (px; 0 .. image.width())
                {
                    const sx = x + px;
                    if (sx < 0 || sx >= surface.width) continue;
                    const si = (cast(size_t) py * image.width() + px) * 4;
                    RgbaColor color;
                    color.r = image.pixels()[si];
                    color.g = image.pixels()[si + 1];
                    color.b = image.pixels()[si + 2];
                    color.a = image.pixels()[si + 3];
                    surface.composite(sx, sy, color);
                }
            }
        }
        catch (Exception)
        {
            // Ignore undecodable bitmaps.
        }
    }

    /// Resolve a CPAL palette entry to an RGBA color with an F2DOT14 alpha.
    private RgbaColor paletteColor(uint paletteIndex, int alphaF2Dot14)
    {
        RgbaColor result;
        if (_cpal is null || paletteIndex == 0xFFFF) return result;
        if (paletteIndex >= _numColorRecords) return result;
        const rec = _colorRecordsArrayOffset + cast(size_t) paletteIndex * 4;
        // ColorRecord is blue, green, red, alpha.
        result.b = _cpal[rec];
        result.g = _cpal[rec + 1];
        result.r = _cpal[rec + 2];
        const baseAlpha = _cpal[rec + 3];
        double alpha = alphaF2Dot14 / 16384.0;
        if (alpha < 0.0) alpha = 0.0;
        if (alpha > 1.0) alpha = 1.0;
        result.a = cast(ubyte) (baseAlpha / 255.0 * alpha * 255.0 + 0.5);
        return result;
    }

    // ------------------------------------------------------------------
    // COLR v1 paint tree rendering.
    // ------------------------------------------------------------------

    private struct Transform
    {
        double xx = 1.0;
        double yx = 0.0;
        double xy = 0.0;
        double yy = 1.0;
        double dx = 0.0;
        double dy = 0.0;

        static Transform identity()
        {
            Transform t;
            t.xx = 1.0; t.yy = 1.0;
            return t;
        }

        Transform mul(Transform other) const
        {
            Transform result;
            result.xx = xx * other.xx + xy * other.yx;
            result.xy = xx * other.xy + xy * other.yy;
            result.yx = yx * other.xx + yy * other.yx;
            result.yy = yx * other.xy + yy * other.yy;
            result.dx = xx * other.dx + xy * other.dy + dx;
            result.dy = yx * other.dx + yy * other.dy + dy;
            return result;
        }

        void apply(double x, double y, ref double ox, ref double oy) const
        {
            ox = xx * x + xy * y + dx;
            oy = yx * x + yy * y + dy;
        }
    }

    private void renderPaint(ref ColorSurface surface, size_t paintPos,
        int originX, int originY, int pixelSize, Transform transform, int depth)
    {
        if (paintPos >= _colr.length || depth > 32) return;
        const format = _colr[paintPos];
        switch (format)
        {
            case 1: // PaintColrLayers
            {
                const numLayers = _colr[paintPos + 1];
                const firstLayer = be32(_colr, paintPos + 2);
                foreach (layer; 0 .. numLayers)
                {
                    if (_layerListOffset >= _colr.length) break;
                    const layerEntry = _layerListOffset + 4 + cast(size_t) (firstLayer + layer) * 4;
                    const paintOffset = be32(_colr, layerEntry);
                    const childPos = _layerListOffset + paintOffset;
                    renderPaint(surface, childPos, originX, originY, pixelSize,
                        transform, depth + 1);
                }
                return;
            }
            case 2: // PaintSolid
            {
                const paletteIndex = be16(_colr, paintPos + 1);
                const alpha = beS16(_colr, paintPos + 3);
                const color = paletteColor(paletteIndex, alpha);
                fillSurfaceWithColor(surface, color, transform);
                return;
            }
            case 3: // PaintVarSolid (treat as solid, ignore variation)
            {
                const paletteIndex = be16(_colr, paintPos + 1);
                const alpha = beS16(_colr, paintPos + 3);
                const color = paletteColor(paletteIndex, alpha);
                fillSurfaceWithColor(surface, color, transform);
                return;
            }
            case 4: // PaintLinearGradient
            {
                renderLinearGradient(surface, paintPos, originX, originY,
                    pixelSize, transform);
                return;
            }
            case 5: // PaintVarLinearGradient
            {
                renderLinearGradient(surface, paintPos, originX, originY,
                    pixelSize, transform);
                return;
            }
            case 6: // PaintRadialGradient
            {
                renderRadialGradient(surface, paintPos, originX, originY,
                    pixelSize, transform);
                return;
            }
            case 7: // PaintVarRadialGradient
            {
                renderRadialGradient(surface, paintPos, originX, originY,
                    pixelSize, transform);
                return;
            }
            case 8: // PaintSweepGradient
            {
                renderSweepGradient(surface, paintPos, originX, originY,
                    pixelSize, transform);
                return;
            }
            case 9: // PaintVarSweepGradient
            {
                renderSweepGradient(surface, paintPos, originX, originY,
                    pixelSize, transform);
                return;
            }
            case 10: // PaintGlyph: clip to the glyph outline, render child.
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const glyphID = be16(_colr, paintPos + 4);
                const childPos = paintPos + paintOffset;
                if (outlineRasterizer !is null)
                {
                    // Clip: rasterize glyph alpha to a mask and render child
                    // only where the mask is non-zero. For simplicity and
                    // correctness we composite the child then mask it by
                    // rendering the child into a temp and applying the mask.
                    auto temp = surface;
                    temp.pixels = surface.pixels.dup;
                    temp.clear();
                    renderPaint(temp, childPos, originX, originY, pixelSize,
                        transform, depth + 1);
                    // Apply the glyph clip: zero pixels outside the outline.
                    applyGlyphClip(glyphID, originX, originY, pixelSize,
                        transform, temp, surface);
                }
                else
                    renderPaint(surface, childPos, originX, originY, pixelSize,
                        transform, depth + 1);
                return;
            }
            case 11: // PaintColrGlyph
            {
                const glyphID = be16(_colr, paintPos + 1);
                const target = baseGlyphPaint(glyphID);
                if (target != size_t.max)
                    renderPaint(surface, target, originX, originY, pixelSize,
                        transform, depth + 1);
                return;
            }
            case 12: case 13: // PaintTransform / PaintVarTransform
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const transformOffset = be24(_colr, paintPos + 4);
                const childPos = paintPos + paintOffset;
                auto childTransform = readAffine(paintPos + transformOffset);
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    transform.mul(childTransform), depth + 1);
                return;
            }
            case 14: // PaintTranslate
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const dx = beS16(_colr, paintPos + 4);
                const dy = beS16(_colr, paintPos + 6);
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                child.dx += dx;
                child.dy += dy;
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 15: // PaintVarTranslate
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const dx = beS16(_colr, paintPos + 4);
                const dy = beS16(_colr, paintPos + 6);
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                child.dx += dx;
                child.dy += dy;
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 16: case 17: // PaintScale / PaintVarScale
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const scaleX = beS16(_colr, paintPos + 4) / 16384.0;
                const scaleY = beS16(_colr, paintPos + 6) / 16384.0;
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                child.xx *= scaleX;
                child.xy *= scaleX;
                child.yx *= scaleY;
                child.yy *= scaleY;
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 18: case 19: // PaintScaleAroundCenter / Var
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const scaleX = beS16(_colr, paintPos + 4) / 16384.0;
                const scaleY = beS16(_colr, paintPos + 6) / 16384.0;
                const centerX = beS16(_colr, paintPos + 8);
                const centerY = beS16(_colr, paintPos + 10);
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                // Translate so the center stays fixed.
                child.dx += centerX * (1.0 - scaleX);
                child.dy += centerY * (1.0 - scaleY);
                child.xx *= scaleX;
                child.xy *= scaleX;
                child.yx *= scaleY;
                child.yy *= scaleY;
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 20: case 21: // PaintScaleUniform / Var
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const scale = beS16(_colr, paintPos + 4) / 16384.0;
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                child.xx *= scale;
                child.xy *= scale;
                child.yx *= scale;
                child.yy *= scale;
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 22: case 23: // PaintScaleUniformAroundCenter / Var
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const scale = beS16(_colr, paintPos + 4) / 16384.0;
                const centerX = beS16(_colr, paintPos + 6);
                const centerY = beS16(_colr, paintPos + 8);
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                child.dx += centerX * (1.0 - scale);
                child.dy += centerY * (1.0 - scale);
                child.xx *= scale;
                child.xy *= scale;
                child.yx *= scale;
                child.yy *= scale;
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 24: case 25: // PaintRotate / VarRotate
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const angle = beS16(_colr, paintPos + 4) / 16384.0 * 3.141592653589793 / 180.0;
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                applyRotation(child, angle, 0.0, 0.0);
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 26: case 27: // PaintRotateAroundCenter / Var
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const angle = beS16(_colr, paintPos + 4) / 16384.0 * 3.141592653589793 / 180.0;
                const centerX = beS16(_colr, paintPos + 6);
                const centerY = beS16(_colr, paintPos + 8);
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                applyRotation(child, angle, centerX, centerY);
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 28: case 29: // PaintSkew / VarSkew
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const xSkew = beS16(_colr, paintPos + 4) / 16384.0 * 3.141592653589793 / 180.0;
                const ySkew = beS16(_colr, paintPos + 6) / 16384.0 * 3.141592653589793 / 180.0;
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                child.xy += -tan(xSkew);
                child.yx += tan(ySkew);
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 30: case 31: // PaintSkewAroundCenter / Var
            {
                const paintOffset = be24(_colr, paintPos + 1);
                const xSkew = beS16(_colr, paintPos + 4) / 16384.0 * 3.141592653589793 / 180.0;
                const ySkew = beS16(_colr, paintPos + 6) / 16384.0 * 3.141592653589793 / 180.0;
                const centerX = beS16(_colr, paintPos + 8);
                const centerY = beS16(_colr, paintPos + 10);
                const childPos = paintPos + paintOffset;
                Transform child = transform;
                child.xy += -tan(xSkew);
                child.yx += tan(ySkew);
                child.dx += centerX - (child.xx * centerX + child.xy * centerY + child.dx);
                child.dy += centerY - (child.yx * centerX + child.yy * centerY + child.dy);
                renderPaint(surface, childPos, originX, originY, pixelSize,
                    child, depth + 1);
                return;
            }
            case 32: // PaintComposite
            {
                const sourceOffset = be24(_colr, paintPos + 1);
                const compositeMode = _colr[paintPos + 4];
                const backdropOffset = be24(_colr, paintPos + 5);
                const sourcePos = paintPos + sourceOffset;
                const backdropPos = paintPos + backdropOffset;
                // Render backdrop then source with the mode.
                auto backdrop = surface;
                backdrop.pixels = surface.pixels.dup;
                backdrop.clear();
                renderPaint(backdrop, backdropPos, originX, originY, pixelSize,
                    transform, depth + 1);
                auto source = surface;
                source.pixels = surface.pixels.dup;
                source.clear();
                renderPaint(source, sourcePos, originX, originY, pixelSize,
                    transform, depth + 1);
                compositeModes(surface, source, backdrop, compositeMode);
                return;
            }
            default:
                return;
        }
    }

    private static void applyRotation(ref Transform t, double angle,
        double centerX, double centerY)
    {
        const cos = cos(angle);
        const sin = sin(angle);
        // Compose rotation about the center into the existing transform.
        // x' = center + R*(x - center)
        // As a transform: apply R, then translate center - R*center.
        const newXx = cos;
        const newXy = -sin;
        const newYx = sin;
        const newYy = cos;
        const nx = t.xx * newXx + t.xy * newYx;
        const nxy = t.xx * newXy + t.xy * newYy;
        const nyx = t.yx * newXx + t.yy * newYx;
        const nyy = t.yx * newXy + t.yy * newYy;
        const ndx = t.dx + centerX - (t.xx * centerX + t.xy * centerY);
        const ndy = t.dy + centerY - (t.yx * centerX + t.yy * centerY);
        t.xx = nx; t.xy = nxy; t.yx = nyx; t.yy = nyy;
        t.dx = ndx; t.dy = ndy;
    }

    private Transform readAffine(size_t pos)
    {
        Transform t;
        if (pos + 24 > _colr.length) return t;
        // Order: xx, yx, xy, yy, dx, dy (all F16DOT16).
        t.xx = beS32(_colr, pos) / 65536.0;
        t.yx = beS32(_colr, pos + 4) / 65536.0;
        t.xy = beS32(_colr, pos + 8) / 65536.0;
        t.yy = beS32(_colr, pos + 12) / 65536.0;
        t.dx = beS32(_colr, pos + 16) / 65536.0;
        t.dy = beS32(_colr, pos + 20) / 65536.0;
        return t;
    }

    private void fillSurfaceWithColor(ref ColorSurface surface, RgbaColor color,
        Transform transform)
    {
        foreach (y; 0 .. surface.height)
        {
            foreach (x; 0 .. surface.width)
            {
                double ox, oy;
                transform.apply(x, y, ox, oy);
                surface.composite(cast(int) ox, cast(int) oy, color);
            }
        }
    }

    private void renderLinearGradient(ref ColorSurface surface, size_t paintPos,
        int originX, int originY, int pixelSize, Transform transform)
    {
        const colorLineOffset = be24(_colr, paintPos + 1);
        const x0 = beS16(_colr, paintPos + 4);
        const y0 = beS16(_colr, paintPos + 6);
        const x1 = beS16(_colr, paintPos + 8);
        const y1 = beS16(_colr, paintPos + 10);
        const x2 = beS16(_colr, paintPos + 12);
        const y2 = beS16(_colr, paintPos + 14);
        const colorLinePos = paintPos + colorLineOffset;
        auto stops = readColorLine(colorLinePos);
        if (stops.length < 2) return;
        // Normalize to pixel coordinates.
        const scale = pixelSize / 16384.0;
        const p0x = x0 * scale;
        const p0y = y0 * scale;
        const p1x = x1 * scale;
        const p1y = y1 * scale;
        const p2x = x2 * scale;
        const p2y = y2 * scale;
        // Gradient direction p0 -> p1 projected along p0->p2.
        const vx = p1x - p0x;
        const vy = p1y - p0y;
        const wx = p2x - p0x;
        const wy = p2y - p0y;
        const lenSq = vx * vx + vy * vy;
        if (lenSq <= 0.0) return;
        foreach (y; 0 .. surface.height)
        {
            foreach (x; 0 .. surface.width)
            {
                double ox, oy;
                transform.apply(x, y, ox, oy);
                const qx = ox - p0x;
                const qy = oy - p0y;
                double t = (qx * vx + qy * vy) / lenSq;
                // Adjust t for the p0->p2 rotation point (project onto p0->p2).
                t = (qx * wx + qy * wy) / (wx * wx + wy * wy);
                const color = sampleColorLine(stops, t);
                surface.composite(cast(int) ox, cast(int) oy, color);
            }
        }
    }

    private void renderRadialGradient(ref ColorSurface surface, size_t paintPos,
        int originX, int originY, int pixelSize, Transform transform)
    {
        const colorLineOffset = be24(_colr, paintPos + 1);
        const x0 = beS16(_colr, paintPos + 4);
        const y0 = beS16(_colr, paintPos + 6);
        const r0 = be16(_colr, paintPos + 8);
        const x1 = beS16(_colr, paintPos + 10);
        const y1 = beS16(_colr, paintPos + 12);
        const r1 = be16(_colr, paintPos + 14);
        const colorLinePos = paintPos + colorLineOffset;
        auto stops = readColorLine(colorLinePos);
        if (stops.length < 2) return;
        const scale = pixelSize / 16384.0;
        foreach (y; 0 .. surface.height)
        {
            foreach (x; 0 .. surface.width)
            {
                double ox, oy;
                transform.apply(x, y, ox, oy);
                const px = ox / scale;
                const py = oy / scale;
                const dx = px - x0;
                const dy = py - y0;
                const cx = x1 - x0;
                const cy = y1 - y0;
                const cr = r1 - r0;
                // Solve for w: |D + w*C| = r0 + w*cr
                const a = cx * cx + cy * cy - cr * cr;
                const b = 2 * (dx * cx + dy * cy + r0 * cr);
                const c = dx * dx + dy * dy - r0 * r0;
                double w = 0;
                bool found;
                if (abs(a) > 1e-9)
                {
                    const disc = b * b - 4 * a * c;
                    if (disc >= 0)
                    {
                        const sqrtDisc = sqrt(disc);
                        double w1 = (-b - sqrtDisc) / (2 * a);
                        double w2 = (-b + sqrtDisc) / (2 * a);
                        // Choose the larger root (painting back to front).
                        if (w2 >= w1) { w = w2; found = true; }
                        else { w = w1; found = true; }
                    }
                }
                else if (abs(b) > 1e-9)
                {
                    w = -c / b;
                    found = true;
                }
                if (found)
                {
                    const color = sampleColorLine(stops, w);
                    surface.composite(cast(int) ox, cast(int) oy, color);
                }
            }
        }
    }

    private void renderSweepGradient(ref ColorSurface surface, size_t paintPos,
        int originX, int originY, int pixelSize, Transform transform)
    {
        const colorLineOffset = be24(_colr, paintPos + 1);
        const centerX = beS16(_colr, paintPos + 4);
        const centerY = beS16(_colr, paintPos + 6);
        const startAngle = beS16(_colr, paintPos + 8) / 16384.0 * 180.0;
        const endAngle = beS16(_colr, paintPos + 10) / 16384.0 * 180.0;
        const colorLinePos = paintPos + colorLineOffset;
        auto stops = readColorLine(colorLinePos);
        if (stops.length < 2) return;
        const scale = pixelSize / 16384.0;
        foreach (y; 0 .. surface.height)
        {
            foreach (x; 0 .. surface.width)
            {
                double ox, oy;
                transform.apply(x, y, ox, oy);
                const px = (ox / scale - centerX);
                const py = (oy / scale - centerY);
                double angle = atan2(py, px) * 180.0 / 3.141592653589793;
                // Sweep from startAngle to endAngle.
                const span = endAngle - startAngle;
                double t = (angle - startAngle) / (span > 0 ? span : 360.0);
                if (span < 0) t = (angle - endAngle) / (startAngle - endAngle);
                t = wrap(t);
                const color = sampleColorLine(stops, t);
                surface.composite(cast(int) ox, cast(int) oy, color);
            }
        }
    }

    private static double wrap(double t)
    {
        while (t < 0.0) t += 1.0;
        while (t > 1.0) t -= 1.0;
        return t;
    }

    private struct ColorStop
    {
        double offset;
        RgbaColor color;
    }

    private ColorStop[] readColorLine(size_t pos)
    {
        ColorStop[] result;
        if (pos + 3 > _colr.length) return result;
        const extend = _colr[pos];
        const numStops = be16(_colr, pos + 1);
        size_t cursor = pos + 3;
        foreach (i; 0 .. numStops)
        {
            if (cursor + 6 > _colr.length) break;
            ColorStop stop;
            stop.offset = beS16(_colr, cursor) / 16384.0;
            const paletteIndex = be16(_colr, cursor + 2);
            const alpha = beS16(_colr, cursor + 4);
            stop.color = paletteColor(paletteIndex, alpha);
            result ~= stop;
            cursor += 6;
        }
        // Sort by offset.
        result.sort!((a, b) => a.offset < b.offset);
        return result;
    }

    private RgbaColor sampleColorLine(const(ColorStop)[] stops, double t)
    {
        // PAD extend: clamp t to [0,1].
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
        if (stops.length == 0)
        {
            RgbaColor transparent;
            return transparent;
        }
        if (stops.length == 1) return stops[0].color;
        foreach (i; 0 .. stops.length - 1)
        {
            if (t >= stops[i].offset && t <= stops[i + 1].offset)
            {
                const span = stops[i + 1].offset - stops[i].offset;
                double f = span <= 0.0 ? 0.0 : (t - stops[i].offset) / span;
                return lerpColor(stops[i].color, stops[i + 1].color, f);
            }
        }
        return t < stops[0].offset ? stops[0].color : stops[$ - 1].color;
    }

    private static RgbaColor lerpColor(RgbaColor a, RgbaColor b, double f)
    {
        RgbaColor result;
        result.r = cast(ubyte) (a.r + (b.r - a.r) * f + 0.5);
        result.g = cast(ubyte) (a.g + (b.g - a.g) * f + 0.5);
        result.b = cast(ubyte) (a.b + (b.b - a.b) * f + 0.5);
        result.a = cast(ubyte) (a.a + (b.a - a.a) * f + 0.5);
        return result;
    }

    private size_t baseGlyphPaint(uint glyphID)
    {
        if (!_hasV1 || _baseGlyphListOffset >= _colr.length) return size_t.max;
        const listOffset = _baseGlyphListOffset;
        const numRecords = be32(_colr, listOffset);
        size_t low;
        size_t high = numRecords;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            const entry = listOffset + 4 + middle * 6;
            const id = be16(_colr, entry);
            if (glyphID < id) high = middle;
            else if (glyphID > id) low = middle + 1;
            else return listOffset + be32(_colr, entry + 2);
        }
        return size_t.max;
    }

    private void applyGlyphClip(uint glyphID, int originX, int originY,
        int pixelSize, Transform transform, ref ColorSurface source,
        ref ColorSurface target)
    {
        if (outlineRasterizer is null) return;
        // Rasterize the clip glyph's alpha into a temporary mask, then zero
        // out target pixels where the mask is transparent.
        auto mask = ColorSurface.create(source.width, source.height);
        // Use an opaque white outline; the mask alpha indicates coverage.
        outlineRasterizer(glyphID, originX, originY, mask, 255);
        foreach (y; 0 .. source.height)
        {
            foreach (x; 0 .. source.width)
            {
                const index = (cast(size_t) y * source.width + x) * 4;
                const maskAlpha = mask.pixels[index + 3];
                if (maskAlpha == 0) continue;
                target.pixels[index] = source.pixels[index];
                target.pixels[index + 1] = source.pixels[index + 1];
                target.pixels[index + 2] = source.pixels[index + 2];
                // Scale source alpha by mask coverage.
                const sa = source.pixels[index + 3];
                target.pixels[index + 3] = cast(ubyte) (sa * maskAlpha / 255.0 + 0.5);
            }
        }
    }

    /// Composite source over backdrop into dest using a Porter-Duff/blend mode.
    private void compositeModes(ref ColorSurface dest, ref ColorSurface source,
        ref ColorSurface backdrop, int mode)
    {
        foreach (y; 0 .. dest.height)
        {
            foreach (x; 0 .. dest.width)
            {
                const index = (cast(size_t) y * dest.width + x) * 4;
                RgbaColor src;
                src.r = source.pixels[index];
                src.g = source.pixels[index + 1];
                src.b = source.pixels[index + 2];
                src.a = source.pixels[index + 3];
                RgbaColor bd;
                bd.r = backdrop.pixels[index];
                bd.g = backdrop.pixels[index + 1];
                bd.b = backdrop.pixels[index + 2];
                bd.a = backdrop.pixels[index + 3];
                RgbaColor result = porterDuff(src, bd, mode);
                // Blend onto dest.
                dest.composite(x, y, result);
            }
        }
    }

    private static RgbaColor porterDuff(RgbaColor src, RgbaColor dst, int mode)
    {
        RgbaColor result;
        if (mode == 3) // SRC_OVER
        {
            const sa = src.a / 255.0;
            const da = dst.a / 255.0;
            const outA = sa + da * (1.0 - sa);
            if (outA <= 0) return result;
            result.r = cast(ubyte) ((src.r * sa + dst.r * da * (1.0 - sa)) / outA);
            result.g = cast(ubyte) ((src.g * sa + dst.g * da * (1.0 - sa)) / outA);
            result.b = cast(ubyte) ((src.b * sa + dst.b * da * (1.0 - sa)) / outA);
            result.a = cast(ubyte) (outA * 255.0);
            return result;
        }
        if (mode == 1) // SRC
            return src;
        if (mode == 2) // DST
            return dst;
        if (mode == 0) // CLEAR
            return result;
        if (mode == 12) // PLUS
        {
            result.r = cast(ubyte) (src.r + dst.r > 255 ? 255 : src.r + dst.r);
            result.g = cast(ubyte) (src.g + dst.g > 255 ? 255 : src.g + dst.g);
            result.b = cast(ubyte) (src.b + dst.b > 255 ? 255 : src.b + dst.b);
            result.a = cast(ubyte) (src.a + dst.a > 255 ? 255 : src.a + dst.a);
            return result;
        }
        // Fallback: source-over.
        return porterDuff(src, dst, 3);
    }

    /// Debug: expose the CBDT lookup.
    const(ubyte)[] debugCbdtBitmap(uint glyphID, int pixelSize,
        ref int width, ref int height, ref int bearingX, ref int bearingY)
    {
        return cbdtBitmap(glyphID, pixelSize, width, height, bearingX, bearingY);
    }

    // ------------------------------------------------------------------
    // CBDT / CBLC bitmap color glyphs.
    // ------------------------------------------------------------------

    /// Look up the bitmap data + metrics for a glyph at the closest strike.
    /// Returns the PNG/raw bytes and the horizontal metrics; null if none.
    private const(ubyte)[] cbdtBitmap(uint glyphID, int pixelSize,
        ref int width, ref int height, ref int bearingX, ref int bearingY)
    {
        if (_cblc is null || _cbdt is null) return null;
        if (_cblc.length < 8) return null;
        const numSizes = be32(_cblc, 4);
        size_t cursor = 8;
        // Find the closest strike.
        uint bestPPEM;
        size_t bestSizeOffset;
        foreach (i; 0 .. numSizes)
        {
            if (cursor + 48 > _cblc.length) break;
            const startGlyph = be16(_cblc, cursor + 40);
            const endGlyph = be16(_cblc, cursor + 42);
            const ppemX = _cblc[cursor + 44];
            if (glyphID >= startGlyph && glyphID <= endGlyph)
            {
                if (bestPPEM == 0 || abs(ppemX - pixelSize) < abs(bestPPEM - pixelSize))
                {
                    bestPPEM = ppemX;
                    bestSizeOffset = cursor;
                }
            }
            cursor += 48;
        }
        if (bestPPEM == 0) return null;

        const indexSubtableListOffset = be32(_cblc, bestSizeOffset);
        const numSubtables = be32(_cblc, bestSizeOffset + 8);
        size_t subCursor = indexSubtableListOffset;
        foreach (i; 0 .. numSubtables)
        {
            if (subCursor + 8 > _cblc.length) break;
            const firstGlyph = be16(_cblc, subCursor);
            const lastGlyph = be16(_cblc, subCursor + 2);
            const subtableOffset = be32(_cblc, subCursor + 4);
            if (glyphID >= firstGlyph && glyphID <= lastGlyph)
            {
                const subBase = indexSubtableListOffset + subtableOffset;
                if (subBase + 8 > _cblc.length) return null;
                const indexFormat = be16(_cblc, subBase);
                const imageFormat = be16(_cblc, subBase + 2);
                const imageDataOffset = be32(_cblc, subBase + 4);
                if (imageDataOffset > _cbdt.length) return null;

                // Find the glyph's data slice.
                size_t dataPos;
                size_t dataLen;
                const glyphIndex = cast(uint) (glyphID - firstGlyph);
                if (indexFormat == 1)
                {
                    // sbitOffsets (uint32).
                    const offsets = subBase + 8;
                    const off0 = be32(_cblc, offsets + glyphIndex * 4);
                    const off1 = be32(_cblc, offsets + (glyphIndex + 1) * 4);
                    dataPos = imageDataOffset + off0;
                    dataLen = off1 - off0;
                }
                else if (indexFormat == 2)
                {
                    const imageSize = be32(_cblc, subBase + 8);
                    dataPos = imageDataOffset + cast(size_t) glyphIndex * imageSize;
                    dataLen = imageSize;
                }
                else if (indexFormat == 3)
                {
                    // sbitOffsets (uint16).
                    const offsets = subBase + 8;
                    const off0 = be16(_cblc, offsets + glyphIndex * 2);
                    const off1 = be16(_cblc, offsets + (glyphIndex + 1) * 2);
                    dataPos = imageDataOffset + off0;
                    dataLen = off1 - off0;
                }
                else if (indexFormat == 4)
                {
                    const numGlyphs = be32(_cblc, subBase + 8);
                    const pairs = subBase + 12;
                    foreach (j; 0 .. numGlyphs)
                    {
                        const gid = be16(_cblc, pairs + j * 4);
                        if (gid == glyphID)
                        {
                            const off0 = be16(_cblc, pairs + j * 4 + 2);
                            const off1 = be16(_cblc, pairs + (j + 1) * 4 + 2);
                            dataPos = imageDataOffset + off0;
                            dataLen = off1 - off0;
                            break;
                        }
                    }
                }
                else if (indexFormat == 5)
                {
                    const imageSize = be32(_cblc, subBase + 8);
                    const numGlyphs = be32(_cblc, subBase + 20);
                    const glyphArray = subBase + 24;
                    foreach (j; 0 .. numGlyphs)
                    {
                        if (be16(_cblc, glyphArray + j * 2) == glyphID)
                        {
                            dataPos = imageDataOffset + cast(size_t) j * imageSize;
                            dataLen = imageSize;
                            break;
                        }
                    }
                }
                else
                    return null;

                if (dataLen == 0 || dataPos + dataLen > _cbdt.length) return null;
                return cbdtImageData(imageFormat, _cbdt, dataPos, dataLen,
                    width, height, bearingX, bearingY);
            }
            subCursor += 8;
        }
        return null;
    }

    /// Parse the CBDT glyph data header and return just the image payload.
    private const(ubyte)[] cbdtImageData(ushort imageFormat, const(ubyte)[] cbdt,
        size_t dataPos, size_t dataLen, ref int width, ref int height,
        ref int bearingX, ref int bearingY)
    {
        size_t cursor = dataPos;
        switch (imageFormat)
        {
            case 17: // SmallGlyphMetrics + uint32 dataLen + PNG.
                if (cursor + 5 > dataPos + dataLen) return null;
                height = cbdt[cursor];
                width = cbdt[cursor + 1];
                bearingX = cast(byte) cbdt[cursor + 2];
                bearingY = cast(byte) cbdt[cursor + 3];
                cursor += 5;
                if (cursor + 4 > dataPos + dataLen) return null;
                {
                    const len = be32(cbdt, cursor);
                    cursor += 4;
                    if (cursor + len > dataPos + dataLen) return null;
                    return cbdt[cursor .. cursor + len];
                }
            case 18: // BigGlyphMetrics + uint32 dataLen + PNG.
                if (cursor + 12 > dataPos + dataLen) return null;
                height = cbdt[cursor];
                width = cbdt[cursor + 1];
                bearingX = cast(byte) cbdt[cursor + 2];
                bearingY = cast(byte) cbdt[cursor + 3];
                cursor += 12;
                if (cursor + 4 > dataPos + dataLen) return null;
                {
                    const len = be32(cbdt, cursor);
                    cursor += 4;
                    if (cursor + len > dataPos + dataLen) return null;
                    return cbdt[cursor .. cursor + len];
                }
            case 19: // uint32 dataLen + PNG (metrics from subtable).
                if (cursor + 4 > dataPos + dataLen) return null;
                {
                    const len = be32(cbdt, cursor);
                    cursor += 4;
                    if (cursor + len > dataPos + dataLen) return null;
                    return cbdt[cursor .. cursor + len];
                }
            default:
                return null; // Raw bitmap formats not needed for color emoji.
        }
    }

    // ------------------------------------------------------------------
    // sbix bitmap color glyphs.
    // ------------------------------------------------------------------

    private const(ubyte)[] sbixBitmap(uint glyphID, int pixelSize)
    {
        if (_sbix is null || glyphID >= _numGlyphs) return null;
        if (_sbix.length < 8) return null;
        const numStrikes = be32(_sbix, 4);
        size_t cursor = 8;
        uint bestPPEM;
        size_t bestStrike;
        foreach (i; 0 .. numStrikes)
        {
            if (cursor + 4 > _sbix.length) break;
            const ppem = be16(_sbix, cursor);
            if (bestPPEM == 0 || abs(ppem - pixelSize) < abs(bestPPEM - pixelSize))
            {
                bestPPEM = ppem;
                bestStrike = cursor;
            }
            cursor += 4;
        }
        if (bestPPEM == 0) return null;
        const glyphDataOffset = be32(_sbix, bestStrike + 4);
        const offsetsBase = bestStrike + glyphDataOffset;
        if (offsetsBase + 8 > _sbix.length) return null;
        const off0 = be32(_sbix, offsetsBase + cast(size_t) glyphID * 4);
        const off1 = be32(_sbix, offsetsBase + cast(size_t) (glyphID + 1) * 4);
        if (off1 <= off0) return null;
        const dataPos = offsetsBase + off0;
        if (dataPos + 8 > _sbix.length) return null;
        // originOffsetX, originOffsetY, then graphicType (4 bytes), then payload.
        const graphicType = (be32(_sbix, dataPos + 4) & 0xFFFFFFFF);
        const payload = _sbix[dataPos + 8 .. offsetsBase + off1];
        if (graphicType == 0x706E6720) // "png "
            return payload;
        return null;
    }

    // ------------------------------------------------------------------
    // Table access.
    // ------------------------------------------------------------------

    private const(ubyte)[] table(uint tableTag)
    {
        if (_data.length < 12) return null;
        const count = be16(_data, _faceOffset + 4);
        size_t cursor = _faceOffset + 12;
        foreach (_; 0 .. count)
        {
            if (cursor + 16 > _data.length) break;
            const name = be32(_data, cursor);
            if (name == tableTag)
            {
                const offset = cast(size_t) be32(_data, cursor + 8);
                const length = cast(size_t) be32(_data, cursor + 12);
                if (offset + length <= _data.length)
                    return _data[offset .. offset + length];
                return null;
            }
            cursor += 16;
        }
        return null;
    }

    private void parseColr()
    {
        if (_colr is null || _colr.length < 14) return;
        const tableVersion = be16(_colr, 0);
        if (tableVersion == 0)
        {
            _numBaseGlyphs = be16(_colr, 2);
            _baseGlyphRecordsOffset = be32(_colr, 4);
            _layerRecordsOffset = be32(_colr, 8);
            _numLayers = be16(_colr, 12);
        }
        else if (tableVersion == 1)
        {
            _hasV1 = true;
            _numBaseGlyphs = be16(_colr, 2);
            _baseGlyphRecordsOffset = be32(_colr, 4);
            _layerRecordsOffset = be32(_colr, 8);
            _numLayers = be16(_colr, 12);
            _baseGlyphListOffset = be32(_colr, 14);
            _layerListOffset = be32(_colr, 18);
            _clipListOffset = be32(_colr, 22);
        }
    }

    private void parseCpal()
    {
        if (_cpal is null || _cpal.length < 14) return;
        const tableVersion = be16(_cpal, 0);
        _numPaletteEntries = be16(_cpal, 2);
        _numPalettes = be16(_cpal, 4);
        _numColorRecords = be16(_cpal, 6);
        _colorRecordsArrayOffset = be32(_cpal, 8);
    }
}

unittest
{
    // Empty data: no color font.
    auto renderer = new ColrRenderer(cast(immutable(ubyte)[]) [], 0);
    assert(!renderer.isColorFont());
    assert(!renderer.hasGlyph(0));
}
