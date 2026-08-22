module aurora.text.variations;

/**
 * Pure-D OpenType variable-font support (fvar/avar/gvar/HVAR/VVAR).
 *
 * Parses the variable-font tables directly from the sfnt bytes and provides:
 *
 *   - Axis inventory (`fvar`), including min/default/max and name IDs.
 *   - Coordinate normalization (`[min,def,max] -> [-1,0,1]`) with the `avar`
 *     piecewise-linear segment mapping applied.
 *   - Per-glyph outline deltas from `gvar` (packed points + packed deltas +
 *     tuple scalars, including shared/embedded/intermediate tuples).
 *   - Advance-width adjustment from `HVAR` (item variation store +
 *     delta-set index map).
 *
 * All internal math follows FreeType's ttgxvar.c: 16.16 fixed point for
 * scalars and deltas, F2DOT14 stored values shifted left two bits.
 */

private enum uint tag(string value) =
    (cast(uint) value[0] << 24) | (cast(uint) value[1] << 16) |
    (cast(uint) value[2] << 8) | cast(uint) value[3];

private ushort be16(const(ubyte)[] data, size_t offset)
{
    if (offset + 2 > data.length) throw new Exception("Truncated variation data");
    return cast(ushort) ((cast(uint) data[offset] << 8) | data[offset + 1]);
}

private short beS16(const(ubyte)[] data, size_t offset)
{
    return cast(short) be16(data, offset);
}

private uint be32(const(ubyte)[] data, size_t offset)
{
    if (offset + 4 > data.length) throw new Exception("Truncated variation data");
    return (cast(uint) data[offset] << 24) | (cast(uint) data[offset + 1] << 16) |
        (cast(uint) data[offset + 2] << 8) | cast(uint) data[offset + 3];
}

private int beS32(const(ubyte)[] data, size_t offset)
{
    return cast(int) be32(data, offset);
}

/// F16DOT16 fixed-point arithmetic helpers (all 16.16).
private long mulFix(long a, long b) @safe pure nothrow @nogc
{
    return (a * b + 0x8000) >> 16;
}

private long mulDiv(long a, long b, long c) @safe pure nothrow @nogc
{
    if (c == 0) return 0;
    const long product = a * b;
    return product >= 0 ? (product + c / 2) / c : (product - c / 2) / c;
}

private long divFix(long a, long b) @safe pure nothrow @nogc
{
    if (b == 0) return 0;
    return (a << 16) / b;
}

/// One axis from the fvar table.
struct VariationAxis
{
    uint axisTag;      /// e.g. 'wght'
    long minValue;     /// F16DOT16
    long defaultValue; /// F16DOT16
    long maxValue;     /// F16DOT16
    ushort flags;
    ushort nameId;
}

/// Resolved normalized coordinates (16.16) plus axis inventory.
final class FontVariations
{
    private const(ubyte)[] _data;
    private size_t _faceOffset;
    private VariationAxis[] _axes;
    private long[] _normalized;      /// Current normalized coords (16.16).
    private bool _hasAvar;
    private int[][] _avarFrom;       /// Per-axis F2DOT14*4 (16.16) from coords.
    private int[][] _avarTo;
    private long[] _design;          /// Current design coords (16.16).

    // gvar.
    private bool _hasGvar;
    private size_t _gvarBase;         /// Absolute offset of the gvar table.
    private uint[] _glyphOffsets;     /// Relative to the gvar table start.
    private long[] _sharedTuples;     /// globalCoordCount * axisCount (16.16).
    private ushort _sharedTupleCount;
    private ushort _axisCount;

    // HVAR.
    private bool _hasHvar;
    private VariationStore _hvarStore;
    private DeltaSetIdxMap _hvarWidthMap;

    /// Item variation store (HVAR/VVAR/avar2).
    private struct Region
    {
        long[] startCoord;
        long[] peakCoord;
        long[] endCoord;
    }

    private struct ItemVarData
    {
        ushort itemCount;
        ushort wordDeltaCount;
        bool longWords;
        ushort[] regionIndices;
        const(ubyte)[] deltaSet;
    }

    private struct VariationStore
    {
        Region[] regions;
        ItemVarData[] varData;
        ushort axisCount;
    }

