module aurora.text.cff;

/**
 * Dependency-free Compact Font Format 1 outline reader.
 *
 * This module implements CFF INDEX/DICT data, name-keyed and CID-keyed
 * CharStrings, local/global subroutines, the Type 2 drawing and arithmetic
 * operators, cubic Bézier flattening, and non-zero-winding A8 rasterization.
 */

import aurora.text.glyph : GlyphBitmap;
import std.algorithm : max, min;
import std.exception : enforce;
import std.math : abs, ceil, floor, sqrt;

private ushort be16(const(ubyte)[] data, size_t offset)
{
    enforce(offset + 2 <= data.length, "Truncated CFF data");
    return cast(ushort) ((cast(uint) data[offset] << 8) | data[offset + 1]);
}

private short beS16(const(ubyte)[] data, size_t offset)
{
    return cast(short) be16(data, offset);
}

private uint be32(const(ubyte)[] data, size_t offset)
{
    enforce(offset + 4 <= data.length, "Truncated CFF data");
    return (cast(uint) data[offset] << 24) | (cast(uint) data[offset + 1] << 16) |
        (cast(uint) data[offset + 2] << 8) | data[offset + 3];
}

private int beS32(const(ubyte)[] data, size_t offset)
{
    return cast(int) be32(data, offset);
}

private uint readOffset(const(ubyte)[] data, size_t offset, int size)
{
    enforce(size >= 1 && size <= 4 && offset + cast(size_t) size <= data.length,
        "Invalid CFF INDEX offset");
    uint value;
    foreach (i; 0 .. size)
        value = (value << 8) | data[offset + cast(size_t) i];
    return value;
}

private struct CffIndex
{
    const(ubyte)[] data;
    uint[] offsets;
    size_t nextOffset;

    size_t length() const @safe pure nothrow @nogc
    {
        return offsets.length > 0 ? offsets.length - 1 : 0;
    }

    const(ubyte)[] object(size_t index) const
    {
        enforce(index < length, "CFF INDEX object is out of range");
        return data[offsets[index] .. offsets[index + 1]];
    }
}

private CffIndex parseIndex(const(ubyte)[] data, size_t start)
{
    enforce(start + 2 <= data.length, "Truncated CFF INDEX");
    CffIndex result;
    const count = be16(data, start);
    if (count == 0)
    {
        result.nextOffset = start + 2;
        return result;
    }
    enforce(start + 3 <= data.length, "Truncated CFF INDEX header");
    const offSize = data[start + 2];
    enforce(offSize >= 1 && offSize <= 4, "Invalid CFF INDEX offSize");
    const offsetArray = start + 3;
    const dataStart = offsetArray + cast(size_t) (count + 1) * offSize;
    enforce(dataStart <= data.length, "Truncated CFF INDEX offsets");
    uint[] relative;
    relative.length = count + 1;
    foreach (i; 0 .. count + 1)
        relative[i] = readOffset(data, offsetArray + cast(size_t) i * offSize, offSize);
    enforce(relative[0] == 1, "Invalid CFF INDEX first offset");
    const end = dataStart + relative[$ - 1] - 1;
    enforce(end <= data.length, "CFF INDEX extends beyond table");
    result.data = data[dataStart .. end];
    result.offsets.length = relative.length;
    foreach (i, value; relative)
    {
        enforce(value >= 1, "Invalid CFF INDEX object offset");
        result.offsets[i] = value - 1;
        if (i > 0) enforce(result.offsets[i] >= result.offsets[i - 1],
            "CFF INDEX offsets are not monotonic");
    }
    result.nextOffset = end;
    return result;
}

private struct DictValues
{
    size_t charStrings;
    size_t privateSize;
    size_t privateOffset;
    size_t localSubrs;
    size_t fdArray;
    size_t fdSelect;
    double[6] fontMatrix = [0.001, 0.0, 0.0, 0.001, 0.0, 0.0];
    bool hasFontMatrix;
}

private double parseReal(const(ubyte)[] data, ref size_t cursor)
{
    string value;
    bool done;
    while (!done)
    {
        enforce(cursor < data.length, "Truncated CFF real number");
        const byteValue = data[cursor++];
        foreach (shift; [4, 0])
        {
            const nibble = (byteValue >> shift) & 0x0f;
            if (nibble <= 9) value ~= cast(char) ('0' + nibble);
            else final switch (nibble)
            {
                case 0xA: value ~= '.'; break;
                case 0xB: value ~= 'E'; break;
                case 0xC: value ~= "E-"; break;
                case 0xD: break;
                case 0xE: value ~= '-'; break;
                case 0xF: done = true; break;
            }
            if (done) break;
        }
    }
    import std.conv : to;
    return value.length > 0 ? value.to!double : 0.0;
}

