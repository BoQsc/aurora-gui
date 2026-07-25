module text_system;

/** Runtime integration checks for Aurora's pure-D font, shaping, and layout stack. */

import aurora.font : FontFace, FontRole;
import aurora.text.atlas : FontSystem, GlyphAtlas;
import aurora.text.fontcollection : FontCollection;
import aurora.text.layout : TextLayoutEngine, TextLayoutOptions;
import aurora.text.opentype : OpenTypeShaper, ShapeInput, ShapeOptions, ShapedGlyph;
import aurora.text.unicode.grapheme : graphemeBoundaries;
import aurora.text.unicode.properties : Script;

import std.file : exists;
import std.math : isFinite;
import std.process : environment;
import std.stdio : stderr, writefln, writeln;

private size_t checks;
private size_t failures;
private size_t skipped;

private void check(bool condition, string message)
{
    ++checks;
    if (!condition)
    {
        ++failures;
        stderr.writefln("FAIL: %s", message);
    }
}

private void skip(string message)
{
    ++skipped;
    writefln("SKIP: %s", message);
}

private string firstExisting(string environmentName, string[] candidates)
{
    const overridePath = environment.get(environmentName, "");
    if (overridePath.length && exists(overridePath)) return overridePath;
    foreach (candidate; candidates)
        if (exists(candidate)) return candidate;
    return null;
}

private ShapeInput[] inputs(const(dchar)[] text)
{
    ShapeInput[] result;
    foreach (i, ch; text) result ~= ShapeInput(ch, i, i + 1);
    return result;
}

private ShapedGlyph[] shape(FontFace face, const(dchar)[] text,
    Script script, bool rtl = false, bool ligatures = true,
    bool kerning = true)
{
    ShapeOptions options;
    options.script = script;
    options.pixelSize = 32;
    options.rightToLeft = rtl;
    options.enableLigatures = ligatures;
    options.enableKerning = kerning;
    return (new OpenTypeShaper(face)).shape(inputs(text), options);
}

private double advance(const(ShapedGlyph)[] glyphs)
{
    double result = 0.0;
    foreach (glyph; glyphs) result += glyph.advanceX;
    return result;
}

private bool antialiased(const(ubyte)[] alpha)
{
    foreach (value; alpha)
        if (value > 0 && value < 255) return true;
    return false;
}

private void testTrueType(string path)
{
    if (path.length == 0)
    {
        skip("TrueType integration font was not found");
        return;
    }
    auto face = FontFace.load(path);
    check(face.isTrueType(), "sfnt face loads");
    check(!face.hasCffOutlines(), "glyf font is identified as non-CFF");
    check(face.supports('A'), "glyf font exposes Unicode cmap coverage");
    auto bitmap = face.rasterizeGlyph(face.glyphIndex('A'), 32, 4);
    check(!bitmap.empty(), "glyf outline rasterizes");
    check(antialiased(bitmap.alpha), "glyf rasterization contains partial coverage");

    const office = "office"d;
    const shaped = shape(face, office, Script.latin, false, true, true);
    const unligated = shape(face, office, Script.latin, false, false, true);
    check(shaped.length < unligated.length,
        "Latin standard ligature substitution reduces office glyph count");
    bool hasClusterSpan;
    foreach (glyph; shaped)
        if (glyph.clusterEnd > glyph.clusterStart + 1) hasClusterSpan = true;
    check(hasClusterSpan, "ligature preserves its complete source cluster span");

    const kerned = shape(face, "AV"d, Script.latin, false, false, true);
    const unkerned = shape(face, "AV"d, Script.latin, false, false, false);
    check(advance(kerned) < advance(unkerned),
        "GPOS or legacy pair kerning tightens AV");

    const marked = shape(face, "a\u0301"d, Script.latin);
    check(marked.length > 0, "combining sequence shapes");
    bool positionedMark;
    foreach (glyph; marked)
    {
        check(isFinite(glyph.advanceX) && isFinite(glyph.offsetX) &&
            isFinite(glyph.offsetY), "shape output contains finite metrics");
        if (glyph.codepoint == '\u0301' && glyph.advanceX == 0.0 &&
            (glyph.offsetX != 0.0 || glyph.offsetY != 0.0))
            positionedMark = true;
    }
    check(positionedMark || marked.length == 1,
        "combining mark is attached or composed by OpenType layout");

    auto atlas = new GlyphAtlas(64, 64);
    const cached = atlas.glyphByIndex(face, shaped[0].glyphIndex, 32);
    check(cached.advance > 0, "shaped glyph enters the shared A8 atlas");
    check(atlas.revision > 1, "atlas revision changes after glyph insertion");
}

