module tests.native_alpha;

import aurora;
import aurora.text.alphacorrection : NativeCoverageClasses, nativeCoverageClass,
    nativeTextCoverage, gammaRatios;
import std.process : environment;
import std.stdio : writeln;

private ubyte[] mask(GlyphAtlas atlas, AtlasGlyph glyph)
{
    ubyte[] result;
    foreach (y; 0 .. glyph.region.height)
        result ~= atlas.pixels()[cast(size_t) (glyph.region.y + y) * atlas.width() +
            glyph.region.x .. cast(size_t) (glyph.region.y + y) * atlas.width() + glyph.region.right()];
    return result;
}

int main(string[] args)
{
    // This is a separate test process. Every profile is constructed explicitly;
    // environment changes are never supported on a live atlas/font cache.
    environment.remove("AURORA_HINTING");
    environment.remove("AURORA_TEXT_EXPERIMENT");
    environment.remove("AURORA_TEXT_COVERAGE");
    environment.remove("AURORA_TEXT_CONTRAST");
    environment.remove("AURORA_TEXT_GAMMA");
    assert((new GlyphAtlas()).nativeAlphaCorrection(), "Refined D must be the shared default");
    environment["AURORA_TEXT_EXPERIMENT"] = "";
    assert((new GlyphAtlas()).nativeAlphaCorrection(), "An empty override must use the shared default");
    environment["AURORA_TEXT_EXPERIMENT"] = "compatible-c";
    assert(!(new GlyphAtlas()).nativeAlphaCorrection(), "C must remain available explicitly");
    environment["AURORA_TEXT_EXPERIMENT"] = "native-next";
    assert(!(new GlyphAtlas()).nativeAlphaCorrection(), "Reviewed D must retain its transfer");
    environment["AURORA_TEXT_EXPERIMENT"] = "native-refined";
    foreach (hinting; ["0", "1"])
    {
        environment["AURORA_HINTING"] = hinting;
        assert(!(new GlyphAtlas()).nativeAlphaCorrection());
    }
    environment["AURORA_HINTING"] = "natural";
    environment["AURORA_TEXT_COVERAGE"] = "legacy";
    assert(!(new GlyphAtlas()).nativeAlphaCorrection());
    environment["AURORA_TEXT_COVERAGE"] = "foreground";
    environment["AURORA_TEXT_GAMMA"] = "NaN";
    assert((new GlyphAtlas()).nativeGamma() == 1.8f);
    environment["AURORA_TEXT_GAMMA"] = "broken";
    assert((new GlyphAtlas()).nativeGamma() == 1.8f);
    environment.remove("AURORA_TEXT_GAMMA");

    auto face = FontFace.load("tests/fonts/InterVariable.ttf");
    assert(!face.needsThinCoverageBoost());
    auto growing = new GlyphAtlas(32, 32);
    assert(growing.nativeAlphaCorrection());
    const index = face.glyphIndex('a');
    const raw = face.rasterizeGlyph(index, 26, 4, 0, true);
    bool[NativeCoverageClasses] seen;
    size_t classes;
    // Sweep a dense RGB cube: all requested masks share one outline and stay
    // within the two-dimensional color bound, including through atlas growth.
    foreach (r; 0 .. 17)
    foreach (g; 0 .. 17)
    foreach (b; 0 .. 17)
    {
        const color = Color.rgb(cast(ubyte) (r * 255 / 16),
            cast(ubyte) (g * 255 / 16), cast(ubyte) (b * 255 / 16));
        const level = nativeCoverageClass(color);
        const glyph = growing.glyphByIndex(face, index, 26, FontRenderMode.sharp, 0, color);
        if (seen[level]) continue;
        seen[level] = true;
        ++classes;
        auto expected = raw.alpha.dup;
        foreach (ref value; expected)
            value = nativeTextCoverage(value, level, 0.5f, gammaRatios(1.8f));
        assert(mask(growing, glyph) == expected, "Atlas growth corrupted native color coverage");
    }
    assert(classes <= NativeCoverageClasses && classes > 32);
    assert(growing.rasterizations() == 1 && growing.width() > 32);
    const revision = growing.revision();
    foreach (r; 0 .. 17)
    foreach (g; 0 .. 17)
    foreach (b; 0 .. 17)
        growing.glyphByIndex(face, index, 26, FontRenderMode.sharp, 0,
            Color.rgba(cast(ubyte) (r * 255 / 16), cast(ubyte) (g * 255 / 16),
                cast(ubyte) (b * 255 / 16), 100));
    assert(growing.revision() == revision, "Opacity must not allocate coverage variants");

    // Optional renamed system font proves family metadata, not path matching.
    if (args.length > 1)
    {
        auto courier = FontFace.load(args[1]);
        assert(courier.needsThinCoverageBoost());
        auto thinAtlas = new GlyphAtlas(32, 32);
        auto thinRaw = courier.rasterizeGlyph(courier.glyphIndex('a'), 17, 4, 0, true);
        foreach (color; [Color.rgb(0, 0, 0), Color.rgb(240, 240, 240), Color.rgb(30, 80, 200)])
        {
            const entry = thinAtlas.glyph(courier, 'a', 17, FontRenderMode.sharp, color);
            auto expected = thinRaw.alpha.dup;
            foreach (ref value; expected)
                value = nativeTextCoverage(value, nativeCoverageClass(color), 0.5f, gammaRatios(1.8f), true);
            assert(mask(thinAtlas, entry) == expected);
        }
        assert(thinAtlas.rasterizations() == 1);
    }

    auto fonts = new FontSystem();
    fonts.setFaces(face, face);
    auto list = new DrawList(fonts);
    list.reset(Size(500, 180), Color.rgb(255, 255, 255));
    auto retained = Canvas(list, 500, 180);
    auto surface = new Surface(500, 180);
    surface.clear(Color.rgb(255, 255, 255));
    auto immediate = Canvas(surface, fonts);
    foreach (ref cv; [&retained, &immediate])
    {
        cv.fillRect(Rect(240, 0, 260, 180), Color.rgb(24, 24, 24));
        cv.fillRect(Rect(0, 120, 500, 30), Color.rgb(160, 195, 240));
        foreach (i, color; [Color.rgb(0, 0, 0), Color.rgb(255, 255, 255),
            Color.rgb(35, 41, 48), Color.rgb(240, 240, 240), Color.rgb(200, 35, 60),
            Color.rgb(30, 130, 70), Color.rgb(40, 80, 210), Color.rgba(60, 80, 160, 100)])
        {
            auto clipped = cv.clipped(Rect(2, 2, 490, 174));
            clipped.drawText(Point(4, 4 + cast(int) i * 20), "office Il1 e\u0301 Жй"d, color, 1);
            clipped.drawText(Point(244, 4 + cast(int) i * 20), "office Il1 e\u0301 Жй"d, color, 1);
        }
    }
    auto replay = new Surface(500, 180);
    SoftwareRenderer.renderInto(list, replay);
    assert(replay.pixels() == surface.pixels(), "Immediate/retained native correction disagrees");
    environment["AURORA_TEXT_CONTRAST"] = "0";
    auto linear = new GlyphAtlas();
    const dark = linear.glyph(face, 'a', 26, FontRenderMode.sharp, Color.rgb(0, 0, 0));
    const before = linear.revision();
    const light = linear.glyph(face, 'a', 26, FontRenderMode.sharp, Color.rgb(240, 240, 240));
    assert(dark.region == light.region && linear.revision() == before);
    assert(mask(linear, dark) == raw.alpha);
    writeln("Native alpha: ", classes, "/", NativeCoverageClasses,
        " color classes reached; one outline, atlas growth, opacity, metadata, profile isolation and Canvas paths passed.");
    return 0;
}
