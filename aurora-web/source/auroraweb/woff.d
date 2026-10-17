module auroraweb.woff;

/**
 * WOFF 1.0 (W3C WOFF File Format 1.0) container decoding.
 *
 * A page's own webfont normally ships as a WOFF container: the same sfnt tables
 * as the TrueType/OpenType original, each stored either verbatim or
 * zlib-compressed, behind a 44-byte header and a 20-byte-per-table directory.
 *
 * The shaper loads uncompressed sfnt files, so a stylesheet whose `src` lists
 * only `format("woff")` — FontAwesome on every Django page, and most Google
 * Fonts responses — otherwise resolves to no face at all: the page's icons have
 * nothing to draw with, and its text silently shapes in a substitute face.
 * Decoding the container here keeps that concern in the engine, where it belongs:
 * the fetch layer hands the shaper the same sfnt it would have received had the
 * page offered an uncompressed source, so nothing downstream needs to know a
 * container existed.
 *
 * Reference: W3C WOFF File Format 1.0, sections 3 (structure) and 4 (directory).
 */

import std.algorithm.sorting : sort;
import std.zlib : uncompress;

/// The signature every WOFF 1.0 file starts with: the ASCII bytes "wOFF".
private enum uint woffSignature = 0x77_4F_46_46;

/// True when `data` begins with the WOFF 1.0 signature.
bool isWoff(const(ubyte)[] data)
{
    return data.length >= 4 && readUint(data, 0) == woffSignature;
}

private uint readUint(const(ubyte)[] data, size_t at)
{
    if (at + 4 > data.length) return 0;
    return (cast(uint) data[at] << 24) | (cast(uint) data[at + 1] << 16) |
        (cast(uint) data[at + 2] << 8) | cast(uint) data[at + 3];
}

private uint readUshort(const(ubyte)[] data, size_t at)
{
    if (at + 2 > data.length) return 0;
    return (cast(uint) data[at] << 8) | cast(uint) data[at + 1];
}

private void writeUint(ubyte[] dst, size_t at, uint value)
{
    dst[at] = cast(ubyte) (value >> 24);
    dst[at + 1] = cast(ubyte) (value >> 16);
    dst[at + 2] = cast(ubyte) (value >> 8);
    dst[at + 3] = cast(ubyte) value;
}

private void writeUshort(ubyte[] dst, size_t at, uint value)
{
    dst[at] = cast(ubyte) (value >> 8);
    dst[at + 1] = cast(ubyte) value;
}

/// Every sfnt table starts on a 4-byte boundary (OpenType, "Table directory").
private size_t align4(size_t value) { return (value + 3) & ~cast(size_t) 3; }

/// The largest power of two that is not greater than `value` (`value` >= 1).
private uint powerOfTwoFloor(uint value)
{
    uint result = 1;
    while (result <= value / 2) result <<= 1;
    return result;
}

/// log2 of a power of two: the sfnt `entrySelector` field.
private uint log2Floor(uint value)
{
    uint result = 0;
    for (uint v = value; v > 1; v >>= 1) ++result;
    return result;
}

/// One decoded table: identification from the directory plus its sfnt bytes.
private struct WoffTable
{
    uint tag;
    uint checksum;
    ubyte[] data;
}

/**
 * Decode a WOFF 1.0 container into the sfnt (TrueType/OpenType) font it wraps.
 *
 * Returns null when `data` is not a WOFF container or is malformed: a caller that
 * cannot decode a source falls back to the next `font-family`, which is what a
 * browser does with an unreadable face, so a corrupt download must never throw.
 *
 * The reassembled file matches the original sfnt byte for byte. The header's
 * `totalSfntSize` is that file's size, and both formats place the tables in
 * ascending tag order on identical alignment, so the `head` table's
 * checkSumAdjustment field is still the value the font was built with and every
 * per-table checksum in the directory still describes its table.
 */