    private struct DeltaSetIdxMap
    {
        ushort[] outerIndex;
        ushort[] innerIndex;
    }

    this(const(ubyte)[] data, size_t faceOffset)
    {
        _data = data;
        _faceOffset = faceOffset;
        parseFvar();
        if (_axes.length == 0) return;
        _normalized.length = _axes.length;
        _design.length = _axes.length;
        foreach (i; 0 .. _axes.length)
            _design[i] = _axes[i].defaultValue;
        parseAvar();
        parseGvar();
        parseHvar();
        computeNormalized();
    }

    bool hasVariations() const @safe pure nothrow @nogc { return _axes.length > 0; }
    const(VariationAxis)[] axes() const @safe pure nothrow @nogc { return _axes; }

    /// Set design-space coordinates (F16DOT16); returns true if changed.
    bool setDesignCoords(long[] coords)
    {
        if (coords.length != _axes.length) return false;
        bool changed;
        foreach (i; 0 .. _axes.length)
            if (_design[i] != coords[i]) { changed = true; break; }
        if (!changed) return false;
        _design = coords.dup;
        computeNormalized();
        return true;
    }

    /// Current normalized coordinates (16.16), avar-mapped.
    const(long)[] normalizedCoords() const @safe pure nothrow @nogc { return _normalized; }

    /// Design coordinates as F16DOT16.
    const(long)[] designCoords() const @safe pure nothrow @nogc { return _design; }

    /// Whether changing an axis currently would change the outline.
    bool active() const @safe pure nothrow @nogc
    {
        return _hasGvar || _hasHvar;
    }