private FontFace testCff(string path)
{
    if (path.length == 0)
    {
        skip("static CFF integration font was not found");
        return null;
    }
    auto face = FontFace.load(path);
    check(face.hasCffOutlines(), "CFF1 outline face is detected");
    auto bitmap = face.rasterizeGlyph(face.glyphIndex('A'), 32, 4);
    check(!bitmap.empty(), "CFF Type 2 charstring rasterizes");
    check(antialiased(bitmap.alpha), "CFF rasterization contains partial coverage");

    const shaped = shape(face, "office"d, Script.latin, false, true, true);
    const unligated = shape(face, "office"d, Script.latin, false, false, true);
    check(shaped.length < unligated.length,
        "OpenType shaping also operates on a CFF outline face");
    return face;
}

private FontFace testArabic(string path)
{
    if (path.length == 0)
    {
        skip("Arabic integration font was not found");
        return null;
    }
    auto face = FontFace.load(path);
    const text = "سلام"d;
    const shaped = shape(face, text, Script.arabic, true);
    check(shaped.length > 0, "Arabic text produces visible glyphs");
    bool contextual;
    if (shaped.length != text.length)
        contextual = true;
    else
        foreach (i, glyph; shaped)
            if (glyph.glyphIndex != face.glyphIndex(text[i])) contextual = true;
    check(contextual, "Arabic joining forms or required ligatures are substituted");
    foreach (glyph; shaped)
        check(isFinite(glyph.advanceX) && isFinite(glyph.offsetX) &&
            isFinite(glyph.offsetY), "Arabic shape output contains finite metrics");
    return face;
}

private void testCffCollection(string path)
{
    if (path.length == 0)
    {
        skip("CID-keyed CFF collection was not found");
        return;
    }
    auto face = FontFace.load(path, 0);
    check(face.hasCffOutlines(), "CID-keyed TTC face loads through CFF parser");
    check(face.supports('中'), "CID-keyed collection maps a CJK character");
    auto bitmap = face.rasterizeGlyph(face.glyphIndex('中'), 32, 4);
    check(!bitmap.empty(), "CID-keyed CFF glyph rasterizes");
}

private void testFallback(FontFace latin, FontFace arabic, string cjkPath)
{
    if (latin is null)
    {
        skip("font fallback test lacks a Latin primary face");
        return;
    }
    auto collection = new FontCollection(latin);
    check(!collection.add(latin), "adding the same face twice is a no-op");
    if (arabic !is null && !latin.supports('س'))
    {
        check(collection.add(arabic), "Arabic fallback face is appended");
        check(collection.resolve("A"d) is latin,
            "Latin cluster stays on the primary face");
        check(collection.resolve("سَ"d) is arabic,
            "base plus combining mark resolves as one fallback cluster");
    }
    else
        skip("primary font already covers Arabic; ordered Arabic fallback is not observable");

    if (cjkPath.length && !latin.supports('中'))
    {
        auto cjk = FontFace.load(cjkPath, 0);
        check(collection.add(cjk), "CJK fallback face is appended");
        check(collection.resolve("中"d) is cjk,
            "CJK grapheme resolves to the matching fallback face");
    }
    else
        skip("CJK fallback font unavailable or already covered by primary");
}

