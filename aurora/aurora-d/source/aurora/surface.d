module aurora.surface;

import aurora.color : Color;
import aurora.types : Rect, Size, clampInt, maxInt, minInt;
import std.exception : enforce;
import std.stdio : File;

/** A CPU-side 32-bit ARGB pixel buffer. */
final class Surface
{
    private uint[] _pixels;
    private int _width;
    private int _height;

    this(int width, int height)
    {
        resize(width, height);
    }

    int width() const @safe pure nothrow @nogc { return _width; }
    int height() const @safe pure nothrow @nogc { return _height; }
    Size size() const @safe pure nothrow @nogc { return Size(_width, _height); }

    uint[] pixels() @safe pure nothrow @nogc { return _pixels; }
    const(uint)[] pixels() const @safe pure nothrow @nogc { return _pixels; }

    void resize(int width, int height)
    {
        width = maxInt(1, width);
        height = maxInt(1, height);
        if (width == _width && height == _height)
            return;
        _width = width;
        _height = height;
        _pixels.length = cast(size_t) width * cast(size_t) height;
        clear(Color.rgb(0, 0, 0));
    }

    void clear(Color color) @safe
    {
        _pixels[] = color.argb();
    }

    uint pixel(int x, int y) const @safe pure nothrow @nogc
    {
        if (x < 0 || y < 0 || x >= _width || y >= _height)
            return 0;
        return _pixels[cast(size_t) y * cast(size_t) _width + cast(size_t) x];
    }

    void setPixel(int x, int y, Color color) @safe nothrow @nogc
    {
        if (x < 0 || y < 0 || x >= _width || y >= _height)
            return;
        const index = cast(size_t) y * cast(size_t) _width + cast(size_t) x;
        if (color.a == 255)
            _pixels[index] = color.argb();
        else if (color.a != 0)
            _pixels[index] = blendArgb(_pixels[index], color);
    }

    void setPixelClipped(int x, int y, Color color, Rect clip) @safe nothrow @nogc
    {
        if (!clip.contains(x, y))
            return;
        setPixel(x, y, color);
    }

    void fillRect(Rect rect, Color color, Rect clip) @safe nothrow
    {
        rect = rect.intersection(clip).intersection(Rect(0, 0, _width, _height));
        if (rect.empty() || color.a == 0)
            return;

        if (color.a == 255)
        {
            const value = color.argb();
            foreach (y; rect.y .. rect.bottom())
            {
                const start = cast(size_t) y * cast(size_t) _width + cast(size_t) rect.x;
                _pixels[start .. start + cast(size_t) rect.width] = value;
            }
            return;
        }

        foreach (y; rect.y .. rect.bottom())
        {
            auto index = cast(size_t) y * cast(size_t) _width + cast(size_t) rect.x;
            foreach (_; 0 .. rect.width)
            {
                _pixels[index] = blendArgb(_pixels[index], color);
                ++index;
            }
        }
    }

    void savePpm(string path) const
    {
        enforce(_width > 0 && _height > 0, "Cannot save an empty surface");
        auto file = File(path, "wb");
        file.writef("P6\n%d %d\n255\n", _width, _height);
        ubyte[] row;
        row.length = cast(size_t) _width * 3;
        foreach (y; 0 .. _height)
        {
            foreach (x; 0 .. _width)
            {
                const argb = _pixels[cast(size_t) y * cast(size_t) _width + cast(size_t) x];
                const target = cast(size_t) x * 3;
                row[target + 0] = cast(ubyte) ((argb >> 16) & 0xff);
                row[target + 1] = cast(ubyte) ((argb >> 8) & 0xff);
                row[target + 2] = cast(ubyte) (argb & 0xff);
            }
            file.rawWrite(row);
        }
    }

    /** Save straight-alpha RGBA as a portable arbitrary map understood by FFmpeg. */
    void savePam(string path) const
    {
        enforce(_width > 0 && _height > 0, "Cannot save an empty surface");
        auto file = File(path, "wb");
        file.writef("P7\nWIDTH %d\nHEIGHT %d\nDEPTH 4\n" ~
            "MAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", _width, _height);
        ubyte[] row;
        row.length = cast(size_t) _width * 4;
        foreach (y; 0 .. _height)
        {
            foreach (x; 0 .. _width)
            {
                const argb = _pixels[cast(size_t) y * cast(size_t) _width +
                    cast(size_t) x];
                const target = cast(size_t) x * 4;
                const alpha = cast(uint) ((argb >> 24) & 0xff);
                uint red = (argb >> 16) & 0xff;
                uint green = (argb >> 8) & 0xff;
                uint blue = argb & 0xff;
                // Surface stores translucent pixels premultiplied. PAM/FFmpeg
                // expects straight-alpha RGBA, so recover the authored channels.
                if (alpha > 0 && alpha < 255)
                {
                    red = cast(uint) minInt(255, cast(int) ((red * 255 + alpha / 2) / alpha));
                    green = cast(uint) minInt(255, cast(int) ((green * 255 + alpha / 2) / alpha));
                    blue = cast(uint) minInt(255, cast(int) ((blue * 255 + alpha / 2) / alpha));
                }
                row[target + 0] = cast(ubyte) red;
                row[target + 1] = cast(ubyte) green;
                row[target + 2] = cast(ubyte) blue;
                row[target + 3] = cast(ubyte) alpha;
            }
            file.rawWrite(row);
        }
    }
}

uint blendArgb(uint destination, Color source) @safe pure nothrow @nogc
{
    const sa = cast(uint) source.a;
    if (sa == 0) return destination;
    if (sa == 255) return source.argb();

    const inv = 255u - sa;
    const dr = (destination >> 16) & 0xffu;
    const dg = (destination >> 8) & 0xffu;
    const db = destination & 0xffu;
    const da = (destination >> 24) & 0xffu;

    const rr = (cast(uint) source.r * sa + dr * inv + 127u) / 255u;
    const rg = (cast(uint) source.g * sa + dg * inv + 127u) / 255u;
    const rb = (cast(uint) source.b * sa + db * inv + 127u) / 255u;
    const ra = sa + (da * inv + 127u) / 255u;

    return (ra << 24) | (rr << 16) | (rg << 8) | rb;
}

unittest
{
    auto surface = new Surface(4, 4);
    surface.clear(Color.rgb(10, 20, 30));
    surface.fillRect(Rect(1, 1, 2, 2), Color.rgb(255, 0, 0), Rect(0, 0, 4, 4));
    assert(surface.pixel(0, 0) == 0xff0a141e);
    assert(surface.pixel(1, 1) == 0xffff0000);
}
