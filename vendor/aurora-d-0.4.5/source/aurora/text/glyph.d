module aurora.text.glyph;

/** An antialiased A8 glyph bitmap and its horizontal metrics. */
struct GlyphBitmap
{
    uint glyphIndex;
    int width;
    int height;
    int bearingX;
    int bearingY;
    int advance;
    ubyte[] alpha;

    bool empty() const @safe pure nothrow @nogc
    {
        return width <= 0 || height <= 0 || alpha.length == 0;
    }
}
