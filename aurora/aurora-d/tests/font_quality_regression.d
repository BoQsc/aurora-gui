module tests.font_quality_regression;

import aurora;
import aurora.text.atlas : glyphOriginX, GlyphHorizontalPhases;
import aurora.text.opentype : fontTag;
import std.math : abs;
import std.format : format;
import std.stdio : writeln;
import std.process : environment;

private uint u16(const(ubyte)[] bytes, size_t offset)
{
    return (cast(uint) bytes[offset] << 8) | bytes[offset + 1];
}

int main(string[] args)
{
    // The checked-in fixture makes the suite independent of OS fonts.
    const path = args.length > 1 ? args[1] : "tests/fonts/InterVariable.ttf";
    auto face = FontFace.load(path);
    auto fonts = new FontSystem(path, path);
    const glyphIndex = face.glyphIndex('H');
    const metrics = face.tableData(fontTag("hmtx"));
    const hhea = face.tableData(fontTag("hhea"));
    const index = glyphIndex < u16(hhea, 34) ? glyphIndex : u16(hhea, 34) - 1;
    const expected = u16(metrics, index * 4) * 13.0 / face.unitsPerEm();
    assert(abs(face.advanceGlyphPrecise(glyphIndex, 13) - expected) < 1e-9);
    auto text = new dchar[80];
    text[] = 'H';
    TextLayoutOptions options;
    options.overrideFace = face;
    options.pixelSize = 13;
    options.enableKerning = false;
    options.wrap = false;
    auto layout = fonts.textEngine.layout(text, options);
    assert(abs(layout.width - expected * text.length) < 1e-7,
        "Repeated fractional advances must not accumulate rounding error");
    assert(glyphOriginX(0.125, true, 13, 4).phase == 2);
    assert(glyphOriginX(0.125, true, 26, 8).phase == 1);
    const carry = glyphOriginX(0.875, true, 13, 4);
    assert(carry.pixel == 1 && carry.phase == 0, "Raster-phase rounding must retain a pixel carry");

    auto atlas = new GlyphAtlas();
    auto original = atlas.glyphByIndex(face, glyphIndex, 13, FontRenderMode.smooth, 0);
    auto shifted = atlas.glyphByIndex(face, glyphIndex, 13, FontRenderMode.smooth, 1);
    assert(original.region != shifted.region, "Horizontal phases must not alias in cache");
    const revision = atlas.revision;
    assert(atlas.glyphByIndex(face, glyphIndex, 13, FontRenderMode.smooth, 1).region == shifted.region);
    assert(atlas.revision == revision, "Repeated phase must reuse cached coverage");

    size_t tested;
    foreach (size; [9, 11, 13, 17, 21, 24, 26, 34, 48])
    foreach (ch; "HIl1oeagjMW09=+-_()[]\u00e9\u00c5\u0416\u0439\u0301"d)
    {
        if (!face.supports(ch)) continue;
        const glyph = face.glyphIndex(ch);
        auto reference = face.rasterizeGlyph(glyph, size, 8);
        ulong referenceInk;
        foreach (a; reference.alpha) referenceInk += a;
        foreach (phase; 0 .. GlyphHorizontalPhases)
        {
            const shift = cast(double) phase / GlyphHorizontalPhases;
            auto smooth = face.rasterizeGlyph(glyph, size, 8, shift);
            auto sharp = face.rasterizeGlyph(glyph, size, 8, shift, true);
            ulong smoothInk, sharpInk;
            foreach (a; smooth.alpha) smoothInk += a;
            foreach (a; sharp.alpha) sharpInk += a;
            assert(referenceInk == 0 || (smoothInk > 0 && sharpInk > 0),
                "A supported visible glyph disappeared");
            assert(abs(cast(double) smoothInk - referenceInk) <=
                reference.alpha.length + smooth.alpha.length,
                format("Horizontal phase must conserve ink: U+%04X size=%s phase=%s ink=%s -> %s; pixel counts=%s/%s",
                    cast(uint) ch, size, phase, referenceInk, smoothInk,
                    reference.alpha.length, smooth.alpha.length));
            assert(smooth.advance == sharp.advance && smooth.advance == reference.advance);
            if (size > 24) assert(smooth.alpha == sharp.alpha,
                "Display sizes must preserve unmodified outline coverage");
            ++tested;
        }
    }
    if (environment.get("AURORA_HINTING", "0") == "natural" && face.rasterPhases(21) == 4)
    {
        // Native phase probes show that off-grid eighths round onto quarters.
        const glyph = face.glyphIndex('l');
        foreach (phase; [1, 3, 5])
        {
            const a = face.rasterizeGlyph(glyph, 21, 8, phase / 8.0);
            const b = face.rasterizeGlyph(glyph, 21, 8, (phase + 1) / 8.0);
            assert(a.alpha == b.alpha && a.bearingX == b.bearingX && a.bearingY == b.bearingY,
                "Natural off-grid phases must match native nearest-quarter behavior");
        }
        const last = face.rasterizeGlyph(glyph, 21, 8, 0.875);
        const first = face.rasterizeGlyph(glyph, 21, 8, 0);
        assert(last.alpha == first.alpha && last.bearingX == first.bearingX + 1 &&
            last.bearingY == first.bearingY, "A rounded phase carry must translate the glyph intact");
    }
    writeln("Fractional layout, phase caching, and ", tested, " glyph/size/phase checks passed.");
    return 0;
}