private double parseDictNumber(const(ubyte)[] data, ref size_t cursor)
{
    enforce(cursor < data.length, "Truncated CFF DICT number");
    const first = data[cursor++];
    if (first >= 32 && first <= 246) return cast(int) first - 139;
    if (first >= 247 && first <= 250)
    {
        enforce(cursor < data.length, "Truncated CFF DICT number");
        return (cast(int) first - 247) * 256 + data[cursor++] + 108;
    }
    if (first >= 251 && first <= 254)
    {
        enforce(cursor < data.length, "Truncated CFF DICT number");
        return -(cast(int) first - 251) * 256 - data[cursor++] - 108;
    }
    if (first == 28)
    {
        const result = beS16(data, cursor);
        cursor += 2;
        return result;
    }
    if (first == 29)
    {
        const result = beS32(data, cursor);
        cursor += 4;
        return result;
    }
    if (first == 30) return parseReal(data, cursor);
    if (first == 255)
    {
        const result = beS32(data, cursor);
        cursor += 4;
        return cast(double) result / 65536.0;
    }
    throw new Exception("Invalid CFF DICT operand");
}

private DictValues parseDict(const(ubyte)[] bytes)
{
    DictValues result;
    double[] stack;
    size_t cursor;
    while (cursor < bytes.length)
    {
        const next = bytes[cursor];
        if (next >= 28 || next == 255)
        {
            stack ~= parseDictNumber(bytes, cursor);
            continue;
        }
        ++cursor;
        int op = next;
        if (next == 12)
        {
            enforce(cursor < bytes.length, "Truncated escaped CFF DICT operator");
            op = 1200 + bytes[cursor++];
        }
        switch (op)
        {
            case 17:
                if (stack.length) result.charStrings = cast(size_t) stack[$ - 1];
                break;
            case 18:
                if (stack.length >= 2)
                {
                    result.privateSize = cast(size_t) stack[$ - 2];
                    result.privateOffset = cast(size_t) stack[$ - 1];
                }
                break;
            case 19:
                if (stack.length) result.localSubrs = cast(size_t) stack[$ - 1];
                break;
            case 1207:
                if (stack.length >= 6)
                {
                    foreach (i; 0 .. 6) result.fontMatrix[i] = stack[$ - 6 + i];
                    result.hasFontMatrix = true;
                }
                break;
            case 1236:
                if (stack.length) result.fdArray = cast(size_t) stack[$ - 1];
                break;
            case 1237:
                if (stack.length) result.fdSelect = cast(size_t) stack[$ - 1];
                break;
            default:
                break;
        }
        stack.length = 0;
    }
    return result;
}

private struct Segment
{
    bool cubic;
    double x1;
    double y1;
    double x2;
    double y2;
    double x3;
    double y3;
}

private struct Contour
{
    double startX;
    double startY;
    Segment[] segments;
}

private struct Edge
{
    double x0;
    double y0;
    double x1;
    double y1;
}

private struct CharStringState
{
    double[] stack;
    double[32] transient = 0.0;
    double x = 0.0;
    double y = 0.0;
    Contour[] contours;
    ptrdiff_t current = -1;
    int stemCount;
    bool widthSeen;
    uint randomState = 0x1234567u;

    void clearStack() { stack.length = 0; }

    void moveTo(double dx, double dy)
    {
        version (DebugCff) { import std.stdio : stderr; stderr.writefln("move before=(%s,%s) delta=(%s,%s)", x,y,dx,dy); }
        x += dx;
        y += dy;
        version (DebugCff) { import std.stdio : stderr; stderr.writefln("move after=(%s,%s)", x,y); }
        contours ~= Contour(x, y, null);
        current = cast(ptrdiff_t) contours.length - 1;
    }

    void ensureContour()
    {
        if (current < 0)
        {
            contours ~= Contour(x, y, null);
            current = cast(ptrdiff_t) contours.length - 1;
        }
    }

    void lineTo(double dx, double dy)
    {
        ensureContour();
        version (DebugCff) { import std.stdio : stderr; stderr.writefln("line before=(%s,%s) delta=(%s,%s)", x,y,dx,dy); }
        x += dx;
        y += dy;
        version (DebugCff) { import std.stdio : stderr; stderr.writefln("line after=(%s,%s)", x,y); }
        contours[cast(size_t) current].segments ~= Segment(false, 0, 0, 0, 0, x, y);
    }

