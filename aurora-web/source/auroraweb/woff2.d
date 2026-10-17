/// Decoding of WOFF 2.0 font containers into plain sfnt data.
///
/// Pure D implementation written from the W3C Recommendation "WOFF File
/// Format 2.0" (https://www.w3.org/TR/WOFF2/, 08 August 2024): the container
/// header and table directory (clause 4), the transformed `glyf`/`loca` pair
/// (subclauses 5.1 - 5.3), the transformed `hmtx` table (subclause 5.4) and
/// the sfnt assembly rules (clause 7).
///
/// The only dependency is `auroraweb.brotli` for the entropy coded table
/// data stream. Everything is bounds checked: malformed input yields an error
/// string, never a crash or a partial font.
module auroraweb.woff2;

import auroraweb.brotli : brotliDecompress;

/// True when `data` starts with the WOFF2 signature.
bool isWoff2(const(ubyte)[] data)
{
    return data.length >= 4 && data[0] == 'w' && data[1] == 'O' &&
        data[2] == 'F' && data[3] == '2';
}

/// Tags addressable by the low six bits of a table directory flag byte.
/// Index 63 means "an arbitrary four byte tag follows".
private immutable string[63] tagTable = [
    "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post",
    "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
    "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea",
    "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
    "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar",
    "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
    "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop",
    "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
];

/// Big endian cursor over a byte range; every read reports failure instead of
/// running off the end.
private struct Cursor
{
    const(ubyte)[] data;
    size_t pos;

    bool remaining(size_t count) const { return count <= data.length - pos; }

    bool u8(ref ubyte value)
    {
        if (!remaining(1))
            return false;
        value = data[pos++];
        return true;
    }

    bool u16(ref ushort value)
    {
        if (!remaining(2))
            return false;
        value = cast(ushort)((data[pos] << 8) | data[pos + 1]);
        pos += 2;
        return true;
    }

    bool i16(ref short value)
    {
        ushort raw;
        if (!u16(raw))
            return false;
        value = cast(short) raw;
        return true;
    }

    bool u32(ref uint value)
    {
        if (!remaining(4))
            return false;
        value = (cast(uint) data[pos] << 24) | (cast(uint) data[pos + 1] << 16) |
            (cast(uint) data[pos + 2] << 8) | data[pos + 3];
        pos += 4;
        return true;
    }

    /// UIntBase128: at most five bytes, no leading zero byte, fits in 32 bits.
    bool uintBase128(ref uint value)
    {
        uint result = 0;
        foreach (i; 0 .. 5)
        {
            ubyte next;
            if (!u8(next))
                return false;
            if (i == 0 && next == 0x80)
                return false; // leading zeros are not allowed
            if ((result & 0xFE000000) != 0)
                return false; // overflow
            result = (result << 7) | (next & 0x7F);
            if ((next & 0x80) == 0)
            {
                value = result;
                return true;
            }
        }
        return false;
    }

    /// 255UInt16 as defined by the specification's pseudo code.
    bool u255(ref uint value)
    {
        ubyte code;
        if (!u8(code))
            return false;
        if (code == 253)
        {
            ushort raw;
            if (!u16(raw))
                return false;
            value = raw;
            return true;
        }
        if (code == 254 || code == 255)
        {
            ubyte next;
            if (!u8(next))
                return false;
            value = cast(uint) next + (code == 255 ? 253u * 2 : 253u);
            return true;
        }
        value = code;
        return true;
    }
}

/// One table directory entry plus its decoded payload.
private struct TableEntry
{
    string tag;
    uint flags;
    uint origLength;
    uint transformLength;
    bool hasTransformLength;
    size_t streamOffset;
    ubyte[] data;

    uint transformVersion() const { return flags >> 6; }
}

/// Result of the transformed glyf reconstruction.
private struct GlyfResult
{
    ubyte[] glyf;
    uint[] offsets; // glyphCount + 1 entries, byte offsets into `glyf`
    int[] xMins; // one per glyph, needed by the hmtx transform
    uint indexFormat;
}

private const uint kChecksumMagic = 0xB1B0AFBA;

