module tests.text_coverage;

import aurora;
import aurora.text.coverage : TextCoverageClasses, textCoverageClass, transferTextCoverage;
import std.conv : to;
import std.process : environment;
import std.stdio : writeln;

private ubyte[] mask(GlyphAtlas atlas, AtlasGlyph glyph)
{
    ubyte[] result;
    foreach (y; 0 .. glyph.region.height)
        result ~= atlas.pixels()[cast(size_t) (glyph.region.y + y) * atlas.width() +
            glyph.region.x .. cast(size_t) (glyph.region.y + y) * atlas.width() +
            glyph.region.right()];
    return result;
}

private void restore(string name, string value)
{
    if (value is null) environment.remove(name);
    else environment[name] = value;
}

int main(string[] args)
{
    const oldCoverage = environment.get("AURORA_TEXT_COVERAGE", null);
    const oldContrast = environment.get("AURORA_TEXT_CONTRAST", null);
    const oldHinting = environment.get("AURORA_HINTING", null);
    scope (exit)
    {
        restore("AURORA_TEXT_COVERAGE", oldCoverage);
        restore("AURORA_TEXT_CONTRAST", oldContrast);
        restore("AURORA_HINTING", oldHinting);
    }
    environment["AURORA_TEXT_CONTRAST"] = "0.5";
    environment["AURORA_HINTING"] = "0";
    auto face = FontFace.load(args.length > 1 ? args[1] : "tests/fonts/InterVariable.ttf");

    assert(textCoverageClass(Color.rgb(0, 0, 0)) == 0);
    assert(textCoverageClass(Color.rgb(255, 255, 255)) == TextCoverageClasses - 1);
    assert(textCoverageClass(Color.rgb(240, 240, 240)) == TextCoverageClasses - 1);
    foreach (level; 0 .. TextCoverageClasses)
    {
        const contrast = 0.5f * level / (TextCoverageClasses - 1);
        uint previous;
        foreach (a; 0 .. 256)
        {
            const value = transferTextCoverage(cast(ubyte) a, contrast);
            assert(value >= previous, "Correction must be monotone");
            assert(value >= a, "Contrast must not erase partial coverage");
            previous = value;
        }
        assert(transferTextCoverage(0, contrast) == 0);
        assert(transferTextCoverage(255, contrast) == 255);
    }

    environment.remove("AURORA_TEXT_COVERAGE");
    assert((new GlyphAtlas()).foregroundCoverage(),
        "Aurora must own the approved foreground-aware default");
    environment["AURORA_TEXT_COVERAGE"] = "legacy";
    auto legacy = new GlyphAtlas();
    assert(!legacy.foregroundCoverage(), "The previous transfer must remain available");
    environment["AURORA_TEXT_COVERAGE"] = "foreground";
    auto candidate = new GlyphAtlas();
    assert(candidate.foregroundCoverage());
    size_t checked;
    foreach (size; [11, 13, 17, 26])
    foreach (phase; 0 .. 8)
    foreach (mode; [FontRenderMode.sharp, FontRenderMode.smooth])
    {
        const index = face.glyphIndex('H');
        const black = candidate.glyphByIndex(face, index, size, mode, cast(ubyte) phase,
            Color.rgb(0, 0, 0));
        const rasterized = candidate.rasterizations();
        const white = candidate.glyphByIndex(face, index, size, mode, cast(ubyte) phase,
            Color.rgb(255, 255, 255));
        assert(candidate.rasterizations() == rasterized,
            "Changing foreground must reuse the raw outline coverage");
        const baseline = legacy.glyphByIndex(face, index, size, mode, cast(ubyte) phase);
        auto raw = face.rasterizeGlyph(index, size, size <= 16 ? 8 : 4,
            cast(double) phase / 8, mode == FontRenderMode.sharp);
        assert(mask(candidate, black) == raw.alpha);
        assert(mask(candidate, white) == mask(legacy, baseline),
            "White text must retain the legacy transfer exactly");
        assert(black.bearingX == white.bearingX && black.bearingY == white.bearingY &&
            black.advance == white.advance && black.region.width == white.region.width &&
            black.region.height == white.region.height);
        ++checked;
    }

    const glyph = face.glyphIndex('a');
    auto initial = candidate.rasterizations();
    foreach (value; 0 .. 256)
        candidate.glyphByIndex(face, glyph, 13, FontRenderMode.sharp, 0,
            Color(cast(ubyte) value, cast(ubyte) value, cast(ubyte) value, 255));
    assert(candidate.rasterizations() == initial + 1);
    const revision = candidate.revision();
    foreach (value; 0 .. 256)
        candidate.glyphByIndex(face, glyph, 13, FontRenderMode.sharp, 0,
            Color(cast(ubyte) value, cast(ubyte) value, cast(ubyte) value, 64));
    assert(candidate.revision() == revision, "Opacity must not allocate new coverage variants");

    // Force atlas growth while deriving variants from a previously cached raw
    // mask. Previously issued glyph regions must survive every reallocation.
    auto growing = new GlyphAtlas(32, 32);
    auto raw = face.rasterizeGlyph(glyph, 26, 4, 0, true);
    foreach (level; 0 .. TextCoverageClasses)
    {
        const shade = cast(ubyte) (level * 16);
        auto entry = growing.glyphByIndex(face, glyph, 26, FontRenderMode.sharp, 0,
            Color.rgb(shade, shade, shade));
        auto expected = raw.alpha.dup;
        foreach (ref value; expected)
            value = transferTextCoverage(value, 0.5f * level / (TextCoverageClasses - 1));
        assert(mask(growing, entry) == expected, "Growth corrupted a color coverage variant");
    }
    assert(growing.width() > 32 && growing.rasterizations() == 1);

    auto fonts = new FontSystem();
    fonts.setFaces(face, face);
    auto list = new DrawList(fonts);
    list.reset(Size(500, 180), Color.rgb(255, 255, 255));
    auto canvas = Canvas(list, 500, 180);
    auto directSurface = new Surface(500, 180);
    directSurface.clear(Color.rgb(255, 255, 255));
    auto direct = Canvas(directSurface, fonts);
    const text = "office Il1 0123 e\u0301 \u0416\u0439"d;
    foreach (ref cv; [&canvas, &direct])
    {
        cv.fillRect(Rect(240, 0, 260, 180), Color.rgb(24, 24, 24));
        cv.fillRect(Rect(0, 120, 500, 30), Color.rgb(160, 195, 240));
        foreach (i, color; [Color.rgb(0, 0, 0), Color.rgb(255, 255, 255),
            Color.rgb(35, 41, 48), Color.rgb(240, 240, 240),
            Color.rgb(200, 35, 60), Color.rgb(30, 130, 70),
            Color.rgb(40, 80, 210), Color.rgba(60, 80, 160, 100)])
        {
            auto clipped = cv.clipped(Rect(2, 2, 490, 174));
            clipped.drawText(Point(4, 4 + cast(int) i * 20), text, color, 1);
            clipped.drawText(Point(244, 4 + cast(int) i * 20), text, color, 1);
        }
    }
    auto replay = new Surface(500, 180);
    SoftwareRenderer.renderInto(list, replay);
    assert(replay.pixels() == directSurface.pixels(),
        "Immediate and retained text must agree for colors, opacity, clips and selections");
    auto before = fonts.atlas.revision();
    canvas.drawText(Point(2, 2), "Invisible"d, Color.rgba(0, 0, 0, 0));
    assert(fonts.atlas.revision() == before);

    environment["AURORA_TEXT_CONTRAST"] = "NaN";
    assert((new GlyphAtlas()).coverageContrast() == 0.5f);
    environment["AURORA_TEXT_CONTRAST"] = "0";
    auto linear = new GlyphAtlas();
    auto dark = linear.glyphByIndex(face, glyph, 13, FontRenderMode.sharp, 0, Color.rgb(0, 0, 0));
    before = linear.revision();
    auto light = linear.glyphByIndex(face, glyph, 13, FontRenderMode.sharp, 0, Color.rgb(255, 255, 255));
    assert(dark.region == light.region && linear.revision() == before);
    candidate.clear();
    assert(candidate.pixels()[0] == 255);
    initial = candidate.rasterizations();
    candidate.glyphByIndex(face, glyph, 13);
    assert(candidate.rasterizations() == initial + 1);
    writeln("Foreground coverage: ", checked,
        " size/phase/mode cases; bounded color cache, growth, opacity, mixed surfaces and compatibility passed.");
    return 0;
}
