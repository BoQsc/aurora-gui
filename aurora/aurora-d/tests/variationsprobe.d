module variationsprobe;

/// Verify variable-font support against a real variable font (InterVariable).
/// Loads the font, checks the axis inventory, renders a glyph at default and
/// heavy weight, and asserts the pixel buffers differ.

import aurora.font : FontFace;
import std.stdio : writeln, writefln;
import std.file : exists;

int main(string[] args)
{
    string path = "tests\\fonts\\InterVariable.ttf";
    if (args.length > 1) path = args[1];
    if (!exists(path))
    {
        writeln("NO FONT: ", path);
        return 1;
    }
    auto face = FontFace.load(path);
    writefln("loaded: %s upem=%d glyphs=%d", path, face.unitsPerEm(),
        face.glyphCount());

    const axes = (cast() face.openTypeFace()).variations();
    if (axes is null || !axes.hasVariations())
    {
        writeln("NO VARIATIONS (this should be a variable font)");
        return 1;
    }
    writefln("axes: %d", axes.axes().length);
    foreach (axis; axes.axes())
        writefln("  tag=0x%X min=%d def=%d max=%d",
            axis.axisTag, axis.minValue >> 16, axis.defaultValue >> 16,
            axis.maxValue >> 16);

    const glyph = face.glyphIndex('A');

    // Default weight render.
    auto tt = cast() face.openTypeFace();
    auto defaultBitmap = face.rasterizeGlyph(glyph, 48, 4);

    // Set the weight axis ('wght') to max (heavy).
    long[] coords;
    coords.length = axes.axes().length;
    foreach (i; 0 .. axes.axes().length)
        coords[i] = axes.axes()[i].defaultValue;
    bool set;
    foreach (i, axis; axes.axes())
    {
        if (axis.axisTag == 0x77676874) // 'wght'
        {
            coords[i] = axis.maxValue;
            set = true;
            break;
        }
    }
    if (!set)
    {
        writeln("NO WGHT AXIS");
        return 1;
    }
    const changed = tt.setVariationCoords(coords);
    writefln("setVariationCoords changed=%s", changed);

    auto heavyBitmap = face.rasterizeGlyph(glyph, 48, 4);

    // The two weight renders must differ in actual pixels.
    size_t diffPixels;
    foreach (i; 0 .. defaultBitmap.alpha.length)
        if (defaultBitmap.alpha[i] != heavyBitmap.alpha[i]) ++diffPixels;

    writefln("default: %dx%d advance=%d", defaultBitmap.width, defaultBitmap.height, defaultBitmap.advance);
    writefln("heavy:   %dx%d advance=%d", heavyBitmap.width, heavyBitmap.height, heavyBitmap.advance);
    writefln("differing pixels: %d", diffPixels);
    return diffPixels > 0 ? 0 : 1;
}
