module aurora.font;

import aurora.text.glyph : GlyphBitmap;
import aurora.text.truetype : TrueTypeFace;
import aurora.types : Size, maxInt;
import std.file : exists;
import std.path : buildPath;
import std.process : environment;

/**
 * Small built-in 5x7 bitmap font.
 *
 * The table is authored for Aurora and keeps text rendering deterministic on
 * every backend. The renderer needs no system fonts or font libraries.
 */
enum GlyphWidth = 5;
enum GlyphHeight = 7;
enum GlyphAdvance = 6;
enum LineAdvance = 9;

private immutable ulong[95] glyphTable = [
    0x000000000UL, 0x100421084UL, 0x00000294aUL, 0x295f52beaUL, 0x13c5751e4UL,
    0x1a7041359UL, 0x36556524cUL, 0x000002084UL, 0x088842082UL, 0x208210888UL,
    0x02aefbaa0UL, 0x0084f9080UL, 0x208600000UL, 0x0000f8000UL, 0x318000000UL,
    0x410820841UL, 0x3a39ace2eUL, 0x7c8425184UL, 0x7d041062eUL, 0x78217043eUL,
    0x085f928c2UL, 0x7821f421fUL, 0x3a31f420eUL, 0x21082083fUL, 0x3a317462eUL,
    0x38217c62eUL, 0x018c03180UL, 0x208603180UL, 0x088882082UL, 0x001f07c00UL,
    0x208208888UL, 0x10041062eUL, 0x3e17ade2eUL, 0x4631fc62eUL, 0x7a31f463eUL,
    0x3a308422eUL, 0x7a318c63eUL, 0x7e10f421fUL, 0x4210f421fUL, 0x3a31bc22eUL,
    0x4631fc631UL, 0x7c842109fUL, 0x3a210843fUL, 0x4654c5251UL, 0x7e1084210UL,
    0x4631ad771UL, 0x4673ae731UL, 0x3a318c62eUL, 0x4210f463eUL, 0x36558c62eUL,
    0x4654f463eUL, 0x78217420fUL, 0x10842109fUL, 0x3a318c631UL, 0x11518c631UL,
    0x4775ac631UL, 0x462a22a31UL, 0x108422a31UL, 0x7e082083fUL, 0x39084210eUL,
    0x044222110UL, 0x38421084eUL, 0x000004544UL, 0x7c0000000UL, 0x000000088UL,
    0x3e2f0b800UL, 0x7a318fa10UL, 0x3a308b800UL, 0x3e318bc21UL, 0x3a1f8b800UL,
    0x2108e2126UL, 0x382f8c5e0UL, 0x46318fa10UL, 0x388423004UL, 0x324211802UL,
    0x4a98a4a10UL, 0x38842108cUL, 0x4635ae800UL, 0x46318f800UL, 0x3a318b800UL,
    0x421e8c7c0UL, 0x042f8c5e0UL, 0x4210cd800UL, 0x782e83c00UL, 0x192847108UL,
    0x36718c400UL, 0x11518c400UL, 0x2ab58c400UL, 0x454454400UL, 0x382f8c620UL,
    0x7d0417c00UL, 0x0c84c1083UL, 0x108421084UL, 0x608419098UL, 0x000393000UL
];

ulong glyphBits(dchar ch) @safe pure nothrow @nogc
{
    if (ch >= 32 && ch <= 126)
        return glyphTable[cast(size_t) (ch - 32)];
    return glyphTable[cast(size_t) ('?' - 32)];
}

bool glyphPixel(ulong bits, int x, int y) @safe pure nothrow @nogc
{
    if (x < 0 || x >= GlyphWidth || y < 0 || y >= GlyphHeight)
        return false;
    const row = cast(uint) ((bits >> (y * GlyphWidth)) & 0x1fUL);
    return (row & (1u << (GlyphWidth - 1 - x))) != 0;
}



enum FontRole : ubyte
{
    ui,
    monospace
}

/**
 * Portable grayscale glyph-rasterization policy.
 *
 * `sharp` retains antialiasing but increases edge contrast for small UI text.
 * It is Aurora's default. `smooth` preserves the unmodified supersampled
 * coverage produced by the outline rasterizer.
 */
enum FontRenderMode : ubyte
{
    smooth,
    sharp
}

/**
 * Semantic text tiers used throughout Aurora's controls and demos.
 *
 * The numeric values preserve the original public integer-size API. The
 * corresponding logical EM sizes form a conventional desktop ramp instead of
 * the former 8/15/22/29-pixel sequence.
 */
enum TextScale : int
{
    caption = 1,
    body = 2,
    heading = 3,
    display = 4
}

enum UiFontSizeCaption = 13;
enum UiFontSizeBody = 17;
enum UiFontSizeHeading = 22;
enum UiFontSizeDisplay = 30;

