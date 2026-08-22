module hintprobe;

/// Standalone probe: rasterize 'M' and 'W' at small sizes with hinting
/// enabled (the pipeline now runs the TrueType bytecode interpreter) and
/// print the resulting bitmap geometry so we can sanity-check it.

import aurora.font : FontFace;
import aurora.text.truetype : TrueTypeFace;
import std.stdio : writeln, writefln;
import std.file : exists;

int main(string[] args)
{
    string path = "C:\\Windows\\Fonts\\segoeui.ttf";
    if (!exists(path))
    {
        writeln("NO FONT");
        return 1;
    }
    auto face = FontFace.load(path);
    writeln("upem=", face.unitsPerEm(), " glyphs=", face.glyphCount());

    foreach (ch; ['M', 'W', 'l', 'i', '0', 'O'])
    {
        const glyph = face.glyphIndex(ch);
        foreach (px; [12, 16, 24])
        {
            auto bitmap = face.rasterizeGlyph(glyph, px, 4);
            writefln("%c @ %2dpx: %3dx%-3d bearingX=%d bearingY=%d advance=%d coverage=%d",
                ch, px, bitmap.width, bitmap.height, bitmap.bearingX,
                bitmap.bearingY, bitmap.advance, glyphCoverage(bitmap.alpha));
        }
    }

    // Stress: every printable ASCII glyph at several sizes. Must never crash
    // and must never produce a blank glyph (hinting fallback guarantees it).
    int blank;
    foreach (ch; 32 .. 127)
    {
        const glyph = face.glyphIndex(cast(dchar) ch);
        foreach (px; [9, 12, 16, 24])
        {
            auto bitmap = face.rasterizeGlyph(glyph, px, 4);
            if (glyphCoverage(bitmap.alpha) == 0)
            {
                ++blank;
                writefln("  blank: char=%d(0x%X) px=%d", ch, ch, px);
            }
        }
    }
    writefln("ASCII stress: blanks=%d (0 expected)", blank);
    return blank == 0 ? 0 : 1;
}

private int glyphCoverage(const(ubyte)[] alpha)
{
    int total;
    foreach (value; alpha)
        if (value > 0) ++total;
    return total;
}
