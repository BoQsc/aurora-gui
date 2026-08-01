module aurora.canvas;

import aurora.color : Color;
import aurora.font : FontFace, FontMetrics, FontRole, fontPixelSize;
import aurora.image : RgbaImage;
import aurora.render.drawlist : DrawList;
import aurora.surface : Surface;
import aurora.text.atlas : AtlasGlyph, FontSystem;
import aurora.text.layout : TextLayout, TextLayoutOptions;
import aurora.text.unicode.grapheme : previousGraphemeBoundary;
import aurora.types : HorizontalAlign, Point, Rect, Size, VerticalAlign,
    clampInt, maxInt, minInt;
import std.math : floor;

/** Drawing context with translation/clipping and software or draw-list output. */
struct Canvas
{
    private Surface _surface;
    private DrawList _drawList;
    private FontSystem _fonts;
    private int _offsetX;
    private int _offsetY;
    private Rect _clip;

    this(Surface surface)
    {
        _surface = surface;
        _fonts = FontSystem.sharedInstance();
        _clip = Rect(0, 0, surface.width(), surface.height());
    }

    /** Immediate surface canvas with an explicit font system.
     * Used by worker-side title rasterization so UI and export do not share a
     * mutable glyph atlas. */
    this(Surface surface, FontSystem fonts)
    {
        _surface = surface;
        _fonts = fonts is null ? FontSystem.sharedInstance() : fonts;
        _clip = Rect(0, 0, surface.width(), surface.height());
    }

    this(DrawList list, int width, int height)
    {
        _drawList = list;
        _fonts = list.fonts;
        _clip = Rect(0, 0, width, height);
    }

    private this(Surface surface, DrawList list, FontSystem fonts,
        int offsetX, int offsetY, Rect clip)
    {
        _surface = surface;
        _drawList = list;
        _fonts = fonts;
        _offsetX = offsetX;
        _offsetY = offsetY;
        _clip = clip;
    }

    Surface surface() { return _surface; }
    DrawList drawList() { return _drawList; }
    Rect clipRect() const @safe pure nothrow @nogc { return _clip; }

    Canvas translated(int dx, int dy)
    {
        return Canvas(_surface, _drawList, _fonts,
            _offsetX + dx, _offsetY + dy, _clip);
    }

    Canvas clipped(Rect localRect)
    {
        const absolute = localRect.translated(_offsetX, _offsetY);
        return Canvas(_surface, _drawList, _fonts, _offsetX, _offsetY,
            _clip.intersection(absolute));
    }

    Point toSurface(Point point) const @safe pure nothrow @nogc
    {
        return Point(point.x + _offsetX, point.y + _offsetY);
    }

    Rect toSurface(Rect rect) const @safe pure nothrow @nogc
    {
        return rect.translated(_offsetX, _offsetY);
    }

    void clear(Color color)
    {
        if (_drawList !is null)
            _drawList.addSolidRect(_clip, color, _clip);
        else if (_surface !is null)
            _surface.fillRect(_clip, color, _clip);
    }

    void fillRect(Rect rect, Color color)
    {
        const absolute = toSurface(rect);
        if (_drawList !is null)
            _drawList.addSolidRect(absolute, color, _clip);
        else if (_surface !is null)
            _surface.fillRect(absolute, color, _clip);
    }

    /** Draw an RGB24 image with scaling. The draw-list path retains the pixel buffer. */
    void drawRgbImage(Rect destination, int width, int height, ubyte[] pixels,
        bool linearFiltering = true)
    {
        if (destination.empty() || width <= 0 || height <= 0) return;
        const required = cast(size_t) width * cast(size_t) height * 3;
        if (pixels.length < required) return;
        const absolute = toSurface(destination);
        if (_drawList !is null)
        {
            _drawList.addRgbImage(absolute, width, height, pixels, _clip,
                linearFiltering);
            return;
        }
        if (_surface is null) return;

        const clipped = absolute.intersection(_clip);
        if (clipped.empty()) return;
        foreach (y; clipped.y .. clipped.bottom())
        {
            const sourceY = clampInt((y - absolute.y) * height /
                maxInt(1, absolute.height), 0, height - 1);
            foreach (x; clipped.x .. clipped.right())
            {
                const sourceX = clampInt((x - absolute.x) * width /
                    maxInt(1, absolute.width), 0, width - 1);
                const offset = (cast(size_t) sourceY * cast(size_t) width +
                    cast(size_t) sourceX) * 3;
                _surface.setPixel(x, y, Color.rgb(pixels[offset],
                    pixels[offset + 1], pixels[offset + 2]));
            }
        }
    }