    void curveTo(double dx1, double dy1, double dx2, double dy2,
        double dx3, double dy3)
    {
        ensureContour();
        const c1x = x + dx1;
        const c1y = y + dy1;
        const c2x = c1x + dx2;
        const c2y = c1y + dy2;
        x = c2x + dx3;
        y = c2y + dy3;
        contours[cast(size_t) current].segments ~= Segment(true,
            c1x, c1y, c2x, c2y, x, y);
    }
}

/** Parsed static CFF version 1 outline data from an OpenType CFF table. */
final class CffFace
{
    private immutable(ubyte)[] _data;
    private int _unitsPerEm;
    private int _glyphCount;
    private CffIndex _charStrings;
    private CffIndex _globalSubrs;
    private CffIndex _localSubrs;
    private CffIndex[] _fdLocalSubrs;
    private ushort[] _fdForGlyph;
    private double[6] _fontMatrix = [0.001, 0.0, 0.0, 0.001, 0.0, 0.0];

    this(immutable(ubyte)[] tableData, int unitsPerEm, int glyphCount)
    {
        _data = tableData;
        _unitsPerEm = max(1, unitsPerEm);
        _glyphCount = max(0, glyphCount);
        parse();
    }

    int glyphCount() const @safe pure nothrow @nogc { return _glyphCount; }

    GlyphBitmap rasterize(uint glyph, int pixelSize, int advance,
        int supersample = 4) const
    {
        GlyphBitmap result;
        result.glyphIndex = glyph;
        result.advance = advance;
        if (glyph >= _charStrings.length || pixelSize <= 0) return result;

        CharStringState state;
        version (DebugCff)
        {
            import std.stdio : stderr;
            stderr.writefln("CFF glyph %s charstrings=%s bytes=%(%02X %)",
                glyph, _charStrings.length, _charStrings.object(glyph));
        }
        execute(_charStrings.object(glyph), glyph, state, 0, false);
        version (DebugCff)
        {
            import std.stdio : stderr;
            stderr.writefln("CFF contours=%s stack=%s x=%s y=%s", state.contours.length,
                state.stack.length, state.x, state.y);
        }
        if (state.contours.length == 0) return result;

        const scale = cast(double) max(1, pixelSize) / _unitsPerEm;
        double minX = double.infinity;
        double minY = double.infinity;
        double maxX = -double.infinity;
        double maxY = -double.infinity;
        foreach (contour; state.contours)
        {
            includePoint(contour.startX, contour.startY, scale, minX, minY, maxX, maxY);
            foreach (segment; contour.segments)
            {
                if (segment.cubic)
                {
                    includePoint(segment.x1, segment.y1, scale, minX, minY, maxX, maxY);
                    includePoint(segment.x2, segment.y2, scale, minX, minY, maxX, maxY);
                }
                includePoint(segment.x3, segment.y3, scale, minX, minY, maxX, maxY);
            }
        }
        if (minX == double.infinity) return result;
        result.bearingX = cast(int) floor(minX);
        result.bearingY = cast(int) ceil(maxY);
        const right = cast(int) ceil(maxX);
        const bottom = cast(int) floor(minY);
        result.width = max(0, right - result.bearingX);
        result.height = max(0, result.bearingY - bottom);
        if (result.width <= 0 || result.height <= 0) return result;

        Edge[] edges;
        foreach (contour; state.contours)
            flattenContour(contour, scale, result.bearingX, result.bearingY, edges);
        if (edges.length == 0) return result;

        supersample = max(1, min(8, supersample));
        const sampleCount = supersample * supersample;
        result.alpha.length = cast(size_t) result.width * result.height;
        foreach (y; 0 .. result.height)
        {
            foreach (x; 0 .. result.width)
            {
                int insideCount;
                foreach (sy; 0 .. supersample)
                {
                    const py = y + (cast(double) sy + 0.5) / supersample;
                    foreach (sx; 0 .. supersample)
                    {
                        const px = x + (cast(double) sx + 0.5) / supersample;
                        if (insideNonZero(edges, px, py)) ++insideCount;
                    }
                }
                result.alpha[cast(size_t) y * result.width + x] =
                    cast(ubyte) ((insideCount * 255 + sampleCount / 2) / sampleCount);
            }
        }
        return result;
    }

