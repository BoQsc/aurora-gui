module aurora.text.truetype;

/**
 * Small dependency-free sfnt outline reader and antialiased rasterizer.
 *
 * Supported outlines: sfnt/TTC faces containing either `glyf` + `loca` or
 * static CFF1, Unicode cmap formats 4/12, horizontal metrics, composite
 * glyphs, and legacy horizontal `kern` format 0. OpenType shaping lives in
 * `aurora.text.opentype`; CFF2 variable outlines remain unsupported.
 */

import aurora.text.cff : CffFace;
import aurora.text.hinter : TrueTypeHinter, HintInput, HintedGlyph;
import aurora.text.variations : FontVariations;
import aurora.text.colr : ColrRenderer, ColorSurface, RgbaColor;
import std.algorithm : min, max;
import std.exception : enforce;
import std.file : read;
import std.math : abs, ceil, floor, sqrt;

private enum uint tag(string value) =
    (cast(uint) value[0] << 24) | (cast(uint) value[1] << 16) |
    (cast(uint) value[2] << 8) | cast(uint) value[3];

private ushort be16(const(ubyte)[] data, size_t offset)
{
    enforce(offset + 2 <= data.length, "Truncated TrueType data");
    return cast(ushort) ((cast(uint) data[offset] << 8) | data[offset + 1]);
}

private short beS16(const(ubyte)[] data, size_t offset)
{
    return cast(short) be16(data, offset);
}

private uint be32(const(ubyte)[] data, size_t offset)
{
    enforce(offset + 4 <= data.length, "Truncated TrueType data");
    return (cast(uint) data[offset] << 24) | (cast(uint) data[offset + 1] << 16) |
        (cast(uint) data[offset + 2] << 8) | cast(uint) data[offset + 3];
}

private int beS32(const(ubyte)[] data, size_t offset)
{
    return cast(int) be32(data, offset);
}

private double f2dot14(const(ubyte)[] data, size_t offset)
{
    return cast(double) beS16(data, offset) / 16384.0;
}

private struct Table
{
    size_t offset;
    size_t length;
}

public import aurora.text.glyph : GlyphBitmap;

private struct OutlinePoint
{
    double x;
    double y;
    bool onCurve;
}

private struct Edge
{
    double x0;
    double y0;
    double x1;
    double y1;
}

/** Parsed TrueType face. The source bytes remain owned by this object. */
final class TrueTypeFace
{
    private immutable(ubyte)[] _data;
    private size_t _faceOffset;
    private Table[uint] _tables;
    private ushort _unitsPerEm;
    private short _ascender;
    private short _descender;
    private short _lineGap;
    private ushort _numGlyphs;
    private ushort _numberOfHMetrics;
    private short _locaFormat;
    private Table _cmap;
    private size_t _cmapSubtable;
    private ushort _cmapFormat;
    private int[ulong] _kernPairs;
    private CffFace _cff;
    private bool _glyfOutlines;
    private string _sourcePath;
    private TrueTypeHinter _hinter;
    private FontVariations _variations;
    private ColrRenderer _colr;

    static TrueTypeFace load(string path, uint faceIndex = 0)
    {
        auto bytes = cast(ubyte[]) read(path);
        enforce(bytes.length >= 12, "Font file is too small: " ~ path);
        auto result = new TrueTypeFace(cast(immutable(ubyte)[]) bytes, path, faceIndex);
        return result;
    }

    private this(immutable(ubyte)[] bytes, string sourcePath, uint faceIndex)
    {
        _data = bytes;
        _sourcePath = sourcePath;
        parse(faceIndex);
    }

    string sourcePath() const @safe pure nothrow { return _sourcePath; }
    int unitsPerEm() const @safe pure nothrow @nogc { return _unitsPerEm; }
    int ascenderUnits() const @safe pure nothrow @nogc { return _ascender; }
    int descenderUnits() const @safe pure nothrow @nogc { return _descender; }
    int lineGapUnits() const @safe pure nothrow @nogc { return _lineGap; }
    int glyphCount() const @safe pure nothrow @nogc { return _numGlyphs; }
    bool hasTrueTypeOutlines() const @safe pure nothrow @nogc { return _glyfOutlines; }
    bool hasCffOutlines() const @safe pure nothrow @nogc { return _cff !is null; }

    /** Return an sfnt table by its big-endian four-byte tag, or an empty slice. */
    const(ubyte)[] tableData(uint tableTag) const
    {
        const found = tableTag in _tables;
        if (found is null) return null;
        return _data[found.offset .. found.offset + found.length];
    }

    bool hasTable(uint tableTag) const @safe pure nothrow @nogc
    {
        return (tableTag in _tables) !is null;
    }

    int ascent(int pixelSize) const @safe pure nothrow @nogc
    {
        return cast(int) ceil(cast(double) _ascender * scaleFor(pixelSize));
    }

    int descent(int pixelSize) const @safe pure nothrow @nogc
    {
        return cast(int) ceil(cast(double) -_descender * scaleFor(pixelSize));
    }

    int lineHeight(int pixelSize) const @safe pure nothrow @nogc
    {
        const value = cast(double) (_ascender - _descender + _lineGap) * scaleFor(pixelSize);
        return max(1, cast(int) ceil(value));
    }