/// Decodes `data` (a WOFF2 container) into an sfnt font image.
/// Returns null and a human readable `error` when the file is unusable.
ubyte[] woff2ToSfnt(const(ubyte)[] data, out string error)
{
    error = null;
    if (!isWoff2(data))
    {
        error = "not a WOFF2 file";
        return null;
    }
    if (data.length < 48)
    {
        error = "truncated WOFF2 header";
        return null;
    }

    auto cursor = Cursor(data, 4);
    uint flavor;
    uint fileLength;
    ushort numTables;
    ushort reserved;
    uint totalSfntSize;
    uint totalCompressedSize;
    ushort majorVersion;
    ushort minorVersion;
    uint metaOffset, metaLength, metaOrigLength, privOffset, privLength;
    if (!cursor.u32(flavor) || !cursor.u32(fileLength) ||
        !cursor.u16(numTables) || !cursor.u16(reserved) ||
        !cursor.u32(totalSfntSize) || !cursor.u32(totalCompressedSize) ||
        !cursor.u16(majorVersion) || !cursor.u16(minorVersion) ||
        !cursor.u32(metaOffset) || !cursor.u32(metaLength) ||
        !cursor.u32(metaOrigLength) || !cursor.u32(privOffset) || !cursor.u32(privLength))
    {
        error = "truncated WOFF2 header";
        return null;
    }
    if (reserved != 0)
    {
        error = "WOFF2 reserved header field is not zero";
        return null;
    }
    if (fileLength != data.length)
    {
        error = "WOFF2 header length does not match the file size";
        return null;
    }
    if (numTables == 0)
    {
        error = "WOFF2 file declares no tables";
        return null;
    }

    // Table directory: entries appear in the order of the compressed data
    // stream, which is also the order used to slice the decoded stream.
    TableEntry[] tables;
    tables.reserve(numTables);
    foreach (i; 0 .. numTables)
    {
        ubyte flagByte;
        if (!cursor.u8(flagByte))
        {
            error = "truncated WOFF2 table directory";
            return null;
        }
        TableEntry entry;
        entry.flags = flagByte;
        const tagIndex = flagByte & 0x3F;
        if (tagIndex == 63)
        {
            if (!cursor.remaining(4))
            {
                error = "truncated WOFF2 table tag";
                return null;
            }
            entry.tag = cast(string) data[cursor.pos .. cursor.pos + 4].idup;
            cursor.pos += 4;
        }
        else
            entry.tag = tagTable[tagIndex];

        if (!cursor.uintBase128(entry.origLength))
        {
            error = "invalid WOFF2 origLength for table '" ~ entry.tag ~ "'";
            return null;
        }

        const transform = entry.transformVersion();
        if (entry.tag == "glyf")
        {
            if (transform != 0 && transform != 3)
            {
                error = "invalid glyf transform version";
                return null;
            }
            entry.hasTransformLength = transform != 3;
        }
        else if (entry.tag == "loca")
        {
            if (transform != 0 && transform != 3)
            {
                error = "invalid loca transform version";
                return null;
            }
            entry.hasTransformLength = transform != 3;
        }
        else if (entry.tag == "hmtx")
        {
            if (transform > 1)
            {
                error = "invalid hmtx transform version";
                return null;
            }
            entry.hasTransformLength = transform == 1;
        }
        else if (transform != 0)
        {
            error = "table '" ~ entry.tag ~ "' uses an unsupported transform";
            return null;
        }

        if (entry.hasTransformLength)
        {
            if (!cursor.uintBase128(entry.transformLength))
            {
                error = "invalid WOFF2 transformLength for table '" ~ entry.tag ~ "'";
                return null;
            }
        }
        else
            entry.transformLength = entry.origLength;
        if (entry.transformLength > entry.origLength)
        {
            error = "WOFF2 transformLength exceeds origLength for table '" ~ entry.tag ~ "'";
            return null;
        }
        tables ~= entry;
    }
    const size_t compressedStart = cursor.pos;
    if (compressedStart + totalCompressedSize > data.length)
    {
        error = "WOFF2 compressed data is truncated";
        return null;
    }

    // The decoded stream holds every table's data back to back in directory
    // order: origLength bytes for untransformed tables, transformLength for
    // transformed ones, with no padding between them (the padded layout only
    // exists in the reconstructed sfnt).
    size_t decodedSize = 0;
    foreach (ref table; tables)
    {
        table.streamOffset = decodedSize;
        decodedSize += table.transformLength;
    }

    auto payload = data[compressedStart .. compressedStart + totalCompressedSize];
    string brotliError;
    auto stream = brotliDecompress(payload, decodedSize, brotliError);
    if (stream is null)
    {
        error = "Brotli decompression failed: " ~ brotliError;
        return null;
    }

    foreach (ref table; tables)
        table.data = stream[table.streamOffset .. table.streamOffset + table.transformLength].dup;

    // Reconstruct the transformed glyf/loca pair.
    TableEntry* glyfTable;
    TableEntry* locaTable;
    TableEntry* headTable;
    TableEntry* maxpTable;
    TableEntry* hheaTable;
    foreach (ref table; tables)
    {
        if (table.tag == "glyf")
            glyfTable = &table;
        else if (table.tag == "loca")
            locaTable = &table;
        else if (table.tag == "head")
            headTable = &table;
        else if (table.tag == "maxp")
            maxpTable = &table;
        else if (table.tag == "hhea")
            hheaTable = &table;
    }

    GlyfResult glyf;
    bool haveGlyf;
    if (glyfTable !is null && glyfTable.transformVersion() == 0)
    {
        if (locaTable is null || locaTable.transformVersion() != 0)
        {
            error = "a transformed glyf table requires a transformed loca table";
            return null;
        }
        if (!reconstructGlyf(glyfTable.data, glyf, error))
            return null;
        haveGlyf = true;

        // The glyf transform rewrites the outline data, so the reconstructed
        // table is not required to be the same length as (or byte-identical
        // to) the original table: it must only be a valid table whose loca
        // reproduces every glyph offset. The checks below verify that.
        const uint entrySize = glyf.indexFormat == 0 ? 2 : 4;
        const size_t expectedLoca = cast(size_t)(glyf.offsets.length) * entrySize;
        if (locaTable.origLength != expectedLoca)
        {
            error = "loca origLength does not match numGlyphs and indexFormat";
            return null;
        }
        glyfTable.data = glyf.glyf;
        if (locaTable.transformLength != 0)
        {
            error = "transformed loca table must have a zero transformLength";
            return null;
        }
        locaTable.data = buildLoca(glyf.offsets, glyf.indexFormat, error);
        if (locaTable.data is null)
            return null;
    }
    else if (locaTable !is null && locaTable.transformVersion() != 0)
    {
        // A null transformed loca next to an untransformed (or absent) glyf is
        // legal as long as the bytes are carried literally.
        haveGlyf = false;
    }
    else
        haveGlyf = false;

    // Reconstruct the transformed hmtx table.
    foreach (ref table; tables)
    {
        if (table.tag != "hmtx" || table.transformVersion() != 1)
            continue;
        const uint numGlyphs = haveGlyf ? cast(uint)(glyf.offsets.length - 1) :
            glyphCount(maxpTable);
        const uint numOfHMetrics = numOfHMetricsFrom(hheaTable);
        if (numGlyphs == 0 || numOfHMetrics == 0 || numOfHMetrics > numGlyphs)
        {
            error = "cannot reconstruct hmtx without valid hhea/maxp values";
            return null;
        }
        table.data = buildHmtx(table.data, numGlyphs, numOfHMetrics,
            haveGlyf ? glyf.xMins : cast(int[]) null, error);
        if (table.data is null)
            return null;
        if (table.origLength != table.data.length)
        {
            error = "reconstructed hmtx length does not match origLength";
            return null;
        }
    }

    // Every table now carries its final bytes; check the sfnt size the header
    // advertises before assembling.
    size_t expectedSfntSize = 12 + 16 * cast(size_t) numTables;
    foreach (ref table; tables)
    {
        // A reconstructed glyf table may legitimately differ in length from the
        // value the header records; every other table must match exactly.
        if (!(haveGlyf && table.tag == "glyf") && table.data.length != table.origLength)
        {
            error = "table '" ~ table.tag ~ "' has an unexpected length";
            return null;
        }
        expectedSfntSize += aligned(table.origLength);
    }
    // The header's totalSfntSize describes the font the file was made from.
    // Only a reconstruction that is byte-exact table by table can be expected
    // to reproduce it, and the glyf transform is not byte-exact.
    if (!haveGlyf && totalSfntSize != expectedSfntSize)
    {
        error = "reconstructed sfnt size " ~ text(expectedSfntSize) ~
            " does not match the header's totalSfntSize " ~ text(totalSfntSize);
        return null;
    }

    return buildSfnt(flavor, tables, headTable, error);
}