    private void parse()
    {
        enforce(_data.length >= 4, "CFF table is too small");
        enforce(_data[0] == 1, "Only static CFF version 1 outlines are supported");
        const headerSize = _data[2];
        enforce(headerSize >= 4 && headerSize <= _data.length, "Invalid CFF header");
        auto names = parseIndex(_data, headerSize);
        auto top = parseIndex(_data, names.nextOffset);
        enforce(top.length > 0, "CFF Top DICT INDEX is empty");
        auto strings = parseIndex(_data, top.nextOffset);
        _globalSubrs = parseIndex(_data, strings.nextOffset);
        auto topValues = parseDict(top.object(0));
        enforce(topValues.charStrings > 0 && topValues.charStrings < _data.length,
            "CFF Top DICT has no valid CharStrings offset");
        _charStrings = parseIndex(_data, topValues.charStrings);
        if (topValues.hasFontMatrix) _fontMatrix = topValues.fontMatrix;

        if (topValues.fdArray != 0 && topValues.fdSelect != 0)
            parseCidData(topValues);
        else
            _localSubrs = parsePrivateSubrs(topValues.privateOffset,
                topValues.privateSize);
    }

    private CffIndex parsePrivateSubrs(size_t offset, size_t length)
    {
        CffIndex empty;
        if (offset == 0 || length == 0) return empty;
        enforce(offset <= _data.length && length <= _data.length - offset,
            "CFF Private DICT extends beyond table");
        const values = parseDict(_data[offset .. offset + length]);
        if (values.localSubrs == 0) return empty;
        const absolute = offset + values.localSubrs;
        enforce(absolute < _data.length, "Invalid CFF local Subrs offset");
        return parseIndex(_data, absolute);
    }

    private void parseCidData(DictValues top)
    {
        enforce(top.fdArray < _data.length && top.fdSelect < _data.length,
            "Invalid CFF CID offsets");
        const fdArray = parseIndex(_data, top.fdArray);
        _fdLocalSubrs.length = fdArray.length;
        foreach (i; 0 .. fdArray.length)
        {
            const values = parseDict(fdArray.object(i));
            _fdLocalSubrs[i] = parsePrivateSubrs(values.privateOffset,
                values.privateSize);
        }
        _fdForGlyph.length = _charStrings.length;
        parseFdSelect(top.fdSelect);
    }

    private void parseFdSelect(size_t offset)
    {
        enforce(offset < _data.length, "Truncated CFF FDSelect");
        const format = _data[offset++];
        if (format == 0)
        {
            enforce(offset + _fdForGlyph.length <= _data.length,
                "Truncated CFF FDSelect format 0");
            foreach (i; 0 .. _fdForGlyph.length)
                _fdForGlyph[i] = _data[offset + i];
            return;
        }
        if (format == 3)
        {
            const count = be16(_data, offset);
            offset += 2;
            enforce(offset + cast(size_t) count * 3 + 2 <= _data.length,
                "Truncated CFF FDSelect format 3");
            ushort[] starts;
            ushort[] fds;
            starts.length = count + 1;
            fds.length = count;
            foreach (i; 0 .. count)
            {
                starts[i] = be16(_data, offset);
                fds[i] = _data[offset + 2];
                offset += 3;
            }
            starts[$ - 1] = be16(_data, offset);
            foreach (range; 0 .. count)
            {
                const end = min(cast(size_t) starts[range + 1], _fdForGlyph.length);
                foreach (glyph; cast(size_t) starts[range] .. end)
                    _fdForGlyph[glyph] = fds[range];
            }
            return;
        }
        if (format == 4)
        {
            const count = be32(_data, offset);
            offset += 4;
            enforce(offset + cast(size_t) count * 6 + 4 <= _data.length,
                "Truncated CFF FDSelect format 4");
            uint[] starts;
            ushort[] fds;
            starts.length = count + 1;
            fds.length = count;
            foreach (i; 0 .. count)
            {
                starts[i] = be32(_data, offset);
                fds[i] = be16(_data, offset + 4);
                offset += 6;
            }
            starts[$ - 1] = be32(_data, offset);
            foreach (range; 0 .. count)
            {
                const end = min(cast(size_t) starts[range + 1], _fdForGlyph.length);
                foreach (glyph; cast(size_t) starts[range] .. end)
                    _fdForGlyph[glyph] = fds[range];
            }
            return;
        }
        throw new Exception("Unsupported CFF FDSelect format");
    }

    private const(CffIndex)* localSubrs(uint glyph) const @safe pure nothrow @nogc
    {
        if (_fdForGlyph.length > glyph)
        {
            const fd = _fdForGlyph[glyph];
            if (fd < _fdLocalSubrs.length) return &_fdLocalSubrs[fd];
        }
        return &_localSubrs;
    }

