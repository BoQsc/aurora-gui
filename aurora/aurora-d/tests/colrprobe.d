module colrprobe;

/// Verify COLR color-glyph support against the real Segoe UI Emoji font.
/// Renders a known emoji glyph and reports whether color pixels appear.

import aurora.font : FontFace;
import std.stdio : writeln, writefln;
import std.math : abs;

int main(string[] args)
{
    string path = "C:\\Windows\\Fonts\\seguiemj.ttf";
    if (args.length > 1) path = args[1];
    import std.file : exists;
    if (!exists(path))
    {
        writeln("NO FONT");
        return 2;
    }
    auto face = FontFace.load(path);
    writefln("loaded %s upem=%d glyphs=%d hasColor=%s",
        path, face.unitsPerEm(), face.glyphCount(), face.hasColorGlyphs());

    const glyph = face.glyphIndex('\U0001F600');
    writefln("U+1F600 glyph index=%d", glyph);

    ubyte[] rgba;
    bool drew = face.rasterizeColorGlyph(glyph, 32, rgba);
    writefln("rasterizeColorGlyph drew=%s buffer=%d bytes", drew, rgba.length);

    // Count colored pixels.
    int opaque;
    int colored;
    foreach (i; 0 .. rgba.length / 4)
    {
        const r = rgba[i * 4];
        const g = rgba[i * 4 + 1];
        const b = rgba[i * 4 + 2];
        const a = rgba[i * 4 + 3];
        if (a == 0) continue;
        ++opaque;
        if (abs(cast(int) r - g) > 12 || abs(cast(int) g - b) > 12 || abs(cast(int) r - b) > 12)
            ++colored;
    }
    writefln("opaque=%d colored(non-gray)=%d", opaque, colored);
    return (drew && opaque > 0 && colored > 0) ? 0 : 1;
}