    uint glyphIndex(dchar codepoint) const
    {
        if (_cmapFormat == 12)
            return glyphIndexFormat12(cast(uint) codepoint);
        if (_cmapFormat == 4)
            return glyphIndexFormat4(cast(uint) codepoint);
        return 0;
    }

    int advance(uint glyph, int pixelSize) const
    {
        return max(0, scaleUnits(cast(int) advanceUnits(glyph), pixelSize));
    }

    int scaleUnits(int value, int pixelSize) const @safe pure nothrow @nogc
    {
        const scaled = cast(double) value * scaleFor(pixelSize);
        return cast(int) (scaled >= 0.0 ? floor(scaled + 0.5) : ceil(scaled - 0.5));
    }

    int kerning(uint leftGlyph, uint rightGlyph, int pixelSize) const
    {
        const key = (cast(ulong) leftGlyph << 32) | rightGlyph;
        const found = key in _kernPairs;
        if (found is null) return 0;
        const scaled = cast(double) *found * scaleFor(pixelSize);
        return cast(int) (scaled >= 0.0 ? floor(scaled + 0.5) : ceil(scaled - 0.5));
    }

    GlyphBitmap rasterize(uint glyph, int pixelSize, int supersample = 4) const
    {
        GlyphBitmap bitmap;
        bitmap.glyphIndex = glyph;
        bitmap.advance = advance(glyph, pixelSize);
        if (glyph >= _numGlyphs || pixelSize <= 0)
            return bitmap;
        if (_cff !is null)
            return _cff.rasterize(glyph, pixelSize, bitmap.advance, supersample);
        OutlinePoint[][] contours;
        loadGlyphContours(glyph, contours, 0);
        if (contours.length == 0)
            return bitmap;

        // Gather raw design-unit points, contours, and the glyph instructions.
        int[] rawXs;
        int[] rawYs;
        bool[] rawOnCurve;
        int[] contourEnds;
        int pointCount;
        foreach (contour; contours)
        {
            foreach (point; contour)
            {
                rawXs ~= cast(int) point.x;
                rawYs ~= cast(int) point.y;
                rawOnCurve ~= point.onCurve;
                ++pointCount;
            }
            contourEnds ~= pointCount - 1;
        }

        const(ubyte)[] glyphIns;
        if (_hinter !is null)
            glyphIns = glyphInstructions(glyph);

        // Apply variable-font deltas to the outline (design units).
        int[] deltasXs = rawXs;
        int[] deltasYs = rawYs;
        if (_variations !is null && _variations.hasVariations())
        {
            try
            {
                (cast() _variations).applyGlyphDeltas(glyph, deltasXs, deltasYs);
            }
            catch (Exception)
            {
                // Ignore malformed variation data.
            }
        }

        // Hint the outline (design units in, design units out). Any hinting
        // failure falls back to the raw outline so glyphs never blank.
        int[] fitXs = deltasXs;
        int[] fitYs = deltasYs;
        int fitLsb = advanceUnits(glyph);
        int fitAdvance = advanceUnits(glyph);
        if (_variations !is null && _variations.hasVariations())
        {
            try
            {
                fitAdvance = (cast() _variations).adjustAdvance(glyph, fitAdvance);
            }
            catch (Exception)
            {
            }
        }
        if (_hinter !is null && glyphIns.length > 0)
        {
            try
            {
                HintInput input;
                input.instructions = glyphIns;
                input.xs = deltasXs;
                input.ys = deltasYs;
                input.onCurve = rawOnCurve;
                input.contours = contourEnds;
                input.unitsPerEm = _unitsPerEm;
                input.pixelSize = pixelSize;
                input.lsb = leftSideBearing(glyph);
                input.advance = fitAdvance;
                input.tsb = topSideBearing(glyph);
                input.vadvance = verticalAdvance(glyph);
                input.fpgm = tableData(tag!"fpgm");
                input.prep = tableData(tag!"prep");
                input.normalizedAxes = variationsNormalizedAxes();
                auto fitted = (cast() _hinter).hint(input);
                fitXs = fitted.xs;
                fitYs = fitted.ys;
                fitLsb = fitted.lsb;
                fitAdvance = fitted.advance;
                bitmap.advance = max(0, scaleUnits(fitAdvance, pixelSize));
            }
            catch (Exception)
            {
                // Fall through to the unhinted outline.
            }
        }

        const scale = scaleFor(pixelSize);
        double minX = double.infinity;
        double minY = double.infinity;
        double maxX = -double.infinity;
        double maxY = -double.infinity;
        foreach (i; 0 .. fitXs.length)
        {
            const px = fitXs[i] * scale;
            const py = fitYs[i] * scale;
            minX = min(minX, px);
            minY = min(minY, py);
            maxX = max(maxX, px);
            maxY = max(maxY, py);
        }
        if (minX == double.infinity)
            return bitmap;

        bitmap.bearingX = cast(int) floor(minX);
        bitmap.bearingY = cast(int) ceil(maxY);
        const right = cast(int) ceil(maxX);
        const bottom = cast(int) floor(minY);
        bitmap.width = max(0, right - bitmap.bearingX);
        bitmap.height = max(0, bitmap.bearingY - bottom);
        if (bitmap.width <= 0 || bitmap.height <= 0)
            return bitmap;

        Edge[] edges;
        // Rebuild contour points from the fitted coordinates.
        {
            int first;
            foreach (endPoint; contourEnds)
            {
                const last = endPoint;
                OutlinePoint[] contour;
                contour.length = last - first + 1;
                foreach (local; 0 .. contour.length)
                {
                    const index = first + local;
                    OutlinePoint point;
                    point.x = fitXs[index];
                    point.y = fitYs[index];
                    point.onCurve = rawOnCurve[index];
                    contour[local] = point;
                }
                flattenContour(contour, scale, bitmap.bearingX, bitmap.bearingY, edges);
                first = last + 1;
            }
        }
        if (edges.length == 0)
            return bitmap;

        supersample = supersample < 1 ? 1 : (supersample > 8 ? 8 : supersample);
        bitmap.alpha.length = cast(size_t) bitmap.width * cast(size_t) bitmap.height;
        const samples = supersample * supersample;
        foreach (y; 0 .. bitmap.height)
        {
            foreach (x; 0 .. bitmap.width)
            {
                int insideCount;
                foreach (sy; 0 .. supersample)
                {
                    const py = y + (cast(double) sy + 0.5) / supersample;
                    foreach (sx; 0 .. supersample)
                    {
                        const px = x + (cast(double) sx + 0.5) / supersample;
                        if (insideNonZero(edges, px, py))
                            ++insideCount;
                    }
                }
                bitmap.alpha[cast(size_t) y * cast(size_t) bitmap.width + x] =
                    cast(ubyte) ((insideCount * 255 + samples / 2) / samples);
            }
        }
        return bitmap;
    }

