module aurora.text.unicode.linebreak;

/** Unicode 17.0 default line-break opportunities (UAX #14). */

import aurora.text.unicode.properties : EastAsianWidth, GeneralCategory,
    LineBreakClass, eastAsianWidth, generalCategory, isExtendedPictographic,
    lineBreakClass;

private struct BreakChar
{
    dchar codepoint;
    LineBreakClass cls;
    LineBreakClass original;
    GeneralCategory category;
    EastAsianWidth width;
    bool extendedPictographic;
    size_t baseIndex;
}

private bool isHard(LineBreakClass value) @safe pure nothrow @nogc
{
    return value == LineBreakClass.bk || value == LineBreakClass.cr ||
        value == LineBreakClass.lf || value == LineBreakClass.nl;
}

private bool isAlphabetic(LineBreakClass value) @safe pure nothrow @nogc
{
    return value == LineBreakClass.al || value == LineBreakClass.hl;
}

private bool isHangul(LineBreakClass value) @safe pure nothrow @nogc
{
    return value == LineBreakClass.jl || value == LineBreakClass.jv ||
        value == LineBreakClass.jt || value == LineBreakClass.h2 ||
        value == LineBreakClass.h3;
}

private bool isAksaraBase(LineBreakClass value, dchar codepoint)
    @safe pure nothrow @nogc
{
    return value == LineBreakClass.ak || value == LineBreakClass.as ||
        codepoint == cast(dchar) 0x25CC;
}

private bool isAksaraFollower(LineBreakClass value, dchar codepoint)
    @safe pure nothrow @nogc
{
    return value == LineBreakClass.ak || codepoint == cast(dchar) 0x25CC;
}

private ptrdiff_t previousBase(const(BreakChar)[] chars, size_t baseIndex)
    @safe pure nothrow @nogc
{
    if (baseIndex == 0) return -1;
    auto index = cast(ptrdiff_t) baseIndex - 1;
    while (index >= 0 && chars[cast(size_t) index].baseIndex == baseIndex) --index;
    return index;
}

private size_t nextBase(const(BreakChar)[] chars, size_t baseIndex)
    @safe pure nothrow @nogc
{
    size_t index = baseIndex + 1;
    while (index < chars.length && chars[index].baseIndex == baseIndex) ++index;
    return index;
}

private bool isEastAsian(BreakChar value) @safe pure nothrow @nogc
{
    return value.width == EastAsianWidth.f || value.width == EastAsianWidth.w ||
        value.width == EastAsianWidth.h;
}

private bool isInitialQuote(BreakChar value) @safe pure nothrow @nogc
{
    return value.cls == LineBreakClass.qu && value.category == GeneralCategory.pi;
}

private bool isFinalQuote(BreakChar value) @safe pure nothrow @nogc
{
    return value.cls == LineBreakClass.qu && value.category == GeneralCategory.pf;
}

private LineBreakClass resolveClass(dchar codepoint) @safe pure nothrow @nogc
{
    const value = lineBreakClass(codepoint);
    switch (value)
    {
        case LineBreakClass.ai:
        case LineBreakClass.sg:
        case LineBreakClass.xx:
            return LineBreakClass.al;
        case LineBreakClass.sa:
            const category = generalCategory(codepoint);
            return category == GeneralCategory.mn || category == GeneralCategory.mc ?
                LineBreakClass.cm : LineBreakClass.al;
        case LineBreakClass.cj:
            return LineBreakClass.ns;
        default:
            return value;
    }
}

private BreakChar[] resolveCharacters(const(dchar)[] text) @safe pure
{
    BreakChar[] result;
    result.length = text.length;
    foreach (i, ch; text)
    {
        result[i].codepoint = ch;
        result[i].original = resolveClass(ch);
        result[i].cls = result[i].original;
        result[i].category = generalCategory(ch);
        result[i].width = eastAsianWidth(ch);
        result[i].extendedPictographic = isExtendedPictographic(ch);
        result[i].baseIndex = i;
    }

    // LB9 and LB10. The boundary before every absorbed CM/ZWJ is prohibited;
    // the caller applies that condition using `original`.
    foreach (i; 0 .. result.length)
    {
        auto value = result[i].cls;
        if (value != LineBreakClass.cm && value != LineBreakClass.zwj) continue;
        if (i > 0)
        {
            const prior = result[i - 1].cls;
            if (!isHard(prior) && prior != LineBreakClass.sp && prior != LineBreakClass.zw)
            {
                const original = result[i].original;
                result[i].cls = prior;
                result[i].codepoint = result[i - 1].codepoint;
                result[i].category = result[i - 1].category;
                result[i].width = result[i - 1].width;
                result[i].extendedPictographic = result[i - 1].extendedPictographic;
                result[i].baseIndex = result[i - 1].baseIndex;
                result[i].original = original;
                continue;
            }
        }
        result[i].cls = LineBreakClass.al;
        result[i].category = GeneralCategory.lu;
        result[i].width = EastAsianWidth.na;
        result[i].extendedPictographic = false;
    }
    return result;
}

