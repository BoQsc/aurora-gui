/**
 * Minimal PPM (P6) to PNG converter used only for verifying Aurora ISO
 * screenshots. The PNG encoding itself now comes from the shared
 * `aurora.image.encodePng`, so no hand-rolled PNG writer lives here.
 */
module ppm2png;

import aurora.image : RgbaImage, encodePng;

import std.file : read, write;
import std.stdio : stderr;
import std.conv : to;

uint readToken(const(ubyte)[] data, ref size_t index, out string token)
{
    while (index < data.length && (data[index] == ' ' || data[index] == '\t' ||
        data[index] == '\r' || data[index] == '\n'))
        ++index;
    if (index < data.length && data[index] == '#')
    {
        while (index < data.length && data[index] != '\n')
            ++index;
        return readToken(data, index, token);
    }
    size_t start = index;
    while (index < data.length && data[index] != ' ' && data[index] != '\t' &&
        data[index] != '\r' && data[index] != '\n')
        ++index;
    token = cast(string) data[start .. index].dup;
    return 1;
}

int main(string[] args)
{
    if (args.length != 3)
    {
        stderr.writeln("usage: ppm2png input.ppm output.png");
        return 2;
    }

    auto data = cast(const(ubyte)[]) read(args[1]);
    size_t index = 0;
    string magic;
    readToken(data, index, magic);
    if (magic != "P6")
    {
        stderr.writeln("not a P6 PPM (got ", magic, ")");
        return 1;
    }
    string widthText;
    string heightText;
    string maxText;
    readToken(data, index, widthText);
    readToken(data, index, heightText);
    readToken(data, index, maxText);
    ++index; // single whitespace after maxval

    const width = widthText.to!uint;
    const height = heightText.to!uint;

    // Expand the RGB PPM into straight-alpha RGBA for the shared encoder.
    auto rgba = new ubyte[cast(size_t) width * cast(size_t) height * 4];
    foreach (i; 0 .. cast(size_t) width * cast(size_t) height)
    {
        const src = index + i * 3;
        if (src + 2 >= data.length) break;
        rgba[i * 4] = data[src];
        rgba[i * 4 + 1] = data[src + 1];
        rgba[i * 4 + 2] = data[src + 2];
        rgba[i * 4 + 3] = 255;
    }

    auto image = new RgbaImage(cast(int) width, cast(int) height, rgba);
    write(args[2], encodePng(image));
    stderr.writeln("wrote ", args[2], " ", width, "x", height);
    return 0;
}