    private void execute(const(ubyte)[] code, uint glyph, ref CharStringState state,
        int depth, bool subroutine) const
    {
        if (depth > 32) return;
        size_t cursor;
        while (cursor < code.length)
        {
            const op = code[cursor++];
            if (op >= 32 || op == 28 || op == 255)
            {
                --cursor;
                state.stack ~= parseCharStringNumber(code, cursor);
                continue;
            }
            switch (op)
            {
                case 1: case 3: case 18: case 23:
                    consumeWidthForStem(state);
                    state.stemCount += cast(int) state.stack.length / 2;
                    state.clearStack();
                    break;
                case 4:
                    consumeWidthForMove(state, 1);
                    if (state.stack.length >= 1)
                        state.moveTo(0, state.stack[$ - 1]);
                    state.clearStack();
                    break;
                case 5:
                    foreach (i; 0 .. state.stack.length / 2)
                        state.lineTo(state.stack[i * 2], state.stack[i * 2 + 1]);
                    state.clearStack();
                    break;
                case 6: case 7:
                {
                    bool horizontal = op == 6;
                    foreach (value; state.stack)
                    {
                        state.lineTo(horizontal ? value : 0, horizontal ? 0 : value);
                        horizontal = !horizontal;
                    }
                    state.clearStack();
                    break;
                }
                case 8:
                    for (size_t i; i + 5 < state.stack.length; i += 6)
                        state.curveTo(state.stack[i], state.stack[i + 1],
                            state.stack[i + 2], state.stack[i + 3],
                            state.stack[i + 4], state.stack[i + 5]);
                    state.clearStack();
                    break;
                case 10:
                    if (state.stack.length)
                    {
                        const operand = cast(int) state.stack[$ - 1];
                        state.stack.length = state.stack.length - 1;
                        const index = localSubrs(glyph);
                        const actual = operand + subrBias(index.length);
                        version (DebugCff)
                        {
                            import std.stdio : stderr;
                            if (depth == 0) stderr.writefln("callsubr operand=%s count=%s actual=%s bytes=%(%02X %)",
                                operand, index.length, actual,
                                actual >= 0 && cast(size_t) actual < index.length ?
                                    index.object(cast(size_t) actual) : null);
                        }
                        if (actual >= 0 && cast(size_t) actual < index.length)
                            execute(index.object(cast(size_t) actual), glyph, state,
                                depth + 1, true);
                    }
                    break;
                case 11:
                    return;
                case 12:
                    enforce(cursor < code.length, "Truncated Type 2 escaped operator");
                    executeEscape(code[cursor++], state);
                    break;
                case 14:
                    if (!state.widthSeen && (state.stack.length == 1 || state.stack.length == 5))
                        state.stack = state.stack[1 .. $];
                    state.widthSeen = true;
                    state.clearStack();
                    return;
                case 19: case 20:
                    consumeWidthForStem(state);
                    state.stemCount += cast(int) state.stack.length / 2;
                    state.clearStack();
                    const maskBytes = cast(size_t) (state.stemCount + 7) / 8;
                    enforce(cursor + maskBytes <= code.length, "Truncated Type 2 hint mask");
                    cursor += maskBytes;
                    break;
                case 21:
                    consumeWidthForMove(state, 2);
                    if (state.stack.length >= 2)
                        state.moveTo(state.stack[$ - 2], state.stack[$ - 1]);
                    state.clearStack();
                    break;
                case 22:
                    consumeWidthForMove(state, 1);
                    if (state.stack.length >= 1)
                        state.moveTo(state.stack[$ - 1], 0);
                    state.clearStack();
                    break;
                case 24:
                {
                    size_t i;
                    while (i + 7 < state.stack.length)
                    {
                        state.curveTo(state.stack[i], state.stack[i + 1],
                            state.stack[i + 2], state.stack[i + 3],
                            state.stack[i + 4], state.stack[i + 5]);
                        i += 6;
                    }
                    if (i + 1 < state.stack.length)
                        state.lineTo(state.stack[i], state.stack[i + 1]);
                    state.clearStack();
                    break;
                }
                case 25:
                {
                    size_t i;
                    while (i + 7 < state.stack.length)
                    {
                        state.lineTo(state.stack[i], state.stack[i + 1]);
                        i += 2;
                    }
                    if (i + 5 < state.stack.length)
                        state.curveTo(state.stack[i], state.stack[i + 1],
                            state.stack[i + 2], state.stack[i + 3],
                            state.stack[i + 4], state.stack[i + 5]);
                    state.clearStack();
                    break;
                }
                case 26:
                    executeVvCurve(state);
                    break;
                case 27:
                    executeHhCurve(state);
                    break;
                case 29:
                    if (state.stack.length)
                    {
                        const operand = cast(int) state.stack[$ - 1];
                        state.stack.length = state.stack.length - 1;
                        const actual = operand + subrBias(_globalSubrs.length);
                        if (actual >= 0 && cast(size_t) actual < _globalSubrs.length)
                            execute(_globalSubrs.object(cast(size_t) actual), glyph,
                                state, depth + 1, true);
                    }
                    break;
                case 30: case 31:
                    executeAlternatingCurve(state, op == 31);
                    break;
                default:
                    // Reserved operators are ignored defensively; malformed
                    // programs cannot escape the table slice or recursion cap.
                    state.clearStack();
                    break;
            }
        }
    }

