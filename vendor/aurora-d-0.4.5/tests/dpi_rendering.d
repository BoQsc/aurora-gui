module tests.dpi_rendering;

/**
 * Deterministic high-DPI regression test.
 *
 * The test runs headlessly but exercises the same logical-to-physical draw
 * list, physical-size glyph atlas, pixel-snapped text quads, and software
 * replay used by the Win32 and Vulkan paths.
 */

import aurora;
import std.math : abs;
import std.stdio : writefln, writeln;

private ulong contrastEnergy(const(ubyte)[] pixels, int atlasWidth, Rect region)
    @safe pure nothrow @nogc
{
    ulong result;
    foreach (y; region.y .. region.bottom())
        foreach (x; region.x .. region.right())
        {
            const value = cast(int) pixels[cast(size_t) y * cast(size_t) atlasWidth +
                cast(size_t) x];
            result += cast(ulong) abs(value - 128);
        }
    return result;
}

private bool hasIntermediateCoverage(const(ubyte)[] pixels, int atlasWidth, Rect region)
    @safe pure nothrow @nogc
{
    foreach (y; region.y .. region.bottom())
        foreach (x; region.x .. region.right())
        {
            const value = pixels[cast(size_t) y * cast(size_t) atlasWidth +
                cast(size_t) x];
            if (value > 0 && value < 255) return true;
        }
    return false;
}

private void verifyScale(FontSystem fonts, uint dpi)
{
    const logical = Size(120, 80);
    const scale = DisplayScale.fromDpi(dpi);
    const physical = scale.logicalToPhysical(logical);
    auto list = new DrawList(fonts);
    list.reset(logical, physical, scale, Color.rgb(4, 8, 12));

    const logicalRect = Rect(10, 12, 20, 8);
    const physicalRect = scale.logicalToPhysical(logicalRect);
    list.addSolidRect(logicalRect, Color.rgb(220, 40, 30),
        Rect(0, 0, logical.width, logical.height));
    assert(list.logicalViewport == logical);
    assert(list.viewport == physical);
    assert(list.vertices[0].x == cast(float) physicalRect.x);
    assert(list.vertices[0].y == cast(float) physicalRect.y);
    assert(list.vertices[2].x == cast(float) physicalRect.right());
    assert(list.vertices[2].y == cast(float) physicalRect.bottom());
    assert(list.batches[0].clip == Rect(0, 0, physical.width, physical.height));

    auto canvas = Canvas(list, logical.width, logical.height);
    auto layout = canvas.layoutText("Sharp DPI"d, 2, FontRole.ui);
    const firstTextVertex = list.vertices.length;
    canvas.drawLayout(Point(20, 42), layout, Color.rgb(255, 255, 255));
    assert(list.vertices.length >= firstTextVertex + 4);

    const physicalPixelSize = scale.logicalToPhysicalY(layout.pixelSize);
    const shaped = layout.glyphs[0];
    const physicalGlyph = fonts.atlas.glyphByIndex(shaped.font, shaped.glyphIndex,
        physicalPixelSize, FontRenderMode.sharp);
    assert(list.vertices[firstTextVertex + 1].x - list.vertices[firstTextVertex].x ==
        cast(float) physicalGlyph.region.width);
    assert(list.vertices[firstTextVertex + 3].y - list.vertices[firstTextVertex].y ==
        cast(float) physicalGlyph.region.height);

    auto target = new Surface(1, 1);
    SoftwareRenderer.renderInto(list, target);
    assert(target.size == physical);
    assert(target.pixel(physicalRect.x + 1, physicalRect.y + 1) ==
        Color.rgb(220, 40, 30).argb());

    bool foundTextPixel;
    foreach (pixel; target.pixels())
    {
        if ((pixel & 0x00ffffffu) == 0x00ffffffu)
        {
            foundTextPixel = true;
            break;
        }
    }
    assert(foundTextPixel);

    writefln("DPI %s: logical %sx%s -> framebuffer %sx%s; font %spx",
        dpi, logical.width, logical.height, physical.width, physical.height,
        physicalPixelSize);
}

int main()
{
    const scale150 = DisplayScale.fromDpi(144);
    assert(DisplayScale.fromDpi(120).logicalToPhysical(Size(800, 600)) ==
        Size(1000, 750));
    assert(scale150.logicalToPhysical(Size(800, 600)) == Size(1200, 900));
    assert(DisplayScale.fromDpi(192).logicalToPhysical(Size(800, 600)) ==
        Size(1600, 1200));
    assert(scale150.physicalToLogical(Size(1200, 900)) == Size(800, 600));
    assert(scale150.logicalToPhysical(Rect(10, 12, 20, 8)) ==
        Rect(15, 18, 30, 12));

    auto fonts = new FontSystem("", "", FontRenderMode.sharp);
    foreach (dpi; [120u, 144u, 192u])
        verifyScale(fonts, dpi);

    auto face = SystemFonts.sans();
    auto smoothAtlas = new GlyphAtlas(64, 64);
    auto sharpAtlas = new GlyphAtlas(64, 64);
    const glyphIndex = face.glyphIndex('A');
    const smooth = smoothAtlas.glyphByIndex(face, glyphIndex, 15,
        FontRenderMode.smooth);
    const sharp = sharpAtlas.glyphByIndex(face, glyphIndex, 15,
        FontRenderMode.sharp);
    assert(smooth.region.width == sharp.region.width);
    assert(smooth.region.height == sharp.region.height);
    const smoothEnergy = contrastEnergy(smoothAtlas.pixels(), smoothAtlas.width(),
        smooth.region);
    const sharpEnergy = contrastEnergy(sharpAtlas.pixels(), sharpAtlas.width(),
        sharp.region);
    assert(sharpEnergy >= smoothEnergy);
    if (face.isOpenType() && hasIntermediateCoverage(
        smoothAtlas.pixels(), smoothAtlas.width(), smooth.region))
        assert(sharpEnergy > smoothEnergy);

    writeln("High-DPI geometry, physical glyphs, and sharp grayscale mode passed.");
    return 0;
}
