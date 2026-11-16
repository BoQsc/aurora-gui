module indicprobe;

/// Verify Indic (Devanagari) complex-script reordering against Nirmala UI.
/// The sequence 'र् + क' (reph + ka) should reorder the reph to the end.

import aurora.font : FontFace;
import aurora.text.opentype : OpenTypeShaper, ShapeInput, ShapeOptions, ShapedGlyph;
import aurora.text.unicode.properties : Script;
import std.stdio : writeln, writefln;
import std.file : exists;

int main(string[] args)
{
    string path = "C:\\Windows\\Fonts\\Nirmala.ttf";
    if (args.length > 1) path = args[1];
    if (!exists(path))
    {
        writeln("NO FONT");
        return 2;
    }
    auto face = FontFace.load(path);
    writefln("loaded %s upem=%d", path, face.unitsPerEm());

    // Devanagari: ra (U+0930) + virama (U+094D) + ka (U+0915) + i-matra (U+093F)
    const text = "\u0930\u094D\u0915\u093F"d;
    ShapeInput[] inputs;
    foreach (i, ch; text) inputs ~= ShapeInput(ch, i, i + 1);

    ShapeOptions options;
    options.script = Script.devanagari;
    options.pixelSize = 32;

    auto shaper = new OpenTypeShaper(face);
    auto shaped = shaper.shape(inputs, options);

    writefln("shaped %d glyphs from %d chars:", shaped.length, text.length);
    foreach (i, glyph; shaped)
        writefln("  [%d] glyph=%d cp=0x%X cluster=%d..%d",
            i, glyph.glyphIndex, glyph.codepoint,
            glyph.clusterStart, glyph.clusterEnd);

    // The reph (ra) should have moved after the base consonant (ka).
    // In the reordered output the reph glyph appears after the ka.
    int raIndex = -1;
    int kaIndex = -1;
    foreach (i, glyph; shaped)
    {
        if (glyph.codepoint == 0x0930) raIndex = cast(int) i;
        if (glyph.codepoint == 0x0915) kaIndex = cast(int) i;
    }
    writefln("raIndex=%d kaIndex=%d (reph after base => %s)",
        raIndex, kaIndex, raIndex > kaIndex);
    return (raIndex > kaIndex) ? 0 : 1;
}
