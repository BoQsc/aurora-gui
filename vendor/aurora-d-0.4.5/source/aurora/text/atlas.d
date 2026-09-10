module aurora.text.atlas;

import aurora.font : FontFace, FontRenderMode, FontRole, SystemFonts;
import aurora.text.glyph : GlyphBitmap;
import aurora.text.fontcollection : FontCollection;
import aurora.text.layout : TextLayoutEngine;
import aurora.types : Rect, maxInt;
import std.math : floor;

enum GlyphHorizontalPhases = 8;

struct GlyphOrigin
{
    int pixel;
    ubyte phase;
}

/// Small text uses eighth pixels below 20px, quarters at larger sizes.
/// Phase indices always represent eighths; larger text uses only even indices.
GlyphOrigin glyphOriginX(double x, bool outline = true, int pixelSize = 13)
    @safe pure nothrow @nogc
{
    if (!outline) return GlyphOrigin(cast(int) floor(x + 0.5), 0);
    const phases = pixelSize < 20 ? GlyphHorizontalPhases : GlyphHorizontalPhases / 2;
    const quantized = floor(x * phases + 0.5);
    const pixel = cast(int) floor(quantized / phases);
    return GlyphOrigin(pixel, cast(ubyte) ((quantized - cast(double) pixel * phases) *
        (GlyphHorizontalPhases / phases)));
}

struct AtlasGlyph
{
    uint glyphIndex;
    Rect region;
    int bearingX;
    int bearingY;
    int advance;

    bool hasPixels() const @safe pure nothrow @nogc
    {
        return region.width > 0 && region.height > 0;
    }
}

private struct GlyphKey
{
    ulong faceIdentity;
    uint glyphIndex;
    ushort pixelSize;
    ushort renderFlags;   // Render mode plus horizontal coverage phase.
    uint variationHash;   // Reserved for future variable-font instances.
}

/** Grow-only A8 glyph atlas shared by the software and Vulkan renderers. */
final class GlyphAtlas
{
    private int _width;
    private int _height;
    private ubyte[] _pixels;
    private AtlasGlyph[GlyphKey] _glyphs;
    private int _cursorX = 2;
    private int _cursorY = 2;
    private int _shelfHeight;
    private ulong _revision = 1;

    this(int width = 512, int height = 512)
    {
        _width = maxInt(32, width);
        _height = maxInt(32, height);
        _pixels.length = cast(size_t) _width * cast(size_t) _height;
        _pixels[0] = 255; // Solid geometry samples this white texel.
    }

    int width() const @safe pure nothrow @nogc { return _width; }
    int height() const @safe pure nothrow @nogc { return _height; }
    ulong revision() const @safe pure nothrow @nogc { return _revision; }
    const(ubyte)[] pixels() const @safe pure nothrow @nogc { return _pixels; }

    AtlasGlyph glyph(const(FontFace) face, dchar codepoint, int pixelSize,
        FontRenderMode renderMode = FontRenderMode.sharp)
    {
        auto selected = face is null ? cast(const(FontFace)) SystemFonts.sans() : face;
        return glyphByIndex(selected, selected.glyphIndex(codepoint), pixelSize, renderMode);
    }

    /** Rasterize/cache a glyph already selected by the shaping engine. */
    AtlasGlyph glyphByIndex(const(FontFace) face, uint glyphIndex, int pixelSize,
        FontRenderMode renderMode = FontRenderMode.sharp, ubyte phaseX = 0)
    {
        assert(phaseX < GlyphHorizontalPhases);
        auto selected = face is null ? cast(const(FontFace)) SystemFonts.sans() : face;
        pixelSize = maxInt(1, pixelSize);
        if (pixelSize > ushort.max) pixelSize = ushort.max;
        const key = GlyphKey(selected.identity(), glyphIndex, cast(ushort) pixelSize,
            cast(ushort) (cast(ushort) renderMode | (cast(ushort) phaseX << 8)),
            selected.variationHash());
        if (auto cached = key in _glyphs)
            return *cached;

        // Use 16 vertical samples per row at small UI sizes and 8 for larger
        // text, with exact horizontal span coverage in both outline formats.
        // Sharp mode also aligns font-authored vertical zones where available;
        // smooth mode preserves the outline. Neither boosts alpha contrast.
        const coverageSamples = pixelSize <= 16 ? 8 : 4;
        auto bitmap = selected.rasterizeGlyph(glyphIndex, pixelSize, coverageSamples,
            cast(double) phaseX / GlyphHorizontalPhases, renderMode == FontRenderMode.sharp);
        auto result = insert(bitmap);
        _glyphs[key] = result;
        return result;
    }

    void clear()
    {
        _glyphs = null;
        _pixels[] = 0;
        _pixels[0] = 255;
        _cursorX = 2;
        _cursorY = 2;
        _shelfHeight = 0;
        ++_revision;
    }

    private AtlasGlyph insert(GlyphBitmap bitmap)
    {
        AtlasGlyph result;
        result.glyphIndex = bitmap.glyphIndex;
        result.bearingX = bitmap.bearingX;
        result.bearingY = bitmap.bearingY;
        result.advance = bitmap.advance;
        if (bitmap.empty())
            return result;

        const paddedWidth = bitmap.width + 2;
        const paddedHeight = bitmap.height + 2;
        ensureRoom(paddedWidth, paddedHeight);
        const x = _cursorX + 1;
        const y = _cursorY + 1;
        result.region = Rect(x, y, bitmap.width, bitmap.height);

        foreach (row; 0 .. bitmap.height)
        {
            const source = cast(size_t) row * cast(size_t) bitmap.width;
            const target = cast(size_t) (y + row) * cast(size_t) _width + cast(size_t) x;
            _pixels[target .. target + cast(size_t) bitmap.width] =
                bitmap.alpha[source .. source + cast(size_t) bitmap.width];
        }
        _cursorX += paddedWidth;
        _shelfHeight = maxInt(_shelfHeight, paddedHeight);
        ++_revision;
        return result;
    }

