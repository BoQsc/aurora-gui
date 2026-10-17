module auroraweb.brotli;

/**
 * Brotli decompression (RFC 7932), implemented from the specification.
 *
 * Web fonts are frequently served only as WOFF2, and a WOFF2 payload is a
 * Brotli stream wrapping the font's table data.  Without a decoder the engine
 * can only skip those sources, so a page whose stylesheet lists nothing else is
 * shaped in a substitute face and its widths, line wrapping and icon placement
 * all drift away from what the page asked for.  Decoding the stream here keeps
 * that concern in the engine, next to the container code that needs it.
 *
 * The decoder follows the specification field by field: the stream header,
 * the meta-block headers (metadata and uncompressed meta-blocks included),
 * prefix codes in both their simple and complex forms, block switching, the
 * insert-and-copy command alphabet, the ring buffer of the last four
 * distances, literal and distance context modelling, and the static
 * dictionary with its word transformations.
 *
 * Compressed bytes are consumed least significant bit first, as the format
 * requires.  Every field is bounds checked, and an inconsistency is reported
 * as an error message rather than an exception so that a caller can move on to
 * another candidate source.
 *
 * The static dictionary is normative data rather than code: the 122,784-byte
 * DICT array and the 121 word transformations are taken from RFC 7932
 * Appendices A and B and live in `auroraweb.brotli_tables`.  Real WOFF2 fonts
 * rely on dictionary references, so they are resolved rather than refused.
 */

import auroraweb.brotli_tables;

/// Decodes a complete Brotli stream.
///
/// Returns the uncompressed bytes, or null when the stream is malformed, needs
/// the static dictionary or does not match `expectedSize` (when that is
/// non-zero).
ubyte[] brotliDecompress(const(ubyte)[] data, size_t expectedSize = 0)
{
    string reason;
    return brotliDecompress(data, expectedSize, reason);
}

/// Decodes a complete Brotli stream, describing any failure in `error`.
ubyte[] brotliDecompress(const(ubyte)[] data, size_t expectedSize, out string error)
{
    auto decoder = BrotliDecoder(data, expectedSize);
    auto decoded = decoder.run(error);
    version (BrotliTrace)
        if (decoded is null)
            decoder.dumpPartial();
    return decoded;
}

/// Largest amount of output a single stream may produce.
private enum size_t maxDecodedSize = 64 * 1024 * 1024;

/// Parsing trace, compiled in only with -version=BrotliTrace.
version (BrotliTrace)
{
    private void trace(A...)(A args)
    {
        import std.stdio : writeln;
        writeln("[brotli] ", args);
    }
}
else
{
    private void trace(A...)(A args)
    {
    }
}

// ---------------------------------------------------------------------------
// Bit reader
// ---------------------------------------------------------------------------

/// Reads bits from a Brotli stream, least significant bit of a byte first.
private struct BitReader
{
    const(ubyte)[] data;
    size_t position;        ///< bit offset of the next bit to read
    bool truncated;         ///< set once a read ran past the end of the data

    this(const(ubyte)[] bytes)
    {
        data = bytes;
    }

    /// Reads one bit.
    uint bit()
    {
        const at = position >> 3;
        if (at >= data.length)
        {
            truncated = true;
            return 0;
        }
        const value = (data[at] >> (position & 7)) & 1;
        ++position;
        return value;
    }

    /// Reads `count` bits (at most 24), the first bit read becoming the least
    /// significant one.
    uint bits(uint count)
    {
        uint value;
        foreach (i; 0 .. count)
            value |= bit() << i;
        return value;
    }

    /// Discards bits up to the next byte boundary.
    void alignToByte()
    {
        position = (position + 7) & ~cast(size_t) 7;
    }

    /// Reads `length` whole bytes; the position must sit on a byte boundary.
    const(ubyte)[] take(size_t length)
    {
        const at = position >> 3;
        if (at > data.length || length > data.length - at)
        {
            truncated = true;
            position = data.length * 8;
            return null;
        }
        position += length * 8;
        return data[at .. at + length];
    }

    /// Discards `length` whole bytes.
    void skip(size_t length)
    {
        take(length);
    }
}

/// Appends `src` to `dst`.
private void appendBytes(ref ubyte[] dst, const(ubyte)[] src)
{
    const start = dst.length;
    dst.length += src.length;
    foreach (i; 0 .. src.length)
        dst[start + i] = src[i];
}

// ---------------------------------------------------------------------------
// Prefix codes
// ---------------------------------------------------------------------------

/**
 * A canonical prefix code, as Brotli defines one: code lengths per symbol,
 * with the symbols ordered by length and then by symbol value.  A code that
 * carries a single symbol consumes no bits at all.
 *
 * Bits arrive least significant first, so decoding walks the lengths from the
 * shortest upwards, extending the candidate code with each bit read.  The
 * first length whose range contains the candidate decides the symbol.
 */
private struct PrefixCode
{
    uint[16] counts;        ///< number of symbols carrying each code length
    uint[] symbols;         ///< symbols ordered by length, then value
    bool single;            ///< true for a one symbol code
    uint singleSymbol;

