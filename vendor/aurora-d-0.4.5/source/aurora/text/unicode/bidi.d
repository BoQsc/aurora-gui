module aurora.text.unicode.bidi;

/** Unicode 17.0 Bidirectional Algorithm through rule L2 (UAX #9). */

import aurora.text.unicode.properties : BidiBracketType, BidiClass,
    bidiBracket, bidiClass;
import std.algorithm.mutation : reverse;
import std.algorithm.sorting : sort;

private enum RemovedLevel = ubyte.max;
private enum MaxExplicitDepth = 125;

enum ParagraphDirection : ubyte
{
    automatic,
    leftToRight,
    rightToLeft
}

struct BidiVisualRun
{
    size_t visualStart;
    size_t visualEnd;
    ubyte level;

    bool rightToLeft() const @safe pure nothrow @nogc
    {
        return (level & 1) != 0;
    }
}

struct BidiResult
{
    ubyte paragraphLevel;
    ubyte[] levels;
    BidiClass[] resolvedTypes;
    size_t[] visualOrder;
    size_t[] logicalToVisual;
    BidiVisualRun[] visualRuns;

    bool removed(size_t logicalIndex) const @safe pure nothrow @nogc
    {
        return logicalIndex >= levels.length || levels[logicalIndex] == RemovedLevel;
    }
}

/** Resolve one paragraph. Paragraph separators should be split by the caller. */
BidiResult resolveBidi(const(dchar)[] text,
    ParagraphDirection direction = ParagraphDirection.automatic)
{
    BidiResult result;
    result.levels.length = text.length;
    result.resolvedTypes.length = text.length;
    result.logicalToVisual.length = text.length;
    result.logicalToVisual[] = size_t.max;
    if (text.length == 0)
    {
        result.paragraphLevel = direction == ParagraphDirection.rightToLeft ? 1 : 0;
        return result;
    }

    auto original = new BidiClass[text.length];
    foreach (i, ch; text)
        original[i] = bidiClass(ch);
    result.resolvedTypes[] = original[];

    auto matchingPdi = computeMatchingPdi(original);
    result.paragraphLevel = paragraphLevel(original, matchingPdi, 0,
        original.length, direction);

    auto removed = new bool[text.length];
    applyExplicitLevels(original, matchingPdi, result.paragraphLevel,
        result.resolvedTypes, result.levels, removed);

    // X10 boundary directions and level-run construction use the explicit
    // embedding levels. I1/I2 must not change the sos/eos of a later run.
    auto explicitLevels = result.levels.dup;
    auto active = buildActiveIndices(removed);
    if (active.length > 0)
    {
        auto runs = buildLevelRuns(active, explicitLevels);
        auto runForLogical = new size_t[text.length];
        runForLogical[] = size_t.max;
        foreach (runIndex, run; runs)
            foreach (activePos; run.start .. run.end)
                runForLogical[active[activePos]] = runIndex;

        auto sequences = buildIsolatingRunSequences(original, matchingPdi,
            active, runs, runForLogical);
        // X10 sequence boundaries and N2 use the embedding levels produced by
        // the explicit phase. Resolving an earlier isolating run sequence must
        // not change the sos/eos calculation of a later sequence.
        const embeddingLevels = result.levels.dup;
        auto activePosition = new size_t[text.length];
        activePosition[] = size_t.max;
        foreach (position, logical; active)
            activePosition[logical] = position;

        foreach (sequence; sequences)
        {
            auto indices = flattenSequence(sequence, runs, active);
            if (indices.length == 0) continue;
            const sos = sequenceBoundaryType(indices[0], true, original,
                matchingPdi, embeddingLevels, active, activePosition,
                result.paragraphLevel);
            const eos = sequenceBoundaryType(indices[$ - 1], false, original,
                matchingPdi, embeddingLevels, active, activePosition,
                result.paragraphLevel);
            resolveWeakTypes(indices, sos, result.resolvedTypes);
            resolveNeutralTypes(text, original, indices, sos, eos,
                embeddingLevels, result.resolvedTypes);
            resolveImplicitLevels(indices, result.resolvedTypes, result.levels);
        }
    }

    foreach (i, isRemoved; removed)
        if (isRemoved)
            result.levels[i] = RemovedLevel;

    applyL1(original, removed, result.paragraphLevel, result.levels);
    result.visualOrder = reorderL2(result.levels);
    foreach (visual, logical; result.visualOrder)
        result.logicalToVisual[logical] = visual;
    result.visualRuns = makeVisualRuns(result.visualOrder, result.levels);
    return result;
}