/// Rounds `length` up to the next multiple of four.
private size_t aligned(size_t length) { return (length + 3) & ~cast(size_t) 3; }

private uint alignOffset(uint offset) { return (offset + 3) & ~3u; }

/// Small helper so error messages can embed numbers without std.conv churn.
private string text(size_t value)
{
    char[24] buffer;
    auto length = buffer.length;
    do
    {
        buffer[--length] = cast(char)('0' + value % 10);
        value /= 10;
    }
    while (value != 0);
    return buffer[length .. $].idup;
}

private uint readU16(const(ubyte)[] data, size_t offset)
{
    return (cast(uint) data[offset] << 8) | data[offset + 1];
}

private int readI16(const(ubyte)[] data, size_t offset)
{
    return cast(short)((cast(uint) data[offset] << 8) | data[offset + 1]);
}

private uint glyphCount(const(TableEntry)* maxpEntry)
{
    if (maxpEntry is null || maxpEntry.data.length < 6)
        return 0;
    return readU16(maxpEntry.data, 4);
}

private uint numOfHMetricsFrom(const(TableEntry)* hheaEntry)
{
    if (hheaEntry is null || hheaEntry.data.length < 36)
        return 0;
    return readU16(hheaEntry.data, 34);
}

/// Decodes one glyph coordinate triplet.
/// `flagByte` is the raw flag stream byte, `glyph` the glyph stream and `pos`
/// its current read position. Returns the deltas and the curve state.
private bool decodeTriplet(ubyte flagByte, const(ubyte)[] glyph, ref size_t pos,
    ref int dx, ref int dy, ref bool onCurve)
{
    onCurve = (flagByte & 0x80) == 0;
    const uint flag = flagByte & 0x7F;
    if (flag < 10)
    {
        if (pos + 1 > glyph.length)
            return false;
        const int b0 = glyph[pos++];
        dx = 0;
        dy = withSign(flag, ((flag & 14) << 7) + b0);
    }
    else if (flag < 20)
    {
        if (pos + 1 > glyph.length)
            return false;
        const int b0 = glyph[pos++];
        dx = withSign(flag, (((flag - 10) & 14) << 7) + b0);
        dy = 0;
    }
    else if (flag < 84)
    {
        if (pos + 1 > glyph.length)
            return false;
        const uint b0 = flag - 20;
        const int b1 = glyph[pos++];
        dx = withSign(flag, 1 + cast(int)(b0 & 0x30) + (b1 >> 4));
        dy = withSign(flag >> 1, 1 + cast(int)((b0 & 0x0C) << 2) + (b1 & 0x0F));
    }
    else if (flag < 120)
    {
        if (pos + 2 > glyph.length)
            return false;
        const uint b0 = flag - 84;
        const int b1 = glyph[pos];
        const int b2 = glyph[pos + 1];
        pos += 2;
        dx = withSign(flag, 1 + cast(int)((b0 / 12) << 8) + b1);
        dy = withSign(flag >> 1, 1 + cast(int)(((b0 % 12) >> 2) << 8) + b2);
    }
    else if (flag < 124)
    {
        if (pos + 3 > glyph.length)
            return false;
        const int b1 = glyph[pos];
        const int b2 = glyph[pos + 1];
        const int b3 = glyph[pos + 2];
        pos += 3;
        dx = withSign(flag, (b1 << 4) + (b2 >> 4));
        dy = withSign(flag >> 1, ((b2 & 0x0F) << 8) + b3);
    }
    else
    {
        if (pos + 4 > glyph.length)
            return false;
        const int b1 = glyph[pos];
        const int b2 = glyph[pos + 1];
        const int b3 = glyph[pos + 2];
        const int b4 = glyph[pos + 3];
        pos += 4;
        dx = withSign(flag, (b1 << 8) + b2);
        dy = withSign(flag >> 1, (b3 << 8) + b4);
    }
    return true;
}

