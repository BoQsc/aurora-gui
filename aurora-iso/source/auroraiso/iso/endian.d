/**
 * Byte-order helpers for the ISO 9660 on-disk format.
 *
 * ISO 9660 stores many numeric fields twice: a little-endian value immediately
 * followed by the same value big-endian ("both-endian", ECMA-119 7.3.x). These
 * helpers read and write those layouts directly and never depend on the host
 * byte order or on unaligned pointer casts.
 */
module auroraiso.iso.endian;

/// True when `[off, off + len)` fits inside `buffer`.
bool hasRange(const(ubyte)[] buffer, size_t off, size_t len) pure nothrow @nogc @safe
{
    return off <= buffer.length && len <= buffer.length - off;
}

ushort readLe16(const(ubyte)[] buffer, size_t off) pure nothrow @nogc @safe
{
    return cast(ushort)(buffer[off] | (cast(ushort) buffer[off + 1] << 8));
}

ushort readBe16(const(ubyte)[] buffer, size_t off) pure nothrow @nogc @safe
{
    return cast(ushort)((cast(ushort) buffer[off] << 8) | buffer[off + 1]);
}

uint readLe32(const(ubyte)[] buffer, size_t off) pure nothrow @nogc @safe
{
    return cast(uint) buffer[off] |
        (cast(uint) buffer[off + 1] << 8) |
        (cast(uint) buffer[off + 2] << 16) |
        (cast(uint) buffer[off + 3] << 24);
}

uint readBe32(const(ubyte)[] buffer, size_t off) pure nothrow @nogc @safe
{
    return (cast(uint) buffer[off] << 24) |
        (cast(uint) buffer[off + 1] << 16) |
        (cast(uint) buffer[off + 2] << 8) |
        cast(uint) buffer[off + 3];
}

/**
 * Read a both-endian 16-bit field, preferring the little-endian half and only
 * falling back to the big-endian half when the two disagree and the LE value is
 * clearly the corrupted one. Real-world images occasionally write one half
 * wrong, so this never throws.
 */
ushort readBoth16(const(ubyte)[] buffer, size_t off) pure nothrow @nogc @safe
{
    return readLe16(buffer, off);
}

uint readBoth32(const(ubyte)[] buffer, size_t off) pure nothrow @nogc @safe
{
    return readLe32(buffer, off);
}

void writeLe16(ubyte[] buffer, size_t off, ushort value) pure nothrow @nogc @safe
{
    buffer[off] = cast(ubyte)(value & 0xFF);
    buffer[off + 1] = cast(ubyte)((value >> 8) & 0xFF);
}

void writeBe16(ubyte[] buffer, size_t off, ushort value) pure nothrow @nogc @safe
{
    buffer[off] = cast(ubyte)((value >> 8) & 0xFF);
    buffer[off + 1] = cast(ubyte)(value & 0xFF);
}

void writeLe32(ubyte[] buffer, size_t off, uint value) pure nothrow @nogc @safe
{
    buffer[off] = cast(ubyte)(value & 0xFF);
    buffer[off + 1] = cast(ubyte)((value >> 8) & 0xFF);
    buffer[off + 2] = cast(ubyte)((value >> 16) & 0xFF);
    buffer[off + 3] = cast(ubyte)((value >> 24) & 0xFF);
}

void writeBe32(ubyte[] buffer, size_t off, uint value) pure nothrow @nogc @safe
{
    buffer[off] = cast(ubyte)((value >> 24) & 0xFF);
    buffer[off + 1] = cast(ubyte)((value >> 16) & 0xFF);
    buffer[off + 2] = cast(ubyte)((value >> 8) & 0xFF);
    buffer[off + 3] = cast(ubyte)(value & 0xFF);
}

void writeBoth16(ubyte[] buffer, size_t off, ushort value) pure nothrow @nogc @safe
{
    writeLe16(buffer, off, value);
    writeBe16(buffer, off + 2, value);
}

void writeBoth32(ubyte[] buffer, size_t off, uint value) pure nothrow @nogc @safe
{
    writeLe32(buffer, off, value);
    writeBe32(buffer, off + 4, value);
}

unittest
{
    ubyte[8] buffer;
    writeBoth16(buffer[], 0, 0x1234);
    assert(buffer[0] == 0x34 && buffer[1] == 0x12);
    assert(buffer[2] == 0x12 && buffer[3] == 0x34);
    assert(readLe16(buffer[], 0) == 0x1234);
    assert(readBe16(buffer[], 2) == 0x1234);
    assert(readBoth16(buffer[], 0) == 0x1234);

    writeBoth32(buffer[], 0, 0x89ABCDEF);
    assert(readLe32(buffer[], 0) == 0x89ABCDEF);
    assert(readBe32(buffer[], 4) == 0x89ABCDEF);
    assert(readBoth32(buffer[], 0) == 0x89ABCDEF);
    assert(hasRange(buffer[], 0, 8));
    assert(!hasRange(buffer[], 1, 8));
}