    /**
     * Apply gvar deltas to a glyph's design-unit outline points.
     * `xs`/`ys` are modified in place; the four phantom points at the end are
     * treated as points n, n+1, n+2, n+3. Returns true if any delta applied.
     */
    bool applyGlyphDeltas(uint glyph, ref int[] xs, ref int[] ys)
    {
        if (!_hasGvar || glyph >= _glyphOffsets.length - 1) return false;
        const start = _glyphOffsets[glyph];
        const end = _glyphOffsets[glyph + 1];
        if (end <= start) return false;

        const nPoints = xs.length;
        long[] deltasX;
        long[] deltasY;
        deltasX.length = nPoints;
        deltasY.length = nPoints;

        const data = _data;
        size_t cursor = _gvarBase + start;
        if (cursor + 4 > data.length) return false;

        ushort tupleCountField = be16(data, cursor);
        ushort offsetToData = be16(data, cursor + 2);
        cursor += 4;

        const sharedPointsFlag = (tupleCountField & 0x8000) != 0;
        const tupleCount = tupleCountField & 0x0FFF;

        // The glyph's own data begins at the offset (which already includes
        // the gvar header's offsetToData) + the glyph's tuple-data offset.
        const dataStart = _gvarBase + start + offsetToData;
        size_t dataCursor = dataStart;

        // Shared point numbers (if the shared flag is set).
        int[] sharedPoints;
        if (sharedPointsFlag)
        {
            sharedPoints = readPackedPoints(data, dataCursor);
            if (sharedPoints.length == 0 && lastPackedWasAllPoints)
                sharedPoints = null; // ALL_POINTS marker
            else if (lastPackedWasAllPoints)
                sharedPoints = null;
        }

        // Walk each tuple.
        foreach (tuple; 0 .. tupleCount)
        {
            if (cursor + 4 > data.length) break;
            const tupleDataSize = be16(data, cursor);
            const tupleIndex = be16(data, cursor + 2);
            cursor += 4;

            const embeddedPeak = (tupleIndex & 0x8000) != 0;
            const intermediate = (tupleIndex & 0x4000) != 0;
            const privatePoints = (tupleIndex & 0x2000) != 0;
            const sharedIndex = tupleIndex & 0x0FFF;

            long[] peakTuple;
            peakTuple.length = _axisCount;
            if (embeddedPeak)
            {
                foreach (axis; 0 .. _axisCount)
                {
                    peakTuple[axis] = cast(long) beS16(data, cursor) << 2;
                    cursor += 2;
                }
            }
            else
            {
                if (sharedIndex >= _sharedTupleCount) continue;
                foreach (axis; 0 .. _axisCount)
                    peakTuple[axis] = _sharedTuples[cast(size_t) sharedIndex * _axisCount + axis];
            }

            long[] imStart;
            long[] imEnd;
            if (intermediate)
            {
                imStart.length = _axisCount;
                imEnd.length = _axisCount;
                foreach (axis; 0 .. _axisCount)
                {
                    imStart[axis] = cast(long) beS16(data, cursor) << 2;
                    cursor += 2;
                }
                foreach (axis; 0 .. _axisCount)
                {
                    imEnd[axis] = cast(long) beS16(data, cursor) << 2;
                    cursor += 2;
                }
            }

            // The tuple's packed point + delta data lives at dataCursor.
            int[] points;
            if (privatePoints)
            {
                points = readPackedPoints(data, dataCursor);
                if (lastPackedWasAllPoints) points = null;
            }
            else
                points = sharedPoints;

            const pointCount = cast(uint) (points is null ? nPoints : points.length);
            long[] dx = readPackedDeltas(data, dataCursor, pointCount);
            long[] dy = readPackedDeltas(data, dataCursor, pointCount);

            // Compute the tuple scalar.
            long apply = 0x10000;
            foreach (axis; 0 .. _axisCount)
            {
                const coord = peakTuple[axis];
                if (coord == 0) continue;
                const ncv = _normalized[axis];
                if (ncv == 0) { apply = 0; break; }
                if (coord == ncv) continue;
                if (!intermediate)
                {
                    if ((coord > ncv && ncv > 0) || (coord < ncv && ncv < 0))
                        apply = mulDiv(apply, ncv, coord);
                    else { apply = 0; break; }
                }
                else
                {
                    if (ncv <= imStart[axis] || ncv >= imEnd[axis]) { apply = 0; break; }
                    if (ncv < coord)
                        apply = mulDiv(apply, ncv - imStart[axis], coord - imStart[axis]);
                    else
                        apply = mulDiv(apply, imEnd[axis] - ncv, imEnd[axis] - coord);
                }
            }
            if (apply == 0)
            {
                // Skip the private data for this tuple.
                dataCursor += tupleDataSize;
                continue;
            }

            if (points is null)
            {
                foreach (j; 0 .. nPoints)
                {
                    deltasX[j] += mulFix(dx[j], apply);
                    deltasY[j] += mulFix(dy[j], apply);
                }
            }
            else
            {
                foreach (j; 0 .. points.length)
                {
                    const idx = points[j];
                    if (idx >= nPoints) continue;
                    deltasX[idx] += mulFix(dx[j], apply);
                    deltasY[idx] += mulFix(dy[j], apply);
                }
                // Interpolate the points without deltas (IUP-like).
                interpolateDeltas(xs, deltasX, points);
                interpolateDeltas(ys, deltasY, points);
            }

            dataCursor += tupleDataSize;
        }

        bool applied;
        foreach (i; 0 .. nPoints)
        {
            const ddx = cast(int) ((deltasX[i] + 0x8000) >> 16);
            const ddy = cast(int) ((deltasY[i] + 0x8000) >> 16);
            if (ddx != 0 || ddy != 0)
            {
                xs[i] += ddx;
                ys[i] += ddy;
                applied = true;
            }
        }
        return applied;
    }

    /// Debug: number of tuples found for a glyph (used by probes/tests).
    int debugTupleCount(uint glyph)
    {
        if (!_hasGvar || glyph >= _glyphOffsets.length - 1) return -1;
        const start = _glyphOffsets[glyph];
        const end = _glyphOffsets[glyph + 1];
        if (end <= start) return -1;
        size_t cursor = _gvarBase + start;
        if (cursor + 4 > _data.length) return -1;
        return be16(_data, cursor) & 0x0FFF;
    }

    /// Debug: HVAR advance delta for a glyph.
    int debugHvarDelta(uint glyph)
    {
        if (!_hasHvar) return 0;
        return hvarDelta(glyph);
    }

    /// Adjust an advance width (design units) by the HVAR delta.
    int adjustAdvance(uint glyph, int advance)
    {
        if (!_hasHvar) return advance;
        const delta = hvarDelta(glyph);
        return advance + delta;
    }