    void drawImage(Rect destination, RgbaImage image, bool linearFiltering = true)
    {
        if (image is null) return;
        drawImage(destination, image, image.bounds(), Color(255, 255, 255, 255),
            linearFiltering);
    }

    void drawImage(Rect destination, RgbaImage image, Rect source,
        Color tint = Color(255, 255, 255, 255), bool linearFiltering = true)
    {
        if (image is null || destination.empty() || tint.a == 0) return;
        source = source.intersection(image.bounds());
        if (source.empty()) return;
        const absolute = toSurface(destination);
        if (_drawList !is null)
        {
            _drawList.addRgbaImage(absolute, image, source, tint, _clip,
                linearFiltering);
            return;
        }
        if (_surface is null) return;

        const clipped = absolute.intersection(_clip);
        if (clipped.empty()) return;
        const pixels = image.pixels();
        foreach (y; clipped.y .. clipped.bottom())
        {
            const sourceY = source.y + clampInt((y - absolute.y) * source.height /
                maxInt(1, absolute.height), 0, source.height - 1);
            foreach (x; clipped.x .. clipped.right())
            {
                const sourceX = source.x + clampInt((x - absolute.x) * source.width /
                    maxInt(1, absolute.width), 0, source.width - 1);
                const offset = (cast(size_t) sourceY * cast(size_t) image.width() +
                    cast(size_t) sourceX) * 4;
                auto color = Color(pixels[offset], pixels[offset + 1],
                    pixels[offset + 2], pixels[offset + 3]);
                if (tint != Color(255, 255, 255, 255))
                    color = tintedImageColor(color, tint);
                _surface.setPixel(x, y, color);
            }
        }
    }

    void strokeRect(Rect rect, Color color, int thickness = 1)
    {
        thickness = maxInt(1, thickness);
        fillRect(Rect(rect.x, rect.y, rect.width, thickness), color);
        fillRect(Rect(rect.x, rect.bottom() - thickness, rect.width, thickness), color);
        fillRect(Rect(rect.x, rect.y + thickness, thickness,
            maxInt(0, rect.height - thickness * 2)), color);
        fillRect(Rect(rect.right() - thickness, rect.y + thickness, thickness,
            maxInt(0, rect.height - thickness * 2)), color);
    }

    void fillVerticalGradient(Rect rect, Color top, Color bottom)
    {
        if (rect.height <= 0) return;
        if (_drawList !is null)
        {
            _drawList.addVerticalGradient(toSurface(rect), top, bottom, _clip);
            return;
        }
        foreach (row; 0 .. rect.height)
        {
            const t = rect.height <= 1 ? 0.0 : cast(double) row / (rect.height - 1);
            fillRect(Rect(rect.x, rect.y + row, rect.width, 1), top.mixed(bottom, t));
        }
    }

    void drawLine(Point from, Point to, Color color, int thickness = 1)
    {
        if (_drawList !is null)
        {
            _drawList.addLine(toSurface(from), toSurface(to), color, thickness, _clip);
            return;
        }
        auto a = toSurface(from);
        auto b = toSurface(to);
        int x0 = a.x;
        int y0 = a.y;
        const x1 = b.x;
        const y1 = b.y;
        const dx = x1 > x0 ? x1 - x0 : x0 - x1;
        const sx = x0 < x1 ? 1 : -1;
        const dyAbs = y1 > y0 ? y1 - y0 : y0 - y1;
        const dy = -dyAbs;
        const sy = y0 < y1 ? 1 : -1;
        int error = dx + dy;
        const radius = maxInt(0, thickness - 1) / 2;
        while (true)
        {
            if (thickness <= 1)
                _surface.setPixelClipped(x0, y0, color, _clip);
            else
                _surface.fillRect(Rect(x0 - radius, y0 - radius, thickness, thickness), color, _clip);
            if (x0 == x1 && y0 == y1) break;
            const twice = 2 * error;
            if (twice >= dy) { error += dy; x0 += sx; }
            if (twice <= dx) { error += dx; y0 += sy; }
        }
    }

    void fillCircle(Point center, int radius, Color color)
    {
        if (radius <= 0) return;
        if (_drawList !is null)
        {
            _drawList.addCircle(toSurface(center), radius, color, _clip);
            return;
        }
        const c = toSurface(center);
        const rr = radius * radius;
        foreach (dy; -radius .. radius + 1)
        {
            int extent;
            while ((extent + 1) * (extent + 1) + dy * dy <= rr) ++extent;
            _surface.fillRect(Rect(c.x - extent, c.y + dy, extent * 2 + 1, 1), color, _clip);
        }
    }