private int withSign(uint flag, int value) { return (flag & 1) != 0 ? value : -value; }

/// Reconstructs the glyf table and the matching glyph offsets from the
/// transformed glyf payload.
private bool reconstructGlyf(const(ubyte)[] transformed, out GlyfResult result,
    out string error)
{
    error = null;
    auto cursor = Cursor(transformed, 0);
    ushort reserved;
    ushort optionFlags;
    ushort numGlyphs;
    ushort indexFormat;
    if (!cursor.u16(reserved) || !cursor.u16(optionFlags) ||
        !cursor.u16(numGlyphs) || !cursor.u16(indexFormat))
    {
        error = "truncated transformed glyf header";
        return false;
    }
    if (reserved != 0)
    {
        error = "transformed glyf reserved field is not zero";
        return false;
    }
    if ((optionFlags & ~1) != 0)
    {
        error = "transformed glyf optionFlags has reserved bits set";
        return false;
    }

    uint[7] sizes;
    foreach (i; 0 .. 7)
    {
        if (!cursor.u32(sizes[i]))
        {
            error = "truncated transformed glyf stream sizes";
            return false;
        }
    }

    // Stream layout, in order: nContour, nPoints, flags, glyph, composite,
    // bbox (bitmap followed by values), instructions, overlap bitmap.
    const size_t headerEnd = cursor.pos;
    size_t[7] offsets;
    size_t offset = headerEnd;
    foreach (i; 0 .. 7)
    {
        offsets[i] = offset;
        offset += sizes[i];
    }
    const size_t bboxBitmapSize = (cast(size_t) numGlyphs + 31) / 32 * 4;
    if (sizes[5] < bboxBitmapSize)
    {
        error = "transformed glyf bbox stream is too small";
        return false;
    }
    if (offset > transformed.length)
    {
        error = "transformed glyf streams exceed the table length";
        return false;
    }
    const bool hasOverlap = (optionFlags & 1) != 0;
    // The overlap bitmap is a numGlyphs-long bit array appended after the
    // seven streams, with no alignment padding.
    const size_t overlapBitmapSize = (cast(size_t) numGlyphs + 7) / 8;
    if (hasOverlap && offset + overlapBitmapSize > transformed.length)
    {
        error = "transformed glyf overlap bitmap is missing";
        return false;
    }

    auto nContourStream = transformed[offsets[0] .. offsets[0] + sizes[0]];
    auto nPointsStream = transformed[offsets[1] .. offsets[1] + sizes[1]];
    auto flagStream = transformed[offsets[2] .. offsets[2] + sizes[2]];
    auto glyphStream = transformed[offsets[3] .. offsets[3] + sizes[3]];
    auto compositeStream = transformed[offsets[4] .. offsets[4] + sizes[4]];
    auto bboxStream = transformed[offsets[5] .. offsets[5] + sizes[5]];
    auto instructionStream = transformed[offsets[6] .. offsets[6] + sizes[6]];
    auto overlapStream = hasOverlap ?
        transformed[offset .. offset + overlapBitmapSize] : null;

    auto nContours = Cursor(nContourStream, 0);
    auto nPoints = Cursor(nPointsStream, 0);
    auto flags = Cursor(flagStream, 0);
    auto bbox = Cursor(bboxStream, 0);
    auto composite = Cursor(compositeStream, 0);
    auto instructions = Cursor(instructionStream, 0);
    size_t glyphPos = 0;

    ubyte[] glyf;
    glyf.reserve(numGlyphs * 64);
    uint[] glyphOffsets;
    glyphOffsets.reserve(cast(size_t) numGlyphs + 1);
    int[] xMins;
    xMins.reserve(numGlyphs);
    glyphOffsets ~= 0;

    foreach (glyphIndex; 0 .. cast(uint) numGlyphs)
    {
        short contourCount;
        if (!nContours.i16(contourCount))
        {
            error = "truncated transformed glyf contour stream";
            return false;
        }
        if (contourCount == 0)
        {
            glyphOffsets ~= cast(uint) glyf.length;
            xMins ~= 0;
            continue;
        }

        const bool hasBBox = bboxBitSet(bboxStream, numGlyphs, glyphIndex);
        int xMin, yMin, xMax, yMax;
        if (hasBBox)
        {
            const size_t skip = bboxBitmapSize;
            const size_t valueOffset = skip + cast(size_t) bboxValuesConsumed(bboxStream, numGlyphs, glyphIndex) * 8;
            if (valueOffset + 8 > bboxStream.length)
            {
                error = "truncated transformed glyf bounding box stream";
                return false;
            }
            xMin = readI16(bboxStream, valueOffset);
            yMin = readI16(bboxStream, valueOffset + 2);
            xMax = readI16(bboxStream, valueOffset + 4);
            yMax = readI16(bboxStream, valueOffset + 6);
        }

        ubyte[] record;
        if (contourCount > 0)
        {
            if (!buildSimpleGlyph(contourCount, glyphIndex, nPoints, flags, glyphStream,
                    glyphPos, instructions, overlapStream, hasBBox, xMin, yMin, xMax,
                    yMax, record, error))
                return false;
        }
        else if (contourCount == -1)
        {
            if (!hasBBox)
            {
                error = "composite glyph is missing its bounding box";
                return false;
            }
            if (!buildCompositeGlyph(glyphStream, glyphPos, composite, instructions,
                    xMin, yMin, xMax, yMax, record, error))
                return false;
        }
        else
        {
            error = "invalid contour count in transformed glyf";
            return false;
        }

        glyf ~= record;
        // Glyph records are padded with a zero byte so that each one starts
        // on an even offset, as the sfnt glyph data requires.
        if ((glyf.length & 1) != 0)
            glyf ~= cast(ubyte) 0;
        glyphOffsets ~= cast(uint) glyf.length;
        xMins ~= xMin;
    }

    result.glyf = glyf;
    result.offsets = glyphOffsets;
    result.xMins = xMins;
    result.indexFormat = indexFormat;
    return true;
}