    private double scaleFor(int pixelSize) const @safe pure nothrow @nogc
    {
        return cast(double) max(1, pixelSize) / max(1, cast(int) _unitsPerEm);
    }

    private void parse(uint faceIndex)
    {
        _faceOffset = 0;
        if (_data.length >= 12 && be32(_data, 0) == tag!"ttcf")
        {
            const count = be32(_data, 8);
            enforce(faceIndex < count, "TrueType collection face index is out of range");
            _faceOffset = be32(_data, 12 + cast(size_t) faceIndex * 4);
        }
        parseDirectory();

        const head = requiredTable(tag!"head");
        const hhea = requiredTable(tag!"hhea");
        const maxp = requiredTable(tag!"maxp");
        requiredTable(tag!"hmtx");
        _cmap = requiredTable(tag!"cmap");

        _unitsPerEm = be16(_data, head.offset + 18);
        _locaFormat = beS16(_data, head.offset + 50);
        _ascender = beS16(_data, hhea.offset + 4);
        _descender = beS16(_data, hhea.offset + 6);
        _lineGap = beS16(_data, hhea.offset + 8);
        _numberOfHMetrics = be16(_data, hhea.offset + 34);
        _numGlyphs = be16(_data, maxp.offset + 4);
        enforce(_unitsPerEm > 0 && _numGlyphs > 0, "Invalid OpenType face metrics");

        const glyf = tag!"glyf" in _tables;
        const loca = tag!"loca" in _tables;
        const cff = tag!"CFF " in _tables;
        if (glyf !is null && loca !is null)
            _glyfOutlines = true;
        else if (cff !is null)
            _cff = new CffFace(_data[cff.offset .. cff.offset + cff.length],
                _unitsPerEm, _numGlyphs);
        else if ((tag!"CFF2" in _tables) !is null)
            throw new Exception("CFF2 variable outlines are not supported yet");
        else
            throw new Exception("Font has neither glyf/loca nor static CFF outlines");

        chooseCmap();
        parseKerning();
        if (_glyfOutlines)
            _hinter = new TrueTypeHinter(_data, _faceOffset);
        try
        {
            _variations = new FontVariations(_data, _faceOffset);
        }
        catch (Exception)
        {
            // Variations are optional.
        }
        try
        {
            _colr = new ColrRenderer(_data, _faceOffset);
            if (_colr.isColorFont())
            {
                _colr.outlineRasterizer = &rasterizeOutlineIntoSurface;
                _colr.layerGlyphRenderer = &rasterizeLayerGlyph;
            }
        }
        catch (Exception)
        {
            // Color glyphs are optional.
        }
    }

    /// The font's variable-font handler, or null when static.
    FontVariations variations()
    {
        return _variations;
    }

    /// Set design-space coordinates (F16DOT16 per axis); returns true if changed.
    bool setVariationCoords(long[] coords)
    {
        if (_variations is null) return false;
        return _variations.setDesignCoords(coords);
    }

    /** Hash of the current variable-font coordinates (0 when static). */
    uint variationHash() const
    {
        if (_variations is null || !_variations.hasVariations()) return 0;
        uint hash = 1469598103934665603UL & 0xFFFFFFFF;
        foreach (value; _variations.normalizedCoords())
        {
            hash ^= cast(uint) value;
            hash = hash * 16777619;
        }
        return hash;
    }

    /// Debug: apply gvar deltas to a caller-supplied outline; returns changed.
    bool debugApplyDeltas(uint glyph, ref int[] xs, ref int[] ys)
    {
        if (_variations is null || !_variations.hasVariations()) return false;
        try { return _variations.applyGlyphDeltas(glyph, xs, ys); }
        catch (Exception) { return false; }
    }