    void strokeCircle(Point center, int radius, Color color, int thickness = 1)
    {
        thickness = maxInt(1, thickness);
        if (_drawList !is null)
        {
            _drawList.addCircleStroke(toSurface(center), radius, color, thickness, _clip);
            return;
        }
        const outer = radius;
        const inner = maxInt(0, radius - thickness);
        const c = toSurface(center);
        const outerSquared = outer * outer;
        const innerSquared = inner * inner;
        foreach (dy; -outer .. outer + 1)
            foreach (dx; -outer .. outer + 1)
            {
                const distance = dx * dx + dy * dy;
                if (distance <= outerSquared && distance >= innerSquared)
                    _surface.setPixelClipped(c.x + dx, c.y + dy, color, _clip);
            }
    }

    void fillRoundedRect(Rect rect, int radius, Color color)
    {
        radius = clampInt(radius, 0, minInt(rect.width, rect.height) / 2);
        if (_drawList !is null)
        {
            _drawList.addRoundedRect(toSurface(rect), radius, color, _clip);
            return;
        }
        if (radius <= 0)
        {
            fillRect(rect, color);
            return;
        }
        auto absolute = toSurface(rect).intersection(_clip);
        if (absolute.empty()) return;
        const original = toSurface(rect);
        const rr = radius * radius;
        foreach (y; absolute.y .. absolute.bottom())
            foreach (x; absolute.x .. absolute.right())
            {
                int cx = x;
                int cy = y;
                if (x < original.x + radius) cx = original.x + radius;
                else if (x >= original.right() - radius) cx = original.right() - radius - 1;
                if (y < original.y + radius) cy = original.y + radius;
                else if (y >= original.bottom() - radius) cy = original.bottom() - radius - 1;
                const dx = x - cx;
                const dy = y - cy;
                if (dx * dx + dy * dy <= rr) _surface.setPixel(x, y, color);
            }
    }

    void drawRoundedRect(Rect rect, int radius, Color fill, Color border, int thickness = 1)
    {
        thickness = maxInt(1, thickness);
        fillRoundedRect(rect, radius, border);
        const inner = rect.inset(thickness);
        if (!inner.empty()) fillRoundedRect(inner, maxInt(0, radius - thickness), fill);
    }

    /** Shape text through the shared Unicode/OpenType layout engine. */
    TextLayout layoutText(const(dchar)[] text, int scale = 2,
        FontRole role = FontRole.ui, const(FontFace) font = null,
        int maxWidth = 0, bool wrap = false)
    {
        if (_fonts is null) _fonts = FontSystem.sharedInstance();
        TextLayoutOptions options;
        options.role = role;
        options.overrideFace = cast(FontFace) font;
        options.pixelSize = fontPixelSize(maxInt(1, scale));
        options.maxWidth = maxWidth;
        options.wrap = wrap;
        return !wrap && maxWidth == 0 ?
            _fonts.textEngine.layoutCached(text, options) :
            _fonts.textEngine.layout(text, options);
    }

    /** Replay a previously shaped layout without reshaping it. */
    void drawLayout(Point position, TextLayout layout, Color color)
    {
        if (layout is null || color.a == 0) return;
        if (_fonts is null) _fonts = FontSystem.sharedInstance();
        foreach (positioned; layout.glyphs)
        {
            if (_drawList !is null)
            {
                // Layout remains in 96-DPI logical units. Rasterize at the
                // monitor's physical size, snap the baseline to a device pixel,
                // and submit the atlas bitmap 1:1 so it is never enlarged by
                // the renderer or by Windows DPI virtualization.
                const pixelSize = maxInt(1,
                    _drawList.logicalToDeviceY(layout.pixelSize));
                const glyph = _fonts.atlas.glyphByIndex(positioned.font,
                    positioned.glyphIndex, pixelSize, _fonts.renderMode);
                if (!glyph.hasPixels()) continue;
                const x = _drawList.logicalToDeviceX(
                    position.x + _offsetX + positioned.x) + glyph.bearingX;
                const y = _drawList.logicalToDeviceY(
                    position.y + _offsetY + positioned.y) - glyph.bearingY;
                const destination = Rect(x, y, glyph.region.width, glyph.region.height);
                _drawList.addTexturedRectDevice(destination, glyph, color,
                    _drawList.logicalToDevice(_clip));
            }
            else
            {
                const glyph = _fonts.atlas.glyphByIndex(positioned.font,
                    positioned.glyphIndex, layout.pixelSize, _fonts.renderMode);
                if (!glyph.hasPixels()) continue;
                const x = position.x + cast(int) floor(positioned.x + 0.5) + glyph.bearingX;
                const y = position.y + cast(int) floor(positioned.y + 0.5) - glyph.bearingY;
                drawGlyphImmediate(toSurface(Rect(x, y,
                    glyph.region.width, glyph.region.height)), glyph, color);
            }
        }
    }