private ptrdiff_t previousNonSpace(const(BreakChar)[] chars, ptrdiff_t index)
    @safe pure nothrow @nogc
{
    while (index >= 0 && chars[cast(size_t) index].cls == LineBreakClass.sp) --index;
    return index;
}

private size_t nextNonSpace(const(BreakChar)[] chars, size_t index)
    @safe pure nothrow @nogc
{
    while (index < chars.length && chars[index].cls == LineBreakClass.sp) ++index;
    return index;
}

private bool isStartContext(LineBreakClass value) @safe pure nothrow @nogc
{
    return isHard(value) || value == LineBreakClass.sp || value == LineBreakClass.zw ||
        value == LineBreakClass.cb || value == LineBreakClass.gl;
}

private bool finalQuoteFollower(LineBreakClass value) @safe pure nothrow @nogc
{
    return value == LineBreakClass.sp || value == LineBreakClass.gl ||
        value == LineBreakClass.wj || value == LineBreakClass.cl ||
        value == LineBreakClass.qu || value == LineBreakClass.cp ||
        value == LineBreakClass.ex || value == LineBreakClass.isValue ||
        value == LineBreakClass.sy || isHard(value) || value == LineBreakClass.zw;
}

private bool hasNumericPrefixPattern(const(BreakChar)[] chars, size_t right)
    @safe pure nothrow @nogc
{
    // Called when chars[right] is NU. Accept PR/PO immediately before NU, or
    // before OP [IS] NU.
    if (right == 0) return false;
    auto i = cast(ptrdiff_t) right - 1;
    if (chars[cast(size_t) i].cls == LineBreakClass.pr ||
        chars[cast(size_t) i].cls == LineBreakClass.po)
        return true;
    if (chars[cast(size_t) i].cls == LineBreakClass.isValue && i > 0) --i;
    if (chars[cast(size_t) i].cls == LineBreakClass.op && i > 0) --i;
    return chars[cast(size_t) i].cls == LineBreakClass.pr ||
        chars[cast(size_t) i].cls == LineBreakClass.po;
}

/**
 * Return a break flag at each logical code-point boundary. The array length is
 * `text.length + 1`; index zero is always false and the final index is true.
 * Mandatory breaks are represented as true and can be identified with
 * `mandatoryBreakAfter`.
 */