    /// Reads one symbol; returns false when the bits read form no symbol.
    bool decode(ref BitReader reader, out uint symbol)
    {
        if (single)
        {
            symbol = singleSymbol;
            return true;
        }
        uint code;
        uint first;
        size_t index;
        foreach (length; 1 .. 16)
        {
            code |= reader.bit();
            if (code < first)
                return false;
            const count = counts[length];
            if (code - first < count)
            {
                const at = index + (code - first);
                if (at >= symbols.length)
                    return false;
                symbol = symbols[at];
                return true;
            }
            index += count;
            first = (first + count) << 1;
            code <<= 1;
        }
        return false;
    }
}

/// Builds the canonical code described by one code length per symbol.
private bool buildCode(ref PrefixCode code, const(uint)[] lengths, ref string error)
{
    uint[16] counts;
    size_t used;
    uint onlySymbol;
    foreach (symbol, length; lengths)
    {
        if (length > 15)
        {
            error = "prefix code length exceeds 15 bits";
            return false;
        }
        if (length != 0)
        {
            ++counts[length];
            ++used;
            onlySymbol = cast(uint) symbol;
        }
    }
    if (used == 0)
    {
        error = "prefix code has no symbols";
        return false;
    }
    code = PrefixCode.init;
    code.counts = counts;
    if (used == 1)
    {
        code.single = true;
        code.singleSymbol = onlySymbol;
        return true;
    }
    code.symbols = new uint[used];
    size_t[16] next;
    size_t at;
    foreach (length; 1 .. 16)
    {
        next[length] = at;
        at += counts[length];
    }
    foreach (symbol, length; lengths)
        if (length != 0)
            code.symbols[next[length]++] = cast(uint) symbol;
    return true;
}

/// Number of bits needed to address a symbol of an alphabet of this size.
private uint symbolBits(uint alphabetSize)
{
    uint width;
    while ((cast(uint) 1 << width) < alphabetSize)
        ++width;
    return width;
}

/// Reads a prefix code, starting with the two-bit code type.
private bool readPrefixCode(ref BitReader reader, uint alphabetSize, ref PrefixCode code, ref string error)
{
    const type = reader.bits(2);
    trace("prefix alphabet=", alphabetSize, " type=", type, " bitPos=", reader.position);
    if (type == 1)
        return readSimpleCode(reader, alphabetSize, code, error);
    return readComplexCode(reader, alphabetSize, type, code, error);
}

/// Reads a simple prefix code: one to four symbols with explicit lengths.
private bool readSimpleCode(ref BitReader reader, uint alphabetSize, ref PrefixCode code, ref string error)
{
    const count = reader.bits(2) + 1;
    const width = symbolBits(alphabetSize);
    uint[4] symbols;
    foreach (i; 0 .. count)
    {
        symbols[i] = reader.bits(width);
        if (symbols[i] >= alphabetSize)
        {
            error = "simple prefix code names a symbol outside its alphabet";
            return false;
        }
        foreach (j; 0 .. i)
            if (symbols[j] == symbols[i])
            {
                error = "simple prefix code repeats a symbol";
                return false;
            }
    }
    if (count == 1)
    {
        code = PrefixCode.init;
        code.single = true;
        code.singleSymbol = symbols[0];
        return true;
    }
    uint[4] lengths;
    if (count == 2)
    {
        lengths[0] = 1;
        lengths[1] = 1;
    }
    else if (count == 3)
    {
        lengths[0] = 1;
        lengths[1] = 2;
        lengths[2] = 2;
    }
    else if (reader.bit() == 0)
    {
        foreach (i; 0 .. 4)
            lengths[i] = 2;
    }
    else
    {
        lengths[0] = 1;
        lengths[1] = 2;
        lengths[2] = 3;
        lengths[3] = 3;
    }
    uint[] full = new uint[alphabetSize];
    foreach (i; 0 .. count)
        full[symbols[i]] = lengths[i];
    return buildCode(code, full, error);
}

/// The order in which the lengths of the code length code appear.
private immutable ubyte[18] codeLengthOrder = [
    1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15
];

/// Reads a code length, encoded in two to four bits.
private uint readCodeLengthCodeLength(ref BitReader reader)
{
    if (reader.bit() == 0)
        return reader.bit() == 0 ? 0 : 3;
    if (reader.bit() == 0)
        return 4;
    if (reader.bit() == 0)
        return 2;
    return reader.bit() == 0 ? 1 : 5;
}