    /// HVAR delta for a glyph advance (design units).
    private int hvarDelta(uint glyph)
    {
        uint outerIndex;
        uint innerIndex;
        if (_hvarWidthMap.innerIndex.length > 0)
        {
            uint idx = glyph;
            if (idx >= _hvarWidthMap.innerIndex.length)
                idx = cast(uint) (_hvarWidthMap.innerIndex.length - 1);
            outerIndex = _hvarWidthMap.outerIndex[idx];
            innerIndex = _hvarWidthMap.innerIndex[idx];
        }
        else
        {
            outerIndex = 0;
            innerIndex = glyph;
        }
        return getItemDelta(_hvarStore, outerIndex, innerIndex);
    }

    private int getItemDelta(VariationStore store, uint outerIndex, uint innerIndex)
    {
        if (outerIndex == 0xFFFF && innerIndex == 0xFFFF) return 0;
        if (outerIndex >= store.varData.length) return 0;
        const varData = store.varData[outerIndex];
        if (innerIndex >= varData.itemCount) return 0;
        if (varData.regionIndices.length == 0) return 0;

        const perRegionSize = (cast(uint) varData.wordDeltaCount +
            cast(uint) varData.regionIndices.length) * (varData.longWords ? 2 : 1);
        size_t bytes = 0;
        foreach (i; 0 .. innerIndex)
            bytes += perRegionSize;

        long accumulator;
        foreach (master; 0 .. varData.regionIndices.length)
        {
            const regionIndex = varData.regionIndices[master];
            const scalar = regionScalar(store, regionIndex);
            if (scalar != 0)
            {
                long delta;
                if (varData.longWords)
                {
                    if (master < varData.wordDeltaCount)
                        delta = readS32(varData.deltaSet, bytes);
                    else
                        delta = readS16(varData.deltaSet, bytes);
                }
                else
                {
                    if (master < varData.wordDeltaCount)
                        delta = readS16(varData.deltaSet, bytes);
                    else
                        delta = readS8(varData.deltaSet, bytes);
                }
                accumulator += delta * scalar;
            }
            else
            {
                bytes += (varData.longWords ? 2 : 1) << (master < varData.wordDeltaCount ? 1 : 0);
            }
        }
        return cast(int) ((accumulator + 0x8000) >> 16);
    }

    private long regionScalar(VariationStore store, uint regionIndex)
    {
        if (regionIndex >= store.regions.length) return 0;
        const region = store.regions[regionIndex];
        long scalar = 0x10000;
        foreach (axis; 0 .. store.axisCount)
        {
            const ncv = _normalized[axis];
            const peak = region.peakCoord[axis];
            if (peak == ncv || peak == 0) continue;
            const start = region.startCoord[axis];
            const end = region.endCoord[axis];
            if (ncv <= start || ncv >= end) { scalar = 0; break; }
            else if (ncv < peak)
                scalar = mulDiv(scalar, ncv - start, peak - start);
            else
                scalar = mulDiv(scalar, end - ncv, end - peak);
        }
        return scalar;
    }

    // ------------------------------------------------------------------
    // Table parsers
    // ------------------------------------------------------------------

    private const(ubyte)[] table(uint tableTag, ref size_t absOffset)
    {
        if (_data.length < 12) return null;
        const count = be16(_data, _faceOffset + 4);
        size_t cursor = _faceOffset + 12;
        foreach (_; 0 .. count)
        {
            if (cursor + 16 > _data.length) break;
            const name = be32(_data, cursor);
            if (name == tableTag)
            {
                const offset = cast(size_t) be32(_data, cursor + 8);
                const length = cast(size_t) be32(_data, cursor + 12);
                absOffset = offset;
                if (offset + length <= _data.length)
                    return _data[offset .. offset + length];
                return null;
            }
            cursor += 16;
        }
        return null;
    }

    private const(ubyte)[] table(uint tableTag)
    {
        size_t unused;
        return table(tableTag, unused);
    }