    private void parseDirectory()
    {
        enforce(_faceOffset + 12 <= _data.length, "Truncated TrueType offset table");
        const signature = be32(_data, _faceOffset);
        enforce(signature == 0x00010000 || signature == tag!"true" || signature == tag!"typ1" ||
                signature == tag!"OTTO", "Unsupported sfnt signature");
        const tableCount = be16(_data, _faceOffset + 4);
        size_t cursor = _faceOffset + 12;
        foreach (_; 0 .. tableCount)
        {
            enforce(cursor + 16 <= _data.length, "Truncated TrueType table directory");
            const name = be32(_data, cursor);
            const offset = cast(size_t) be32(_data, cursor + 8);
            const length = cast(size_t) be32(_data, cursor + 12);
            enforce(offset <= _data.length && length <= _data.length - offset,
                "TrueType table extends beyond the file");
            _tables[name] = Table(offset, length);
            cursor += 16;
        }
    }

    private Table requiredTable(uint name) const
    {
        const result = name in _tables;
        enforce(result !is null, "Font is missing a required TrueType outline table");
        return *result;
    }

    private void chooseCmap()
    {
        enforce(_cmap.length >= 4, "Invalid cmap table");
        const count = be16(_data, _cmap.offset + 2);
        size_t chosen4;
        size_t chosen12;
        foreach (index; 0 .. count)
        {
            const record = _cmap.offset + 4 + cast(size_t) index * 8;
            enforce(record + 8 <= _cmap.offset + _cmap.length, "Truncated cmap encoding record");
            const platform = be16(_data, record);
            const encoding = be16(_data, record + 2);
            const relative = be32(_data, record + 4);
            const subtable = _cmap.offset + relative;
            if (subtable + 2 > _data.length) continue;
            const format = be16(_data, subtable);
            const unicode = platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10));
            if (!unicode) continue;
            if (format == 12 && chosen12 == 0) chosen12 = subtable;
            if (format == 4 && chosen4 == 0) chosen4 = subtable;
        }
        if (chosen12 != 0)
        {
            _cmapSubtable = chosen12;
            _cmapFormat = 12;
        }
        else if (chosen4 != 0)
        {
            _cmapSubtable = chosen4;
            _cmapFormat = 4;
        }
        else
            throw new Exception("Font has no supported Unicode cmap (format 4 or 12)");
    }

    private uint glyphIndexFormat12(uint codepoint) const
    {
        const offset = _cmapSubtable;
        const groupCount = be32(_data, offset + 12);
        size_t low;
        size_t high = groupCount;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            const entry = offset + 16 + middle * 12;
            const start = be32(_data, entry);
            const end = be32(_data, entry + 4);
            if (codepoint < start)
                high = middle;
            else if (codepoint > end)
                low = middle + 1;
            else
                return be32(_data, entry + 8) + (codepoint - start);
        }
        return 0;
    }

    private uint glyphIndexFormat4(uint codepoint) const
    {
        if (codepoint > 0xffff) return 0;
        const offset = _cmapSubtable;
        const segCount = be16(_data, offset + 6) / 2;
        const endCodes = offset + 14;
        const startCodes = endCodes + cast(size_t) segCount * 2 + 2;
        const idDeltas = startCodes + cast(size_t) segCount * 2;
        const idRangeOffsets = idDeltas + cast(size_t) segCount * 2;
        foreach (segment; 0 .. segCount)
        {
            const end = be16(_data, endCodes + cast(size_t) segment * 2);
            if (codepoint > end) continue;
            const start = be16(_data, startCodes + cast(size_t) segment * 2);
            if (codepoint < start) return 0;
            const delta = beS16(_data, idDeltas + cast(size_t) segment * 2);
            const rangeOffsetPosition = idRangeOffsets + cast(size_t) segment * 2;
            const rangeOffset = be16(_data, rangeOffsetPosition);
            if (rangeOffset == 0)
                return cast(ushort) (codepoint + delta);
            const glyphAddress = rangeOffsetPosition + rangeOffset +
                cast(size_t) (codepoint - start) * 2;
            if (glyphAddress + 2 > _data.length) return 0;
            uint glyph = be16(_data, glyphAddress);
            if (glyph != 0) glyph = cast(ushort) (glyph + delta);
            return glyph;
        }
        return 0;
    }

    private uint advanceUnits(uint glyph) const
    {
        const hmtx = requiredTable(tag!"hmtx");
        const metricCount = max(1, cast(int) _numberOfHMetrics);
        const metric = min(cast(uint) metricCount - 1, glyph);
        const offset = hmtx.offset + cast(size_t) metric * 4;
        if (offset + 2 > hmtx.offset + hmtx.length) return _unitsPerEm / 2;
        return be16(_data, offset);
    }

    private int[] variationsNormalizedAxes() const
    {
        int[] result;
        if (_variations is null) return result;
        foreach (value; _variations.normalizedCoords())
            result ~= cast(int) (value >> 2); // 16.16 -> 2.14
        return result;
    }

    /// Whether this face has color (COLR) glyph definitions.
    bool hasColorGlyphs() const @safe pure nothrow @nogc
    {
        return _colr !is null && _colr.isColorFont();
    }

    /// Whether a specific glyph has a COLR color definition.
    bool isColorGlyph(uint glyph) const
    {
        if (_colr is null || !_colr.isColorFont()) return false;
        return (cast() _colr).hasGlyph(glyph);
    }

    /// Rasterize a COLR color glyph into an RGBA buffer at the given size.
    /// Returns true when a color glyph was drawn; the buffer is sized size*size.
    bool rasterizeColorGlyph(uint glyph, int pixelSize, ref ubyte[] rgba) const
    {
        if (_colr is null || !_colr.isColorFont()) return false;
        auto surface = ColorSurface.create(pixelSize, pixelSize);
        bool drew = (cast() _colr).render(glyph, surface, 0, 0, pixelSize);
        rgba = surface.pixels.dup;
        return drew;
    }

    /// Rasterize a glyph outline's alpha into a ColorSurface (COLR layer).
    private void rasterizeOutlineIntoSurface(uint glyphID, int x, int y,
        ref ColorSurface surface, ubyte alpha)
    {
        // Render the glyph outline as a mask, then apply it with the alpha.
        if (glyphID >= _numGlyphs) return;
        auto bitmap = rasterize(glyphID, max(1, surface.height), 1);
        if (bitmap.empty()) return;
        foreach (py; 0 .. bitmap.height)
        {
            const sy = y - bitmap.height + bitmap.bearingY + py;
            if (sy < 0 || sy >= surface.height) continue;
            foreach (px; 0 .. bitmap.width)
            {
                const sx = x + bitmap.bearingX + px;
                if (sx < 0 || sx >= surface.width) continue;
                const coverage = bitmap.alpha[cast(size_t) py * bitmap.width + px];
                if (coverage == 0) continue;
                const combined = cast(ubyte) (coverage * alpha / 255);
                RgbaColor color;
                color.r = 255; color.g = 255; color.b = 255;
                color.a = combined;
                surface.composite(sx, sy, color);
            }
        }
    }

    /// Render a COLR layer glyph (outline or bitmap) with its palette color.
    private void rasterizeLayerGlyph(uint glyphID, int x, int y,
        ref ColorSurface surface, int pixelSize, RgbaColor color)
    {
        if (glyphID >= _numGlyphs) return;
        auto bitmap = rasterize(glyphID, max(1, pixelSize), 1);
        if (bitmap.empty()) return;
        foreach (py; 0 .. bitmap.height)
        {
            const sy = y - bitmap.height + bitmap.bearingY + py;
            if (sy < 0 || sy >= surface.height) continue;
            foreach (px; 0 .. bitmap.width)
            {
                const sx = x + bitmap.bearingX + px;
                if (sx < 0 || sx >= surface.width) continue;
                const coverage = bitmap.alpha[cast(size_t) py * bitmap.width + px];
                if (coverage == 0) continue;
                RgbaColor tinted;
                const f = coverage / 255.0;
                tinted.r = cast(ubyte) (color.r * f + 0.5);
                tinted.g = cast(ubyte) (color.g * f + 0.5);
                tinted.b = cast(ubyte) (color.b * f + 0.5);
                tinted.a = cast(ubyte) (color.a * f + 0.5);
                surface.composite(sx, sy, tinted);
            }
        }
    }

    private int leftSideBearing(uint glyph) const
    {
        const hmtx = requiredTable(tag!"hmtx");
        const metricCount = max(1, cast(int) _numberOfHMetrics);
        const metric = min(cast(uint) metricCount - 1, glyph);
        const offset = hmtx.offset + cast(size_t) metric * 4;
        if (offset + 4 > hmtx.offset + hmtx.length) return 0;
        if (glyph < cast(uint) metricCount)
            return beS16(_data, offset + 2);
        // The lsb array follows the metrics.
        const lsbOffset = hmtx.offset + cast(size_t) metricCount * 4 +
            cast(size_t) (glyph - cast(uint) metricCount) * 2;
        if (lsbOffset + 2 > hmtx.offset + hmtx.length) return 0;
        return beS16(_data, lsbOffset);
    }

    private int topSideBearing(uint glyph) const
    {
        const vmtx = tag!"vmtx" in _tables;
        if (vmtx is null) return 0;
        const metricCount = max(1, cast(int) _numberOfHMetrics);
        const metric = min(cast(uint) metricCount - 1, glyph);
        const offset = vmtx.offset + cast(size_t) metric * 4;
        if (offset + 4 > vmtx.offset + vmtx.length) return 0;
        if (glyph < cast(uint) metricCount)
            return beS16(_data, offset + 2);
        const lsbOffset = vmtx.offset + cast(size_t) metricCount * 4 +
            cast(size_t) (glyph - cast(uint) metricCount) * 2;
        if (lsbOffset + 2 > vmtx.offset + vmtx.length) return 0;
        return beS16(_data, lsbOffset);
    }

    private int verticalAdvance(uint glyph) const
    {
        const vmtx = tag!"vmtx" in _tables;
        if (vmtx is null) return _unitsPerEm / 2;
        const metricCount = max(1, cast(int) _numberOfHMetrics);
        const metric = min(cast(uint) metricCount - 1, glyph);
        const offset = vmtx.offset + cast(size_t) metric * 4;
        if (offset + 2 > vmtx.offset + vmtx.length) return _unitsPerEm / 2;
        return be16(_data, offset);
    }

    private void parseKerning()
    {
        const kernPointer = tag!"kern" in _tables;
        if (kernPointer is null || kernPointer.length < 4) return;
        const kern = *kernPointer;
        size_t cursor = kern.offset;
        const kernVersion = be16(_data, cursor);
        if (kernVersion != 0) return;
        const tableCount = be16(_data, cursor + 2);
        cursor += 4;
        foreach (_; 0 .. tableCount)
        {
            if (cursor + 6 > kern.offset + kern.length) break;
            const length = be16(_data, cursor + 2);
            const coverage = be16(_data, cursor + 4);
            if (length < 6 || cursor + length > kern.offset + kern.length) break;
            const format = coverage >> 8;
            const horizontal = (coverage & 1) != 0;
            const crossStream = (coverage & 4) != 0;
            if (format == 0 && horizontal && !crossStream && length >= 14)
            {
                const pairCount = be16(_data, cursor + 6);
                size_t pair = cursor + 14;
                foreach (__; 0 .. pairCount)
                {
                    if (pair + 6 > cursor + length) break;
                    const left = be16(_data, pair);
                    const right = be16(_data, pair + 2);
                    const value = beS16(_data, pair + 4);
                    _kernPairs[(cast(ulong) left << 32) | right] = value;
                    pair += 6;
                }
            }
            cursor += length;
        }
    }

    private size_t glyphOffset(uint glyph) const
    {
        const loca = requiredTable(tag!"loca");
        if (_locaFormat == 0)
            return cast(size_t) be16(_data, loca.offset + cast(size_t) glyph * 2) * 2;
        return be32(_data, loca.offset + cast(size_t) glyph * 4);
    }

    /// Extract the bytecode program for one glyph (empty when absent).
    private const(ubyte)[] glyphInstructions(uint glyph) const
    {
        if (glyph >= _numGlyphs) return null;
        const glyf = requiredTable(tag!"glyf");
        const relativeStart = glyphOffset(glyph);
        const relativeEnd = glyphOffset(glyph + 1);
        if (relativeEnd <= relativeStart || relativeEnd > glyf.length) return null;
        const start = glyf.offset + relativeStart;
        const contourCount = beS16(_data, start);
        if (contourCount < 0)
        {
            // Composite glyph: instructions may appear after the components.
            return compositeInstructions(start);
        }
        if (contourCount == 0) return null;
        size_t cursor = start + 10;
        foreach (_; 0 .. contourCount)
        {
            if (cursor + 2 > _data.length) return null;
            cursor += 2;
        }
        if (cursor + 2 > _data.length) return null;
        const instructionLength = be16(_data, cursor);
        cursor += 2;
        if (cursor + instructionLength > _data.length) return null;
        return _data[cursor .. cursor + cast(size_t) instructionLength];
    }

    private const(ubyte)[] compositeInstructions(size_t start) const
    {
        enum ushort ArgWords = 0x0001;
        enum ushort MoreComponents = 0x0020;
        enum ushort HaveInstructions = 0x0100;
        size_t cursor = start + 10;
        ushort flags;
        do
        {
            if (cursor + 4 > _data.length) return null;
            flags = be16(_data, cursor);
            cursor += 4;
            const argumentsAreXY = (flags & 0x0002) != 0;
            if ((flags & ArgWords) != 0)
                cursor += 4;
            else
                cursor += 2;
            if ((flags & 0x0008) != 0)
                cursor += 2;
            else if ((flags & 0x0040) != 0)
                cursor += 4;
            else if ((flags & 0x0080) != 0)
                cursor += 8;
        }
        while ((flags & MoreComponents) != 0);
        if ((flags & HaveInstructions) != 0)
        {
            if (cursor + 2 > _data.length) return null;
            const instructionLength = be16(_data, cursor);
            cursor += 2;
            if (cursor + instructionLength > _data.length) return null;
            return _data[cursor .. cursor + cast(size_t) instructionLength];
        }
        return null;
    }

    private void loadGlyphContours(uint glyph, ref OutlinePoint[][] output, int depth) const
    {
        if (glyph >= _numGlyphs || depth > 12) return;
        const glyf = requiredTable(tag!"glyf");
        const relativeStart = glyphOffset(glyph);
        const relativeEnd = glyphOffset(glyph + 1);
        if (relativeEnd <= relativeStart || relativeEnd > glyf.length) return;
        const start = glyf.offset + relativeStart;
        const contourCount = beS16(_data, start);
        if (contourCount >= 0)
            loadSimpleGlyph(start, contourCount, output);
        else
            loadCompositeGlyph(start, output, depth);
    }

    private void loadSimpleGlyph(size_t start, int contourCount, ref OutlinePoint[][] output) const
    {
        if (contourCount == 0) return;
        size_t cursor = start + 10;
        ushort[] endPoints;
        endPoints.length = contourCount;
        foreach (index; 0 .. contourCount)
        {
            endPoints[index] = be16(_data, cursor);
            cursor += 2;
        }
        const pointCount = cast(int) endPoints[$ - 1] + 1;
        const instructionLength = be16(_data, cursor);
        cursor += 2 + instructionLength;
        enforce(cursor <= _data.length, "Truncated TrueType glyph instructions");

        ubyte[] flags;
        flags.reserve(pointCount);
        while (flags.length < pointCount)
        {
            enforce(cursor < _data.length, "Truncated TrueType glyph flags");
            const value = _data[cursor++];
            flags ~= value;
            if ((value & 0x08) != 0)
            {
                enforce(cursor < _data.length, "Truncated TrueType repeat flag");
                const repeat = _data[cursor++];
                foreach (_; 0 .. repeat) flags ~= value;
            }
        }
        enforce(flags.length == pointCount, "Invalid TrueType glyph point count");

        int[] xs;
        int[] ys;
        xs.length = pointCount;
        ys.length = pointCount;
        int coordinate;
        foreach (index; 0 .. pointCount)
        {
            const flag = flags[index];
            if ((flag & 0x02) != 0)
            {
                enforce(cursor < _data.length, "Truncated TrueType x coordinate");
                const delta = _data[cursor++];
                coordinate += (flag & 0x10) != 0 ? delta : -cast(int) delta;
            }
            else if ((flag & 0x10) == 0)
            {
                coordinate += beS16(_data, cursor);
                cursor += 2;
            }
            xs[index] = coordinate;
        }
        coordinate = 0;
        foreach (index; 0 .. pointCount)
        {
            const flag = flags[index];
            if ((flag & 0x04) != 0)
            {
                enforce(cursor < _data.length, "Truncated TrueType y coordinate");
                const delta = _data[cursor++];
                coordinate += (flag & 0x20) != 0 ? delta : -cast(int) delta;
            }
            else if ((flag & 0x20) == 0)
            {
                coordinate += beS16(_data, cursor);
                cursor += 2;
            }
            ys[index] = coordinate;
        }

        int first;
        foreach (endPoint; endPoints)
        {
            const last = cast(int) endPoint;
            OutlinePoint[] contour;
            contour.length = last - first + 1;
            foreach (local; 0 .. contour.length)
            {
                const index = first + cast(int) local;
                contour[local] = OutlinePoint(xs[index], ys[index], (flags[index] & 1) != 0);
            }
            output ~= contour;
            first = last + 1;
        }
    }

    private void loadCompositeGlyph(size_t start, ref OutlinePoint[][] output, int depth) const
    {
        enum ushort ArgWords = 0x0001;
        enum ushort ArgsAreXY = 0x0002;
        enum ushort RoundXYToGrid = 0x0004;
        enum ushort HaveScale = 0x0008;
        enum ushort MoreComponents = 0x0020;
        enum ushort HaveXYScale = 0x0040;
        enum ushort HaveTwoByTwo = 0x0080;
        enum ushort HaveInstructions = 0x0100;
        enum ushort ScaledComponentOffset = 0x0800;

        size_t cursor = start + 10;
        ushort flags;
        do
        {
            enforce(cursor + 4 <= _data.length, "Truncated composite glyph component");
            flags = be16(_data, cursor);
            const componentGlyph = be16(_data, cursor + 2);
            cursor += 4;

            int arg1;
            int arg2;
            const argumentsAreXY = (flags & ArgsAreXY) != 0;
            if ((flags & ArgWords) != 0)
            {
                enforce(cursor + 4 <= _data.length, "Truncated composite glyph arguments");
                if (argumentsAreXY)
                {
                    arg1 = beS16(_data, cursor);
                    arg2 = beS16(_data, cursor + 2);
                }
                else
                {
                    arg1 = be16(_data, cursor);
                    arg2 = be16(_data, cursor + 2);
                }
                cursor += 4;
            }
            else
            {
                enforce(cursor + 2 <= _data.length, "Truncated composite glyph arguments");
                if (argumentsAreXY)
                {
                    arg1 = cast(byte) _data[cursor];
                    arg2 = cast(byte) _data[cursor + 1];
                }
                else
                {
                    arg1 = _data[cursor];
                    arg2 = _data[cursor + 1];
                }
                cursor += 2;
            }

            double xx = 1.0;
            double xy = 0.0;
            double yx = 0.0;
            double yy = 1.0;
            if ((flags & HaveScale) != 0)
            {
                enforce(cursor + 2 <= _data.length, "Truncated composite glyph scale");
                xx = yy = f2dot14(_data, cursor);
                cursor += 2;
            }
            else if ((flags & HaveXYScale) != 0)
            {
                enforce(cursor + 4 <= _data.length, "Truncated composite glyph XY scale");
                xx = f2dot14(_data, cursor);
                yy = f2dot14(_data, cursor + 2);
                cursor += 4;
            }
            else if ((flags & HaveTwoByTwo) != 0)
            {
                enforce(cursor + 8 <= _data.length, "Truncated composite glyph transform");
                xx = f2dot14(_data, cursor);
                xy = f2dot14(_data, cursor + 2);
                yx = f2dot14(_data, cursor + 4);
                yy = f2dot14(_data, cursor + 6);
                cursor += 8;
            }

            OutlinePoint[][] component;
            loadGlyphContours(componentGlyph, component, depth + 1);
            foreach (contour; component)
                foreach (ref point; contour)
                {
                    const x = point.x;
                    const y = point.y;
                    point.x = x * xx + y * xy;
                    point.y = x * yx + y * yy;
                }

            double dx = 0.0;
            double dy = 0.0;
            if (argumentsAreXY)
            {
                dx = arg1;
                dy = arg2;
                if ((flags & ScaledComponentOffset) != 0)
                {
                    const translatedX = dx * xx + dy * xy;
                    const translatedY = dx * yx + dy * yy;
                    dx = translatedX;
                    dy = translatedY;
                }
                if ((flags & RoundXYToGrid) != 0)
                {
                    dx = floor(dx + 0.5);
                    dy = floor(dy + 0.5);
                }
            }
            else
            {
                OutlinePoint parentPoint;
                OutlinePoint componentPoint;
                if (findPoint(output, arg1, parentPoint) &&
                    findPoint(component, arg2, componentPoint))
                {
                    dx = parentPoint.x - componentPoint.x;
                    dy = parentPoint.y - componentPoint.y;
                }
            }

            foreach (contour; component)
            {
                foreach (ref point; contour)
                {
                    point.x += dx;
                    point.y += dy;
                }
                output ~= contour;
            }
        }
        while ((flags & MoreComponents) != 0);

        if ((flags & HaveInstructions) != 0)
        {
            enforce(cursor + 2 <= _data.length, "Truncated composite glyph instructions");
            const instructionLength = be16(_data, cursor);
            cursor += 2;
            enforce(cursor + instructionLength <= _data.length,
                "Truncated composite glyph instructions");
        }
    }

    private static bool findPoint(OutlinePoint[][] contours, int requested,
        out OutlinePoint point)
    {
        if (requested < 0) return false;
        int index;
        foreach (contour; contours)
            foreach (candidate; contour)
            {
                if (index == requested)
                {
                    point = candidate;
                    return true;
                }
                ++index;
            }
        return false;
    }

    private static OutlinePoint midpoint(OutlinePoint a, OutlinePoint b)
    {
        return OutlinePoint((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, true);
    }

    private static void appendLine(OutlinePoint a, OutlinePoint b, double scale,
        int bearingX, int bearingY, ref Edge[] edges)
    {
        Edge edge;
        edge.x0 = a.x * scale - bearingX;
        edge.y0 = bearingY - a.y * scale;
        edge.x1 = b.x * scale - bearingX;
        edge.y1 = bearingY - b.y * scale;
        if (abs(edge.x0 - edge.x1) > 1e-7 || abs(edge.y0 - edge.y1) > 1e-7)
            edges ~= edge;
    }

    private static void appendQuadratic(OutlinePoint from, OutlinePoint control, OutlinePoint to,
        double scale, int bearingX, int bearingY, ref Edge[] edges)
    {
        const estimate = (sqrt((control.x - from.x) ^^ 2 + (control.y - from.y) ^^ 2) +
            sqrt((to.x - control.x) ^^ 2 + (to.y - control.y) ^^ 2)) * scale;
        int segments = cast(int) ceil(estimate / 3.0);
        if (segments < 2) segments = 2;
        if (segments > 32) segments = 32;
        auto previous = from;
        foreach (segment; 1 .. segments + 1)
        {
            const t = cast(double) segment / segments;
            const inv = 1.0 - t;
            OutlinePoint point;
            point.x = inv * inv * from.x + 2.0 * inv * t * control.x + t * t * to.x;
            point.y = inv * inv * from.y + 2.0 * inv * t * control.y + t * t * to.y;
            point.onCurve = true;
            appendLine(previous, point, scale, bearingX, bearingY, edges);
            previous = point;
        }
    }

    private static void flattenContour(const(OutlinePoint)[] contour, double scale,
        int bearingX, int bearingY, ref Edge[] edges)
    {
        if (contour.length == 0) return;
        OutlinePoint start;
        if (contour[0].onCurve)
            start = contour[0];
        else if (contour[$ - 1].onCurve)
            start = contour[$ - 1];
        else
            start = midpoint(contour[$ - 1], contour[0]);

        auto current = start;
        size_t index;
        while (index < contour.length)
        {
            auto point = contour[index];
            if (index == 0 && contour[0].onCurve && current.x == point.x && current.y == point.y)
            {
                ++index;
                continue;
            }
            if (point.onCurve)
            {
                appendLine(current, point, scale, bearingX, bearingY, edges);
                current = point;
                ++index;
                continue;
            }
            const nextIndex = (index + 1) % contour.length;
            const next = contour[nextIndex];
            if (next.onCurve)
            {
                appendQuadratic(current, point, next, scale, bearingX, bearingY, edges);
                current = next;
                index += 2;
            }
            else
            {
                const implied = midpoint(point, next);
                appendQuadratic(current, point, implied, scale, bearingX, bearingY, edges);
                current = implied;
                ++index;
            }
        }
        appendLine(current, start, scale, bearingX, bearingY, edges);
    }

    private static bool insideNonZero(const(Edge)[] edges, double x, double y)
    {
        int winding;
        foreach (edge; edges)
        {
            if (edge.y0 <= y)
            {
                if (edge.y1 > y && isLeft(edge, x, y) > 0.0) ++winding;
            }
            else if (edge.y1 <= y && isLeft(edge, x, y) < 0.0)
                --winding;
        }
        return winding != 0;
    }

    private static double isLeft(Edge edge, double x, double y)
    {
        return (edge.x1 - edge.x0) * (y - edge.y0) -
            (x - edge.x0) * (edge.y1 - edge.y0);
    }
}

unittest
{
    // Parser behavior is exercised with a real font by the integration test.
    assert(tag!"glyf" == 0x676c7966);
}