/// Number of explicit bounding boxes that precede `glyphIndex`; used to find
/// the position of that glyph's box inside the bbox stream.
private size_t bboxValuesConsumed(const(ubyte)[] bboxStream, uint numGlyphs, uint glyphIndex)
{
    size_t count = 0;
    foreach (index; 0 .. glyphIndex)
        if (bboxBitSet(bboxStream, numGlyphs, index))
            ++count;
    return count;
}

private bool bboxBitSet(const(ubyte)[] bboxStream, uint numGlyphs, uint glyphIndex)
{
    const size_t offset = glyphIndex / 8;
    if (offset >= bboxStream.length)
        return false;
    return (bboxStream[offset] & (0x80 >> (glyphIndex % 8))) != 0;
}

/// Builds the reconstructed TrueType record of one simple glyph.
private bool buildSimpleGlyph(short contourCount, uint glyphIndex, ref Cursor nPoints,
    ref Cursor flags, const(ubyte)[] glyphStream, ref size_t glyphPos,
    ref Cursor instructions, const(ubyte)[] overlapStream, bool hasBBox,
    int explicitXMin, int explicitYMin, int explicitXMax, int explicitYMax,
    out ubyte[] record, out string error)
{
    error = null;
    record = null;

    // Contour end points and total point count.
    auto endPts = new ushort[contourCount];
    uint totalPoints = 0;
    foreach (i; 0 .. contourCount)
    {
        uint count;
        if (!nPoints.u255(count) || count == 0)
        {
            error = "invalid point count in transformed glyf";
            return false;
        }
        totalPoints += count;
        endPts[i] = cast(ushort)(totalPoints - 1);
    }

    auto onCurve = new bool[totalPoints];
    auto dx = new int[totalPoints];
    auto dy = new int[totalPoints];
    int x = 0, y = 0;
    int xMin = 0, yMin = 0, xMax = 0, yMax = 0;
    foreach (i; 0 .. totalPoints)
    {
        ubyte flag;
        if (!flags.u8(flag))
        {
            error = "truncated transformed glyf flag stream";
            return false;
        }
        int deltaX, deltaY;
        if (!decodeTriplet(flag, glyphStream, glyphPos, deltaX, deltaY, onCurve[i]))
        {
            error = "truncated transformed glyf coordinate stream";
            return false;
        }
        dx[i] = deltaX;
        dy[i] = deltaY;
        x += deltaX;
        y += deltaY;
        if (i == 0)
        {
            xMin = xMax = x;
            yMin = yMax = y;
        }
        else
        {
            if (x < xMin) xMin = x;
            if (x > xMax) xMax = x;
            if (y < yMin) yMin = y;
            if (y > yMax) yMax = y;
        }
    }

    uint instructionLength;
    if (!read255FromStream(glyphStream, glyphPos, instructionLength))
    {
        error = "truncated transformed glyf instruction length";
        return false;
    }
    ubyte[] instructionBytes;
    instructionBytes.length = instructionLength;
    foreach (i; 0 .. instructionLength)
    {
        ubyte value;
        if (!instructions.u8(value))
        {
            error = "truncated transformed glyf instruction stream";
            return false;
        }
        instructionBytes[i] = value;
    }

    if (!hasBBox)
    {
        explicitXMin = xMin;
        explicitYMin = yMin;
        explicitXMax = xMax;
        explicitYMax = yMax;
    }

    // TrueType flags. OVERLAP_SIMPLE is placed on the first flag byte.
    auto ttFlags = new ubyte[totalPoints];
    foreach (i; 0 .. totalPoints)
    {
        ubyte f = onCurve[i] ? 0x01 : 0x00;
        if (dx[i] == 0)
            f |= 0x10;
        else if (dx[i] >= -255 && dx[i] <= 255)
        {
            f |= 0x02;
            if (dx[i] > 0)
                f |= 0x10;
        }
        if (dy[i] == 0)
            f |= 0x20;
        else if (dy[i] >= -255 && dy[i] <= 255)
        {
            f |= 0x04;
            if (dy[i] > 0)
                f |= 0x20;
        }
        ttFlags[i] = f;
    }
    if (totalPoints > 0 && overlapStream.length != 0 &&
        (overlapStream[glyphIndex / 8] & (0x80 >> (glyphIndex % 8))) != 0)
        ttFlags[0] |= 0x40;

    // Serialize the record.
    auto output = new ubyte[0];
    output.reserve(22 + totalPoints * 3 + instructionLength);
    appendI16(output, cast(short) contourCount);
    appendI16(output, cast(short) explicitXMin);
    appendI16(output, cast(short) explicitYMin);
    appendI16(output, cast(short) explicitXMax);
    appendI16(output, cast(short) explicitYMax);
    foreach (endPoint; endPts)
        appendU16(output, endPoint);
    appendU16(output, cast(ushort) instructionLength);
    output ~= instructionBytes;
    // Runs of identical flag bytes are run-length encoded with the REPEAT flag,
    // matching the form the reference decoder emits.
    size_t repeats = 0;
    foreach (i; 0 .. totalPoints)
    {
        if (i > 0 && ttFlags[i] == ttFlags[i - 1] && repeats < 255)
        {
            ++repeats;
            if (repeats == 1)
                output ~= ttFlags[i];
            else
            {
                output[$ - 2] = ttFlags[i] | 0x08;
                output[$ - 1] = cast(ubyte) repeats;
            }
        }
        else
        {
            repeats = 0;
            output ~= ttFlags[i];
        }
    }
    foreach (i; 0 .. totalPoints)
    {
        if (ttFlags[i] & 0x02)
            output ~= cast(ubyte)(dx[i] < 0 ? -dx[i] : dx[i]);
        else if ((ttFlags[i] & 0x10) == 0)
            appendI16(output, cast(short) dx[i]);
    }
    foreach (i; 0 .. totalPoints)
    {
        if (ttFlags[i] & 0x04)
            output ~= cast(ubyte)(dy[i] < 0 ? -dy[i] : dy[i]);
        else if ((ttFlags[i] & 0x20) == 0)
            appendI16(output, cast(short) dy[i]);
    }

    record = output;
    return true;
}

