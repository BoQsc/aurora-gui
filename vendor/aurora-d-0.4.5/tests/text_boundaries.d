module tests.text_boundaries;

import aurora;
import std.algorithm : all, any;
import std.file : exists;
import std.math : abs;
import std.stdio : writefln, writeln;

private enum interPath = "/usr/share/fonts/opentype/inter/Inter-Regular.otf";
private enum cjkPath = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc";
private enum dejavuPath = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf";
private enum dejavuMonoPath = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf";
private enum amiriPath = "/usr/share/fonts/opentype/fonts-hosny-amiri/Amiri-Regular.ttf";

private ShapeInput[] makeInput(const(dchar)[] text)
{
    ShapeInput[] result;
    foreach (i, ch; text)
        result ~= ShapeInput(ch, i, i + 1);
    return result;
}

private double totalAdvance(const(ShapedGlyph)[] glyphs)
{
    double result = 0.0;
    foreach (glyph; glyphs) result += glyph.advanceX;
    return result;
}

private void testCff(string path, dchar sample, uint faceIndex = 0)
{
    if (!exists(path))
    {
        writefln("Skipping unavailable CFF fixture: %s", path);
        return;
    }
    auto face = FontFace.load(path, faceIndex);
    assert(face.hasCffOutlines());
    const glyph = face.glyphIndex(sample);
    assert(glyph != 0);
    auto bitmap = face.rasterizeGlyph(glyph, 32, 4);
    assert(!bitmap.empty());
    assert(bitmap.alpha.any!(value => value != 0));
    assert(bitmap.alpha.any!(value => value > 0 && value < 255));
    writefln("CFF: face %d U+%04X -> glyph %d, %dx%d (%s)",
        faceIndex, cast(uint) sample, glyph, bitmap.width, bitmap.height, path);
}

private void testOpenTypeShaping()
{
    if (exists(dejavuPath))
    {
        auto latin = FontFace.load(dejavuPath);
        auto shaper = new OpenTypeShaper(latin);
        immutable dstring sample = "office affinity"d;
        ShapeOptions enabled;
        enabled.script = Script.latin;
        enabled.pixelSize = 28;
        enabled.enableLigatures = true;
        auto withLigatures = shaper.shape(makeInput(sample), enabled);
        auto disabled = enabled;
        disabled.enableLigatures = false;
        auto withoutLigatures = shaper.shape(makeInput(sample), disabled);
        assert(withLigatures.length < withoutLigatures.length);
        assert(withLigatures.any!(glyph => glyph.isLigature));

        immutable dstring kernSample = "AV"d;
        auto kerned = shaper.shape(makeInput(kernSample), enabled);
        auto unkernedOptions = enabled;
        unkernedOptions.enableKerning = false;
        auto unkerned = shaper.shape(makeInput(kernSample), unkernedOptions);
        assert(abs(totalAdvance(kerned) - totalAdvance(unkerned)) > 0.1);

        immutable dstring markSample = "A\u0323"d;
        auto marked = shaper.shape(makeInput(markSample), enabled);
        assert(marked.length == 2);
        assert(marked[1].advanceX == 0.0);
        assert(abs(marked[1].offsetX) > 0.01 || abs(marked[1].offsetY) > 0.01);
        writefln("OpenType Latin: %d code points -> %d glyphs with liga; GPOS kern/mark active",
            sample.length, withLigatures.length);

        // Some monospaced fonts zero combining-mark width with a separate
        // SinglePos lookup after mark attachment. Attachment itself must not
        // zero the width first or the final advance becomes negative.
        if (exists(dejavuMonoPath))
        {
            auto mono = FontFace.load(dejavuMonoPath);
            auto monoShaper = new OpenTypeShaper(mono);
            auto monoMark = monoShaper.shape(makeInput("A\u0301"d), enabled);
            auto monoBase = monoShaper.shape(makeInput("A"d), enabled);
            assert(monoMark.length == 2);
            assert(monoMark[1].advanceX == 0.0);
            assert(abs(totalAdvance(monoMark) - totalAdvance(monoBase)) < 0.01);
        }
    }
    else
        writefln("Skipping unavailable Latin shaping fixture: %s", dejavuPath);

    if (exists(amiriPath))
    {
        auto arabic = FontFace.load(amiriPath);
        auto shaper = new OpenTypeShaper(arabic);
        immutable dstring text = "سَلَام العربية"d;
        ShapeOptions options;
        options.script = Script.arabic;
        options.rightToLeft = true;
        options.pixelSize = 30;
        auto shaped = shaper.shape(makeInput(text), options);
        assert(shaped.length > 0);
        assert(shaped.all!(glyph => glyph.glyphIndex != 0));
        bool substituted;
        foreach (glyph; shaped)
        {
            if (glyph.glyphIndex != arabic.glyphIndex(glyph.codepoint))
            {
                substituted = true;
                break;
            }
        }
        assert(substituted);
        assert(shaped.any!(glyph => glyph.advanceX == 0.0 &&
            (abs(glyph.offsetX) > 0.01 || abs(glyph.offsetY) > 0.01)));
        writefln("OpenType Arabic: joining substitutions and mark positioning active (%d glyphs)",
            shaped.length);
    }
    else
        writefln("Skipping unavailable Arabic fixture: %s", amiriPath);
}