    private void parseFvar()
    {
        const fvar = table(tag!"fvar");
        if (fvar is null || fvar.length < 16) return;
        const tableVersion = be32(fvar, 0);
        if (tableVersion != 0x00010000) return;
        const offsetToData = be16(fvar, 4);
        const axisCount = be16(fvar, 8);
        const axisSize = be16(fvar, 10);
        if (axisCount == 0 || axisCount > 64) return;
        if (axisSize < 20) return;
        _axisCount = cast(ushort) axisCount;
        size_t cursor = offsetToData;
        foreach (axis; 0 .. axisCount)
        {
            if (cursor + 20 > fvar.length) return;
            VariationAxis info;
            info.axisTag = be32(fvar, cursor);
            info.minValue = beS32(fvar, cursor + 4);
            info.defaultValue = beS32(fvar, cursor + 8);
            info.maxValue = beS32(fvar, cursor + 12);
            info.flags = be16(fvar, cursor + 16);
            info.nameId = be16(fvar, cursor + 18);
            if (info.minValue > info.defaultValue || info.defaultValue > info.maxValue)
            {
                info.minValue = info.defaultValue;
                info.maxValue = info.defaultValue;
            }
            _axes ~= info;
            cursor += axisSize;
        }
    }

    private void parseAvar()
    {
        const avar = table(tag!"avar");
        if (avar is null || avar.length < 8) return;
        const tableVersion = be32(avar, 0);
        if (tableVersion != 0x00010000) return;
        const axisCount = be32(avar, 4);
        if (cast(ushort) axisCount != _axisCount) return;
        _hasAvar = true;
        size_t cursor = 8;
        foreach (axis; 0 .. _axisCount)
        {
            if (cursor + 2 > avar.length) return;
            const pairCount = be16(avar, cursor);
            cursor += 2;
            int[] from;
            int[] to;
            foreach (pair; 0 .. pairCount)
            {
                if (cursor + 4 > avar.length) return;
                from ~= cast(int) (cast(long) beS16(avar, cursor) << 2);
                to ~= cast(int) (cast(long) beS16(avar, cursor + 2) << 2);
                cursor += 4;
            }
            _avarFrom ~= from;
            _avarTo ~= to;
        }
    }

    private void parseGvar()
    {
        size_t absOffset;
        const gvar = table(tag!"gvar", absOffset);
        if (gvar is null || gvar.length < 20) return;
        _gvarBase = absOffset;
        const tableVersion = be32(gvar, 0);
        if (tableVersion != 0x00010000) return;
        const axisCount = be16(gvar, 4);
        if (cast(ushort) axisCount != _axisCount) return;
        _sharedTupleCount = be16(gvar, 6);
        const offsetToCoord = be32(gvar, 8);
        const glyphCount = be16(gvar, 12);
        const flags = be16(gvar, 14);
        const offsetToData = be32(gvar, 16);

        // Shared tuples.
        const sharedTuples = offsetToCoord < gvar.length ?
            gvar[offsetToCoord .. gvar.length] : null;
        _sharedTuples.length = cast(size_t) _sharedTupleCount * _axisCount;
        foreach (i; 0 .. cast(size_t) _sharedTupleCount * _axisCount)
        {
            if (i * 2 + 2 > (sharedTuples is null ? 0 : sharedTuples.length))
            {
                _sharedTuples.length = i;
                break;
            }
            _sharedTuples[i] = cast(long) beS16(sharedTuples, i * 2) << 2;
        }

        // Glyph offsets: the array of glyphCount+1 offsets sits immediately
        // after the 20-byte header. Each entry is relative to the start of
        // the glyphVariationDataArray, so absolute (from gvar start) =
        // offsetToData + entry.
        const offsets32 = (flags & 1) != 0;
        const offsetCount = cast(size_t) glyphCount + 1;
        _glyphOffsets.length = offsetCount;
        size_t cursor = 20;
        foreach (i; 0 .. offsetCount)
        {
            uint relative;
            if (offsets32)
            {
                if (cursor + 4 > gvar.length) break;
                relative = be32(gvar, cursor);
                cursor += 4;
            }
            else
            {
                if (cursor + 2 > gvar.length) break;
                relative = cast(uint) be16(gvar, cursor) * 2;
                cursor += 2;
            }
            _glyphOffsets[i] = offsetToData + relative;
        }
        _hasGvar = _glyphOffsets.length >= 2;
    }

