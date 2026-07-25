module aurora.text.unicode.grapheme;

/** Unicode 17.0 extended grapheme-cluster segmentation (UAX #29). */

import aurora.text.unicode.properties : GraphemeBreak, IndicConjunctBreak,
    graphemeBreak, indicConjunctBreak, isExtendedPictographic;

/** Return every extended grapheme-cluster boundary, including 0 and length. */
size_t[] graphemeBoundaries(const(dchar)[] text)
{
    size_t[] result;
    result.reserve(text.length + 1);
    result ~= 0;
    foreach (i; 1 .. text.length)
        if (breakBefore(text, i))
            result ~= i;
    if (text.length > 0)
        result ~= text.length;
    return result;
}

/** Whether `index` is an extended grapheme-cluster boundary. */
bool isGraphemeBoundary(const(dchar)[] text, size_t index)
    @safe pure nothrow @nogc
{
    if (index == 0 || index >= text.length)
        return index <= text.length;
    return breakBefore(text, index);
}

/** Nearest boundary strictly before `index`, clamped to 0. */
size_t previousGraphemeBoundary(const(dchar)[] text, size_t index)
    @safe pure nothrow @nogc
{
    if (index > text.length) index = text.length;
    if (index == 0) return 0;
    --index;
    while (index > 0 && !breakBefore(text, index))
        --index;
    return index;
}

/** Nearest boundary strictly after `index`, clamped to text.length. */
size_t nextGraphemeBoundary(const(dchar)[] text, size_t index)
    @safe pure nothrow @nogc
{
    if (index >= text.length) return text.length;
    ++index;
    while (index < text.length && !breakBefore(text, index))
        ++index;
    return index;
}

/** Snap an arbitrary logical index to the preceding grapheme boundary. */
size_t floorGraphemeBoundary(const(dchar)[] text, size_t index)
    @safe pure nothrow @nogc
{
    if (index >= text.length) return text.length;
    while (index > 0 && !breakBefore(text, index))
        --index;
    return index;
}

/** Snap an arbitrary logical index to the following grapheme boundary. */
size_t ceilGraphemeBoundary(const(dchar)[] text, size_t index)
    @safe pure nothrow @nogc
{
    if (index >= text.length) return text.length;
    if (index == 0 || breakBefore(text, index)) return index;
    return nextGraphemeBoundary(text, index);
}

private bool breakBefore(const(dchar)[] text, size_t index)
    @safe pure nothrow @nogc
{
    assert(index > 0 && index < text.length);
    const left = graphemeBreak(text[index - 1]);
    const right = graphemeBreak(text[index]);

    // GB3: CR × LF.
    if (left == GraphemeBreak.cr && right == GraphemeBreak.lf)
        return false;

    // GB4 / GB5: break around controls.
    if (isControl(left) || isControl(right))
        return true;

    // GB6..GB8: Hangul syllable composition.
    if (left == GraphemeBreak.l &&
        (right == GraphemeBreak.l || right == GraphemeBreak.v ||
         right == GraphemeBreak.lv || right == GraphemeBreak.lvt))
        return false;
    if ((left == GraphemeBreak.lv || left == GraphemeBreak.v) &&
        (right == GraphemeBreak.v || right == GraphemeBreak.t))
        return false;
    if ((left == GraphemeBreak.lvt || left == GraphemeBreak.t) &&
        right == GraphemeBreak.t)
        return false;

    // GB9 / GB9a / GB9b.
    if (right == GraphemeBreak.extend || right == GraphemeBreak.zwj)
        return false;
    if (right == GraphemeBreak.spacingMark)
        return false;
    if (left == GraphemeBreak.prepend)
        return false;

    // GB9c: Indic consonant-linker-consonant sequences.
    if (indicConjunctBreak(text[index]) == IndicConjunctBreak.consonant &&
        hasIndicLinkerSequence(text, index))
        return false;

    // GB11: emoji extended pictographic ZWJ sequences.
    if (isExtendedPictographic(text[index]) && hasEmojiZwjSequence(text, index))
        return false;

    // GB12 / GB13: pair regional indicators from the start of the RI run.
    if (left == GraphemeBreak.regionalIndicator &&
        right == GraphemeBreak.regionalIndicator)
    {
        size_t count;
        size_t cursor = index;
        while (cursor > 0 &&
            graphemeBreak(text[cursor - 1]) == GraphemeBreak.regionalIndicator)
        {
            ++count;
            --cursor;
        }
        return (count & 1) == 0;
    }

    // GB999.
    return true;
}

private bool isControl(GraphemeBreak value) @safe pure nothrow @nogc
{
    return value == GraphemeBreak.control || value == GraphemeBreak.cr ||
        value == GraphemeBreak.lf;
}

private bool hasEmojiZwjSequence(const(dchar)[] text, size_t index)
    @safe pure nothrow @nogc
{
    if (index < 2 || graphemeBreak(text[index - 1]) != GraphemeBreak.zwj)
        return false;
    size_t cursor = index - 1;
    while (cursor > 0 && graphemeBreak(text[cursor - 1]) == GraphemeBreak.extend)
        --cursor;
    return cursor > 0 && isExtendedPictographic(text[cursor - 1]);
}

private bool hasIndicLinkerSequence(const(dchar)[] text, size_t index)
    @safe pure nothrow @nogc
{
    size_t cursor = index;
    bool sawLinker;
    while (cursor > 0)
    {
        const value = indicConjunctBreak(text[cursor - 1]);
        if (value == IndicConjunctBreak.linker)
        {
            sawLinker = true;
            --cursor;
            continue;
        }
        if (value == IndicConjunctBreak.extend)
        {
            --cursor;
            continue;
        }
        break;
    }
    return sawLinker && cursor > 0 &&
        indicConjunctBreak(text[cursor - 1]) == IndicConjunctBreak.consonant;
}

unittest
{
    import std.array : array;

    assert(graphemeBoundaries("a\u0301b"d) == [0UL, 2UL, 3UL]);
    assert(graphemeBoundaries("\r\n"d) == [0UL, 2UL]);
    assert(graphemeBoundaries("\U0001F1F1\U0001F1F9"d) == [0UL, 2UL]);
    assert(graphemeBoundaries("\U0001F1F1\U0001F1F9\U0001F1EA"d) == [0UL, 2UL, 3UL]);
    assert(graphemeBoundaries("\U0001F469\u200D\U0001F4BB"d) == [0UL, 3UL]);
    assert(graphemeBoundaries("\u0915\u094D\u0937"d) == [0UL, 3UL]);
    assert(previousGraphemeBoundary("a\u0301b"d, 2) == 0);
    assert(nextGraphemeBoundary("a\u0301b"d, 0) == 2);
}