private size_t[] computeMatchingPdi(const(BidiClass)[] types)
{
    size_t[] result;
    result.length = types.length;
    result[] = size_t.max;
    size_t[] stack;
    foreach (i, value; types)
    {
        if (isIsolateInitiator(value))
            stack ~= i;
        else if (value == BidiClass.pdi && stack.length > 0)
        {
            const opening = stack[$ - 1];
            stack.length = stack.length - 1;
            result[opening] = i;
            result[i] = opening;
        }
    }
    return result;
}

private ubyte paragraphLevel(const(BidiClass)[] types,
    const(size_t)[] matchingPdi, size_t start, size_t end,
    ParagraphDirection requested) @safe pure nothrow @nogc
{
    if (requested == ParagraphDirection.leftToRight) return 0;
    if (requested == ParagraphDirection.rightToLeft) return 1;

    size_t i = start;
    while (i < end)
    {
        const value = types[i];
        if (isIsolateInitiator(value))
        {
            const match = matchingPdi[i];
            if (match != size_t.max && match < end)
                i = match + 1;
            else
                break;
            continue;
        }
        if (value == BidiClass.l) return 0;
        if (value == BidiClass.r || value == BidiClass.al) return 1;
        ++i;
    }
    return 0;
}

private enum OverrideStatus : ubyte
{
    neutral,
    leftToRight,
    rightToLeft
}

private struct DirectionalStatus
{
    ubyte level;
    OverrideStatus overrideStatus;
    bool isolate;
}

private void applyExplicitLevels(const(BidiClass)[] original,
    const(size_t)[] matchingPdi, ubyte paragraph,
    BidiClass[] types, ubyte[] levels, bool[] removed)
{
    DirectionalStatus[] stack;
    stack ~= DirectionalStatus(paragraph, OverrideStatus.neutral, false);
    int overflowIsolateCount;
    int overflowEmbeddingCount;
    int validIsolateCount;

    foreach (i, originalType; original)
    {
        if (originalType == BidiClass.b)
        {
            levels[i] = paragraph;
            continue;
        }
        auto top = stack[$ - 1];
        levels[i] = top.level;

        switch (originalType)
        {
            case BidiClass.rle:
                pushEmbedding(nextOdd(top.level), OverrideStatus.neutral, false,
                    stack, overflowIsolateCount, overflowEmbeddingCount,
                    validIsolateCount);
                removed[i] = true;
                break;
            case BidiClass.lre:
                pushEmbedding(nextEven(top.level), OverrideStatus.neutral, false,
                    stack, overflowIsolateCount, overflowEmbeddingCount,
                    validIsolateCount);
                removed[i] = true;
                break;
            case BidiClass.rlo:
                pushEmbedding(nextOdd(top.level), OverrideStatus.rightToLeft, false,
                    stack, overflowIsolateCount, overflowEmbeddingCount,
                    validIsolateCount);
                removed[i] = true;
                break;
            case BidiClass.lro:
                pushEmbedding(nextEven(top.level), OverrideStatus.leftToRight, false,
                    stack, overflowIsolateCount, overflowEmbeddingCount,
                    validIsolateCount);
                removed[i] = true;
                break;
            case BidiClass.rli:
            case BidiClass.lri:
            case BidiClass.fsi:
            {
                applyOverride(types[i], top.overrideStatus);
                bool rtl = originalType == BidiClass.rli;
                if (originalType == BidiClass.fsi)
                {
                    const end = matchingPdi[i] == size_t.max ? original.length : matchingPdi[i];
                    rtl = paragraphLevel(original, matchingPdi, i + 1, end,
                        ParagraphDirection.automatic) == 1;
                }
                const newLevel = rtl ? nextOdd(top.level) : nextEven(top.level);
                if (newLevel <= MaxExplicitDepth && overflowIsolateCount == 0 &&
                    overflowEmbeddingCount == 0)
                {
                    ++validIsolateCount;
                    stack ~= DirectionalStatus(cast(ubyte) newLevel,
                        OverrideStatus.neutral, true);
                }
                else
                    ++overflowIsolateCount;
                break;
            }
            case BidiClass.pdi:
                if (overflowIsolateCount > 0)
                    --overflowIsolateCount;
                else if (validIsolateCount > 0)
                {
                    overflowEmbeddingCount = 0;
                    while (stack.length > 1 && !stack[$ - 1].isolate)
                        stack.length = stack.length - 1;
                    if (stack.length > 1)
                    {
                        stack.length = stack.length - 1;
                        --validIsolateCount;
                    }
                }
                top = stack[$ - 1];
                levels[i] = top.level;
                applyOverride(types[i], top.overrideStatus);
                break;
            case BidiClass.pdf:
                if (overflowIsolateCount > 0)
                {
                    // Ignored within an overflow isolate.
                }
                else if (overflowEmbeddingCount > 0)
                    --overflowEmbeddingCount;
                else if (stack.length > 1 && !stack[$ - 1].isolate)
                    stack.length = stack.length - 1;
                removed[i] = true;
                break;
            case BidiClass.bn:
                removed[i] = true;
                break;
            case BidiClass.b:
                break;
            default:
                applyOverride(types[i], top.overrideStatus);
                break;
        }
    }
}