private void testLayoutAndFallback()
{
    if (!exists(interPath) || !exists(amiriPath))
    {
        writefln("Skipping fallback fixture; Inter or Amiri is unavailable");
        return;
    }
    auto inter = FontFace.load(interPath);
    auto amiri = FontFace.load(amiriPath);
    auto fonts = new FontCollection(inter);
    fonts.add(amiri);
    fonts.add(FontFace.bitmapFallback());
    auto engine = new TextLayoutEngine(fonts, fonts);

    immutable dstring mixed = "English العربية (123) עברית A\u0301 👩‍🚀"d;
    TextLayoutOptions options;
    options.pixelSize = 24;
    options.maxWidth = 250;
    options.wrap = true;
    auto layout = engine.layout(mixed, options);
    assert(layout.lines.length >= 2);
    assert(layout.runs.length >= 3);
    assert(layout.glyphs.any!(glyph => glyph.font.identity == inter.identity));
    assert(layout.glyphs.any!(glyph => glyph.font.identity == amiri.identity));

    const boundaries = graphemeBoundaries(mixed);
    foreach (boundary; boundaries)
    {
        const caret = layout.caretPosition(boundary);
        assert(caret.logicalIndex == boundary);
        const hit = layout.hitTest(caret.x, caret.y + caret.height * 0.5);
        assert(isGraphemeBoundary(mixed, hit));
    }
    assert(layout.visualMove(0, 1) != 0);
    assert(layout.selectionRects(0, mixed.length).length >= layout.lines.length);
    writefln("Layout: %d lines, %d runs, %d glyphs, %d visual clusters",
        layout.lines.length, layout.runs.length, layout.glyphs.length,
        layout.visualClusters.length);
}

private Event keyEvent(Key key, bool control = false, bool shift = false)
{
    Event event;
    event.type = EventType.keyDown;
    event.key = key;
    if (control) event.modifiers |= cast(uint) KeyModifier.control;
    if (shift) event.modifiers |= cast(uint) KeyModifier.shift;
    return event;
}

private void testEditorClusters()
{
    auto editor = new TextArea("A\u0301👩‍🚀\nabc אבג");
    editor.setCursorIndex(1);
    assert(editor.cursorIndex == 0); // Inside A + combining acute snaps left.

    auto right = keyEvent(Key.right);
    assert(editor.onKeyDown(right));
    assert(editor.cursorIndex == 2);
    assert(editor.onKeyDown(right));
    assert(editor.cursorIndex == 5); // Complete emoji ZWJ cluster.

    auto backspace = keyEvent(Key.backspace);
    assert(editor.onKeyDown(backspace));
    assert(editor.textUtf32 == "A\u0301\nabc אבג"d);
    assert(editor.cursorIndex == 2);

    editor.setCursorIndex(0);
    assert(editor.onKeyDown(right));
    assert(editor.cursorIndex == 2);
    auto deleteKey = keyEvent(Key.deleteKey);
    assert(editor.onKeyDown(deleteKey));
    assert(editor.textUtf32 == "A\u0301abc אבג"d); // newline deleted intact.

    editor.setText("abc אבג", false);
    editor.setCursorIndex(4);
    assert(editor.caretAffinity == CaretAffinity.downstream);
    auto left = keyEvent(Key.left);
    // From the right edge of the RTL run, physical-left traversal visits the
    // Hebrew graphemes in visual order, then the second caret for logical 4.
    foreach (expected; [cast(size_t) 5, 6, 7, 4])
    {
        assert(editor.onKeyDown(left));
        assert(editor.cursorIndex == expected);
        assert(isGraphemeBoundary(editor.textView, editor.cursorIndex));
    }
    assert(editor.caretAffinity == CaretAffinity.upstream);
    assert(editor.onKeyDown(left));
    assert(editor.cursorIndex == 3);
    writeln("Editor: grapheme-safe navigation/deletion and visual bidi movement active");
}

int main()
{
    testCff(interPath, 'A');
    testCff(cjkPath, '中');
    testOpenTypeShaping();
    testLayoutAndFallback();
    testEditorClusters();
    writeln("Text boundary integration tests passed.");
    return 0;
}