/// Builds the reconstructed TrueType record of one composite glyph.
private bool buildCompositeGlyph(const(ubyte)[] glyphStream, ref size_t glyphPos,
    ref Cursor composite, ref Cursor instructions, int xMin, int yMin, int xMax, int yMax,
    out ubyte[] record, out string error)
{
    error = null;
    auto output = new ubyte[0];
    output.reserve(64);
    appendI16(output, cast(short) -1);
    appendI16(output, cast(short) xMin);
    appendI16(output, cast(short) yMin);
    appendI16(output, cast(short) xMax);
    appendI16(output, cast(short) yMax);

    bool haveInstructions = false;
    while (true)
    {
        ushort componentFlags;
        if (!composite.u16(componentFlags))
        {
            error = "truncated transformed glyf composite stream";
            return false;
        }
        // Glyph index (2 bytes) plus arguments plus optional transform.
        size_t argumentBytes = (componentFlags & 0x0001) ? 4 : 2;
        if (componentFlags & 0x0008)
            argumentBytes += 2;
        else if (componentFlags & 0x0040)
            argumentBytes += 4;
        else if (componentFlags & 0x0080)
            argumentBytes += 8;
        const size_t payloadBytes = 2 + argumentBytes;
        if (!composite.remaining(payloadBytes))
        {
            error = "truncated transformed glyf composite component";
            return false;
        }
        appendU16(output, componentFlags);
        output ~= composite.data[composite.pos .. composite.pos + payloadBytes];
        composite.pos += payloadBytes;
        if (componentFlags & 0x0100)
            haveInstructions = true;
        if ((componentFlags & 0x0020) == 0)
            break;
    }

    if (haveInstructions)
    {
        uint instructionLength;
        if (!read255FromStream(glyphStream, glyphPos, instructionLength))
        {
            error = "truncated transformed glyf instruction length";
            return false;
        }
        appendU16(output, cast(ushort) instructionLength);
        foreach (i; 0 .. instructionLength)
        {
            ubyte value;
            if (!instructions.u8(value))
            {
                error = "truncated transformed glyf instruction stream";
                return false;
            }
            output ~= value;
        }
    }

    record = output;
    return true;
}

private bool read255FromStream(const(ubyte)[] stream, ref size_t pos, out uint value)
{
    auto cursor = Cursor(stream, pos);
    if (!cursor.u255(value))
        return false;
    pos = cursor.pos;
    return true;
}

