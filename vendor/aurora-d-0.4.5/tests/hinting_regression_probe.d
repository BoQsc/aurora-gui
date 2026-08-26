module hinting_regression_probe;

// Regression probe: verifies that rasterizing the sequence of glyphs used by
// the timeline ruler ("0","1","2",...) and the status "Idle" label never
// produces a blank glyph. With the partial TrueType hinting interpreter the
// glyphs '1' and 'I' collapsed to a zero-bbox blank (order-dependent), which
// is exactly the "number missing in the ruler" and "'Idle' rendered as 'dle'"
// complaints.

import aurora.font : FontFace;
import std.stdio : writeln, writefln;
import std.file : exists;

private static int coverage(const(ubyte)[] alpha)
{
    int total;
    foreach (value; alpha)
        if (value > 0) ++total;
    return total;
}

int main(string[] args)
{
    const path = "C:\\Windows\\Fonts\\segoeui.ttf";
    if (!exists(path))
    {
        writeln("NO FONT - cannot run regression probe");
        return 2;
    }
    auto face = FontFace.load(path);

    // Rasterize the ruler label set that drawRuler() produces, in order, then
    // repeat each glyph to catch order-dependent state corruption (the bug).
    int blanks;
    foreach (run; 0 .. 3)
    {
        foreach (ch; "Idle" ~ "0123456789:")
        {
            const glyph = face.glyphIndex(cast(dchar) ch);
            auto bitmap = face.rasterizeGlyph(glyph, 13, 4);
            if (bitmap.width <= 0 || bitmap.height <= 0)
            {
                ++blanks;
                writefln("  blank: char='%c' px=13 run=%d", ch, run);
            }
        }
    }
    writefln("ruler/idle glyph set: blanks=%d (0 expected)", blanks);
    return blanks == 0 ? 0 : 1;
}
