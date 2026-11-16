module gvarprobe;

/// Inspect the gvar table structure of a variable font to validate parsing.

import std.file : read;
import std.stdio : writeln, writefln;

private ushort be16(const(ubyte)[] d, size_t o) { return cast(ushort) ((d[o] << 8) | d[o + 1]); }
private uint be32(const(ubyte)[] d, size_t o) { return (cast(uint) d[o] << 24) | (cast(uint) d[o + 1] << 16) | (cast(uint) d[o + 2] << 8) | d[o + 3]; }

int main(string[] args)
{
    auto data = cast(immutable(ubyte)[]) read("tests\\fonts\\InterVariable.ttf");
    const n = be16(data, 4);
    size_t fvarOff, gvarOff;
    foreach (i; 0 .. n)
    {
        size_t c = 12 + i * 16;
        string tag = cast(string) data[c .. c + 4];
        if (tag == "fvar") fvarOff = be32(data, c + 8);
        if (tag == "gvar") gvarOff = be32(data, c + 8);
    }
    writefln("fvar@%d gvar@%d", fvarOff, gvarOff);

    const axisCount = be16(data, fvarOff + 8);
    writefln("axisCount=%d", axisCount);

    const gvAxisCount = be16(data, gvarOff + 4);
    const sharedCount = be16(data, gvarOff + 6);
    const offsetToCoord = be32(data, gvarOff + 8);
    const glyphCount = be16(data, gvarOff + 12);
    const flags = be16(data, gvarOff + 14);
    const offsetToData = be32(data, gvarOff + 16);
    writefln("gvar axisCount=%d shared=%d offsetToCoord=%d glyphCount=%d flags=%d offsetToData=%d",
        gvAxisCount, sharedCount, offsetToCoord, glyphCount, flags, offsetToData);

    // Read the glyph offsets for glyph 'A' (glyph index from cmap, use a known: 'A' is usually 36 or so).
    // Print first 5 offsets.
    const offsets32 = (flags & 1) != 0;
    size_t cursor = gvarOff + offsetToData;
    uint[] offsets;
    foreach (g; 0 .. glyphCount + 1)
    {
        uint rel = offsets32 ? be32(data, cursor) : cast(uint) be16(data, cursor) * 2;
        offsets ~= rel;
        cursor += offsets32 ? 4 : 2;
    }
    foreach (g; 0 .. 8)
        writefln("  glyph %d offset rel=%d abs=%d size=%d", g, offsets[g],
            gvarOff + offsetToData + offsets[g], offsets[g + 1] - offsets[g]);

    // Dump glyph 2's variation data header and first tuple header.
    const g = 2;
    const base = gvarOff + offsetToData;
    const start = offsets[g];
    const size = offsets[g + 1] - offsets[g];
    writefln("\nglyph %d variation data size=%d at array-rel %d..%d (abs %d..%d):",
        g, size, start, start + size, base + start, base + start + size);
    const tupleCountField = cast(ushort) ((data[base + start] << 8) | data[base + start + 1]);
    const tupleOffset = cast(ushort) ((data[base + start + 2] << 8) | data[base + start + 3]);
    writefln("tupleCountField=0x%04X (count=%d shared=%s) offsetToData=%d",
        tupleCountField, tupleCountField & 0x0FFF, (tupleCountField & 0x8000) != 0, tupleOffset);
    // The tuple headers start at base+start+4.
    const hdr = base + start + 4;
    const tupleDataSize = cast(ushort) ((data[hdr] << 8) | data[hdr + 1]);
    const tupleIndex = cast(ushort) ((data[hdr + 2] << 8) | data[hdr + 3]);
    writefln("first tuple: dataSize=%d index=0x%04X (embedded=%s intermediate=%s privatePoints=%s sharedIdx=%d)",
        tupleDataSize, tupleIndex, (tupleIndex & 0x8000) != 0, (tupleIndex & 0x4000) != 0,
        (tupleIndex & 0x2000) != 0, tupleIndex & 0x0FFF);
    return 0;
}