    private void parseHvar()
    {
        const hvar = table(tag!"HVAR");
        if (hvar is null || hvar.length < 12) return;
        const major = be16(hvar, 0);
        if (major != 1) return;
        const storeOffset = be32(hvar, 4);
        const widthMapOffset = be32(hvar, 8);
        if (storeOffset >= hvar.length) return;

        _hvarStore = parseItemStore(hvar, storeOffset);
        if (widthMapOffset < hvar.length)
            _hvarWidthMap = parseDeltaSetIdxMap(hvar, widthMapOffset, _hvarStore);
        _hasHvar = true;
    }

    private VariationStore parseItemStore(const(ubyte)[] base, size_t offset)
    {
        VariationStore store;
        if (offset + 8 > base.length) return store;
        const format = be16(base, offset);
        if (format != 1) return store;
        const regionListOffset = be32(base, offset + 2);
        const dataCount = be16(base, offset + 6);
        if (dataCount == 0) return store;

        size_t cursor = offset + 8;
        uint[] dataOffsets;
        foreach (i; 0 .. dataCount)
        {
            if (cursor + 4 > base.length) return store;
            dataOffsets ~= be32(base, cursor);
            cursor += 4;
        }

        // Region list.
        const regionStart = offset + regionListOffset;
        if (regionStart + 4 > base.length) return store;
        store.axisCount = be16(base, regionStart);
        const regionCount = be16(base, regionStart + 2);
        size_t rcursor = regionStart + 4;
        foreach (region; 0 .. regionCount)
        {
            Region r;
            r.startCoord.length = store.axisCount;
            r.peakCoord.length = store.axisCount;
            r.endCoord.length = store.axisCount;
            foreach (axis; 0 .. store.axisCount)
            {
                if (rcursor + 6 > base.length) return store;
                int start = beS16(base, rcursor);
                int peak = beS16(base, rcursor + 2);
                int end = beS16(base, rcursor + 4);
                if ((start < 0 && end > 0) || start > peak || peak > end)
                    peak = 0;
                r.startCoord[axis] = cast(long) start << 2;
                r.peakCoord[axis] = cast(long) peak << 2;
                r.endCoord[axis] = cast(long) end << 2;
                rcursor += 6;
            }
            store.regions ~= r;
        }

        // varData items.
        foreach (i; 0 .. dataCount)
        {
            const dataStart = offset + dataOffsets[i];
            if (dataStart + 6 > base.length) return store;
            ItemVarData varData;
            varData.itemCount = be16(base, dataStart);
            varData.wordDeltaCount = be16(base, dataStart + 2);
            varData.longWords = (varData.wordDeltaCount & 0x8000) != 0;
            varData.wordDeltaCount &= 0x7FFF;
            const regionIdxCount = be16(base, dataStart + 4);
            if (regionIdxCount > store.regions.length) return store;
            size_t vcursor = dataStart + 6;
            foreach (j; 0 .. regionIdxCount)
            {
                if (vcursor + 2 > base.length) return store;
                varData.regionIndices ~= be16(base, vcursor);
                vcursor += 2;
            }
            const perRegionSize = (cast(size_t) varData.wordDeltaCount +
                cast(size_t) regionIdxCount) * (varData.longWords ? 2 : 1);
            const deltaCount = cast(size_t) varData.itemCount * perRegionSize;
            if (vcursor + deltaCount > base.length) return store;
            varData.deltaSet = base[vcursor .. vcursor + deltaCount];
            store.varData ~= varData;
        }
        return store;
    }