    void drawText(Point position, const(dchar)[] text, Color color, int scale = 2,
        FontRole role = FontRole.ui, const(FontFace) font = null)
    {
        if (text.length == 0 || color.a == 0) return;
        auto layout = layoutText(text, scale, role, font, 0, false);
        drawLayout(position, layout, color);
    }

    void drawTextInRect(Rect rect, const(dchar)[] text, Color color, int scale = 2,
        HorizontalAlign horizontal = HorizontalAlign.left,
        VerticalAlign vertical = VerticalAlign.middle,
        bool ellipsis = true, FontRole role = FontRole.ui, const(FontFace) font = null)
    {
        scale = maxInt(1, scale);
        dchar[] rendered = text.dup;
        auto layout = layoutText(rendered, scale, role, font, 0, false);
        if (ellipsis && layout.width > rect.width)
        {
            immutable(dchar)[] dots = "..."d;
            auto dotsLayout = layoutText(dots, scale, role, font, 0, false);
            if (dotsLayout.width > rect.width)
            {
                rendered.length = 0;
                layout = layoutText(rendered, scale, role, font, 0, false);
            }
            else
            {
                size_t boundary = rendered.length;
                do
                {
                    boundary = previousGraphemeBoundary(rendered, boundary);
                    layout = layoutText(rendered[0 .. boundary] ~ dots,
                        scale, role, font, 0, false);
                }
                while (boundary > 0 && layout.width > rect.width);
                rendered = rendered[0 .. boundary] ~ dots;
            }
        }
        const measured = layout.measuredSize();
        int x = rect.x;
        final switch (horizontal)
        {
            case HorizontalAlign.left: break;
            case HorizontalAlign.center: x += maxInt(0, (rect.width - measured.width) / 2); break;
            case HorizontalAlign.right: x += maxInt(0, rect.width - measured.width); break;
        }
        int y = rect.y;
        final switch (vertical)
        {
            case VerticalAlign.top: break;
            case VerticalAlign.middle: y += maxInt(0, (rect.height - measured.height) / 2); break;
            case VerticalAlign.bottom: y += maxInt(0, rect.height - measured.height); break;
        }
        auto child = clipped(rect);
        child.drawLayout(Point(x, y), layout, color);
    }

    Size measureText(const(dchar)[] text, int scale = 2,
        FontRole role = FontRole.ui, const(FontFace) font = null)
    {
        return layoutText(text, scale, role, font, 0, false).measuredSize();
    }

    private const(FontFace) selectFont(FontRole role, const(FontFace) overrideFace)
    {
        if (overrideFace !is null) return overrideFace;
        if (_fonts is null) _fonts = FontSystem.sharedInstance();
        return _fonts.face(role);
    }

    private void drawGlyphImmediate(Rect destination, AtlasGlyph glyph, Color color)
    {
        if (_surface is null) return;
        const atlas = _fonts.atlas;
        const pixels = atlas.pixels();
        const atlasWidth = atlas.width();
        foreach (y; 0 .. glyph.region.height)
        {
            foreach (x; 0 .. glyph.region.width)
            {
                const coverage = pixels[cast(size_t) (glyph.region.y + y) * atlasWidth +
                    cast(size_t) glyph.region.x + x];
                if (coverage == 0) continue;
                const alpha = (cast(int) color.a * coverage + 127) / 255;
                _surface.setPixelClipped(destination.x + x, destination.y + y,
                    Color(color.r, color.g, color.b, cast(ubyte) alpha), _clip);
            }
        }
    }

    private static Color tintedImageColor(Color source, Color tint)
        @safe pure nothrow @nogc
    {
        return Color(
            cast(ubyte) ((cast(uint) source.r * cast(uint) tint.r + 127u) / 255u),
            cast(ubyte) ((cast(uint) source.g * cast(uint) tint.g + 127u) / 255u),
            cast(ubyte) ((cast(uint) source.b * cast(uint) tint.b + 127u) / 255u),
            cast(ubyte) ((cast(uint) source.a * cast(uint) tint.a + 127u) / 255u));
    }
}

unittest
{
    auto surface = new Surface(128, 48);
    auto canvas = Canvas(surface);
    canvas.fillRect(Rect(0, 0, 128, 48), Color.rgb(255, 255, 255));
    canvas.drawText(Point(2, 2), "Smooth"d, Color.rgb(0, 0, 0), 2);
    bool changed;
    foreach (pixel; surface.pixels())
        if (pixel != 0xffffffff) { changed = true; break; }
    assert(changed);
}