private void testLayout()
{
    auto engine = new TextLayoutEngine();
    TextLayoutOptions options;
    options.pixelSize = 24;

    auto latin = engine.layout("office A\u0301"d, options);
    check(latin.lines.length == 1 && latin.glyphs.length > 0,
        "layout shapes a Latin line");
    check(latin.visualClusters.length ==
        graphemeBoundaries(latin.text).length - 1,
        "layout exposes one visual cluster per grapheme");

    auto emojiText = "x\U0001F469\u200D\U0001F4BBy"d;
    auto emoji = engine.layout(emojiText, options);
    check(emoji.visualMove(0, 1) == 1 && emoji.visualMove(1, 1) == 4,
        "visual caret movement treats emoji ZWJ sequence as one unit");

    options.maxWidth = 90;
    options.wrap = true;
    auto wrapped = engine.layout("one two three four five"d, options);
    check(wrapped.lines.length > 1, "Unicode line opportunities drive wrapping");
    foreach (line; wrapped.lines)
        check(line.width <= options.maxWidth + 1.0 ||
            line.logicalEnd == line.logicalStart + 1,
            "wrapped line obeys width unless one cluster itself is wider");

    options.maxWidth = 0;
    options.wrap = false;
    auto mixed = engine.layout("abc אבג 123"d, options);
    check(mixed.runs.length >= 2, "mixed-direction paragraph creates bidi runs");
    const selection = mixed.selectionRects(4, 7);
    check(selection.length > 0, "bidi selection produces visual geometry");
    foreach (rect; selection)
        check(rect.width > 0 && rect.height > 0,
            "bidi selection rectangles are non-empty");
    foreach (boundary; graphemeBoundaries(mixed.text))
    {
        const caret = mixed.caretPosition(boundary);
        check(caret.logicalIndex == boundary,
            "every grapheme boundary has a logical caret mapping");
    }
}

private void testFontSystemRevision(string fallbackPath)
{
    auto system = new FontSystem();
    const before = system.revision;
    if (fallbackPath.length)
    {
        const added = system.addFallback(FontRole.ui, fallbackPath);
        if (added)
            check(system.revision > before,
                "font-system revision changes when fallback order changes");
        else
            skip("revision test fallback was already present");
    }
    else
        skip("font-system revision test lacks an additional fallback face");
}

int main()
{
    const ttfPath = firstExisting("AURORA_TEST_TTF", [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
        "/usr/share/fonts/fonts/fonts-go/Go-Regular.ttf"
    ]);
    const latinFallbackPath = firstExisting("AURORA_TEST_LATIN_FALLBACK", [
        "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
        "/usr/share/fonts/fonts/fonts-go/Go-Regular.ttf",
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf"
    ]);
    const cffPath = firstExisting("AURORA_TEST_CFF", [
        "/usr/share/fonts/opentype/freefont/FreeSans.otf",
        "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
        "/usr/share/fonts/opentype/artemisia/GFSArtemisia.otf"
    ]);
    const arabicPath = firstExisting("AURORA_TEST_ARABIC", [
        "/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
        "/usr/share/fonts/opentype/fonts-hosny-amiri/Amiri-Regular.ttf"
    ]);
    const cjkPath = firstExisting("AURORA_TEST_CJK", [
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
    ]);

    testTrueType(ttfPath);
    auto cff = testCff(cffPath);
    auto arabic = testArabic(arabicPath);
    testCffCollection(cjkPath);

    FontFace fallbackPrimary;
    if (latinFallbackPath.length) fallbackPrimary = FontFace.load(latinFallbackPath);
    else if (ttfPath.length) fallbackPrimary = FontFace.load(ttfPath);
    else fallbackPrimary = cff;
    testFallback(fallbackPrimary, arabic, cjkPath);
    testLayout();
    testFontSystemRevision(cffPath);

    writefln("Text-system integration: %d checks, %d failures, %d skips",
        checks, failures, skipped);
    return failures == 0 ? 0 : 1;
}