private void pushEmbedding(int newLevel, OverrideStatus overrideStatus,
    bool isolate, ref DirectionalStatus[] stack,
    ref int overflowIsolateCount, ref int overflowEmbeddingCount,
    ref int validIsolateCount)
{
    if (newLevel <= MaxExplicitDepth && overflowIsolateCount == 0 &&
        overflowEmbeddingCount == 0)
        stack ~= DirectionalStatus(cast(ubyte) newLevel, overrideStatus, isolate);
    else if (overflowIsolateCount == 0)
        ++overflowEmbeddingCount;
}

private int nextOdd(int level) @safe pure nothrow @nogc
{
    return (level & 1) == 0 ? level + 1 : level + 2;
}

private int nextEven(int level) @safe pure nothrow @nogc
{
    return (level & 1) == 0 ? level + 2 : level + 1;
}

private void applyOverride(ref BidiClass value, OverrideStatus status)
    @safe pure nothrow @nogc
{
    if (status == OverrideStatus.leftToRight) value = BidiClass.l;
    else if (status == OverrideStatus.rightToLeft) value = BidiClass.r;
}

private size_t[] buildActiveIndices(const(bool)[] removed)
{
    size_t[] result;
    result.reserve(removed.length);
    foreach (i, value; removed)
        if (!value) result ~= i;
    return result;
}

private struct LevelRun
{
    size_t start;
    size_t end;
}

private LevelRun[] buildLevelRuns(const(size_t)[] active, const(ubyte)[] levels)
{
    LevelRun[] result;
    if (active.length == 0) return result;
    size_t start;
    ubyte current = levels[active[0]];
    foreach (position; 1 .. active.length)
    {
        const next = levels[active[position]];
        if (next != current)
        {
            result ~= LevelRun(start, position);
            start = position;
            current = next;
        }
    }
    result ~= LevelRun(start, active.length);
    return result;
}

private size_t[][] buildIsolatingRunSequences(const(BidiClass)[] original,
    const(size_t)[] matchingPdi, const(size_t)[] active,
    const(LevelRun)[] runs, const(size_t)[] runForLogical)
{
    size_t[][] result;
    bool[] visited;
    visited.length = runs.length;
    foreach (runIndex, run; runs)
    {
        if (visited[runIndex]) continue;
        const first = active[run.start];
        if (original[first] == BidiClass.pdi && matchingPdi[first] != size_t.max)
            continue;

        size_t[] sequence;
        size_t current = runIndex;
        while (current != size_t.max && !visited[current])
        {
            visited[current] = true;
            sequence ~= current;
            const last = active[runs[current].end - 1];
            if (!isIsolateInitiator(original[last]) || matchingPdi[last] == size_t.max)
                break;
            current = runForLogical[matchingPdi[last]];
        }
        result ~= sequence;
    }

    // Defensive coverage for malformed/overflow sequences.
    foreach (runIndex; 0 .. runs.length)
        if (!visited[runIndex])
            result ~= [runIndex];
    return result;
}

private size_t[] flattenSequence(const(size_t)[] sequence,
    const(LevelRun)[] runs, const(size_t)[] active)
{
    size_t[] result;
    foreach (runIndex; sequence)
        result ~= active[runs[runIndex].start .. runs[runIndex].end];
    return result;
}