private void appendU16(ref ubyte[] output, ushort value)
{
    output ~= cast(ubyte)(value >> 8);
    output ~= cast(ubyte)(value & 0xFF);
}

private void appendI16(ref ubyte[] output, short value)
{
    appendU16(output, cast(ushort) value);
}

private void appendU32(ref ubyte[] output, uint value)
{
    output ~= cast(ubyte)(value >> 24);
    output ~= cast(ubyte)((value >> 16) & 0xFF);
    output ~= cast(ubyte)((value >> 8) & 0xFF);
    output ~= cast(ubyte)(value & 0xFF);
}

/// Serializes the reconstructed loca table using `indexFormat`.
private ubyte[] buildLoca(const uint[] offsets, uint indexFormat, out string error)
{
    error = null;
    ubyte[] output;
    output.reserve(offsets.length * (indexFormat == 0 ? 2 : 4));
    if (indexFormat == 0)
    {
        foreach (offset; offsets)
        {
            if ((offset & 1) != 0 || offset / 2 > 0xFFFF)
            {
                error = "glyph offset is not representable in a short loca table";
                return null;
            }
            appendU16(output, cast(ushort)(offset / 2));
        }
    }
    else
        foreach (offset; offsets)
            appendU32(output, offset);
    return output;
}

/// Rebuilds the hmtx table from its transformed form (subclause 5.4).
private ubyte[] buildHmtx(const(ubyte)[] transformed, uint numGlyphs,
    uint numOfHMetrics, const int[] xMins, out string error)
{
    error = null;
    if (transformed.length < 1)
    {
        error = "truncated transformed hmtx table";
        return null;
    }
    const ubyte flags = transformed[0];
    if ((flags & 0x03) == 0 || (flags & 0xFC) != 0)
    {
        error = "invalid transformed hmtx flags";
        return null;
    }
    const bool reconstructFirst = (flags & 0x01) != 0;
    const bool reconstructSecond = (flags & 0x02) != 0;
    const uint trailingGlyphs = numGlyphs - numOfHMetrics;
    size_t needed = 1 + 2 * cast(size_t) numOfHMetrics;
    if (!reconstructFirst)
        needed += 2 * cast(size_t) numOfHMetrics;
    if (!reconstructSecond)
        needed += 2 * cast(size_t) trailingGlyphs;
    if (transformed.length < needed)
    {
        error = "transformed hmtx table is shorter than its flags require";
        return null;
    }

    ushort[] advances = new ushort[numOfHMetrics];
    short[] firstBearings = new short[numOfHMetrics];
    short[] trailingBearings = new short[trailingGlyphs];
    auto cursor = Cursor(transformed, 1);
    foreach (i; 0 .. numOfHMetrics)
    {
        if (!cursor.u16(advances[i]))
        {
            error = "truncated transformed hmtx advance widths";
            return null;
        }
    }
    if (reconstructFirst)
    {
        if (xMins is null || xMins.length < numOfHMetrics)
        {
            error = "hmtx transform needs glyph xMin values";
            return null;
        }
        foreach (i; 0 .. numOfHMetrics)
            firstBearings[i] = cast(short) xMins[i];
    }
    else
    {
        foreach (i; 0 .. numOfHMetrics)
        {
            if (!cursor.i16(firstBearings[i]))
            {
                error = "truncated transformed hmtx side bearings";
                return null;
            }
        }
    }
    if (reconstructSecond)
    {
        if (xMins is null || xMins.length < numGlyphs)
        {
            error = "hmtx transform needs glyph xMin values";
            return null;
        }
        foreach (i; 0 .. trailingGlyphs)
            trailingBearings[i] = cast(short) xMins[numOfHMetrics + i];
    }
    else
    {
        foreach (i; 0 .. trailingGlyphs)
        {
            if (!cursor.i16(trailingBearings[i]))
            {
                error = "truncated transformed hmtx side bearings";
                return null;
            }
        }
    }

    ubyte[] output;
    output.reserve(4 * cast(size_t) numGlyphs);
    foreach (i; 0 .. numOfHMetrics)
    {
        appendU16(output, advances[i]);
        appendI16(output, firstBearings[i]);
    }
    foreach (bearing; trailingBearings)
        appendI16(output, bearing);
    return output;
}