    private static double parseCharStringNumber(const(ubyte)[] code,
        ref size_t cursor)
    {
        enforce(cursor < code.length, "Truncated Type 2 number");
        const first = code[cursor++];
        if (first >= 32 && first <= 246) return cast(int) first - 139;
        if (first >= 247 && first <= 250)
        {
            enforce(cursor < code.length, "Truncated Type 2 number");
            return (cast(int) first - 247) * 256 + code[cursor++] + 108;
        }
        if (first >= 251 && first <= 254)
        {
            enforce(cursor < code.length, "Truncated Type 2 number");
            return -(cast(int) first - 251) * 256 - code[cursor++] - 108;
        }
        if (first == 28)
        {
            const result = beS16(code, cursor);
            cursor += 2;
            return result;
        }
        if (first == 255)
        {
            const result = beS32(code, cursor);
            cursor += 4;
            return cast(double) result / 65536.0;
        }
        throw new Exception("Invalid Type 2 number");
    }

    private static void consumeWidthForStem(ref CharStringState state)
    {
        if (!state.widthSeen && (state.stack.length & 1) != 0)
            state.stack = state.stack[1 .. $];
        state.widthSeen = true;
    }

    private static void consumeWidthForMove(ref CharStringState state,
        size_t required)
    {
        if (!state.widthSeen && state.stack.length > required)
            state.stack = state.stack[1 .. $];
        state.widthSeen = true;
    }

    private static int subrBias(size_t count) @safe pure nothrow @nogc
    {
        return count < 1240 ? 107 : count < 33900 ? 1131 : 32768;
    }

    private static double pop(ref CharStringState state)
    {
        if (!state.stack.length) return 0;
        const result = state.stack[$ - 1];
        state.stack.length = state.stack.length - 1;
        return result;
    }

    private static void executeEscape(ubyte op, ref CharStringState state)
    {
        double a = 0.0, b = 0.0, c = 0.0, d = 0.0;
        switch (op)
        {
            case 0: break; // dotsection
            case 3: b = pop(state); a = pop(state); state.stack ~= (a != 0 && b != 0) ? 1.0 : 0.0; break;
            case 4: b = pop(state); a = pop(state); state.stack ~= (a != 0 || b != 0) ? 1.0 : 0.0; break;
            case 5: a = pop(state); state.stack ~= a == 0 ? 1.0 : 0.0; break;
            case 9: a = pop(state); state.stack ~= abs(a); break;
            case 10: b = pop(state); a = pop(state); state.stack ~= a + b; break;
            case 11: b = pop(state); a = pop(state); state.stack ~= a - b; break;
            case 12: b = pop(state); a = pop(state); state.stack ~= b == 0 ? 0 : a / b; break;
            case 14: a = pop(state); state.stack ~= -a; break;
            case 15: b = pop(state); a = pop(state); state.stack ~= a == b ? 1.0 : 0.0; break;
            case 18: pop(state); break;
            case 20:
                b = pop(state); a = pop(state);
                if (cast(int) a >= 0 && cast(int) a < state.transient.length)
                    state.transient[cast(size_t) cast(int) a] = b;
                break;
            case 21:
                a = pop(state);
                state.stack ~= cast(int) a >= 0 && cast(int) a < state.transient.length ?
                    state.transient[cast(size_t) cast(int) a] : 0.0;
                break;
            case 22:
                d = pop(state); c = pop(state); b = pop(state); a = pop(state);
                state.stack ~= a <= b ? c : d;
                break;
            case 23:
                state.randomState = state.randomState * 1664525u + 1013904223u;
                state.stack ~= (state.randomState + 1.0) / (uint.max + 2.0);
                break;
            case 24: b = pop(state); a = pop(state); state.stack ~= a * b; break;
            case 26: a = pop(state); state.stack ~= sqrt(max(0.0, a)); break;
            case 27: if (state.stack.length) state.stack ~= state.stack[$ - 1]; break;
            case 28:
                if (state.stack.length >= 2)
                {
                    const last = state.stack[$ - 1];
                    state.stack[$ - 1] = state.stack[$ - 2];
                    state.stack[$ - 2] = last;
                }
                break;
            case 29:
                a = pop(state);
                if (state.stack.length)
                {
                    auto index = cast(long) a;
                    if (index < 0) index = 0;
                    if (index >= state.stack.length) index = state.stack.length - 1;
                    state.stack ~= state.stack[$ - 1 - cast(size_t) index];
                }
                break;
            case 30:
                b = pop(state); a = pop(state);
                roll(state.stack, cast(int) a, cast(int) b);
                break;
            case 34: executeHFlex(state); break;
            case 35: executeFlex(state); break;
            case 36: executeHFlex1(state); break;
            case 37: executeFlex1(state); break;
            default: state.clearStack(); break;
        }
    }