// Source-compatible names retained for code written against the 0.4.2 preview.
enum UiFontSizeSmall = UiFontSizeCaption;
enum UiFontSizeLarge = UiFontSizeHeading;

/** Maps Aurora's integer text tier to a 96-DPI logical EM pixel size. */
int fontPixelSize(int scale) @safe pure nothrow @nogc
{
    scale = maxInt(cast(int) TextScale.caption, scale);
    switch (scale)
    {
        case cast(int) TextScale.caption: return UiFontSizeCaption;
        case cast(int) TextScale.body: return UiFontSizeBody;
        case cast(int) TextScale.heading: return UiFontSizeHeading;
        case cast(int) TextScale.display: return UiFontSizeDisplay;
        default: return UiFontSizeDisplay +
            (scale - cast(int) TextScale.display) * 6;
    }
}

/** Returns the closest standard Aurora tier for a logical EM pixel size. */
int fontScaleForPixelSize(int pixelSize) @safe pure nothrow @nogc
{
    pixelSize = maxInt(1, pixelSize);
    if (pixelSize <= (UiFontSizeCaption + UiFontSizeBody) / 2)
        return cast(int) TextScale.caption;
    if (pixelSize <= (UiFontSizeBody + UiFontSizeHeading) / 2)
        return cast(int) TextScale.body;
    if (pixelSize <= (UiFontSizeHeading + UiFontSizeDisplay) / 2)
        return cast(int) TextScale.heading;
    return cast(int) TextScale.display +
        maxInt(0, (pixelSize - UiFontSizeDisplay + 3) / 6);
}

private __gshared ulong nextFontIdentity = 1;

/**
 * A loadable OpenType/sfnt face, with the built-in bitmap font as a last
 * fallback. Both TrueType `glyf` and static CFF1 outlines are accepted.
 */
final class FontFace
{
    private TrueTypeFace _trueType;
    private ulong _identity;
    private string _path;
    private bool _bitmap;

    private this(TrueTypeFace face, string path, bool bitmap)
    {
        _trueType = face;
        _path = path;
        _bitmap = bitmap;
        _identity = nextFontIdentity++;
    }

    static FontFace load(string path, uint faceIndex = 0)
    {
        return new FontFace(TrueTypeFace.load(path, faceIndex), path, false);
    }

    static FontFace tryLoad(string path, uint faceIndex = 0)
    {
        if (path.length == 0 || !exists(path)) return null;
        try
            return load(path, faceIndex);
        catch (Exception)
            return null;
    }

    static FontFace bitmapFallback()
    {
        static FontFace fallback;
        if (fallback is null)
            fallback = new FontFace(null, "<Aurora bitmap fallback>", true);
        return fallback;
    }

    ulong identity() const @safe pure nothrow @nogc { return _identity; }
    string path() const @safe pure nothrow { return _path; }
    bool isBitmapFallback() const @safe pure nothrow @nogc { return _bitmap; }
    bool isOpenType() const @safe pure nothrow @nogc { return _trueType !is null; }

    // Compatibility name retained from Aurora-D 0.2.0. It reports a parsed
    // sfnt face, including one whose outlines are static CFF1.
    bool isTrueType() const @safe pure nothrow @nogc { return isOpenType(); }

    bool hasTrueTypeOutlines() const @safe pure nothrow @nogc
    {
        return _trueType !is null && _trueType.hasTrueTypeOutlines();
    }

    bool hasCffOutlines() const @safe pure nothrow @nogc
    {
        return _trueType !is null && _trueType.hasCffOutlines();
    }

    const(TrueTypeFace) openTypeFace() const @safe pure nothrow @nogc
    {
        return _trueType;
    }

    int unitsPerEm() const @safe pure nothrow @nogc
    {
        return _trueType is null ? GlyphHeight : _trueType.unitsPerEm();
    }

    int glyphCount() const @safe pure nothrow @nogc
    {
        return _trueType is null ? 128 : _trueType.glyphCount();
    }

    int scaleUnits(int units, int pixelSize) const @safe pure nothrow @nogc
    {
        if (_trueType is null)
            return cast(int) (cast(long) units * bitmapScale(pixelSize) / GlyphHeight);
        return _trueType.scaleUnits(units, pixelSize);
    }

    double unitsToPixels(double value, int pixelSize) const @safe pure nothrow @nogc
    {
        return value * maxInt(1, pixelSize) / maxInt(1, unitsPerEm());
    }

    bool hasTable(uint tableTag) const @safe pure nothrow @nogc
    {
        return _trueType !is null && _trueType.hasTable(tableTag);
    }

    const(ubyte)[] tableData(uint tableTag) const
    {
        return _trueType is null ? null : _trueType.tableData(tableTag);
    }