private BidiClass sequenceBoundaryType(size_t logical, bool start,
    const(BidiClass)[] original, const(size_t)[] matchingPdi,
    const(ubyte)[] levels, const(size_t)[] active,
    const(size_t)[] activePosition, ubyte paragraph) @safe pure nothrow @nogc
{
    const position = activePosition[logical];
    int neighborLevel = paragraph;
    if (start)
    {
        if (position != size_t.max && position > 0)
            neighborLevel = levels[active[position - 1]];
    }
    else
    {
        const unmatchedIsolate = isIsolateInitiator(original[logical]) &&
            matchingPdi[logical] == size_t.max;
        if (!unmatchedIsolate && position != size_t.max && position + 1 < active.length)
            neighborLevel = levels[active[position + 1]];
    }
    const higher = levels[logical] > neighborLevel ? levels[logical] : neighborLevel;
    return (higher & 1) != 0 ? BidiClass.r : BidiClass.l;
}

private void resolveWeakTypes(const(size_t)[] sequence, BidiClass sos,
    BidiClass[] types)
{
    // W1.
    BidiClass previous = sos;
    foreach (logical; sequence)
    {
        if (types[logical] == BidiClass.nsm)
            types[logical] = isIsolateInitiator(previous) || previous == BidiClass.pdi ?
                BidiClass.on : previous;
        previous = types[logical];
    }

    // W2.
    BidiClass lastStrong = sos;
    foreach (logical; sequence)
    {
        if (types[logical] == BidiClass.en && lastStrong == BidiClass.al)
            types[logical] = BidiClass.an;
        if (types[logical] == BidiClass.r || types[logical] == BidiClass.l ||
            types[logical] == BidiClass.al)
            lastStrong = types[logical];
    }

    // W3.
    foreach (logical; sequence)
        if (types[logical] == BidiClass.al)
            types[logical] = BidiClass.r;

    // W4.
    if (sequence.length >= 3)
    {
        foreach (position; 1 .. sequence.length - 1)
        {
            const before = types[sequence[position - 1]];
            const after = types[sequence[position + 1]];
            auto current = types[sequence[position]];
            if (current == BidiClass.es && before == BidiClass.en && after == BidiClass.en)
                types[sequence[position]] = BidiClass.en;
            else if (current == BidiClass.cs && before == after &&
                (before == BidiClass.en || before == BidiClass.an))
                types[sequence[position]] = before;
        }
    }

    // W5.
    size_t cursor;
    while (cursor < sequence.length)
    {
        if (types[sequence[cursor]] != BidiClass.et)
        {
            ++cursor;
            continue;
        }
        const start = cursor;
        while (cursor < sequence.length && types[sequence[cursor]] == BidiClass.et)
            ++cursor;
        const beforeEn = start > 0 && types[sequence[start - 1]] == BidiClass.en;
        const afterEn = cursor < sequence.length && types[sequence[cursor]] == BidiClass.en;
        if (beforeEn || afterEn)
            foreach (position; start .. cursor)
                types[sequence[position]] = BidiClass.en;
    }

    // W6.
    foreach (logical; sequence)
        if (types[logical] == BidiClass.es || types[logical] == BidiClass.et ||
            types[logical] == BidiClass.cs)
            types[logical] = BidiClass.on;

    // W7.
    lastStrong = sos;
    foreach (logical; sequence)
    {
        if (types[logical] == BidiClass.en && lastStrong == BidiClass.l)
            types[logical] = BidiClass.l;
        if (types[logical] == BidiClass.r || types[logical] == BidiClass.l)
            lastStrong = types[logical];
    }
}

private struct BracketPairPosition
{
    size_t openPosition;
    size_t closePosition;
}

private struct BracketStackEntry
{
    dchar expectedClose;
    size_t position;
}

private void resolveNeutralTypes(const(dchar)[] text,
    const(BidiClass)[] original, const(size_t)[] sequence,
    BidiClass sos, BidiClass eos, const(ubyte)[] levels,
    BidiClass[] types)
{
    resolveBrackets(text, original, sequence, sos, levels, types);

    // N1/N2.
    BidiClass previousStrong = sos;
    size_t cursor;
    while (cursor < sequence.length)
    {
        const currentDirection = strongDirection(types[sequence[cursor]]);
        if (currentDirection != BidiClass.on)
        {
            previousStrong = currentDirection;
            ++cursor;
            continue;
        }
        if (!isNeutralOrIsolate(types[sequence[cursor]]))
        {
            ++cursor;
            continue;
        }

        const start = cursor;
        while (cursor < sequence.length &&
            isNeutralOrIsolate(types[sequence[cursor]]))
            ++cursor;
        BidiClass followingStrong = eos;
        for (size_t scan = cursor; scan < sequence.length; ++scan)
        {
            const direction = strongDirection(types[sequence[scan]]);
            if (direction != BidiClass.on)
            {
                followingStrong = direction;
                break;
            }
        }
        foreach (position; start .. cursor)
        {
            const logical = sequence[position];
            types[logical] = previousStrong == followingStrong ? previousStrong :
                ((levels[logical] & 1) != 0 ? BidiClass.r : BidiClass.l);
        }
    }
}