    private static void roll(ref double[] stack, int count, int shift)
    {
        if (count <= 0 || cast(size_t) count > stack.length) return;
        shift %= count;
        if (shift < 0) shift += count;
        if (shift == 0) return;
        auto start = stack.length - count;
        auto temp = stack[start .. $].dup;
        foreach (i; 0 .. count)
            stack[start + (i + shift) % count] = temp[i];
    }

    private static void executeHFlex(ref CharStringState state)
    {
        if (state.stack.length >= 7)
        {
            auto s = state.stack;
            state.curveTo(s[0], 0, s[1], s[2], s[3], 0);
            state.curveTo(s[4], 0, s[5], -s[2], s[6], 0);
        }
        state.clearStack();
    }

    private static void executeFlex(ref CharStringState state)
    {
        if (state.stack.length >= 13)
        {
            auto s = state.stack;
            state.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
            state.curveTo(s[6], s[7], s[8], s[9], s[10], s[11]);
        }
        state.clearStack();
    }

    private static void executeHFlex1(ref CharStringState state)
    {
        if (state.stack.length >= 9)
        {
            auto s = state.stack;
            state.curveTo(s[0], s[1], s[2], s[3], s[4], 0);
            state.curveTo(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3]));
        }
        state.clearStack();
    }

    private static void executeFlex1(ref CharStringState state)
    {
        if (state.stack.length >= 11)
        {
            auto s = state.stack;
            const dx = s[0] + s[2] + s[4] + s[6] + s[8];
            const dy = s[1] + s[3] + s[5] + s[7] + s[9];
            state.curveTo(s[0], s[1], s[2], s[3], s[4], s[5]);
            if (abs(dx) > abs(dy))
                state.curveTo(s[6], s[7], s[8], s[9], s[10], -dy);
            else
                state.curveTo(s[6], s[7], s[8], s[9], -dx, s[10]);
        }
        state.clearStack();
    }

    private static void executeVvCurve(ref CharStringState state)
    {
        size_t i;
        double firstDx = 0.0;
        if ((state.stack.length & 1) != 0) firstDx = state.stack[i++];
        bool first = true;
        while (i + 3 < state.stack.length)
        {
            state.curveTo(first ? firstDx : 0, state.stack[i],
                state.stack[i + 1], state.stack[i + 2], 0, state.stack[i + 3]);
            first = false;
            i += 4;
        }
        state.clearStack();
    }

    private static void executeHhCurve(ref CharStringState state)
    {
        size_t i;
        double firstDy = 0.0;
        if ((state.stack.length & 1) != 0) firstDy = state.stack[i++];
        bool first = true;
        while (i + 3 < state.stack.length)
        {
            state.curveTo(state.stack[i], first ? firstDy : 0,
                state.stack[i + 1], state.stack[i + 2], state.stack[i + 3], 0);
            first = false;
            i += 4;
        }
        state.clearStack();
    }

    private static void executeAlternatingCurve(ref CharStringState state,
        bool horizontalFirst)
    {
        size_t i;
        bool horizontal = horizontalFirst;
        while (i + 3 < state.stack.length)
        {
            const remaining = state.stack.length - i;
            if (horizontal)
            {
                const dx1 = state.stack[i++];
                const dx2 = state.stack[i++];
                const dy2 = state.stack[i++];
                double dy3 = state.stack[i++];
                double dx3 = 0.0;
                if (remaining == 5) dx3 = state.stack[i++];
                state.curveTo(dx1, 0, dx2, dy2, dx3, dy3);
            }
            else
            {
                const dy1 = state.stack[i++];
                const dx2 = state.stack[i++];
                const dy2 = state.stack[i++];
                double dx3 = state.stack[i++];
                double dy3 = 0.0;
                if (remaining == 5) dy3 = state.stack[i++];
                state.curveTo(0, dy1, dx2, dy2, dx3, dy3);
            }
            horizontal = !horizontal;
        }
        state.clearStack();
    }

    private void transform(double x, double y, double scale,
        out double px, out double py) const @safe pure nothrow @nogc
    {
        const unitsX = (_fontMatrix[0] * x + _fontMatrix[2] * y + _fontMatrix[4]) * _unitsPerEm;
        const unitsY = (_fontMatrix[1] * x + _fontMatrix[3] * y + _fontMatrix[5]) * _unitsPerEm;
        px = unitsX * scale;
        py = unitsY * scale;
    }

    private void includePoint(double x, double y, double scale,
        ref double minX, ref double minY, ref double maxX, ref double maxY) const
    {
        double px, py;
        transform(x, y, scale, px, py);
        minX = min(minX, px);
        minY = min(minY, py);
        maxX = max(maxX, px);
        maxY = max(maxY, py);
    }

    private void flattenContour(const(Contour) contour, double scale,
        int bearingX, int bearingY, ref Edge[] edges) const
    {
        double startX, startY;
        transform(contour.startX, contour.startY, scale, startX, startY);
        startX -= bearingX;
        startY = bearingY - startY;
        double x = startX;
        double y = startY;
        foreach (segment; contour.segments)
        {
            double endX, endY;
            transform(segment.x3, segment.y3, scale, endX, endY);
            endX -= bearingX;
            endY = bearingY - endY;
            if (segment.cubic)
            {
                double c1x, c1y, c2x, c2y;
                transform(segment.x1, segment.y1, scale, c1x, c1y);
                transform(segment.x2, segment.y2, scale, c2x, c2y);
                c1x -= bearingX; c1y = bearingY - c1y;
                c2x -= bearingX; c2y = bearingY - c2y;
                flattenCubic(x, y, c1x, c1y, c2x, c2y, endX, endY,
                    edges, 0);
            }
            else if (x != endX || y != endY)
                edges ~= Edge(x, y, endX, endY);
            x = endX;
            y = endY;
        }
        if (x != startX || y != startY)
            edges ~= Edge(x, y, startX, startY);
    }

    private static void flattenCubic(double x0, double y0, double x1, double y1,
        double x2, double y2, double x3, double y3, ref Edge[] edges, int depth)
    {
        const ux = 3.0 * x1 - 2.0 * x0 - x3;
        const uy = 3.0 * y1 - 2.0 * y0 - y3;
        const vx = 3.0 * x2 - 2.0 * x3 - x0;
        const vy = 3.0 * y2 - 2.0 * y3 - y0;
        const flatness = max(ux * ux + uy * uy, vx * vx + vy * vy);
        if (depth >= 12 || flatness <= 0.20)
        {
            if (x0 != x3 || y0 != y3) edges ~= Edge(x0, y0, x3, y3);
            return;
        }
        const x01 = (x0 + x1) * 0.5;
        const y01 = (y0 + y1) * 0.5;
        const x12 = (x1 + x2) * 0.5;
        const y12 = (y1 + y2) * 0.5;
        const x23 = (x2 + x3) * 0.5;
        const y23 = (y2 + y3) * 0.5;
        const x012 = (x01 + x12) * 0.5;
        const y012 = (y01 + y12) * 0.5;
        const x123 = (x12 + x23) * 0.5;
        const y123 = (y12 + y23) * 0.5;
        const xm = (x012 + x123) * 0.5;
        const ym = (y012 + y123) * 0.5;
        flattenCubic(x0, y0, x01, y01, x012, y012, xm, ym,
            edges, depth + 1);
        flattenCubic(xm, ym, x123, y123, x23, y23, x3, y3,
            edges, depth + 1);
    }

    private static bool insideNonZero(const(Edge)[] edges, double x, double y)
        @safe pure nothrow @nogc
    {
        int winding;
        foreach (edge; edges)
        {
            if (edge.y0 <= y)
            {
                if (edge.y1 > y && isLeft(edge, x, y) > 0) ++winding;
            }
            else if (edge.y1 <= y && isLeft(edge, x, y) < 0)
                --winding;
        }
        return winding != 0;
    }

    private static double isLeft(Edge edge, double x, double y)
        @safe pure nothrow @nogc
    {
        return (edge.x1 - edge.x0) * (y - edge.y0) -
            (x - edge.x0) * (edge.y1 - edge.y0);
    }
}