    private DeltaSetIdxMap parseDeltaSetIdxMap(const(ubyte)[] base,
        size_t offset, VariationStore store)
    {
        DeltaSetIdxMap map;
        if (offset + 2 > base.length) return map;
        const format = base[offset];
        const entryFormat = base[offset + 1];
        if (format > 1) return map;
        const entrySize = ((entryFormat >> 4) & 0x3) + 1;
        const innerBitCount = (entryFormat & 0x0F) + 1;
        const innerMask = (1u << innerBitCount) - 1;

        uint mapCount;
        size_t cursor = offset + 2;
        if (format == 0)
        {
            if (cursor + 2 > base.length) return map;
            mapCount = be16(base, cursor);
            cursor += 2;
        }
        else
        {
            if (cursor + 4 > base.length) return map;
            mapCount = be32(base, cursor);
            cursor += 4;
        }

        foreach (i; 0 .. mapCount)
        {
            uint mapData = 0;
            foreach (j; 0 .. entrySize)
            {
                if (cursor + 1 > base.length) return map;
                mapData = (mapData << 8) | base[cursor];
                cursor += 1;
            }
            if (mapData == 0xFFFFFFFF)
            {
                map.outerIndex ~= 0xFFFF;
                map.innerIndex ~= 0xFFFF;
                continue;
            }
            const outerIndex = mapData >> innerBitCount;
            const innerIndex = mapData & innerMask;
            map.outerIndex ~= cast(ushort) outerIndex;
            map.innerIndex ~= cast(ushort) innerIndex;
        }
        return map;
    }

    // ------------------------------------------------------------------
    // Packed data readers
    // ------------------------------------------------------------------

    private bool lastPackedWasAllPoints;

    private int[] readPackedPoints(const(ubyte)[] data, ref size_t cursor)
    {
        lastPackedWasAllPoints = false;
        if (cursor >= data.length) return null;
        const first = data[cursor];
        cursor++;
        if (first == 0)
        {
            lastPackedWasAllPoints = true;
            return null;
        }
        uint count;
        if ((first & 0x80) != 0)
        {
            count = (cast(uint) (first & 0x7F) << 8);
            if (cursor >= data.length) return null;
            count |= data[cursor];
            cursor++;
        }
        else
            count = first;

        int[] points;
        points.reserve(count);
        int point = 0;
        while (points.length < count)
        {
            if (cursor >= data.length) return null;
            const runcnt = data[cursor];
            cursor++;
            const runCount = (runcnt & 0x7F) + 1;
            const words = (runcnt & 0x80) != 0;
            foreach (_; 0 .. runCount)
            {
                if (words)
                {
                    if (cursor + 2 > data.length) return null;
                    point += be16(data, cursor);
                    cursor += 2;
                }
                else
                {
                    if (cursor >= data.length) return null;
                    point += data[cursor];
                    cursor++;
                }
                points ~= point;
                if (points.length >= count) break;
            }
        }
        return points;
    }

    private long[] readPackedDeltas(const(ubyte)[] data, ref size_t cursor, uint count)
    {
        long[] deltas;
        deltas.length = count;
        uint read;
        while (read < count)
        {
            if (cursor >= data.length) return deltas;
            const runcnt = data[cursor];
            cursor++;
            const runCount = (runcnt & 0x3F) + 1;
            const zero = (runcnt & 0x80) != 0;
            const words = (runcnt & 0x40) != 0;
            foreach (_; 0 .. runCount)
            {
                if (read >= count) break;
                if (zero)
                    deltas[read] = 0;
                else if (words)
                {
                    if (cursor + 2 > data.length) return deltas;
                    deltas[read] = cast(long) beS16(data, cursor) << 16;
                    cursor += 2;
                }
                else
                {
                    if (cursor >= data.length) return deltas;
                    deltas[read] = cast(long) (cast(byte) data[cursor]) << 16;
                    cursor++;
                }
                read++;
            }
        }
        return deltas;
    }

    private int readS16(const(ubyte)[] data, size_t offset)
    {
        if (offset + 2 > data.length) return 0;
        return beS16(data, offset);
    }

    private int readS8(const(ubyte)[] data, size_t offset)
    {
        if (offset >= data.length) return 0;
        return cast(byte) data[offset];
    }

    private int readS32(const(ubyte)[] data, size_t offset)
    {
        if (offset + 4 > data.length) return 0;
        return beS32(data, offset);
    }

    // ------------------------------------------------------------------
    // Coordinate normalization
    // ------------------------------------------------------------------