/// Reads a complex prefix code: a code for the code lengths, then the lengths
/// themselves with repeat codes.
private bool readComplexCode(ref BitReader reader, uint alphabetSize, uint hskip, ref PrefixCode code, ref string error)
{
    uint[18] lengthLengths;
    int space = 32;
    size_t used;
    foreach (order; 0 .. codeLengthOrder.length)
    {
        if (order < hskip)
            continue;
        if (space <= 0)
            break;
        const length = readCodeLengthCodeLength(reader);
        lengthLengths[codeLengthOrder[order]] = length;
        if (length != 0)
        {
            space -= 32 >> length;
            ++used;
        }
    }
    if (reader.truncated)
    {
        error = "truncated prefix code definition";
        return false;
    }
    if (used == 0)
    {
        error = "prefix code has no code lengths";
        return false;
    }
    PrefixCode lengthCode;
    if (!buildCode(lengthCode, lengthLengths[], error))
        return false;
    if (used >= 2 && space != 0)
    {
        error = "code length code is not complete";
        return false;
    }

    uint[] lengths = new uint[alphabetSize];
    int mainSpace = 32768;
    size_t at;
    size_t mainUsed;
    uint previous = 8;
    uint repeatSymbol;
    int repeatCount;
    while (at < alphabetSize && mainSpace > 0)
    {
        uint symbol;
        if (!lengthCode.decode(reader, symbol))
        {
            error = "invalid code length symbol";
            return false;
        }
        if (reader.truncated)
        {
            error = "truncated prefix code definition";
            return false;
        }

        if (symbol < 16)
        {
            lengths[at++] = symbol;
            if (symbol != 0)
            {
                mainSpace -= 32768 >> symbol;
                ++mainUsed;
                previous = symbol;
            }
            repeatSymbol = 0;
            repeatCount = 0;
            continue;
        }
        int repeat = cast(int) reader.bits(symbol == 16 ? 2 : 3) + 3;
        if (repeatSymbol == symbol)
        {
            // A repeat code directly after the same repeat code modifies the
            // previous count instead of adding to it; only the difference
            // still has to be emitted.
            const count = (symbol == 16 ? 4 : 8) * (repeatCount - 2) + repeat;
            repeat = count - repeatCount;
            repeatCount = count;
        }
        else
            repeatCount = repeat;
        repeatSymbol = symbol;
        if (repeat > cast(int) (alphabetSize - at))
        {
            error = "code length repeat overruns its alphabet";
            return false;
        }
        if (symbol == 16)
        {
            if (previous == 0)
            {
                error = "code length repeat without a previous length";
                return false;
            }
            foreach (i; 0 .. repeat)
                lengths[at++] = previous;
            mainSpace -= (32768 >> previous) * repeat;
            mainUsed += repeat;
        }
        else
        {
            foreach (i; 0 .. repeat)
                lengths[at++] = 0;
        }
    }
    if (mainUsed == 0)
    {
        error = "prefix code has no symbols";
        return false;
    }
    if (mainUsed > 1 && mainSpace != 0)
    {
        error = "prefix code is not complete";
        return false;
    }
    return buildCode(code, lengths, error);
}

// ---------------------------------------------------------------------------
// Block switching and context maps
// ---------------------------------------------------------------------------

/// Extra bits and base count of each block count code.
private immutable uint[26] blockCountExtraBits = [
    2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11,
    12, 13, 24
];
private immutable uint[26] blockCountBase = [
    1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305,
    369, 497, 753, 1265, 2289, 4337, 8433, 16625
];

/// Reads the variable length code used for block type and tree counts.
private uint readVariableLengthCode(ref BitReader reader)
{
    if (reader.bit() == 0)
        return 1;
    const prefix = reader.bits(3);
    if (prefix == 0)
        return 2;
    return (cast(uint) 1 << prefix) + 1 + reader.bits(prefix);
}

/// The switching state of one block category: literals, commands, distances.
private struct BlockState
{
    uint count;                 ///< number of block types
    uint type;                  ///< current block type
    uint previous;              ///< block type before the current one
    size_t remaining;           ///< blocks items left in the current block
    PrefixCode typeCode;
    PrefixCode countCode;
}

/// Moves a category on to its next block when the current one runs out.
private bool switchBlock(ref BitReader reader, ref BlockState state, ref string error)
{
    uint symbol;
    if (!state.typeCode.decode(reader, symbol))
    {
        error = "invalid block type symbol";
        return false;
    }
    // The two extra symbols of the block type alphabet name the previous block
    // type and the one after the current one; the rest name types from zero.
    uint type;
    if (symbol == 0)
        type = state.previous;
    else if (symbol == 1)
        type = state.type + 1 == state.count ? 0 : state.type + 1;
    else
        type = symbol - 2;
    if (type >= state.count)
    {
        error = "block type outside its alphabet";
        return false;
    }
    if (!state.countCode.decode(reader, symbol) || symbol >= 26)
    {
        error = "invalid block count symbol";
        return false;
    }
    state.previous = state.type;
    state.type = type;
    state.remaining = blockCountBase[symbol] + reader.bits(blockCountExtraBits[symbol]);
    return true;
}

/// Reads a context map: which prefix code serves each context.
private bool readContextMap(ref BitReader reader, uint[] map, uint treeCount, ref string error)
{
    uint maxRunLength;
    if (reader.bit() != 0)
    {
        maxRunLength = reader.bits(4) + 1;
        if (maxRunLength > 16)
        {
            error = "context map run length prefix is too large";
            return false;
        }
    }
    PrefixCode runCode;
    // The code is present even when RLEMAX is zero: its symbols are then the
    // context map values themselves.
    if (!readPrefixCode(reader, maxRunLength + treeCount, runCode, error))
        return false;

    uint[] values = new uint[map.length];
    size_t at;
    while (at < map.length)
    {
        uint symbol;
        if (!runCode.decode(reader, symbol))
        {
            error = "invalid context map symbol";
            return false;
        }
        if (symbol == 0)
        {
            values[at++] = 0;
            continue;
        }
        if (symbol <= maxRunLength)
        {
            const run = (cast(size_t) 1 << symbol) + reader.bits(symbol);
            if (reader.truncated)
            {
                error = "truncated context map";
                return false;
            }
            if (run > map.length - at)
            {
                error = "context map run overruns the map";
                return false;
            }
            foreach (i; 0 .. run)
                values[at++] = 0;
            continue;
        }
        values[at++] = symbol - maxRunLength;
    }
    if (reader.bit() != 0)
    {
        // Inverse move-to-front transform.
        uint[272] mtf;
        foreach (i; 0 .. 272)
            mtf[i] = i < 256 ? cast(uint) i : 0;
        foreach (i; 0 .. values.length)
        {
            const index = values[i];
            if (index >= 272)
            {
                error = "context map value is too large";
                return false;
            }
            const value = mtf[index];
            values[i] = value;
            for (uint j = index; j > 0; --j)
                mtf[j] = mtf[j - 1];
            mtf[0] = value;
        }
    }
    foreach (i; 0 .. map.length)
    {
        if (values[i] >= treeCount)
        {
            error = "context map names a prefix code that does not exist";
            return false;
        }
        map[i] = values[i];
    }
    return true;
}