    private void ensureRoom(int requestedWidth, int requestedHeight)
    {
        if (_cursorX + requestedWidth > _width)
        {
            _cursorX = 2;
            _cursorY += _shelfHeight;
            _shelfHeight = 0;
        }
        while (_cursorY + requestedHeight > _height || requestedWidth + 4 > _width)
            grow();
    }

    private void grow()
    {
        const newWidth = _width < 4096 ? _width * 2 : _width;
        const newHeight = _height < 4096 ? _height * 2 : _height;
        if (newWidth == _width && newHeight == _height)
            throw new Exception("Aurora glyph atlas reached its 4096x4096 limit");
        ubyte[] next;
        next.length = cast(size_t) newWidth * cast(size_t) newHeight;
        foreach (row; 0 .. _height)
        {
            const source = cast(size_t) row * cast(size_t) _width;
            const target = cast(size_t) row * cast(size_t) newWidth;
            next[target .. target + cast(size_t) _width] =
                _pixels[source .. source + cast(size_t) _width];
        }
        _pixels = next;
        _width = newWidth;
        _height = newHeight;
        ++_revision;
    }
}

/** Window-local font collections, layout engine, and glyph cache. */
final class FontSystem
{
    FontFace uiFace;
    FontFace monospaceFace;
    FontCollection uiCollection;
    FontCollection monospaceCollection;
    GlyphAtlas atlas;
    TextLayoutEngine textEngine;
    FontRenderMode renderMode = FontRenderMode.sharp;
    private ulong _revision = 1;

    this(string uiFontPath = "", string monospaceFontPath = "",
        FontRenderMode mode = FontRenderMode.sharp)
    {
        renderMode = mode;
        uiFace = uiFontPath.length > 0 ? FontFace.tryLoad(uiFontPath) : null;
        monospaceFace = monospaceFontPath.length > 0 ? FontFace.tryLoad(monospaceFontPath) : null;
        if (uiFace is null) uiFace = SystemFonts.sans();
        if (monospaceFace is null) monospaceFace = SystemFonts.monospace();
        uiCollection = FontCollection.system(FontRole.ui, uiFace);
        monospaceCollection = FontCollection.system(FontRole.monospace, monospaceFace);
        atlas = new GlyphAtlas();
        textEngine = new TextLayoutEngine(uiCollection, monospaceCollection);
    }

    FontFace face(FontRole role) @safe pure nothrow @nogc
    {
        return role == FontRole.monospace ? monospaceFace : uiFace;
    }

    FontCollection collection(FontRole role) @safe pure nothrow @nogc
    {
        return role == FontRole.monospace ? monospaceCollection : uiCollection;
    }

    /** Changes whenever a primary or fallback collection changes. */
    ulong revision() const @safe pure nothrow @nogc { return _revision; }

    void setRenderMode(FontRenderMode value)
    {
        if (renderMode == value) return;
        renderMode = value;
        atlas.clear();
        ++_revision;
    }

    void setFaces(FontFace ui, FontFace monospace)
    {
        if (ui !is null)
        {
            uiFace = ui;
            uiCollection = FontCollection.system(FontRole.ui, uiFace);
        }
        if (monospace !is null)
        {
            monospaceFace = monospace;
            monospaceCollection = FontCollection.system(FontRole.monospace, monospaceFace);
        }
        textEngine.setCollections(uiCollection, monospaceCollection);
        atlas.clear();
        ++_revision;
    }

    /** Append an application-provided fallback face without replacing primary. */
    bool addFallback(FontRole role, FontFace face)
    {
        const added = collection(role).add(face);
        if (added)
        {
            textEngine.clearLayoutCache();
            ++_revision;
        }
        return added;
    }

    /** Load and append one fallback face from an sfnt/TTC file. */
    bool addFallback(FontRole role, string path, uint faceIndex = 0)
    {
        auto face = FontFace.tryLoad(path, faceIndex);
        return face !is null && addFallback(role, face);
    }

    static FontSystem sharedInstance()
    {
        static FontSystem instance;
        if (instance is null) instance = new FontSystem();
        return instance;
    }
}

unittest
{
    assert(glyphOriginX(3.06) == GlyphOrigin(3, 0));
    assert(glyphOriginX(3.07) == GlyphOrigin(3, 1));
    assert(glyphOriginX(3.94) == GlyphOrigin(4, 0));
    assert(glyphOriginX(-0.25) == GlyphOrigin(-1, 6));
    assert(glyphOriginX(-0.1) == GlyphOrigin(-1, 7));
    assert(glyphOriginX(-0.05) == GlyphOrigin(0, 0));
    assert(glyphOriginX(3.12, true, 20) == GlyphOrigin(3, 0));
    assert(glyphOriginX(3.13, true, 20) == GlyphOrigin(3, 2));
    assert(glyphOriginX(3.88, true, 20) == GlyphOrigin(4, 0));
    assert(glyphOriginX(3.75, false) == GlyphOrigin(4, 0));
    auto system = new FontSystem();
    auto glyph = system.atlas.glyph(system.uiFace, 'A', 18, system.renderMode);
    assert(glyph.advance > 0);
    assert(system.atlas.pixels()[0] == 255);
}