bool[] lineBreakOpportunities(const(dchar)[] text) @safe pure
{
    bool[] breaks;
    breaks.length = text.length + 1;
    if (text.length == 0)
    {
        breaks[0] = true;
        return breaks;
    }
    auto chars = resolveCharacters(text);
    breaks[0] = false; // LB2

    foreach (boundary; 1 .. text.length)
    {
        const leftIndex = boundary - 1;
        const rightIndex = boundary;
        const left = chars[leftIndex];
        const right = chars[rightIndex];
        bool allow = true; // LB31 unless an earlier rule matches.

        // LB4-LB6.
        if (left.cls == LineBreakClass.cr && right.cls == LineBreakClass.lf)
            allow = false;
        else if (isHard(left.cls))
            allow = true;
        else if (isHard(right.cls))
            allow = false;
        // LB7, LB8 and LB8a.
        else if (right.cls == LineBreakClass.sp || right.cls == LineBreakClass.zw)
            allow = false;
        else
        {
            const beforeSpaces = previousNonSpace(chars, cast(ptrdiff_t) leftIndex);
            if (beforeSpaces >= 0 && chars[cast(size_t) beforeSpaces].cls == LineBreakClass.zw)
                allow = true;
            else if (left.original == LineBreakClass.zwj)
                allow = false;
            // LB9: never break before an absorbed CM or ZWJ.
            else if ((right.original == LineBreakClass.cm ||
                      right.original == LineBreakClass.zwj) &&
                     !isHard(left.original) && left.original != LineBreakClass.sp &&
                     left.original != LineBreakClass.zw)
                allow = false;
            // LB11-LB12a.
            else if (left.cls == LineBreakClass.wj || right.cls == LineBreakClass.wj)
                allow = false;
            else if (left.cls == LineBreakClass.gl)
                allow = false;
            else if (right.cls == LineBreakClass.gl &&
                    left.cls != LineBreakClass.sp && left.cls != LineBreakClass.ba &&
                    left.cls != LineBreakClass.hy && left.cls != LineBreakClass.hh)
                allow = false;
            // LB13.
            else if (right.cls == LineBreakClass.cl || right.cls == LineBreakClass.cp ||
                    right.cls == LineBreakClass.ex || right.cls == LineBreakClass.sy)
                allow = false;
            // LB14: OP SP* ×.
            else if (beforeSpaces >= 0 &&
                    chars[cast(size_t) beforeSpaces].cls == LineBreakClass.op)
                allow = false;
            else
            {
                // LB15a. Initial QU in start/open/quote context, with SP*.
                bool matched = false;
                if (beforeSpaces >= 0 && isInitialQuote(chars[cast(size_t) beforeSpaces]))
                {
                    const quote = cast(size_t) beforeSpaces;
                    // LB15a examines the immediate character before the quote.
                    // A preceding SP is itself a valid start context; skipping it
                    // would incorrectly allow a break inside opening quotation.
                    const beforeQuote = quote == 0 ? -1 : cast(ptrdiff_t) quote - 1;
                    if (beforeQuote < 0 || isStartContext(chars[cast(size_t) beforeQuote].cls) ||
                        chars[cast(size_t) beforeQuote].cls == LineBreakClass.op ||
                        chars[cast(size_t) beforeQuote].cls == LineBreakClass.qu)
                    {
                        allow = false;
                        matched = true;
                    }
                }
                // LB15b. Final QU before prohibited/end context.
                if (!matched && isFinalQuote(right))
                {
                    const after = rightIndex + 1;
                    if (after >= chars.length || finalQuoteFollower(chars[after].cls))
                    {
                        allow = false;
                        matched = true;
                    }
                }
                // LB15c: SP ÷ IS NU.
                if (!matched && left.cls == LineBreakClass.sp &&
                    right.cls == LineBreakClass.isValue && rightIndex + 1 < chars.length &&
                    chars[rightIndex + 1].cls == LineBreakClass.nu)
                {
                    allow = true;
                    matched = true;
                }
                // LB15d.
                if (!matched && right.cls == LineBreakClass.isValue)
                {
                    allow = false;
                    matched = true;
                }
                // LB16, LB17.
                if (!matched && beforeSpaces >= 0 &&
                    (chars[cast(size_t) beforeSpaces].cls == LineBreakClass.cl ||
                     chars[cast(size_t) beforeSpaces].cls == LineBreakClass.cp) &&
                    right.cls == LineBreakClass.ns)
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && beforeSpaces >= 0 &&
                    chars[cast(size_t) beforeSpaces].cls == LineBreakClass.b2 &&
                    right.cls == LineBreakClass.b2)
                {
                    allow = false;
                    matched = true;
                }
                // LB18.
                if (!matched && left.cls == LineBreakClass.sp)
                {
                    allow = true;
                    matched = true;
                }
                // LB19 and LB19a.
                if (!matched && right.cls == LineBreakClass.qu && !isInitialQuote(right))
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && left.cls == LineBreakClass.qu && !isFinalQuote(left))
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && right.cls == LineBreakClass.qu)
                {
                    const after = rightIndex + 1;
                    const leftNonEast = !isEastAsian(left);
                    const afterNonEast = after >= chars.length || !isEastAsian(chars[after]);
                    if (leftNonEast || afterNonEast)
                    {
                        allow = false;
                        matched = true;
                    }
                }
                if (!matched && left.cls == LineBreakClass.qu)
                {
                    const before = leftIndex == 0 ? -1 : cast(ptrdiff_t) leftIndex - 1;
                    const beforeNonEast = before < 0 || !isEastAsian(chars[cast(size_t) before]);
                    if (!isEastAsian(right) || beforeNonEast)
                    {
                        allow = false;
                        matched = true;
                    }
                }
                // LB20.
                if (!matched && (left.cls == LineBreakClass.cb || right.cls == LineBreakClass.cb))
                {
                    allow = true;
                    matched = true;
                }
                // LB20a.
                if (!matched && (left.cls == LineBreakClass.hy || left.cls == LineBreakClass.hh) &&
                    isAlphabetic(right.cls))
                {
                    const beforeHyphen = left.baseIndex == 0 ? -1 :
                        cast(ptrdiff_t) left.baseIndex - 1;
                    if (beforeHyphen < 0 || isStartContext(chars[cast(size_t) beforeHyphen].cls))
                    {
                        allow = false;
                        matched = true;
                    }
                }
                // LB21 / LB21a / LB21b / LB22.
                if (!matched && (right.cls == LineBreakClass.ba ||
                    right.cls == LineBreakClass.hh || right.cls == LineBreakClass.hy ||
                    right.cls == LineBreakClass.ns))
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && left.cls == LineBreakClass.bb)
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && (left.cls == LineBreakClass.hy || left.cls == LineBreakClass.hh) &&
                    left.baseIndex > 0 && chars[left.baseIndex - 1].cls == LineBreakClass.hl &&
                    right.cls != LineBreakClass.hl)
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && left.cls == LineBreakClass.sy && right.cls == LineBreakClass.hl)
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && right.cls == LineBreakClass.inValue)
                {
                    allow = false;
                    matched = true;
                }
                // LB23 and LB23a.
                if (!matched && ((isAlphabetic(left.cls) && right.cls == LineBreakClass.nu) ||
                    (left.cls == LineBreakClass.nu && isAlphabetic(right.cls))))
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && ((left.cls == LineBreakClass.pr &&
                    (right.cls == LineBreakClass.id || right.cls == LineBreakClass.eb ||
                     right.cls == LineBreakClass.em)) ||
                    ((left.cls == LineBreakClass.id || left.cls == LineBreakClass.eb ||
                      left.cls == LineBreakClass.em) && right.cls == LineBreakClass.po)))
                {
                    allow = false;
                    matched = true;
                }
                // LB24.
                if (!matched && (((left.cls == LineBreakClass.pr || left.cls == LineBreakClass.po) &&
                    isAlphabetic(right.cls)) ||
                    (isAlphabetic(left.cls) &&
                    (right.cls == LineBreakClass.pr || right.cls == LineBreakClass.po))))
                {
                    allow = false;
                    matched = true;
                }
                // LB25 number patterns.
                if (!matched)
                {
                    bool numericNoBreak;
                    // PR/PO × OP [IS] NU. This rule applies at the boundary
                    // before OP, so looking only from a right-hand NU misses it.
                    if ((left.cls == LineBreakClass.pr || left.cls == LineBreakClass.po) &&
                        right.cls == LineBreakClass.op)
                    {
                        auto look = nextBase(chars, right.baseIndex);
                        if (look < chars.length && chars[look].cls == LineBreakClass.isValue)
                            look = nextBase(chars, chars[look].baseIndex);
                        if (look < chars.length && chars[look].cls == LineBreakClass.nu)
                            numericNoBreak = true;
                    }
                    if (!numericNoBreak &&
                        (right.cls == LineBreakClass.po || right.cls == LineBreakClass.pr ||
                         right.cls == LineBreakClass.nu))
                    {
                        auto scan = cast(ptrdiff_t) leftIndex;
                        if ((right.cls == LineBreakClass.po || right.cls == LineBreakClass.pr) &&
                            (chars[cast(size_t) scan].cls == LineBreakClass.cl ||
                             chars[cast(size_t) scan].cls == LineBreakClass.cp))
                            --scan;
                        while (scan >= 0 &&
                            (chars[cast(size_t) scan].cls == LineBreakClass.sy ||
                             chars[cast(size_t) scan].cls == LineBreakClass.isValue))
                            --scan;
                        if (scan >= 0 && chars[cast(size_t) scan].cls == LineBreakClass.nu)
                            numericNoBreak = true;
                    }
                    if (!numericNoBreak && right.cls == LineBreakClass.nu &&
                        (left.cls == LineBreakClass.hy || left.cls == LineBreakClass.isValue ||
                         hasNumericPrefixPattern(chars, rightIndex)))
                        numericNoBreak = true;
                    if (numericNoBreak)
                    {
                        allow = false;
                        matched = true;
                    }
                }
                // LB26 and LB27.
                if (!matched && ((left.cls == LineBreakClass.jl &&
                    (right.cls == LineBreakClass.jl || right.cls == LineBreakClass.jv ||
                     right.cls == LineBreakClass.h2 || right.cls == LineBreakClass.h3)) ||
                    ((left.cls == LineBreakClass.jv || left.cls == LineBreakClass.h2) &&
                     (right.cls == LineBreakClass.jv || right.cls == LineBreakClass.jt)) ||
                    ((left.cls == LineBreakClass.jt || left.cls == LineBreakClass.h3) &&
                     right.cls == LineBreakClass.jt)))
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && ((isHangul(left.cls) && right.cls == LineBreakClass.po) ||
                    (left.cls == LineBreakClass.pr && isHangul(right.cls))))
                {
                    allow = false;
                    matched = true;
                }
                // LB28.
                if (!matched && isAlphabetic(left.cls) && isAlphabetic(right.cls))
                {
                    allow = false;
                    matched = true;
                }
                // LB28a Brahmic orthographic syllables.
                if (!matched && left.cls == LineBreakClass.ap &&
                    isAksaraBase(right.cls, right.codepoint))
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && isAksaraBase(left.cls, left.codepoint) &&
                    (right.cls == LineBreakClass.vf || right.cls == LineBreakClass.vi))
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && left.cls == LineBreakClass.vi &&
                    isAksaraFollower(right.cls, right.codepoint))
                {
                    const beforeVirama = previousBase(chars, left.baseIndex);
                    if (beforeVirama >= 0 &&
                        isAksaraBase(chars[cast(size_t) beforeVirama].cls,
                            chars[cast(size_t) beforeVirama].codepoint))
                    {
                        allow = false;
                        matched = true;
                    }
                }
                if (!matched && isAksaraBase(left.cls, left.codepoint) &&
                    isAksaraBase(right.cls, right.codepoint))
                {
                    const following = nextBase(chars, right.baseIndex);
                    if (following < chars.length &&
                        chars[following].cls == LineBreakClass.vf)
                    {
                        allow = false;
                        matched = true;
                    }
                }
                // LB29.
                if (!matched && left.cls == LineBreakClass.isValue &&
                    isAlphabetic(right.cls))
                {
                    allow = false;
                    matched = true;
                }
                // LB30 with East Asian punctuation exclusions.
                if (!matched && (isAlphabetic(left.cls) || left.cls == LineBreakClass.nu) &&
                    right.cls == LineBreakClass.op && !isEastAsian(right))
                {
                    allow = false;
                    matched = true;
                }
                if (!matched && left.cls == LineBreakClass.cp && !isEastAsian(left) &&
                    (isAlphabetic(right.cls) || right.cls == LineBreakClass.nu))
                {
                    allow = false;
                    matched = true;
                }
                // LB30a.
                if (!matched && left.cls == LineBreakClass.ri && right.cls == LineBreakClass.ri)
                {
                    size_t count;
                    auto scan = cast(ptrdiff_t) leftIndex;
                    size_t lastBase = size_t.max;
                    while (scan >= 0 && chars[cast(size_t) scan].cls == LineBreakClass.ri)
                    {
                        const base = chars[cast(size_t) scan].baseIndex;
                        if (base != lastBase)
                        {
                            ++count;
                            lastBase = base;
                        }
                        --scan;
                    }
                    allow = (count & 1) == 0;
                    matched = true;
                }
                // LB30b.
                if (!matched && right.cls == LineBreakClass.em &&
                    (left.cls == LineBreakClass.eb ||
                     (left.extendedPictographic && left.category == GeneralCategory.cn)))
                {
                    allow = false;
                    matched = true;
                }
            }
        }
        breaks[boundary] = allow;
    }
    breaks[$ - 1] = true; // LB3
    return breaks;
}

bool mandatoryBreakAfter(const(dchar)[] text, size_t boundary)
    @safe pure nothrow @nogc
{
    if (boundary == 0 || boundary > text.length) return false;
    const left = resolveClass(text[boundary - 1]);
    if (left == LineBreakClass.cr && boundary < text.length &&
        resolveClass(text[boundary]) == LineBreakClass.lf)
        return false;
    return isHard(left);
}

unittest
{
    auto basic = lineBreakOpportunities("hello world"d);
    assert(!basic[0]);
    assert(basic[6]);
    assert(!basic[1]);
    assert(basic[$ - 1]);

    auto crlf = lineBreakOpportunities("a\r\nb"d);
    assert(!crlf[2]);
    assert(crlf[3]);
    assert(mandatoryBreakAfter("a\r\nb"d, 3));

    auto combining = lineBreakOpportunities("A\u0301B"d);
    assert(!combining[1]);
    assert(!combining[2]);
}