ubyte[] woffToSfnt(const(ubyte)[] data)
{
    if (!isWoff(data) || data.length < 44) return null;
    const flavor = readUint(data, 4);
    const numTables = readUshort(data, 12);
    if (numTables == 0) return null;
    if (44 + 20 * cast(size_t) numTables > data.length) return null;

    WoffTable[] tables;
    tables.reserve(numTables);
    foreach (i; 0 .. cast(size_t) numTables)
    {
        const at = 44 + 20 * i;
        WoffTable table;
        table.tag = readUint(data, at);
        const offset = readUint(data, at + 4);
        const compLength = readUint(data, at + 8);
        const origLength = readUint(data, at + 12);
        table.checksum = readUint(data, at + 16);
        if (origLength == 0 || compLength == 0) return null;
        // The compressed form can only be shorter; a longer one means the
        // directory disagrees with the data.
        if (compLength > origLength) return null;
        if (offset > data.length || compLength > data.length - offset) return null;
        const stored = data[offset .. offset + compLength];
        if (compLength == origLength)
        {
            // Stored as-is: compressing it would have made it larger.
            table.data = stored.dup;
        }
        else
        {
            // zlib (RFC 1950), which is what `uncompress`'s default 15-bit
            // window header expects.
            ubyte[] inflated;
            try inflated = cast(ubyte[]) uncompress(stored, 0, 15);
            catch (Exception) return null;
            if (inflated.length != origLength) return null;
            table.data = inflated;
        }
        tables ~= table;
    }

    // Ascending tag order, which is the order an sfnt reader binary searches.
    tables.sort!((a, b) => a.tag < b.tag);

    size_t total = 12 + 16 * tables.length;
    foreach (t; tables) total = align4(total) + t.data.length;
    auto sfnt = new ubyte[total];

    const pow2 = powerOfTwoFloor(numTables);
    const searchRange = pow2 * 16;
    writeUint(sfnt, 0, flavor);
    writeUshort(sfnt, 4, numTables);
    writeUshort(sfnt, 6, searchRange);
    writeUshort(sfnt, 8, log2Floor(pow2));
    writeUshort(sfnt, 10, numTables * 16 - searchRange);

    size_t dataAt = 12 + 16 * cast(size_t) numTables;
    foreach (i, t; tables)
    {
        const record = 12 + 16 * i;
        writeUint(sfnt, record, t.tag);
        writeUint(sfnt, record + 4, t.checksum);
        writeUint(sfnt, record + 8, cast(uint) dataAt);
        writeUint(sfnt, record + 12, cast(uint) t.data.length);
        sfnt[dataAt .. dataAt + t.data.length] = t.data;
        dataAt = align4(dataAt + t.data.length);
    }
    return sfnt;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    /// A table to assemble into a synthetic font.
    private struct TestTable
    {
        string tag;
        ubyte[] data;
    }

    /// The sfnt checksum of one table: its bytes read as big-endian uint32s and
    /// summed, with the final partial word zero-padded.
    private uint tableChecksum(const(ubyte)[] data)
    {
        uint sum = 0;
        size_t i = 0;
        while (i < data.length)
        {
            uint word = 0;
            foreach (k; 0 .. 4)
                word = (word << 8) | (i + k < data.length ? data[i + k] : 0);
            sum += word;
            i += 4;
        }
        return sum;
    }

    /// Assemble a synthetic sfnt with the layout `woffToSfnt` must reproduce:
    /// 12-byte offset table, 16-byte records in ascending tag order, then the
    /// table data on 4-byte boundaries.
    private ubyte[] testSfnt(TestTable[] tables)
    {
        tables.sort!((a, b) => a.tag < b.tag);
        const n = cast(uint) tables.length;
        size_t total = 12 + 16 * cast(size_t) n;
        foreach (t; tables)
        {
            total = align4(total);
            total += t.data.length;
        }

        auto sfnt = new ubyte[total];
        const pow2 = powerOfTwoFloor(n);
        writeUint(sfnt, 0, 0x0001_0000);          // sfnt version 1.0
        writeUshort(sfnt, 4, n);
        writeUshort(sfnt, 6, pow2 * 16);
        writeUshort(sfnt, 8, log2Floor(pow2));
        writeUshort(sfnt, 10, n * 16 - pow2 * 16);

        size_t at = 12 + 16 * cast(size_t) n;
        foreach (i, t; tables)
        {
            const record = 12 + 16 * i;
            foreach (k; 0 .. 4)
                sfnt[record + k] = cast(ubyte) t.tag[k];
            writeUint(sfnt, record + 4, tableChecksum(t.data));
            writeUint(sfnt, record + 8, cast(uint) at);
            writeUint(sfnt, record + 12, cast(uint) t.data.length);
            sfnt[at .. at + t.data.length] = t.data;
            at = align4(at + t.data.length);
        }
        return sfnt;
    }

    /// One table of a synthetic container.
    private struct TestEntry
    {
        uint tag;
        uint checksum;
        ubyte[] stored;
        size_t origLength;
        size_t offset;
    }

    /// The size an sfnt holding these (uncompressed) tables occupies.
    private size_t testSfntSize(const(TestEntry)[] entries)
    {
        size_t total = 12 + 16 * entries.length;
        foreach (e; entries)
        {
            total = align4(total);
            total += e.origLength;
        }
        return total;
    }

    /// Wrap an assembled sfnt in a WOFF 1.0 container, storing each table as its
    /// zlib form when that is genuinely shorter — the rule a producer follows,
    /// which exercises both directory cases.
    private ubyte[] testWoff(const(ubyte)[] sfnt)
    {
        import std.zlib : compress;

        const numTables = readUshort(sfnt, 4);
        TestEntry[] entries;
        ubyte[] body;
        foreach (i; 0 .. cast(size_t) numTables)
        {
            const record = 12 + 16 * i;
            const offset = readUint(sfnt, record + 8);
            const length = readUint(sfnt, record + 12);
            auto original = sfnt[offset .. offset + length].dup;
            auto packed = cast(ubyte[]) compress(original);
            TestEntry entry;
            entry.tag = readUint(sfnt, record);
            entry.checksum = readUint(sfnt, record + 4);
            entry.origLength = length;
            entry.stored = packed.length < original.length ? packed : original;
            entry.offset = 0;
            entries ~= entry;
        }

        // Table data starts after the directory and is padded to 4 bytes.
        size_t at = 44 + 20 * cast(size_t) numTables;
        foreach (ref e; entries)
        {
            e.offset = at;
            body ~= e.stored;
            at += e.stored.length;
            while (at % 4) { body ~= 0; ++at; }
        }

        auto container = new ubyte[at];
        container[0 .. 4] = ['w', 'O', 'F', 'F'];
        writeUint(container, 4, readUint(sfnt, 0));            // flavor
        writeUint(container, 8, cast(uint) container.length);  // container size
        writeUshort(container, 12, numTables);
        writeUint(container, 16, cast(uint) sfnt.length);      // totalSfntSize
        const dataStart = 44 + 20 * cast(size_t) numTables;
        container[dataStart .. at] = body[];

        foreach (i, e; entries)
        {
            const record = 44 + 20 * i;
            writeUint(container, record, e.tag);
            writeUint(container, record + 4, cast(uint) e.offset);
            writeUint(container, record + 8, cast(uint) e.stored.length);
            writeUint(container, record + 12, cast(uint) e.origLength);
            writeUint(container, record + 16, e.checksum);
        }
        // The header's totalSfntSize must describe the file the container came
        // from, which is what makes the reassembly byte-exact.
        assert(readUint(container, 16) == testSfntSize(entries),
            "the synthetic container must declare the original sfnt size");
        return container;
    }

    /// A WOFF with compressible tables decodes back to the same sfnt.
    unittest
    {
        import std.algorithm.comparison : equal;
        const payload = "the quick brown fox jumps over the lazy dog ".dup;
        auto sfnt = testSfnt([
            TestTable("cmap", cast(ubyte[]) payload),
            TestTable("head", cast(ubyte[]) payload),
        ]);
        auto woff = testWoff(sfnt);
        assert(isWoff(woff), "the container must carry the WOFF signature");
        auto decoded = woffToSfnt(woff);
        assert(decoded !is null, "a WOFF container must decode");
        assert(equal(decoded, sfnt),
            "the decoded font must match the original sfnt byte for byte");
        assert(readUint(decoded, 0) == 0x0001_0000, "the sfnt flavor must survive");
        assert(readUshort(decoded, 4) == 2, "both tables must be present");
    }

    /// A table stored verbatim (zlib could not shrink it) still decodes.
    unittest
    {
        import std.algorithm.comparison : equal;
        ubyte[] noise;
        uint x = 2463534242u;
        foreach (i; 0 .. 64)
        {
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            noise ~= cast(ubyte) x;
        }
        auto sfnt = testSfnt([TestTable("cvt ", noise), TestTable("name", noise.dup)]);
        auto woff = testWoff(sfnt);
        assert(readUint(woff, 44 + 8) == noise.length,
            "this payload must take the stored-verbatim path");
        auto decoded = woffToSfnt(woff);
        assert(decoded !is null && equal(decoded, sfnt),
            "a verbatim table must decode");
    }

    /// Anything that is not a WOFF container, or is damaged, is rejected instead
    /// of throwing.
    unittest
    {
        assert(woffToSfnt(null) is null);
        assert(woffToSfnt([]) is null);
        assert(!isWoff(cast(ubyte[]) "\x00\x01\x00\x00".dup),
            "an sfnt must not look like a container");
        assert(woffToSfnt(cast(ubyte[]) "OTTO\x00\x01\x00\x00".dup) is null);

        auto sfnt = testSfnt([TestTable("head", cast(ubyte[]) "0123456789".dup)]);
        auto woff = testWoff(sfnt);
        assert(woffToSfnt(woff) !is null, "the unmodified container decodes");

        assert(woffToSfnt(woff[0 .. 20]) is null, "a short header must be rejected");
        assert(woffToSfnt(woff[0 .. 50]) is null, "a short directory must be rejected");

        auto bad = woff.dup;
        writeUint(bad, 44 + 4, cast(uint) bad.length + 8);
        assert(woffToSfnt(bad) is null, "an out-of-range table offset must be rejected");

        bad = woff.dup;
        writeUint(bad, 44 + 12, 1 << 20);
        assert(woffToSfnt(bad) is null, "a decompressed length mismatch must be rejected");

        bad = woff.dup;
        writeUint(bad, 44 + 8, 1 << 20);
        assert(woffToSfnt(bad) is null, "compLength > origLength must be rejected");

        bad = woff.dup;
        writeUshort(bad, 12, 999);
        assert(woffToSfnt(bad) is null, "a directory past the container must be rejected");

        // A damaged payload may fail or may inflate, but it must never throw.
        bool threw = false;
        try
        {
            bad = woff.dup;
            bad[bad.length - 1] = cast(ubyte) (bad[bad.length - 1] ^ 0xFF);
            woffToSfnt(bad);
        }
        catch (Throwable) threw = true;
        assert(!threw, "a damaged container must be rejected, not thrown");
    }
}