private void resolveBrackets(const(dchar)[] text,
    const(BidiClass)[] original, const(size_t)[] sequence,
    BidiClass sos, const(ubyte)[] levels, BidiClass[] types)
{
    BracketStackEntry[] stack;
    BracketPairPosition[] pairs;
    foreach (position, logical; sequence)
    {
        if (types[logical] != BidiClass.on) continue;
        const bracket = bidiBracket(text[logical]);
        if (bracket.kind == BidiBracketType.open)
        {
            if (stack.length >= 63)
            {
                pairs.length = 0;
                break;
            }
            stack ~= BracketStackEntry(canonicalBracket(bracket.pair), position);
        }
        else if (bracket.kind == BidiBracketType.close)
        {
            const closing = canonicalBracket(text[logical]);
            ptrdiff_t found = cast(ptrdiff_t) stack.length - 1;
            while (found >= 0 && stack[cast(size_t) found].expectedClose != closing)
                --found;
            if (found >= 0)
            {
                pairs ~= BracketPairPosition(stack[cast(size_t) found].position, position);
                stack.length = cast(size_t) found;
            }
        }
    }
    sort!((a, b) => a.openPosition < b.openPosition)(pairs);

    const embeddingDirection = (levels[sequence[0]] & 1) != 0 ?
        BidiClass.r : BidiClass.l;
    const opposite = embeddingDirection == BidiClass.l ? BidiClass.r : BidiClass.l;

    foreach (pair; pairs)
    {
        bool hasEmbedding;
        bool hasOpposite;
        foreach (position; pair.openPosition + 1 .. pair.closePosition)
        {
            const direction = strongDirection(types[sequence[position]]);
            if (direction == embeddingDirection) hasEmbedding = true;
            else if (direction == opposite) hasOpposite = true;
        }

        BidiClass resolved = BidiClass.on;
        if (hasEmbedding)
            resolved = embeddingDirection;
        else if (hasOpposite)
        {
            BidiClass before = sos;
            size_t scan = pair.openPosition;
            while (scan > 0)
            {
                --scan;
                const direction = strongDirection(types[sequence[scan]]);
                if (direction != BidiClass.on)
                {
                    before = direction;
                    break;
                }
            }
            resolved = before == opposite ? opposite : embeddingDirection;
        }

        if (resolved != BidiClass.on)
        {
            const openLogical = sequence[pair.openPosition];
            const closeLogical = sequence[pair.closePosition];
            types[openLogical] = resolved;
            types[closeLogical] = resolved;
            propagateBracketNsm(original, sequence, pair.openPosition, resolved, types);
            propagateBracketNsm(original, sequence, pair.closePosition, resolved, types);
        }
    }
}

private void propagateBracketNsm(const(BidiClass)[] original,
    const(size_t)[] sequence, size_t position, BidiClass resolved,
    BidiClass[] types)
{
    for (size_t scan = position + 1; scan < sequence.length; ++scan)
    {
        const logical = sequence[scan];
        if (original[logical] != BidiClass.nsm) break;
        types[logical] = resolved;
    }
}

private dchar canonicalBracket(dchar value) @safe pure nothrow @nogc
{
    return value == 0x232A ? cast(dchar) 0x3009 : value;
}

private BidiClass strongDirection(BidiClass value) @safe pure nothrow @nogc
{
    if (value == BidiClass.l) return BidiClass.l;
    if (value == BidiClass.r || value == BidiClass.en || value == BidiClass.an)
        return BidiClass.r;
    return BidiClass.on;
}

private bool isNeutralOrIsolate(BidiClass value) @safe pure nothrow @nogc
{
    return value == BidiClass.b || value == BidiClass.s ||
        value == BidiClass.ws || value == BidiClass.on ||
        value == BidiClass.fsi || value == BidiClass.lri ||
        value == BidiClass.rli || value == BidiClass.pdi;
}