    uint glyphIndex(dchar codepoint) const
    {
        return _trueType is null ? cast(uint) codepoint : _trueType.glyphIndex(codepoint);
    }

    bool supports(dchar codepoint) const
    {
        return _trueType is null ? (codepoint >= 32 && codepoint <= 126) :
            _trueType.glyphIndex(codepoint) != 0;
    }

    int ascent(int pixelSize) const
    {
        if (_trueType !is null) return _trueType.ascent(pixelSize);
        return GlyphHeight * bitmapScale(pixelSize);
    }

    int descent(int pixelSize) const
    {
        if (_trueType !is null) return _trueType.descent(pixelSize);
        return 2 * bitmapScale(pixelSize);
    }

    int lineHeight(int pixelSize) const
    {
        if (_trueType !is null) return _trueType.lineHeight(pixelSize);
        return LineAdvance * bitmapScale(pixelSize);
    }

    int advance(dchar codepoint, int pixelSize) const
    {
        if (_trueType !is null)
            return _trueType.advance(_trueType.glyphIndex(codepoint), pixelSize);
        return GlyphAdvance * bitmapScale(pixelSize);
    }

    int advanceGlyph(uint glyph, int pixelSize) const
    {
        if (_trueType !is null) return _trueType.advance(glyph, pixelSize);
        return GlyphAdvance * bitmapScale(pixelSize);
    }

    int kerning(uint leftGlyph, uint rightGlyph, int pixelSize) const
    {
        return _trueType is null ? 0 : _trueType.kerning(leftGlyph, rightGlyph, pixelSize);
    }

    GlyphBitmap rasterizeGlyph(uint glyph, int pixelSize, int supersample = 4) const
    {
        if (_trueType !is null)
            return _trueType.rasterize(glyph, pixelSize, supersample);

        GlyphBitmap result;
        result.glyphIndex = glyph;
        const scale = bitmapScale(pixelSize);
        result.width = GlyphWidth * scale;
        result.height = GlyphHeight * scale;
        result.bearingY = result.height;
        result.advance = GlyphAdvance * scale;
        result.alpha.length = cast(size_t) result.width * cast(size_t) result.height;
        const bits = glyphBits(cast(dchar) glyph);
        foreach (y; 0 .. GlyphHeight)
        {
            foreach (x; 0 .. GlyphWidth)
            {
                if (!glyphPixel(bits, x, y)) continue;
                foreach (dy; 0 .. scale)
                    foreach (dx; 0 .. scale)
                        result.alpha[cast(size_t) (y * scale + dy) * result.width + x * scale + dx] = 255;
            }
        }
        return result;
    }

    private static int bitmapScale(int pixelSize) @safe pure nothrow @nogc
    {
        return maxInt(1, (pixelSize + GlyphHeight - 1) / GlyphHeight);
    }
}

/** Platform-neutral discovery of common system font files. No font library is used. */
struct SystemFonts
{
    private __gshared FontFace cachedSans;
    private __gshared FontFace cachedMonospace;
    private __gshared bool triedSans;
    private __gshared bool triedMonospace;

    static FontFace sans()
    {
        if (!triedSans)
        {
            triedSans = true;
            cachedSans = findFirst(sansCandidates(), "AURORA_UI_FONT");
            if (cachedSans is null) cachedSans = FontFace.bitmapFallback();
        }
        return cachedSans;
    }

    static FontFace monospace()
    {
        if (!triedMonospace)
        {
            triedMonospace = true;
            cachedMonospace = findFirst(monospaceCandidates(), "AURORA_MONOSPACE_FONT");
            if (cachedMonospace is null) cachedMonospace = sans();
        }
        return cachedMonospace;
    }

    private static FontFace findFirst(string[] candidates, string roleVariable)
    {
        auto overridePath = environment.get(roleVariable, "");
        if (overridePath.length == 0)
            overridePath = environment.get("AURORA_FONT", "");
        if (overridePath.length > 0)
        {
            auto face = FontFace.tryLoad(overridePath);
            if (face !is null) return face;
        }
        foreach (candidate; candidates)
        {
            auto face = FontFace.tryLoad(candidate);
            if (face !is null) return face;
        }
        return null;
    }

    private static string[] sansCandidates()
    {
        string[] result;
        version (Windows)
        {
            const root = environment.get("WINDIR", `C:\Windows`);
            result ~= buildPath(root, "Fonts", "segoeui.ttf");
            result ~= buildPath(root, "Fonts", "arial.ttf");
            result ~= buildPath(root, "Fonts", "calibri.ttf");
        }
        else version (OSX)
        {
            result ~= "/System/Library/Fonts/Supplemental/Arial.ttf";
            result ~= "/System/Library/Fonts/Supplemental/Verdana.ttf";
            result ~= "/Library/Fonts/Arial.ttf";
        }
        else
        {
            result ~= "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
            result ~= "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf";
            result ~= "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf";
            result ~= "/usr/share/fonts/truetype/croscore/Arimo-Regular.ttf";
            const home = environment.get("HOME", "");
            if (home.length > 0) result ~= buildPath(home, ".fonts", "DejaVuSans.ttf");
        }
        return result;
    }

