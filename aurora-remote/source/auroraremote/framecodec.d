module auroraremote.framecodec;

import std.exception : enforce;
import std.zlib : compress, uncompress;

private enum headerLength = 22;
private enum maximumPixels = 4096 * 2160;

private void putU16(ubyte[] bytes, size_t offset, ushort value)
{
    bytes[offset] = cast(ubyte)(value >> 8);
    bytes[offset + 1] = cast(ubyte) value;
}

private ushort getU16(const(ubyte)[] bytes, size_t offset)
{
    return cast(ushort)((cast(ushort) bytes[offset] << 8) | bytes[offset + 1]);
}

private void putU32(ubyte[] bytes, size_t offset, uint value)
{
    bytes[offset] = cast(ubyte)(value >> 24);
    bytes[offset + 1] = cast(ubyte)(value >> 16);
    bytes[offset + 2] = cast(ubyte)(value >> 8);
    bytes[offset + 3] = cast(ubyte) value;
}

private uint getU32(const(ubyte)[] bytes, size_t offset)
{
    return (cast(uint) bytes[offset] << 24) |
        (cast(uint) bytes[offset + 1] << 16) |
        (cast(uint) bytes[offset + 2] << 8) | bytes[offset + 3];
}

struct DecodedFrame
{
    int width;
    int height;
    uint sequence;
    ubyte[] rgba;
}

final class DeltaFrameEncoder
{
    private ubyte[] _previous;
    private uint _sequence;

    ubyte[] encode(const(ubyte)[] rgba, int width, int height)
    {
        enforce(width > 0 && height > 0 &&
            cast(long) width * height <= maximumPixels,
            "Captured frame dimensions are invalid.");
        const rawLength = cast(size_t) width * height * 4;
        enforce(rgba.length == rawLength, "Captured frame length is invalid.");
        const keyFrame = _previous.length != rawLength || _sequence % 100 == 0;
        auto transformed = new ubyte[rawLength];
        if (keyFrame) transformed[] = rgba[];
        else foreach (index; 0 .. rawLength)
            transformed[index] = rgba[index] ^ _previous[index];

        const compressed = compress(transformed, 1);
        auto packet = new ubyte[headerLength + compressed.length];
        packet[0 .. 4] = cast(const(ubyte)[]) "ARVF";
        packet[4] = 1;
        packet[5] = keyFrame ? 1 : 0;
        putU16(packet, 6, cast(ushort) width);
        putU16(packet, 8, cast(ushort) height);
        putU32(packet, 10, _sequence);
        putU32(packet, 14, cast(uint) rawLength);
        putU32(packet, 18, cast(uint) compressed.length);
        packet[headerLength .. $] = compressed[];
        _previous = rgba.dup;
        ++_sequence;
        return packet;
    }
}

final class DeltaFrameDecoder
{
    private ubyte[] _previous;
    private uint _expectedSequence;

    DecodedFrame decode(const(ubyte)[] packet)
    {
        enforce(packet.length >= headerLength, "Video frame is truncated.");
        enforce(packet[0 .. 4] == cast(const(ubyte)[]) "ARVF" &&
            packet[4] == 1, "Video frame header is invalid.");
        const keyFrame = packet[5] != 0;
        const width = getU16(packet, 6);
        const height = getU16(packet, 8);
        const sequence = getU32(packet, 10);
        const rawLength = getU32(packet, 14);
        const compressedLength = getU32(packet, 18);
        enforce(width > 0 && height > 0 &&
            cast(long) width * height <= maximumPixels,
            "Video frame dimensions are invalid.");
        enforce(rawLength == cast(uint) width * height * 4,
            "Video frame raw length is invalid.");
        enforce(packet.length == headerLength + compressedLength,
            "Video frame compressed length is invalid.");
        enforce(keyFrame || (_previous.length == rawLength &&
            sequence == _expectedSequence),
            "Delta video frame arrived without its predecessor.");
        auto transformed = cast(ubyte[]) uncompress(packet[headerLength .. $],
            rawLength);
        enforce(transformed.length == rawLength,
            "Video frame decompressed to the wrong length.");
        auto rgba = new ubyte[rawLength];
        if (keyFrame) rgba[] = transformed[];
        else foreach (index; 0 .. rawLength)
            rgba[index] = transformed[index] ^ _previous[index];
        _previous = rgba.dup;
        _expectedSequence = sequence + 1;
        return DecodedFrame(width, height, sequence, rgba);
    }
}

unittest
{
    auto encoder = new DeltaFrameEncoder;
    auto decoder = new DeltaFrameDecoder;
    auto first = new ubyte[64 * 36 * 4];
    foreach (index, ref value; first) value = cast(ubyte)(index * 13);
    const decodedFirst = decoder.decode(encoder.encode(first, 64, 36));
    assert(decodedFirst.rgba == first);
    auto second = first.dup;
    second[100 .. 140] = 255;
    const encodedSecond = encoder.encode(second, 64, 36);
    assert(encodedSecond.length < first.length);
    const decodedSecond = decoder.decode(encodedSecond);
    assert(decodedSecond.rgba == second);
}