/// Assembles the final sfnt image, sorting directory entries by tag and
/// recalculating every checksum (clause 7).
private ubyte[] buildSfnt(uint flavor, TableEntry[] tables, TableEntry* headEntry,
    out string error)
{
    error = null;
    import std.algorithm.sorting : sort;

    auto order = tables.dup;
    order.sort!((a, b) => a.tag < b.tag);

    const uint numTables = cast(uint) order.length;
    const uint entrySelector = log2Floor(numTables);
    const uint searchRange = (1u << entrySelector) * 16;
    const uint rangeShift = numTables * 16 - searchRange;

    // Offsets follow the 12 byte header and the 16 byte directory entries.
    uint offset = 12 + 16 * numTables;
    uint[] offsets = new uint[numTables];
    uint[] checkSums = new uint[numTables];
    // The head table's checkSumAdjustment is excluded from checksum
    // computation, so clear it before any checksum is taken.
    size_t headAdjustmentOffset = size_t.max;
    foreach (i, ref table; order)
    {
        offsets[i] = offset;
        if (table.tag == "head" && table.data.length >= 12)
        {
            table.data[8] = 0;
            table.data[9] = 0;
            table.data[10] = 0;
            table.data[11] = 0;
            headAdjustmentOffset = offset + 8;
        }
        checkSums[i] = tableChecksum(table);
        offset += alignOffset(cast(uint) table.data.length);
    }

    ubyte[] output;
    output.reserve(offset);
    appendU32(output, flavor);
    appendU16(output, cast(ushort) numTables);
    appendU16(output, cast(ushort) searchRange);
    appendU16(output, cast(ushort) entrySelector);
    appendU16(output, cast(ushort) rangeShift);

    foreach (i, ref table; order)
    {
        foreach (c; table.tag)
            output ~= cast(ubyte) c;
        appendU32(output, checkSums[i]);
        appendU32(output, offsets[i]);
        appendU32(output, cast(uint) table.data.length);
    }
    foreach (i, ref table; order)
    {
        output ~= table.data;
        while (output.length % 4 != 0)
            output ~= 0;
    }

    if (headEntry !is null && headAdjustmentOffset != size_t.max)
    {
        const uint sum = wholeFontChecksum(output);
        const uint adjustment = kChecksumMagic - sum;
        output[headAdjustmentOffset] = cast(ubyte)(adjustment >> 24);
        output[headAdjustmentOffset + 1] = cast(ubyte)((adjustment >> 16) & 0xFF);
        output[headAdjustmentOffset + 2] = cast(ubyte)((adjustment >> 8) & 0xFF);
        output[headAdjustmentOffset + 3] = cast(ubyte)(adjustment & 0xFF);
    }
    else if (headEntry !is null)
    {
        error = "head table is too small to hold checkSumAdjustment";
        return null;
    }
    return output;
}

private uint tableChecksum(const TableEntry table)
{
    uint sum = 0;
    size_t i = 0;
    while (i < table.data.length)
    {
        uint word = 0;
        foreach (b; 0 .. 4)
            word = (word << 8) | (i + b < table.data.length ? table.data[i + b] : 0);
        sum += word;
        i += 4;
    }
    return sum;
}

private uint wholeFontChecksum(const(ubyte)[] font)
{
    uint sum = 0;
    foreach (i; 0 .. font.length / 4)
    {
        const size_t base = i * 4;
        sum += (cast(uint) font[base] << 24) | (cast(uint) font[base + 1] << 16) |
            (cast(uint) font[base + 2] << 8) | font[base + 3];
    }
    return sum;
}

private uint log2Floor(uint value)
{
    uint result = 0;
    while (value > 1)
    {
        value >>= 1;
        ++result;
    }
    return result;
}

version (unittest)
{
    unittest // UIntBase128
    {
        auto cursor = Cursor([cast(ubyte) 0x7F, 0x81, 0x01], 0);
        uint value;
        assert(cursor.uintBase128(value) && value == 0x7F);
        assert(cursor.uintBase128(value) && value == 0x81);
        auto bad = Cursor([cast(ubyte) 0x80, 0x01], 0);
        assert(!bad.uintBase128(value)); // leading zero
    }

    unittest // 255UInt16
    {
        auto small = Cursor([cast(ubyte) 5], 0);
        uint value;
        assert(small.u255(value) && value == 5);
        auto two = Cursor([cast(ubyte) 253, 0x12, 0x34], 0);
        assert(two.u255(value) && value == 0x1234);
        auto one = Cursor([cast(ubyte) 254, 7], 0);
        assert(one.u255(value) && value == 7 + 253);
        auto one2 = Cursor([cast(ubyte) 255, 7], 0);
        assert(one2.u255(value) && value == 7 + 506);
    }

    unittest // triplet decoding against the specification's table
    {
        int dx, dy;
        bool onCurve;
        auto glyph = [cast(ubyte) 0x11];
        size_t pos = 0;
        // Flag 20: four bit deltas based at one, both signs negative.
        assert(decodeTriplet(20, glyph, pos, dx, dy, onCurve));
        assert(dx == -2 && dy == -2 && onCurve);
        // Flag 21 flips the x sign only.
        pos = 0;
        assert(decodeTriplet(21, glyph, pos, dx, dy, onCurve));
        assert(dx == 2 && dy == -2);
        // Flag 0x94 is flag 20 marked off curve.
        pos = 0;
        assert(decodeTriplet(0x94, glyph, pos, dx, dy, onCurve));
        assert(!onCurve && dx == -2 && dy == -2);
        // Flag 84: eight bit deltas based at one.
        auto two = cast(ubyte[]) [0x05, 0x03];
        pos = 0;
        assert(decodeTriplet(84, two, pos, dx, dy, onCurve));
        assert(dx == -6 && dy == -4);
        // Flag 124: sixteen bit deltas; the second byte pair is the y delta.
        auto four = cast(ubyte[]) [0x01, 0x02, 0x03, 0x04];
        pos = 0;
        assert(decodeTriplet(124, four, pos, dx, dy, onCurve));
        assert(dx == -258 && dy == -772);
    }
}