// ---------------------------------------------------------------------------
// Decoding
// ---------------------------------------------------------------------------

/// Literal context lookup tables, as published with RFC 7932 (section 7.1).
private immutable ubyte[256] lut0 = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 0, 0, 4, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    8, 12, 16, 12, 12, 20, 12, 16, 24, 28, 12, 12, 32, 12, 36, 12,
    44, 44, 44, 44, 44, 44, 44, 44, 44, 44, 32, 32, 24, 40, 28, 12,
    12, 48, 52, 52, 52, 48, 52, 52, 52, 48, 52, 52, 52, 52, 52, 48,
    52, 52, 52, 52, 52, 48, 52, 52, 52, 52, 52, 24, 12, 28, 12, 12,
    12, 56, 60, 60, 60, 56, 60, 60, 60, 56, 60, 60, 60, 60, 60, 56,
    60, 60, 60, 60, 60, 56, 60, 60, 60, 60, 60, 24, 12, 28, 12, 0,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1,
    2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
    2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
    2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3,
    2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3
];
private immutable ubyte[256] lut1 = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1,
    1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1,
    1, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 1, 1, 1, 1, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2
];
private immutable ubyte[256] lut2 = [
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
    6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 7
];

/// Insert and copy length codes: extra bits and base length.
private immutable uint[24] insertExtraBits = [
    0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24
];
private immutable uint[24] insertBase = [
    0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322,
    578, 1090, 2114, 6210, 22594
];
private immutable uint[24] copyExtraBits = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24
];
private immutable uint[24] copyBase = [
    2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198,
    326, 582, 1094, 2118
];

/// Where the insert and copy length codes of each command cell start.
private immutable uint[11] insertCodeRange = [
    0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16
];
private immutable uint[11] copyCodeRange = [
    0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16
];

/// The number of static dictionary words of `length` bytes (RFC 7932, Section 8).
private size_t dictionaryWordCount(uint length)
{
    return length < 4 || length > 24 ? 0 : cast(size_t) 1 << dictionaryNdBits[length];
}

/// Where the words of `length` bytes begin in the DICT array (DOFFSET).
private size_t dictionaryWordOffset(uint length)
{
    size_t offset;
    foreach (candidate; 0 .. length)
        offset += candidate * dictionaryWordCount(cast(uint) candidate);
    return offset;
}

/// Upper-cases the character of a dictionary word that starts at `position`,
/// as RFC 7932 defines "Ferment", and reports how many bytes it occupies.
private uint ferment(ubyte[] word, size_t position)
{
    if (word[position] < 192)
    {
        if (word[position] >= 97 && word[position] <= 122)
            word[position] ^= 32;
        return 1;
    }
    if (word[position] < 224)
    {
        if (position + 1 < word.length)
            word[position + 1] ^= 32;
        return 2;
    }
    if (position + 2 < word.length)
        word[position + 2] ^= 5;
    return 3;
}

/// Applies one of the 121 word transformations to a base dictionary word.
private void applyWordTransform(ref ubyte[] word, uint transformId)
{
    const kind = wordTransformKind[transformId];
    ubyte[] body = word;
    if (kind >= 3 && kind <= 11)                    // OmitFirst1 to OmitFirst9
    {
        const omit = kind - 2;
        body = body.length > omit ? body[omit .. $] : body[0 .. 0];
    }
    else if (kind >= 12 && kind <= 20)              // OmitLast1 to OmitLast9
    {
        const omit = kind - 11;
        body = body.length > omit ? body[0 .. $ - omit] : body[0 .. 0];
    }
    else if (kind == 1 || kind == 2)                // FermentFirst, FermentAll
    {
        body = body.dup;
        if (kind == 1)
        {
            if (body.length != 0)
                ferment(body, 0);
        }
        else
        {
            size_t at;
            while (at < body.length)
                at += ferment(body, at);
        }
    }
    const prefix = cast(const(ubyte)[]) wordTransformPrefix[transformId];
    const suffix = cast(const(ubyte)[]) wordTransformSuffix[transformId];
    ubyte[] transformed = new ubyte[prefix.length + body.length + suffix.length];
    transformed[0 .. prefix.length] = prefix;
    transformed[prefix.length .. prefix.length + body.length] = body;
    transformed[prefix.length + body.length .. $] = suffix;
    word = transformed;
}

/// Decodes one Brotli stream.
private struct BrotliDecoder
{
    BitReader reader;
    ubyte[] result;             ///< bytes produced so far, over the whole stream
    size_t[4] distances;        ///< ring of the last four distances
    ubyte p1;                   ///< last byte produced
    ubyte p2;                   ///< byte before it
    size_t windowSize;
    size_t expectedSize;

    this(const(ubyte)[] data, size_t expectedSize)
    {
        reader = BitReader(data);
        this.expectedSize = expectedSize;
        distances = [16, 15, 11, 4];
    }

