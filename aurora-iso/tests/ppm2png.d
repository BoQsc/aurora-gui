/**
 * Minimal PPM (P6) to PNG converter used only for verifying Aurora ISO
 * screenshots. Depends on the standard library's zlib only.
 */
module ppm2png;

import std.file : read, write;
import std.stdio : stderr;
import std.zlib : compress, crc32;

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

void appendBe32(ref ubyte[] buffer, uint value)
{
    buffer ~= cast(ubyte)(value >> 24);
    buffer ~= cast(ubyte)(value >> 16);
    buffer ~= cast(ubyte)(value >> 8);
    buffer ~= cast(ubyte) value;
}

void appendChunk(ref ubyte[] output, string type, const(ubyte)[] payload)
{
    appendBe32(output, cast(uint) payload.length);
    ubyte[] crcInput;
    foreach (ch; type)
        crcInput ~= cast(ubyte) ch;
    crcInput ~= payload;
    output ~= crcInput[0 .. 4];
    output ~= payload;
    appendBe32(output, crc32(0, crcInput));
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

    import std.conv : to;
    const width = widthText.to!uint;
    const height = heightText.to!uint;

    ubyte[] raw;
    raw.reserve(height * (1 + width * 3));
    foreach (row; 0 .. height)
    {
        raw ~= cast(ubyte) 0; // filter: none
        const start = index + row * width * 3;
        raw ~= data[start .. start + width * 3];
    }
    auto compressed = cast(const(ubyte)[]) compress(raw);

    ubyte[] png;
    static immutable ubyte[] signature =
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
    png ~= signature;

    ubyte[] ihdr;
    appendBe32(ihdr, width);
    appendBe32(ihdr, height);
    ihdr ~= cast(ubyte) 8;  // bit depth
    ihdr ~= cast(ubyte) 2;  // color type: truecolor
    ihdr ~= cast(ubyte) 0;  // compression
    ihdr ~= cast(ubyte) 0;  // filter
    ihdr ~= cast(ubyte) 0;  // interlace
    appendChunk(png, "IHDR", ihdr);
    appendChunk(png, "IDAT", compressed);
    appendChunk(png, "IEND", []);

    write(args[2], png);
    stderr.writeln("wrote ", args[2], " ", width, "x", height);
    return 0;
}