    private void computeNormalized()
    {
        if (_axes.length == 0) return;
        long[] norm;
        norm.length = _axes.length;
        foreach (i; 0 .. _axes.length)
        {
            const axis = _axes[i];
            const coord = _design[i];
            const def = axis.defaultValue;
            const min = axis.minValue;
            const max = axis.maxValue;
            long value;
            if (coord > def)
                value = coord >= max ? 0x10000 : divFix(coord - def, max - def);
            else if (coord < def)
                value = coord <= min ? -0x10000 : divFix(coord - def, def - min);
            else
                value = 0;
            norm[i] = value;
        }

        // avar segment mapping.
        if (_hasAvar)
        {
            foreach (i; 0 .. _axes.length)
            {
                const from = _avarFrom[i];
                const to = _avarTo[i];
                if (from.length == 0) continue;
                size_t segment = 0;
                foreach (j; 1 .. from.length)
                {
                    if (norm[i] < from[j])
                    {
                        segment = j;
                        break;
                    }
                }
                if (segment == 0) continue;
                const from0 = from[segment - 1];
                const from1 = from[segment];
                const to0 = to[segment - 1];
                const to1 = to[segment];
                if (from1 != from0)
                    norm[i] = mulDiv(norm[i] - from0, to1 - to0, from1 - from0) + to0;
                else
                    norm[i] = to0;
            }
        }

        _normalized = norm;
    }

    // ------------------------------------------------------------------
    // IUP-like interpolation of deltas between reference points.
    // ------------------------------------------------------------------

    private static void interpolateDeltas(const(int)[] org, long[] deltas, int[] points)
    {
        // Build the set of points with deltas, then interpolate the deltas of
        // points between consecutive reference points along each contour. The
        // gvar deltas use the ORIGINAL (pre-delta) coordinates as the parameter
        // space, matching FreeType's tt_interpolate_deltas.
        import std.algorithm : sort;
        auto refs = points.dup;
        refs.sort();
        if (refs.length == 0) return;

        const n = org.length;
        // We interpolate per full glyph using the sorted reference list; the
        // contour boundaries are not strictly needed for a close approximation
        // because interpolation is local between consecutive references.
        foreach (pair; 0 .. refs.length - 1)
        {
            const ref1 = refs[pair];
            const ref2 = refs[pair + 1];
            const d1 = deltas[ref1];
            const d2 = deltas[ref2];
            const o1 = org[ref1];
            const o2 = org[ref2];
            foreach (i; ref1 + 1 .. ref2)
            {
                if (o2 == o1)
                    deltas[i] = d1;
                else
                    deltas[i] = mulDiv(d2 - d1, org[i] - o1, o2 - o1) + d1;
            }
        }
        // Outside the first/last reference: shift by the nearest delta.
        const first = refs[0];
        const last = refs[$ - 1];
        foreach (i; 0 .. first)
            deltas[i] = deltas[first];
        foreach (i; last + 1 .. n)
            deltas[i] = deltas[last];
    }
}

unittest
{
    // The module must tolerate a font with no variation tables.
    auto v = new FontVariations(cast(immutable(ubyte)[]) [], 0);
    assert(!v.hasVariations());
    assert(v.axes().length == 0);
}

unittest
{
    // If a real variable font is present, verify the axes parse and that
    // changing a coordinate produces nonzero normalized values.
    import std.file : exists;
    const paths = [
        "tests/fonts/InterVariable.ttf",
        "vendor/aurora-d-0.4.5/tests/fonts/InterVariable.ttf",
        "../../tests/fonts/InterVariable.ttf"
    ];
    string found;
    foreach (p; paths)
        if (exists(p)) { found = p; break; }
    if (found.length == 0) return;

    import std.file : read;
    auto bytes = cast(immutable(ubyte)[]) read(found);
    auto v = new FontVariations(bytes, 0);
    if (!v.hasVariations()) return;
    assert(v.axes().length >= 1, "variable font exposes its axes");

    // Find the weight axis if present and test normalization.
    bool foundWeight;
    foreach (i, axis; v.axes())
    {
        if (axis.axisTag == 0x77676874) // 'wght'
        {
            foundWeight = true;
            long[] coords;
            coords.length = v.axes().length;
            foreach (j, a; v.axes()) coords[j] = a.defaultValue;
            coords[i] = axis.maxValue;
            assert(v.setDesignCoords(coords), "changing weight reports a change");
            const normalized = v.normalizedCoords();
            assert(normalized[i] > 0, "weight above default normalizes positive");
            break;
        }
    }
    assert(foundWeight, "InterVariable exposes a wght axis");
}