    /// Runs the decoder, returning the output or null.
    ubyte[] run(out string error)
    {
        if (!readStreamHeader(error))
            return null;
        if (expectedSize != 0)
            result.reserve(expectedSize);

        bool last = false;
        while (!last)
        {
            const isLast = reader.bit() != 0;
            if (isLast && reader.bit() != 0)
                break;                          // last meta-block, and empty
            const nibbleCode = reader.bits(2);
            if (reader.truncated)
            {
                error = "truncated meta-block header";
                return null;
            }
            if (nibbleCode == 3)
            {
                if (!skipMetadata(error))
                    return null;
                last = isLast;
                continue;
            }
            const nibbles = nibbleCode + 4;
            uint encoded;
            uint topNibble;
            foreach (i; 0 .. nibbles)
            {
                const nibble = reader.bits(4);
                if (i + 1 == nibbles)
                    topNibble = nibble;
                encoded |= nibble << (4 * i);
            }
            if (nibbles > 4 && topNibble == 0)
            {
                error = "meta-block length is not in its shortest form";
                return null;
            }
            const blockLength = cast(size_t) encoded + 1;
            bool uncompressed;
            if (!isLast)
                uncompressed = reader.bit() != 0;
            if (reader.truncated)
            {
                error = "truncated meta-block header";
                return null;
            }
            if (uncompressed)
            {
                if (!appendUncompressed(blockLength, error))
                    return null;
                last = isLast;
                continue;
            }
            if (!decodeCommands(blockLength, error))
                return null;
            last = isLast;
        }
        if (reader.truncated)
        {
            error = "truncated Brotli stream";
            return null;
        }
        if (expectedSize != 0 && result.length != expectedSize)
        {
            error = "Brotli output length does not match the expected size";
            return null;
        }
        return result;
    }

    /// Reads the stream header, which carries only the window size.
    private bool readStreamHeader(out string error)
    {
        size_t bits;
        if (reader.bit() == 0)
            bits = 16;
        else
        {
            const high = reader.bits(3);
            if (high != 0)
                bits = 17 + high;
            else
            {
                const low = reader.bits(3);
                if (low == 1)
                {
                    error = "invalid window size in the Brotli header";
                    return false;
                }
                bits = low != 0 ? 8 + low : 17;
            }
        }
        if (reader.truncated)
        {
            error = "truncated Brotli stream header";
            return false;
        }
        windowSize = (cast(size_t) 1 << bits) - 16;
        return true;
    }

    /// Skips a metadata meta-block, which carries no uncompressed data.
    private bool skipMetadata(out string error)
    {
        if (reader.bit() != 0)
        {
            error = "metadata meta-block has a reserved bit set";
            return false;
        }
        const skipBytes = reader.bits(2);
        size_t length;
        if (skipBytes != 0)
        {
            uint top;
            size_t encoded;
            foreach (i; 0 .. skipBytes)
            {
                const part = reader.bits(8);
                if (i + 1 == skipBytes)
                    top = part;
                encoded |= cast(size_t) part << (8 * i);
            }
            if (skipBytes > 1 && top == 0)
            {
                error = "metadata length is not in its shortest form";
                return false;
            }
            length = encoded + 1;
        }
        reader.alignToByte();
        reader.skip(length);
        if (reader.truncated)
        {
            error = "truncated metadata meta-block";
            return false;
        }
        return true;
    }

    /// Copies an uncompressed meta-block into the output.
    private bool appendUncompressed(size_t blockLength, out string error)
    {
        reader.alignToByte();
        const chunk = reader.take(blockLength);
        if (chunk is null)
        {
            error = "truncated uncompressed meta-block";
            return false;
        }
        appendBytes(result, chunk);
        if (result.length > maxDecodedSize)
        {
            error = "Brotli output exceeds the size limit";
            return false;
        }
        if (blockLength >= 2)
            p2 = chunk[blockLength - 2];
        else
            p2 = p1;
        p1 = chunk[blockLength - 1];
        return true;
    }

    version (BrotliTrace)
    {
        /// Writes the bytes produced so far to a file, so that a decoder
        /// under development can be compared with a reference decoder.
        private void dumpPartial()
        {
            import std.file : write;
            write("C:/Users/windows10/AppData/Local/Temp/aurora-evtest/mine.bin", result);
            trace("DUMP bytes=", result.length);
        }
    }

    /// Copies the static dictionary word that `distance` names.
    ///
    /// RFC 7932, Section 8: a distance past the bytes produced so far selects a
    /// base word of `copyLength` bytes from DICT and then one of the 121 word
    /// transformations.  The transformed word may be shorter or longer than the
    /// base word, and it is that length which counts towards the meta-block.
    private bool appendDictionaryWord(size_t distance, uint copyLength, size_t reach,
        size_t blockLength, ref size_t produced, out string error)
    {
        if (copyLength < 4 || copyLength > 24)
        {
            error = "static dictionary reference has a length outside 4 to 24";
            version (BrotliTrace) dumpPartial();
            return false;
        }
        const bits = dictionaryNdBits[copyLength];
        const wordId = distance - reach - 1;
        const transformId = cast(uint) (wordId >> bits);
        if (transformId > 120)
        {
            error = "static dictionary reference names an unknown transformation";
            version (BrotliTrace) dumpPartial();
            return false;
        }
        const wordCount = cast(size_t) 1 << bits;
        const start = dictionaryWordOffset(copyLength) + (wordId % wordCount) * copyLength;
        ubyte[] word = dictionaryBytes[start .. start + copyLength].dup;
        applyWordTransform(word, transformId);
        if (produced + word.length > blockLength)
        {
            error = "static dictionary copy exceeds the meta-block length";
            return false;
        }
        if (result.length + word.length > maxDecodedSize)
        {
            error = "Brotli output exceeds the size limit";
            return false;
        }
        appendBytes(result, word);
        produced += word.length;
        if (word.length >= 2)
            p2 = word[word.length - 2];
        else if (word.length == 1)
            p2 = p1;
        if (word.length != 0)
            p1 = word[word.length - 1];
        return true;
    }

