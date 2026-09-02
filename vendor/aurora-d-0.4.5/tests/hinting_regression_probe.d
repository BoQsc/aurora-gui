module tests.hinting_regression_probe;

/**
 * Exercise the small UI glyph sequence that previously exposed shared
 * TrueType-hinter state leaking from one glyph into the next.
 */

import aurora.font : FontFace;
import std.file : exists;
import std.process : environment;
import std.stdio : writefln, writeln;

int main()
{
    const path = `C:\Windows\Fonts\segoeui.ttf`;
    if (!exists(path))
    {
        writeln("SKIP: Segoe UI is not installed");
        return 0;
    }

    auto face = FontFace.load(path);
    const enabled = environment.get("AURORA_HINTING", "0") == "1";
    const corpus = "Idle" ~ "0123456789:";
    int blanks;
    foreach (run; 0 .. 3)
    {
        foreach (ch; corpus)
        {
            const glyph = face.glyphIndex(cast(dchar) ch);
            auto bitmap = face.rasterizeGlyph(glyph, 13, 4);
            if (bitmap.width <= 0 || bitmap.height <= 0)
            {
                ++blanks;
                writefln("blank: char='%c' run=%d", ch, run);
            }
        }
    }

    writefln("hinting=%s blanks=%d", enabled ? "on" : "off", blanks);
    return blanks == 0 ? 0 : 1;
}
