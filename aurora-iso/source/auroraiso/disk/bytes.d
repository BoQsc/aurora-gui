/**
 * Little-endian byte helpers shared by the GPT, FAT32, and exFAT writers.
 * Keeping them in one place means the on-disk encoders agree on byte order.
 */
module auroraiso.disk.bytes;

void putU16(ubyte[] buffer, size_t offset, ushort value)
{
    buffer[offset] = cast(ubyte) value;
    buffer[offset + 1] = cast(ubyte) (value >> 8);
}

void putU32(ubyte[] buffer, size_t offset, uint value)
{
    foreach (i; 0 .. 4)
        buffer[offset + i] = cast(ubyte) (value >> (8 * i));
}

void putU64(ubyte[] buffer, size_t offset, ulong value)
{
    foreach (i; 0 .. 8)
        buffer[offset + i] = cast(ubyte) (value >> (8 * i));
}

ushort getU16(const(ubyte)[] buffer, size_t offset)
{
    return cast(ushort) (buffer[offset] | (buffer[offset + 1] << 8));
}

uint getU32(const(ubyte)[] buffer, size_t offset)
{
    uint value = 0;
    foreach (i; 0 .. 4)
        value |= cast(uint) buffer[offset + i] << (8 * i);
    return value;
}

ulong getU64(const(ubyte)[] buffer, size_t offset)
{
    ulong value = 0;
    foreach (i; 0 .. 8)
        value |= cast(ulong) buffer[offset + i] << (8 * i);
    return value;
}

void putBytes(ubyte[] buffer, size_t offset, const(ubyte)[] source)
{
    buffer[offset .. offset + source.length] = source[];
}

void putAscii(ubyte[] buffer, size_t offset, string text)
{
    foreach (i, ch; text)
        buffer[offset + i] = cast(ubyte) ch;
}