    /// Decodes one compressed meta-block of `blockLength` bytes.
    private bool decodeCommands(size_t blockLength, out string error)
    {
        BlockState[3] blocks;
        foreach (category; 0 .. 3)
        {
            const types = readVariableLengthCode(reader);
            if (reader.truncated || types < 1 || types > 256)
            {
                error = "invalid number of block types";
                return false;
            }
            blocks[category] = BlockState.init;
            blocks[category].count = types;
            blocks[category].type = 0;
            blocks[category].previous = 1;
            if (types >= 2)
            {
                if (!readPrefixCode(reader, types + 2, blocks[category].typeCode, error))
                    return false;
                if (!readPrefixCode(reader, 26, blocks[category].countCode, error))
                    return false;
                uint symbol;
                if (!blocks[category].countCode.decode(reader, symbol) || symbol >= 26)
                {
                    error = "invalid block count";
                    return false;
                }
                blocks[category].remaining =
                    blockCountBase[symbol] + reader.bits(blockCountExtraBits[symbol]);
            }
            else
            {
                blocks[category].remaining = size_t.max;
            }
        }
        const postfixBits = reader.bits(2);
        const directCount = reader.bits(4) << postfixBits;
        const postfixMask = (cast(uint) 1 << postfixBits) - 1;
        const distanceAlphabet = 16 + directCount + (48 << postfixBits);
        if (reader.truncated)
        {
            error = "truncated meta-block header";
            return false;
        }

        uint[] contextModes = new uint[blocks[0].count];
        foreach (i; 0 .. contextModes.length)
            contextModes[i] = reader.bits(2);

        const literalTrees = readVariableLengthCode(reader);
        if (reader.truncated || literalTrees < 1 || literalTrees > 256)
        {
            error = "invalid number of literal prefix codes";
            return false;
        }
        uint[] literalMap;
        if (literalTrees >= 2)
        {
            literalMap = new uint[64 * blocks[0].count];
            if (!readContextMap(reader, literalMap, literalTrees, error))
                return false;
        }

        const distanceTrees = readVariableLengthCode(reader);
        if (reader.truncated || distanceTrees < 1 || distanceTrees > 256)
        {
            error = "invalid number of distance prefix codes";
            return false;
        }
        uint[] distanceMap;
        if (distanceTrees >= 2)
        {
            distanceMap = new uint[4 * blocks[2].count];
            if (!readContextMap(reader, distanceMap, distanceTrees, error))
                return false;
        }

        PrefixCode[] literalCodes = new PrefixCode[literalTrees];
        trace("mb len=", blockLength, " typesL=", blocks[0].count, " typesI=", blocks[1].count,
            " typesD=", blocks[2].count, " npostfix=", postfixBits, " ndirect=", directCount,
            " cmode0=", contextModes[0], " nTreesL=", literalTrees, " nTreesD=", distanceTrees,
            " bitPos=", reader.position);
        foreach (i; 0 .. literalCodes.length)
            if (!readPrefixCode(reader, 256, literalCodes[i], error))
                return false;
        PrefixCode[] commandCodes = new PrefixCode[blocks[1].count];
        foreach (i; 0 .. commandCodes.length)
            if (!readPrefixCode(reader, 704, commandCodes[i], error))
                return false;
        PrefixCode[] distanceCodes = new PrefixCode[distanceTrees];
        foreach (i; 0 .. distanceCodes.length)
            if (!readPrefixCode(reader, distanceAlphabet, distanceCodes[i], error))
                return false;
        if (reader.truncated)
        {
            error = "truncated meta-block header";
            return false;
        }

        size_t produced;
        while (produced < blockLength)
        {
            if (blocks[1].remaining == 0)
                if (!switchBlock(reader, blocks[1], error))
                    return false;
            --blocks[1].remaining;
            uint command;
            if (!commandCodes[blocks[1].type].decode(reader, command) || command >= 704)
            {
                error = "invalid insert-and-copy length symbol";
                return false;
            }
            const cell = command >> 6;
            const insertCode = insertCodeRange[cell] + ((command >> 3) & 7);
            const copyCode = copyCodeRange[cell] + (command & 7);
            const insertLength = insertBase[insertCode] + reader.bits(insertExtraBits[insertCode]);
            const copyLength = copyBase[copyCode] + reader.bits(copyExtraBits[copyCode]);
            if (produced < 2000)
                trace("cmd=", command, " ins=", insertLength, " copy=", copyLength,
                    " pos=", result.length);

            foreach (i; 0 .. insertLength)
            {
                if (blocks[0].remaining == 0)
                    if (!switchBlock(reader, blocks[0], error))
                        return false;
                --blocks[0].remaining;
                const mode = contextModes[blocks[0].type];
                uint context;
                if (mode == 0)
                    context = p1 & 0x3f;
                else if (mode == 1)
                    context = p1 >> 2;
                else if (mode == 2)
                    context = lut0[p1] | lut1[p2];
                else
                    context = (lut2[p1] << 3) | lut2[p2];
                const tree = literalMap.length != 0 ?
                    literalMap[64 * blocks[0].type + context] : 0;
                if (tree >= literalCodes.length)
                {
                    error = "literal context names a prefix code that does not exist";
                    return false;
                }
                uint literal;
                if (!literalCodes[tree].decode(reader, literal))
                {
                    error = "invalid literal symbol";
                    return false;
                }
                result ~= cast(ubyte) literal;
                p2 = p1;
                p1 = cast(ubyte) literal;
                ++produced;
            }
            if (reader.truncated)
            {
                error = "truncated meta-block";
                return false;
            }
            if (produced > blockLength)
            {
                error = "meta-block literals exceed its length";
                return false;
            }
            if (produced == blockLength)
                break;                  // the last command's copy length is unused

            const distanceContext =
                copyLength == 2 ? 0 : copyLength == 3 ? 1 : copyLength == 4 ? 2 : 3;

            size_t distance;
            bool rememberDistance;
            if (command < 128)
            {
                // The insert-and-copy length code stands for distance symbol 0.
                distance = distances[3];
                rememberDistance = false;
            }
            else
            {
                // Only commands that carry an explicit distance code advance the
                // distance block counter.
                if (blocks[2].remaining == 0)
                    if (!switchBlock(reader, blocks[2], error))
                        return false;
                --blocks[2].remaining;
                const tree = distanceMap.length != 0 ?
                    distanceMap[4 * blocks[2].type + distanceContext] : 0;
                if (tree >= distanceCodes.length)
                {
                    error = "distance context names a prefix code that does not exist";
                    return false;
                }
                uint symbol;
                if (!distanceCodes[tree].decode(reader, symbol) || symbol >= distanceAlphabet)
                {
                    error = "invalid distance symbol";
                    return false;
                }
                if (symbol < 4)
                {
                    distance = distances[3 - symbol];
                }
                else if (symbol < 16)
                {
                    const recent = symbol < 10;
                    immutable int[6] steps = [-1, 1, -2, 2, -3, 3];
                    const base = recent ? distances[3] : distances[2];
                    const step = steps[recent ? symbol - 4 : symbol - 10];
                    if (step < 0 && base < cast(size_t) -step)
                    {
                        error = "distance shortcut resolves to zero or less";
                        return false;
                    }
                    const adjusted = cast(ptrdiff_t) base + step;
                    if (adjusted <= 0)
                    {
                        error = "distance shortcut resolves to zero or less";
                        return false;
                    }
                    distance = cast(size_t) adjusted;
                }
                else if (symbol < 16 + directCount)
                {
                    distance = symbol - 15;
                }
                else
                {
                    const code = symbol - directCount - 16;
                    const extraBits = 1 + (code >> (postfixBits + 1));
                    const extra = reader.bits(extraBits);
                    const high = code >> postfixBits;
                    const low = code & postfixMask;
                    const offset = ((2 + (high & 1)) << extraBits) - 4;
                    distance = ((cast(size_t) (offset + extra)) << postfixBits) +
                        low + directCount + 1;
                }
                if (reader.truncated)
                {
                    error = "truncated distance code";
                    return false;
                }
                rememberDistance = symbol != 0;
            }

            const reach = windowSize < result.length ? windowSize : result.length;
            if (distance > reach)
            {
                // A distance beyond the bytes produced so far names a word in
                // the static dictionary rather than a backward reference.
                if (!appendDictionaryWord(distance, copyLength, reach, blockLength,
                        produced, error))
                    return false;
                continue;
            }
            if (rememberDistance)
            {
                // Dictionary references are not pushed onto the ring.
                distances[0] = distances[1];
                distances[1] = distances[2];
                distances[2] = distances[3];
                distances[3] = distance;
            }
            if (distance == 0 || produced + copyLength > blockLength)
            {
                error = "meta-block copy exceeds its length";
                return false;
            }
            foreach (i; 0 .. copyLength)
            {
                const value = result[result.length - distance];
                result ~= value;
                p2 = p1;
                p1 = value;
            }
            produced += copyLength;
            if (result.length > maxDecodedSize)
            {
                error = "Brotli output exceeds the size limit";
                return false;
            }
        }
        return true;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    /// Assembles a Brotli stream bit by bit, as the format reads it.
    private struct BitWriter
    {
        ubyte[] bytes;
        uint used;              ///< bits already filled in the last byte

        /// Writes `count` bits of `value`, least significant bit first.
        void put(uint value, uint count)
        {
            foreach (i; 0 .. count)
                putBit((value >> i) & 1);
        }

        void putBit(uint bit)
        {
            if (used == 0)
                bytes ~= 0;
            bytes[$ - 1] |= cast(ubyte) (bit << used);
            used = (used + 1) & 7;
        }
    }

    /// The prefix code for a single symbol, which consumes no bits.
    private void putSimpleCode(BitWriter* writer, uint alphabetSize, uint symbol)
    {
        writer.put(1, 2);                       // code type: simple
        writer.put(0, 2);                       // one symbol
        writer.put(symbol, symbolBits(alphabetSize));
    }

    /// An uncompressed meta-block followed by an empty last one.
    unittest
    {
        import std.algorithm.comparison : equal;
        const expected = "Hello, Brotli!";
        BitWriter writer;
        writer.put(0, 1);                       // window size 16
        writer.put(0, 1);                       // not the last meta-block
        writer.put(0, 2);                       // four nibbles of length
        writer.put(cast(uint) expected.length - 1, 16);
        writer.put(1, 1);                       // uncompressed
        while (writer.used != 0)
            writer.putBit(0);
        foreach (i; 0 .. expected.length)
            writer.bytes ~= cast(ubyte) expected[i];
        writer.put(1, 1);                       // last meta-block
        writer.put(1, 1);                       // and empty

        string error;
        auto decoded = brotliDecompress(writer.bytes, expected.length, error);
        assert(decoded !is null, error);
        assert(equal(cast(const(ubyte)[]) decoded, cast(const(ubyte)[]) expected));
    }

    /// A compressed meta-block: one literal, then a copy of two bytes from the
    /// single byte just produced.
    unittest
    {
        import std.algorithm.comparison : equal;
        const expected = "AAA";
        BitWriter writer;
        writer.put(0, 1);                       // window size 16
        writer.put(0, 1);                       // not the last meta-block
        writer.put(0, 2);                       // four nibbles of length
        writer.put(cast(uint) expected.length - 1, 16);
        writer.put(0, 1);                       // compressed
        writer.put(0, 1);                       // one literal block type
        writer.put(0, 1);                       // one command block type
        writer.put(0, 1);                       // one distance block type
        writer.put(0, 2);                       // no postfix bits
        writer.put(0, 4);                       // no direct distance codes
        writer.put(0, 2);                       // literal context mode LSB6
        writer.put(0, 1);                       // one literal prefix code
        writer.put(0, 1);                       // one distance prefix code
        putSimpleCode(&writer, 256, 'A');
        // Insert-and-copy code 1 with copy code 0: one literal, then two bytes.
        putSimpleCode(&writer, 704, 128 + (1 << 3));
        // Distance code 16 with no extra bits is a backward distance of one.
        putSimpleCode(&writer, 64, 16);
        writer.put(0, 1);                       // the extra bit of distance code 16
        writer.put(1, 1);                       // last meta-block
        writer.put(1, 1);                       // and empty

        string error;
        auto decoded = brotliDecompress(writer.bytes, expected.length, error);
        assert(decoded !is null, error);
        assert(equal(cast(const(ubyte)[]) decoded, cast(const(ubyte)[]) expected));
    }

    /// The literal context tables published with the specification.
    unittest
    {
        assert(crc32(lut0[]) == 0x8e91_efb7, "Lut0 does not match RFC 7932");
        assert(crc32(lut1[]) == 0xd01a_32f4, "Lut1 does not match RFC 7932");
        assert(crc32(lut2[]) == 0x0dd7_a0d6, "Lut2 does not match RFC 7932");
    }

    /// Damaged or unsupported streams are reported, never thrown.
    unittest
    {
        string error;
        assert(brotliDecompress(null, 0, error) is null, "an empty stream has no header");
        assert(brotliDecompress([], 0, error) is null);

        // An uncompressed meta-block announcing more bytes than the stream has.
        BitWriter writer;
        writer.put(0, 1);
        writer.put(0, 1);
        writer.put(0, 2);
        writer.put(999, 16);
        writer.put(1, 1);
        while (writer.used != 0)
            writer.putBit(0);
        assert(brotliDecompress(writer.bytes, 0, error) is null,
            "a truncated meta-block must be rejected");

        // Output that does not match the size the caller expects.
        BitWriter plain;
        plain.put(0, 1);
        plain.put(0, 1);
        plain.put(0, 2);
        plain.put(2, 16);
        plain.put(1, 1);
        while (plain.used != 0)
            plain.putBit(0);
        plain.bytes ~= "abc";
        plain.put(1, 1);
        plain.put(1, 1);
        assert(brotliDecompress(plain.bytes, 0, error) !is null, error);
        assert(brotliDecompress(plain.bytes, 4, error) is null,
            "a length mismatch must be rejected");

        // A distance that reaches past the output is a dictionary reference.
        BitWriter distant;
        distant.put(0, 1);
        distant.put(0, 1);
        distant.put(0, 2);
        distant.put(2, 16);
        distant.put(0, 1);
        distant.put(0, 1);
        distant.put(0, 1);
        distant.put(0, 1);
        distant.put(0, 2);
        distant.put(0, 4);
        distant.put(0, 2);
        distant.put(0, 1);
        distant.put(0, 1);
        putSimpleCode(&distant, 256, 'A');
        putSimpleCode(&distant, 704, 128 + (1 << 3));
        putSimpleCode(&distant, 64, 16);
        distant.put(1, 1);                      // ... so the distance becomes two
        distant.put(1, 1);
        distant.put(1, 1);
        assert(brotliDecompress(distant.bytes, 0, error) is null,
            "a dictionary reference must be refused, not guessed");
    }

    /// The reference CRC-32 (as used by the published table checksums).
    private uint crc32(const(ubyte)[] data)
    {
        uint crc = 0xFFFF_FFFF;
        foreach (byteValue; data)
        {
            crc ^= byteValue;
            foreach (i; 0 .. 8)
                crc = (crc & 1) ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1;
        }
        return ~crc;
    }
}