private void resolveImplicitLevels(const(size_t)[] sequence,
    const(BidiClass)[] types, ubyte[] levels)
{
    foreach (logical; sequence)
    {
        if ((levels[logical] & 1) == 0)
        {
            if (types[logical] == BidiClass.r)
                levels[logical] += 1;
            else if (types[logical] == BidiClass.an || types[logical] == BidiClass.en)
                levels[logical] += 2;
        }
        else if (types[logical] == BidiClass.l || types[logical] == BidiClass.en ||
            types[logical] == BidiClass.an)
            levels[logical] += 1;
    }
}

private void applyL1(const(BidiClass)[] original, const(bool)[] removed,
    ubyte paragraph, ubyte[] levels)
{
    foreach (i, value; original)
    {
        if (removed[i]) continue;
        if (value == BidiClass.b || value == BidiClass.s)
        {
            levels[i] = paragraph;
            size_t cursor = i;
            while (cursor > 0)
            {
                --cursor;
                // X9 formatting characters are absent from the sequence for
                // L1; they must not interrupt the whitespace run.
                if (removed[cursor]) continue;
                if (!isL1Whitespace(original[cursor])) break;
                levels[cursor] = paragraph;
            }
        }
    }

    size_t cursor = original.length;
    while (cursor > 0)
    {
        --cursor;
        if (removed[cursor]) continue;
        if (!isL1Whitespace(original[cursor])) break;
        levels[cursor] = paragraph;
    }
}

private bool isL1Whitespace(BidiClass value) @safe pure nothrow @nogc
{
    return value == BidiClass.ws || value == BidiClass.fsi ||
        value == BidiClass.lri || value == BidiClass.rli ||
        value == BidiClass.pdi;
}

private size_t[] reorderL2(const(ubyte)[] levels)
{
    size_t[] order;
    ubyte highest;
    ubyte lowestOdd = ubyte.max;
    foreach (i, level; levels)
    {
        if (level == RemovedLevel) continue;
        order ~= i;
        if (level > highest) highest = level;
        if ((level & 1) != 0 && level < lowestOdd) lowestOdd = level;
    }
    if (lowestOdd == ubyte.max) return order;

    int current = highest;
    while (current >= lowestOdd)
    {
        size_t cursor;
        while (cursor < order.length)
        {
            while (cursor < order.length && levels[order[cursor]] < current)
                ++cursor;
            const start = cursor;
            while (cursor < order.length && levels[order[cursor]] >= current)
                ++cursor;
            if (cursor > start + 1)
                reverse(order[start .. cursor]);
        }
        --current;
    }
    return order;
}

private BidiVisualRun[] makeVisualRuns(const(size_t)[] order,
    const(ubyte)[] levels)
{
    BidiVisualRun[] result;
    if (order.length == 0) return result;
    size_t start;
    ubyte level = levels[order[0]];
    foreach (visual; 1 .. order.length)
    {
        if (levels[order[visual]] != level)
        {
            result ~= BidiVisualRun(start, visual, level);
            start = visual;
            level = levels[order[visual]];
        }
    }
    result ~= BidiVisualRun(start, order.length, level);
    return result;
}

private bool isIsolateInitiator(BidiClass value) @safe pure nothrow @nogc
{
    return value == BidiClass.lri || value == BidiClass.rli ||
        value == BidiClass.fsi;
}

unittest
{
    auto latin = resolveBidi("abc"d);
    assert(latin.paragraphLevel == 0);
    assert(latin.levels == [0, 0, 0]);
    assert(latin.visualOrder == [0UL, 1UL, 2UL]);

    auto hebrew = resolveBidi("\u05D0\u05D1\u05D2"d);
    assert(hebrew.paragraphLevel == 1);
    assert(hebrew.visualOrder == [2UL, 1UL, 0UL]);

    auto mixed = resolveBidi("abc \u05D0\u05D1\u05D2"d,
        ParagraphDirection.leftToRight);
    assert(mixed.visualOrder[$ - 3 .. $] == [6UL, 5UL, 4UL]);

    // Isolate contents do not determine the surrounding paragraph direction.
    auto isolated = resolveBidi("\u2067\u05D0\u2069A"d);
    assert(isolated.paragraphLevel == 0);
}
