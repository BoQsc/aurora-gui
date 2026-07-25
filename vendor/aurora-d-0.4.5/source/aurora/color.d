module aurora.color;

import aurora.types : clampInt;

/** Non-premultiplied 8-bit RGBA color. */
struct Color
{
    ubyte r;
    ubyte g;
    ubyte b;
    ubyte a = 255;

    static Color rgb(int red, int green, int blue) @safe pure nothrow @nogc
    {
        return rgba(red, green, blue, 255);
    }

    static Color rgba(int red, int green, int blue, int alpha) @safe pure nothrow @nogc
    {
        return Color(
            cast(ubyte) clampInt(red, 0, 255),
            cast(ubyte) clampInt(green, 0, 255),
            cast(ubyte) clampInt(blue, 0, 255),
            cast(ubyte) clampInt(alpha, 0, 255));
    }

    static Color fromHex(uint value, ubyte alpha = 255) @safe pure nothrow @nogc
    {
        return Color(
            cast(ubyte) ((value >> 16) & 0xff),
            cast(ubyte) ((value >> 8) & 0xff),
            cast(ubyte) (value & 0xff),
            alpha);
    }

    uint argb() const @safe pure nothrow @nogc
    {
        return (cast(uint) a << 24) |
               (cast(uint) r << 16) |
               (cast(uint) g << 8) |
               cast(uint) b;
    }

    Color withAlpha(int alpha) const @safe pure nothrow @nogc
    {
        return Color(r, g, b, cast(ubyte) clampInt(alpha, 0, 255));
    }

    Color lighter(int amount) const @safe pure nothrow @nogc
    {
        return rgba(r + amount, g + amount, b + amount, a);
    }

    Color darker(int amount) const @safe pure nothrow @nogc
    {
        return rgba(r - amount, g - amount, b - amount, a);
    }

    Color mixed(Color other, double t) const @safe pure nothrow @nogc
    {
        if (t < 0.0) t = 0.0;
        if (t > 1.0) t = 1.0;
        const inv = 1.0 - t;
        return rgba(
            cast(int) (r * inv + other.r * t + 0.5),
            cast(int) (g * inv + other.g * t + 0.5),
            cast(int) (b * inv + other.b * t + 0.5),
            cast(int) (a * inv + other.a * t + 0.5));
    }
}

unittest
{
    assert(Color.fromHex(0x123456).argb() == 0xff123456);
    assert(Color.rgb(300, -1, 4) == Color(255, 0, 4, 255));
}