    private static string[] monospaceCandidates()
    {
        string[] result;
        version (Windows)
        {
            const root = environment.get("WINDIR", `C:\Windows`);
            result ~= buildPath(root, "Fonts", "consola.ttf");
            result ~= buildPath(root, "Fonts", "cour.ttf");
            result ~= buildPath(root, "Fonts", "lucon.ttf");
        }
        else version (OSX)
        {
            result ~= "/System/Library/Fonts/Menlo.ttc";
            result ~= "/System/Library/Fonts/Monaco.ttf";
            result ~= "/System/Library/Fonts/Supplemental/Courier New.ttf";
        }
        else
        {
            result ~= "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
            result ~= "/usr/share/fonts/truetype/liberation2/LiberationMono-Regular.ttf";
            result ~= "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf";
            result ~= "/usr/share/fonts/truetype/croscore/Cousine-Regular.ttf";
            const home = environment.get("HOME", "");
            if (home.length > 0) result ~= buildPath(home, ".fonts", "DejaVuSansMono.ttf");
        }
        return result;
    }
}

struct FontMetrics
{
    const(FontFace) face;
    int pixelSize;
    int scale = 2;

    this(int legacyScale)
    {
        scale = maxInt(1, legacyScale);
        pixelSize = fontPixelSize(scale);
        face = SystemFonts.sans();
    }

    this(const(FontFace) value, int size)
    {
        face = value is null ? SystemFonts.sans() : value;
        pixelSize = maxInt(1, size);
        scale = fontScaleForPixelSize(pixelSize);
    }

    int characterWidth() const
    {
        auto selected = face is null ? SystemFonts.sans() : face;
        return maxInt(1, selected.advance('M', effectivePixelSize()));
    }

    int glyphHeight() const
    {
        auto selected = face is null ? SystemFonts.sans() : face;
        return maxInt(1, selected.ascent(effectivePixelSize()) + selected.descent(effectivePixelSize()));
    }

    int lineHeight() const
    {
        auto selected = face is null ? SystemFonts.sans() : face;
        return maxInt(1, selected.lineHeight(effectivePixelSize()));
    }

    Size measure(const(dchar)[] text) const
    {
        auto selected = face is null ? SystemFonts.sans() : face;
        const size = effectivePixelSize();
        int lineWidth;
        int widest;
        int lines = 1;
        uint previous;
        foreach (ch; text)
        {
            if (ch == '\r') continue;
            if (ch == '\n')
            {
                if (lineWidth > widest) widest = lineWidth;
                lineWidth = 0;
                previous = 0;
                ++lines;
                continue;
            }
            if (ch == '\t')
            {
                const tab = maxInt(1, selected.advance(' ', size)) * 4;
                lineWidth = ((lineWidth / tab) + 1) * tab;
                previous = 0;
                continue;
            }
            const glyph = selected.glyphIndex(ch);
            if (previous != 0) lineWidth += selected.kerning(previous, glyph, size);
            lineWidth += selected.advanceGlyph(glyph, size);
            previous = glyph;
        }
        if (lineWidth > widest) widest = lineWidth;
        return Size(widest, lines * lineHeight());
    }

    private int effectivePixelSize() const @safe pure nothrow @nogc
    {
        return pixelSize > 0 ? pixelSize : fontPixelSize(scale);
    }
}

unittest
{
    assert(glyphPixel(glyphBits('A'), 1, 0));
    assert(fontPixelSize(cast(int) TextScale.caption) == UiFontSizeCaption);
    assert(fontPixelSize(cast(int) TextScale.body) == UiFontSizeBody);
    assert(fontPixelSize(cast(int) TextScale.heading) == UiFontSizeHeading);
    assert(fontPixelSize(cast(int) TextScale.display) == UiFontSizeDisplay);
    assert(fontPixelSize(5) == 36);
    assert(fontScaleForPixelSize(UiFontSizeCaption) == cast(int) TextScale.caption);
    assert(fontScaleForPixelSize(UiFontSizeBody) == cast(int) TextScale.body);
    assert(fontScaleForPixelSize(UiFontSizeHeading) == cast(int) TextScale.heading);
    assert(fontScaleForPixelSize(UiFontSizeDisplay) == cast(int) TextScale.display);
    auto fallback = FontFace.bitmapFallback();
    assert(FontMetrics(fallback, UiFontSizeBody).measure("AB"d).width > 0);
}
