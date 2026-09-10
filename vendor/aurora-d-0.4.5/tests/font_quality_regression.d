module tests.font_quality_regression;

import aurora;
import aurora.text.atlas : glyphOriginX, GlyphHorizontalPhases;
import aurora.text.opentype : fontTag;
import std.math : abs;
import std.stdio : writeln;

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
                "Horizontal phase must conserve ink within A8 rounding error");
            assert(smooth.advance == sharp.advance && smooth.advance == reference.advance);
            if (size > 24) assert(smooth.alpha == sharp.alpha,
                "Display sizes must preserve unmodified outline coverage");
            ++tested;
        }
    }
    writeln("Fractional layout, phase caching, and ", tested, " glyph/size/phase checks passed.");
    return 0;
}
