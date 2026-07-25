module aurora.text.opentype;

/**
 * Pure-D OpenType layout engine.
 *
 * The implementation consumes GDEF, GSUB and GPOS directly from an sfnt face.
 * It preserves source clusters through substitutions and emits positioned
 * glyphs in logical order; the paragraph layout layer performs visual bidi
 * ordering after shaping.
 */

import aurora.font : FontFace;
import aurora.text.unicode.properties : JoiningType, Script, bidiMirror,
    isDefaultIgnorable, joiningType, openTypeScriptTag;
import std.algorithm : max, min;
import std.exception : enforce;

uint fontTag(string value) @safe pure nothrow @nogc
{
    if (value.length != 4) return 0;
    return (cast(uint) value[0] << 24) | (cast(uint) value[1] << 16) |
        (cast(uint) value[2] << 8) | cast(uint) value[3];
}

private enum GdefTag = 0x47444546u; // GDEF
private enum GsubTag = 0x47535542u; // GSUB
private enum GposTag = 0x47504F53u; // GPOS
private enum DfltTag = 0x44464C54u; // DFLT

struct ShapeInput
{
    dchar codepoint;
    size_t clusterStart;
    size_t clusterEnd;
}

struct ShapedGlyph
{
    uint glyphIndex;
    dchar codepoint;
    size_t clusterStart;
    size_t clusterEnd;
    double advanceX = 0.0;
    double advanceY = 0.0;
    double offsetX = 0.0;
    double offsetY = 0.0;
    uint formFeature;
    ushort componentCount = 1;
    bool hidden;

    bool isLigature() const @safe pure nothrow @nogc
    {
        return componentCount > 1;
    }
}

struct ShapeOptions
{
    Script script = Script.common;
    uint languageTag;
    int pixelSize = 17;
    bool rightToLeft;
    bool enableKerning = true;
    bool enableLigatures = true;
    bool enableContextualAlternates = true;
    bool enableMarkPositioning = true;
}

private ushort u16(const(ubyte)[] data, size_t offset)
{
    enforce(offset + 2 <= data.length, "Truncated OpenType layout table");
    return cast(ushort) ((cast(uint) data[offset] << 8) | data[offset + 1]);
}

private short s16(const(ubyte)[] data, size_t offset)
{
    return cast(short) u16(data, offset);
}

private uint u32(const(ubyte)[] data, size_t offset)
{
    enforce(offset + 4 <= data.length, "Truncated OpenType layout table");
    return (cast(uint) data[offset] << 24) | (cast(uint) data[offset + 1] << 16) |
        (cast(uint) data[offset + 2] << 8) | data[offset + 3];
}

private size_t checkedOffset(const(ubyte)[] data, size_t base, size_t relative)
{
    enforce(relative <= data.length && base <= data.length - relative,
        "OpenType layout offset is outside the table");
    return base + relative;
}

private int coverageIndex(const(ubyte)[] data, size_t offset, uint glyph)
{
    if (offset == 0 || offset + 4 > data.length) return -1;
    const format = u16(data, offset);
    if (format == 1)
    {
        const count = u16(data, offset + 2);
        size_t low;
        size_t high = count;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            const value = u16(data, offset + 4 + middle * 2);
            if (glyph < value) high = middle;
            else if (glyph > value) low = middle + 1;
            else return cast(int) middle;
        }
        return -1;
    }
    if (format == 2)
    {
        const count = u16(data, offset + 2);
        size_t low;
        size_t high = count;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            const record = offset + 4 + middle * 6;
            const first = u16(data, record);
            const last = u16(data, record + 2);
            if (glyph < first) high = middle;
            else if (glyph > last) low = middle + 1;
            else return u16(data, record + 4) + cast(int) glyph - first;
        }
    }
    return -1;
}

private uint classValue(const(ubyte)[] data, size_t offset, uint glyph)
{
    if (offset == 0 || offset + 4 > data.length) return 0;
    const format = u16(data, offset);
    if (format == 1)
    {
        const start = u16(data, offset + 2);
        const count = u16(data, offset + 4);
        if (glyph < start || glyph >= cast(uint) start + count) return 0;
        return u16(data, offset + 6 + cast(size_t) (glyph - start) * 2);
    }
    if (format == 2)
    {
        const count = u16(data, offset + 2);
        size_t low;
        size_t high = count;
        while (low < high)
        {
            const middle = low + (high - low) / 2;
            const record = offset + 4 + middle * 6;
            const first = u16(data, record);
            const last = u16(data, record + 2);
            if (glyph < first) high = middle;
            else if (glyph > last) low = middle + 1;
            else return u16(data, record + 4);
        }
    }
    return 0;
}

private struct FeatureUse
{
    uint tag;
    ushort[] lookups;
}

private struct LanguageFeatures
{
    ushort required = ushort.max;
    ushort[] indices;
}

private LanguageFeatures findLanguageFeatures(const(ubyte)[] table,
    uint scriptTag, uint languageTag)
{
    LanguageFeatures result;
    if (table.length < 10) return result;
    const scriptList = checkedOffset(table, 0, u16(table, 4));
    const count = u16(table, scriptList);
    size_t scriptOffset;
    size_t dfltOffset;
    foreach (i; 0 .. count)
    {
        const record = scriptList + 2 + i * 6;
        const tag = u32(table, record);
        const offset = checkedOffset(table, scriptList, u16(table, record + 4));
        if (tag == scriptTag) scriptOffset = offset;
        if (tag == DfltTag) dfltOffset = offset;
    }
    if (scriptOffset == 0) scriptOffset = dfltOffset;
    if (scriptOffset == 0) return result;

    size_t langSys;
    const defaultOffset = u16(table, scriptOffset);
    if (languageTag != 0)
    {
        const langCount = u16(table, scriptOffset + 2);
        foreach (i; 0 .. langCount)
        {
            const record = scriptOffset + 4 + i * 6;
            if (u32(table, record) == languageTag)
            {
                langSys = checkedOffset(table, scriptOffset, u16(table, record + 4));
                break;
            }
        }
    }
    if (langSys == 0 && defaultOffset != 0)
        langSys = checkedOffset(table, scriptOffset, defaultOffset);
    if (langSys == 0) return result;
    result.required = u16(table, langSys + 2);
    const featureCount = u16(table, langSys + 4);
    result.indices.length = featureCount;
    foreach (i; 0 .. featureCount)
        result.indices[i] = u16(table, langSys + 6 + i * 2);
    return result;
}

private FeatureUse featureByIndex(const(ubyte)[] table, ushort featureIndex)
{
    FeatureUse result;
    const featureList = checkedOffset(table, 0, u16(table, 6));
    const count = u16(table, featureList);
    if (featureIndex >= count) return result;
    const record = featureList + 2 + cast(size_t) featureIndex * 6;
    result.tag = u32(table, record);
    const feature = checkedOffset(table, featureList, u16(table, record + 4));
    const lookupCount = u16(table, feature + 2);
    result.lookups.length = lookupCount;
    foreach (i; 0 .. lookupCount)
        result.lookups[i] = u16(table, feature + 4 + i * 2);
    return result;
}

private FeatureUse[] selectFeatures(const(ubyte)[] table, uint scriptTag,
    uint languageTag, const(uint)[] policy)
{
    FeatureUse[] result;
    if (table.length < 10) return result;
    const language = findLanguageFeatures(table, scriptTag, languageTag);
    if (language.required != ushort.max)
    {
        auto required = featureByIndex(table, language.required);
        if (required.tag != 0) result ~= required;
    }
    foreach (wanted; policy)
    {
        foreach (index; language.indices)
        {
            auto feature = featureByIndex(table, index);
            if (feature.tag == wanted)
            {
                bool duplicate;
                foreach (existing; result)
                    if (existing.tag == feature.tag && existing.lookups == feature.lookups)
                        duplicate = true;
                if (!duplicate) result ~= feature;
            }
        }
    }
    return result;
}

private final class GdefInfo
{
    private const(ubyte)[] data;
    private size_t glyphClassOffset;
    private size_t ligCaretOffset;
    private size_t markAttachOffset;
    private size_t markSetsOffset;

    this(const(ubyte)[] bytes)
    {
        data = bytes;
        if (data.length < 12) return;
        const glyph = u16(data, 4);
        const lig = u16(data, 8);
        const mark = u16(data, 10);
        if (glyph) glyphClassOffset = checkedOffset(data, 0, glyph);
        if (lig) ligCaretOffset = checkedOffset(data, 0, lig);
        if (mark) markAttachOffset = checkedOffset(data, 0, mark);
        const tableVersion = u32(data, 0);
        if (tableVersion >= 0x00010002 && data.length >= 14)
        {
            const sets = u16(data, 12);
            if (sets) markSetsOffset = checkedOffset(data, 0, sets);
        }
    }

    uint glyphClass(uint glyph) const
    {
        return classValue(data, glyphClassOffset, glyph);
    }

    uint markAttachmentClass(uint glyph) const
    {
        return classValue(data, markAttachOffset, glyph);
    }

    bool inMarkSet(uint setIndex, uint glyph) const
    {
        if (markSetsOffset == 0 || markSetsOffset + 4 > data.length) return false;
        if (u16(data, markSetsOffset) != 1) return false;
        const count = u16(data, markSetsOffset + 2);
        if (setIndex >= count) return false;
        const coverage = checkedOffset(data, markSetsOffset,
            u32(data, markSetsOffset + 4 + cast(size_t) setIndex * 4));
        return coverageIndex(data, coverage, glyph) >= 0;
    }

    double[] ligatureCarets(uint glyph, const(FontFace) face, int pixelSize) const
    {
        double[] result;
        if (ligCaretOffset == 0 || ligCaretOffset + 4 > data.length) return result;
        const coverage = checkedOffset(data, ligCaretOffset, u16(data, ligCaretOffset));
        const index = coverageIndex(data, coverage, glyph);
        const count = u16(data, ligCaretOffset + 2);
        if (index < 0 || index >= count) return result;
        const ligGlyph = checkedOffset(data, ligCaretOffset,
            u16(data, ligCaretOffset + 4 + cast(size_t) index * 2));
        const caretCount = u16(data, ligGlyph);
        foreach (i; 0 .. caretCount)
        {
            const caret = checkedOffset(data, ligGlyph,
                u16(data, ligGlyph + 2 + i * 2));
            const format = u16(data, caret);
            if (format == 1 || format == 3)
                result ~= face.unitsToPixels(s16(data, caret + 2), pixelSize);
        }
        return result;
    }
}

private bool formFeature(uint tag) @safe pure nothrow @nogc
{
    return tag == fontTag("isol") || tag == fontTag("init") ||
        tag == fontTag("medi") || tag == fontTag("fina") ||
        tag == fontTag("med2") || tag == fontTag("fin2") ||
        tag == fontTag("fin3");
}

private bool joinsLeft(JoiningType value) @safe pure nothrow @nogc
{
    return value == JoiningType.leftJoining || value == JoiningType.dualJoining ||
        value == JoiningType.joinCausing;
}

private bool joinsRight(JoiningType value) @safe pure nothrow @nogc
{
    return value == JoiningType.rightJoining || value == JoiningType.dualJoining ||
        value == JoiningType.joinCausing;
}

private void assignJoiningForms(ref ShapedGlyph[] glyphs)
{
    foreach (i; 0 .. glyphs.length)
    {
        const current = joiningType(glyphs[i].codepoint);
        if (current == JoiningType.transparent) continue;
        ptrdiff_t previous = cast(ptrdiff_t) i - 1;
        while (previous >= 0 &&
            joiningType(glyphs[cast(size_t) previous].codepoint) == JoiningType.transparent)
            --previous;
        size_t next = i + 1;
        while (next < glyphs.length &&
            joiningType(glyphs[next].codepoint) == JoiningType.transparent)
            ++next;
        const connectPrevious = previous >= 0 && joinsRight(current) &&
            joinsLeft(joiningType(glyphs[cast(size_t) previous].codepoint));
        const connectNext = next < glyphs.length && joinsLeft(current) &&
            joinsRight(joiningType(glyphs[next].codepoint));
        glyphs[i].formFeature = connectPrevious && connectNext ? fontTag("medi") :
            connectPrevious ? fontTag("fina") :
            connectNext ? fontTag("init") : fontTag("isol");
    }
}

private bool featureApplies(const ShapedGlyph glyph, uint featureTag)
    @safe pure nothrow @nogc
{
    return !formFeature(featureTag) || glyph.formFeature == featureTag;
}

private struct LookupHeader
{
    ushort type;
    ushort flags;
    size_t[] subtables;
    ushort markFilteringSet = ushort.max;
}

private LookupHeader lookupHeader(const(ubyte)[] table, size_t lookupList,
    ushort lookupIndex)
{
    LookupHeader result;
    const count = u16(table, lookupList);
    if (lookupIndex >= count) return result;
    const lookup = checkedOffset(table, lookupList,
        u16(table, lookupList + 2 + cast(size_t) lookupIndex * 2));
    result.type = u16(table, lookup);
    result.flags = u16(table, lookup + 2);
    const subtableCount = u16(table, lookup + 4);
    result.subtables.length = subtableCount;
    foreach (i; 0 .. subtableCount)
        result.subtables[i] = checkedOffset(table, lookup,
            u16(table, lookup + 6 + i * 2));
    if ((result.flags & 0x0010) != 0)
        result.markFilteringSet = u16(table, lookup + 6 + subtableCount * 2);
    return result;
}

private bool ignoredGlyph(const GdefInfo gdef, ShapedGlyph glyph,
    ushort flags, ushort markSet)
{
    if (gdef is null) return false;
    const cls = gdef.glyphClass(glyph.glyphIndex);
    if ((flags & 0x0002) != 0 && cls == 1) return true;
    if ((flags & 0x0004) != 0 && cls == 2) return true;
    if (cls == 3)
    {
        if ((flags & 0x0008) != 0) return true;
        const attachment = flags >> 8;
        if (attachment != 0 && gdef.markAttachmentClass(glyph.glyphIndex) != attachment)
            return true;
        if ((flags & 0x0010) != 0 && markSet != ushort.max &&
            !gdef.inMarkSet(markSet, glyph.glyphIndex))
            return true;
    }
    return false;
}

private ptrdiff_t nextEligible(const(ShapedGlyph)[] glyphs, ptrdiff_t from,
    int direction, const GdefInfo gdef, ushort flags, ushort markSet)
{
    auto cursor = from + direction;
    while (cursor >= 0 && cursor < cast(ptrdiff_t) glyphs.length)
    {
        if (!ignoredGlyph(gdef, glyphs[cast(size_t) cursor], flags, markSet))
            return cursor;
        cursor += direction;
    }
    return -1;
}

private ShapedGlyph mergedGlyph(const(ShapedGlyph)[] source, uint glyph)
{
    ShapedGlyph result = source[0];
    result.glyphIndex = glyph;
    result.clusterStart = source[0].clusterStart;
    result.clusterEnd = source[0].clusterEnd;
    ushort components;
    result.hidden = true;
    foreach (item; source)
    {
        result.clusterStart = min(result.clusterStart, item.clusterStart);
        result.clusterEnd = max(result.clusterEnd, item.clusterEnd);
        components += max(cast(ushort) 1, item.componentCount);
        result.hidden = result.hidden && item.hidden;
    }
    result.componentCount = max(cast(ushort) 1, components);
    result.advanceX = result.advanceY = result.offsetX = result.offsetY = 0;
    return result;
}

private void replaceGlyphs(ref ShapedGlyph[] glyphs, size_t start, size_t count,
    const(ShapedGlyph)[] replacement)
{
    auto next = new ShapedGlyph[glyphs.length - count + replacement.length];
    next[0 .. start] = glyphs[0 .. start];
    next[start .. start + replacement.length] = replacement;
    next[start + replacement.length .. $] = glyphs[start + count .. $];
    glyphs = next;
}

/** Font-specific OpenType substitution and positioning state. */
final class OpenTypeShaper
{
    private FontFace face;
    private GdefInfo gdef;

    this(FontFace selected)
    {
        face = selected;
        if (face !is null)
        {
            auto bytes = face.tableData(GdefTag);
            if (bytes.length) gdef = new GdefInfo(bytes);
        }
    }

    FontFace font() @safe pure nothrow @nogc { return face; }

    ShapedGlyph[] shape(const(ShapeInput)[] input, ShapeOptions options)
    {
        ShapedGlyph[] glyphs;
        glyphs.reserve(input.length);
        foreach (item; input)
        {
            dchar mapped = item.codepoint;
            if (options.rightToLeft)
            {
                const mirror = bidiMirror(mapped);
                if (mirror != mapped && face.supports(mirror)) mapped = mirror;
            }
            ShapedGlyph glyph;
            glyph.glyphIndex = face.glyphIndex(mapped);
            glyph.codepoint = item.codepoint;
            glyph.clusterStart = item.clusterStart;
            glyph.clusterEnd = item.clusterEnd;
            glyph.hidden = isDefaultIgnorable(item.codepoint);
            glyphs ~= glyph;
        }
        assignJoiningForms(glyphs);

        try
            applyGsub(glyphs, options);
        catch (Exception)
        {
            // Invalid optional layout data must not prevent text display.
        }

        foreach (ref glyph; glyphs)
        {
            glyph.advanceX = glyph.hidden ? 0.0 :
                cast(double) face.advanceGlyph(glyph.glyphIndex, options.pixelSize);
            glyph.advanceY = 0;
            glyph.offsetX = glyph.offsetY = 0;
        }

        bool positionedKern;
        try
            positionedKern = applyGpos(glyphs, options);
        catch (Exception)
        {
            // Preserve cmap and metrics output if positioning data is malformed.
        }
        if (options.enableKerning && !positionedKern)
            applyLegacyKerning(glyphs, options.pixelSize);

        ShapedGlyph[] visible;
        visible.reserve(glyphs.length);
        foreach (glyph; glyphs)
            if (!glyph.hidden)
                visible ~= glyph;
        return visible;
    }

    double[] ligatureCarets(uint glyph, int pixelSize) const
    {
        return gdef is null ? null : gdef.ligatureCarets(glyph, face, pixelSize);
    }

    private void applyGsub(ref ShapedGlyph[] glyphs, ShapeOptions options)
    {
        const table = face.tableData(GsubTag);
        if (table.length < 10) return;
        uint[] policy = [fontTag("ccmp"), fontTag("locl"), fontTag("rlig"),
            fontTag("isol"), fontTag("fina"), fontTag("fin2"), fontTag("fin3"),
            fontTag("medi"), fontTag("med2"), fontTag("init")];
        if (options.enableContextualAlternates) policy ~= fontTag("calt");
        if (options.enableLigatures)
        {
            policy ~= fontTag("liga");
            policy ~= fontTag("clig");
        }
        const scriptTag = openTypeScriptTag(options.script);
        const features = selectFeatures(table, scriptTag,
            options.languageTag, policy);
        const lookupList = checkedOffset(table, 0, u16(table, 8));
        foreach (feature; features)
            foreach (lookup; feature.lookups)
                applyGsubLookup(table, lookupList, lookup, feature.tag,
                    glyphs, 0);
    }

    private void applyGsubLookup(const(ubyte)[] table, size_t lookupList,
        ushort lookupIndex, uint featureTag, ref ShapedGlyph[] glyphs, int depth)
    {
        if (depth > 12) return;
        const header = lookupHeader(table, lookupList, lookupIndex);
        if (header.type == 0) return;
        if (header.type == 8)
        {
            for (ptrdiff_t i = cast(ptrdiff_t) glyphs.length - 1; i >= 0; --i)
                applyGsubAt(table, lookupList, header, cast(size_t) i,
                    featureTag, glyphs, depth);
            return;
        }
        size_t position;
        while (position < glyphs.length)
        {
            const beforeLength = glyphs.length;
            const changed = applyGsubAt(table, lookupList, header, position,
                featureTag, glyphs, depth);
            if (changed && glyphs.length < beforeLength)
                ++position;
            else
                ++position;
        }
    }

    private bool applyGsubAt(const(ubyte)[] table, size_t lookupList,
        const(LookupHeader) header, size_t position, uint featureTag,
        ref ShapedGlyph[] glyphs, int depth)
    {
        if (position >= glyphs.length ||
            ignoredGlyph(gdef, glyphs[position], header.flags,
                header.markFilteringSet) ||
            !featureApplies(glyphs[position], featureTag))
            return false;
        foreach (subtable; header.subtables)
        {
            ushort type = header.type;
            size_t actual = subtable;
            if (type == 7)
            {
                if (u16(table, subtable) != 1) continue;
                type = u16(table, subtable + 2);
                actual = checkedOffset(table, subtable, u32(table, subtable + 4));
            }
            switch (type)
            {
                case 1:
                    if (singleSubstitution(table, actual, position, glyphs)) return true;
                    break;
                case 2:
                    if (multipleSubstitution(table, actual, position, glyphs)) return true;
                    break;
                case 3:
                    if (alternateSubstitution(table, actual, position, glyphs)) return true;
                    break;
                case 4:
                    if (ligatureSubstitution(table, actual, header, position,
                        glyphs)) return true;
                    break;
                case 5:
                    if (contextSubstitution(table, lookupList, actual, header,
                        position, featureTag, glyphs, depth)) return true;
                    break;
                case 6:
                    if (chainSubstitution(table, lookupList, actual, header,
                        position, featureTag, glyphs, depth)) return true;
                    break;
                case 8:
                    if (reverseSubstitution(table, actual, header, position,
                        glyphs)) return true;
                    break;
                default:
                    break;
            }
        }
        return false;
    }

    private bool singleSubstitution(const(ubyte)[] table, size_t subtable,
        size_t position, ref ShapedGlyph[] glyphs)
    {
        const format = u16(table, subtable);
        const coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const index = coverageIndex(table, coverage, glyphs[position].glyphIndex);
        if (index < 0) return false;
        if (format == 1)
            glyphs[position].glyphIndex = cast(ushort)
                (glyphs[position].glyphIndex + s16(table, subtable + 4));
        else if (format == 2)
        {
            const count = u16(table, subtable + 4);
            if (index >= count) return false;
            glyphs[position].glyphIndex = u16(table,
                subtable + 6 + cast(size_t) index * 2);
        }
        else return false;
        return true;
    }

    private bool multipleSubstitution(const(ubyte)[] table, size_t subtable,
        size_t position, ref ShapedGlyph[] glyphs)
    {
        if (u16(table, subtable) != 1) return false;
        const coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const index = coverageIndex(table, coverage, glyphs[position].glyphIndex);
        const count = u16(table, subtable + 4);
        if (index < 0 || index >= count) return false;
        const sequence = checkedOffset(table, subtable,
            u16(table, subtable + 6 + cast(size_t) index * 2));
        const glyphCount = u16(table, sequence);
        ShapedGlyph[] replacement;
        replacement.length = glyphCount;
        foreach (i; 0 .. glyphCount)
        {
            replacement[i] = glyphs[position];
            replacement[i].glyphIndex = u16(table, sequence + 2 + i * 2);
            replacement[i].componentCount = 1;
        }
        replaceGlyphs(glyphs, position, 1, replacement);
        return true;
    }

    private bool alternateSubstitution(const(ubyte)[] table, size_t subtable,
        size_t position, ref ShapedGlyph[] glyphs)
    {
        if (u16(table, subtable) != 1) return false;
        const coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const index = coverageIndex(table, coverage, glyphs[position].glyphIndex);
        const count = u16(table, subtable + 4);
        if (index < 0 || index >= count) return false;
        const set = checkedOffset(table, subtable,
            u16(table, subtable + 6 + cast(size_t) index * 2));
        const alternateCount = u16(table, set);
        if (alternateCount == 0) return false;
        glyphs[position].glyphIndex = u16(table, set + 2);
        return true;
    }

    private bool ligatureSubstitution(const(ubyte)[] table, size_t subtable,
        const(LookupHeader) header, size_t position, ref ShapedGlyph[] glyphs)
    {
        if (u16(table, subtable) != 1) return false;
        const coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const coveragePosition = coverageIndex(table, coverage,
            glyphs[position].glyphIndex);
        const setCount = u16(table, subtable + 4);
        if (coveragePosition < 0 || coveragePosition >= setCount) return false;
        const set = checkedOffset(table, subtable,
            u16(table, subtable + 6 + cast(size_t) coveragePosition * 2));
        const ligatureCount = u16(table, set);
        foreach (ligatureIndex; 0 .. ligatureCount)
        {
            const ligature = checkedOffset(table, set,
                u16(table, set + 2 + ligatureIndex * 2));
            const output = u16(table, ligature);
            const componentCount = u16(table, ligature + 2);
            if (componentCount < 2) continue;
            size_t[] matched = [position];
            ptrdiff_t cursor = cast(ptrdiff_t) position;
            bool match = true;
            foreach (component; 1 .. componentCount)
            {
                cursor = nextEligible(glyphs, cursor, 1, gdef, header.flags,
                    header.markFilteringSet);
                if (cursor < 0 || glyphs[cast(size_t) cursor].glyphIndex !=
                    u16(table, ligature + 4 + cast(size_t) (component - 1) * 2))
                {
                    match = false;
                    break;
                }
                matched ~= cast(size_t) cursor;
            }
            if (!match) continue;
            ShapedGlyph[] components;
            foreach (index; matched) components ~= glyphs[index];
            auto merged = mergedGlyph(components, output);
            // Remove matched glyphs from right to left, leaving ignored marks
            // in place and attaching the cluster to the replacement.
            foreach_reverse (index; matched[1 .. $])
                replaceGlyphs(glyphs, index, 1, null);
            glyphs[position] = merged;
            return true;
        }
        return false;
    }

    private bool contextSubstitution(const(ubyte)[] table, size_t lookupList,
        size_t subtable, const(LookupHeader) header, size_t position, uint featureTag,
        ref ShapedGlyph[] glyphs, int depth)
    {
        const format = u16(table, subtable);
        if (format == 3)
        {
            const glyphCount = u16(table, subtable + 2);
            const substitutionCount = u16(table, subtable + 4);
            if (glyphCount == 0) return false;
            size_t[] positions = [position];
            ptrdiff_t cursor = position;
            foreach (i; 0 .. glyphCount)
            {
                if (i > 0)
                {
                    cursor = nextEligible(glyphs, cursor, 1, gdef, header.flags,
                        header.markFilteringSet);
                    if (cursor < 0) return false;
                    positions ~= cast(size_t) cursor;
                }
                const coverage = checkedOffset(table, subtable,
                    u16(table, subtable + 6 + i * 2));
                if (coverageIndex(table, coverage,
                    glyphs[positions[i]].glyphIndex) < 0) return false;
            }
            const records = subtable + 6 + cast(size_t) glyphCount * 2;
            applySubstitutionRecords(table, lookupList, records,
                substitutionCount, positions, featureTag, glyphs, depth);
            return true;
        }
        if (format == 1)
        {
            const coverage = checkedOffset(table, subtable,
                u16(table, subtable + 2));
            const index = coverageIndex(table, coverage, glyphs[position].glyphIndex);
            const setCount = u16(table, subtable + 4);
            if (index < 0 || index >= setCount) return false;
            const relative = u16(table, subtable + 6 + cast(size_t) index * 2);
            if (relative == 0) return false;
            const set = checkedOffset(table, subtable, relative);
            const ruleCount = u16(table, set);
            foreach (r; 0 .. ruleCount)
            {
                const rule = checkedOffset(table, set, u16(table, set + 2 + r * 2));
                const glyphCount = u16(table, rule);
                const substitutionCount = u16(table, rule + 2);
                size_t[] positions = [position];
                ptrdiff_t cursor = position;
                bool match = true;
                foreach (i; 1 .. glyphCount)
                {
                    cursor = nextEligible(glyphs, cursor, 1, gdef, header.flags,
                        header.markFilteringSet);
                    if (cursor < 0 || glyphs[cast(size_t) cursor].glyphIndex !=
                        u16(table, rule + 4 + cast(size_t) (i - 1) * 2))
                    {
                        match = false;
                        break;
                    }
                    positions ~= cast(size_t) cursor;
                }
                if (!match) continue;
                const records = rule + 4 + cast(size_t) (glyphCount - 1) * 2;
                applySubstitutionRecords(table, lookupList, records,
                    substitutionCount, positions, featureTag, glyphs, depth);
                return true;
            }
        }
        if (format == 2)
        {
            const coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
            if (coverageIndex(table, coverage, glyphs[position].glyphIndex) < 0)
                return false;
            const classDef = checkedOffset(table, subtable, u16(table, subtable + 4));
            const setCount = u16(table, subtable + 6);
            const firstClass = classValue(table, classDef, glyphs[position].glyphIndex);
            if (firstClass >= setCount) return false;
            const relative = u16(table, subtable + 8 + cast(size_t) firstClass * 2);
            if (relative == 0) return false;
            const set = checkedOffset(table, subtable, relative);
            const ruleCount = u16(table, set);
            foreach (r; 0 .. ruleCount)
            {
                const rule = checkedOffset(table, set, u16(table, set + 2 + r * 2));
                const glyphCount = u16(table, rule);
                const substitutionCount = u16(table, rule + 2);
                size_t[] positions = [position];
                ptrdiff_t cursor = position;
                bool match = true;
                foreach (i; 1 .. glyphCount)
                {
                    cursor = nextEligible(glyphs, cursor, 1, gdef, header.flags,
                        header.markFilteringSet);
                    if (cursor < 0 || classValue(table, classDef,
                        glyphs[cast(size_t) cursor].glyphIndex) !=
                        u16(table, rule + 4 + cast(size_t) (i - 1) * 2))
                    {
                        match = false;
                        break;
                    }
                    positions ~= cast(size_t) cursor;
                }
                if (!match) continue;
                const records = rule + 4 + cast(size_t) (glyphCount - 1) * 2;
                applySubstitutionRecords(table, lookupList, records,
                    substitutionCount, positions, featureTag, glyphs, depth);
                return true;
            }
        }
        return false;
    }

    private bool chainSubstitution(const(ubyte)[] table, size_t lookupList,
        size_t subtable, const(LookupHeader) header, size_t position, uint featureTag,
        ref ShapedGlyph[] glyphs, int depth)
    {
        const format = u16(table, subtable);
        if (format == 1)
        {
            const coverage = checkedOffset(table, subtable,
                u16(table, subtable + 2));
            const coveragePosition = coverageIndex(table, coverage,
                glyphs[position].glyphIndex);
            const setCount = u16(table, subtable + 4);
            if (coveragePosition < 0 || coveragePosition >= setCount) return false;
            const relative = u16(table, subtable + 6 +
                cast(size_t) coveragePosition * 2);
            if (relative == 0) return false;
            const set = checkedOffset(table, subtable, relative);
            const ruleCount = u16(table, set);
            foreach (ruleIndex; 0 .. ruleCount)
            {
                const rule = checkedOffset(table, set,
                    u16(table, set + 2 + ruleIndex * 2));
                size_t cursorOffset = rule;
                const backtrackCount = u16(table, cursorOffset);
                cursorOffset += 2;
                ptrdiff_t before = position;
                bool match = true;
                foreach (i; 0 .. backtrackCount)
                {
                    before = nextEligible(glyphs, before, -1, gdef,
                        header.flags, header.markFilteringSet);
                    if (before < 0 || glyphs[cast(size_t) before].glyphIndex !=
                        u16(table, cursorOffset + i * 2))
                    { match = false; break; }
                }
                cursorOffset += cast(size_t) backtrackCount * 2;
                if (!match) continue;

                const inputCount = u16(table, cursorOffset);
                cursorOffset += 2;
                if (inputCount == 0) continue;
                size_t[] positions = [position];
                ptrdiff_t current = position;
                foreach (i; 1 .. inputCount)
                {
                    current = nextEligible(glyphs, current, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (current < 0 || glyphs[cast(size_t) current].glyphIndex !=
                        u16(table, cursorOffset + cast(size_t) (i - 1) * 2))
                    { match = false; break; }
                    positions ~= cast(size_t) current;
                }
                cursorOffset += cast(size_t) (inputCount - 1) * 2;
                if (!match) continue;

                const lookaheadCount = u16(table, cursorOffset);
                cursorOffset += 2;
                ptrdiff_t after = current;
                foreach (i; 0 .. lookaheadCount)
                {
                    after = nextEligible(glyphs, after, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (after < 0 || glyphs[cast(size_t) after].glyphIndex !=
                        u16(table, cursorOffset + i * 2))
                    { match = false; break; }
                }
                cursorOffset += cast(size_t) lookaheadCount * 2;
                if (!match) continue;

                const substitutionCount = u16(table, cursorOffset);
                cursorOffset += 2;
                applySubstitutionRecords(table, lookupList, cursorOffset,
                    substitutionCount, positions, featureTag, glyphs, depth);
                return true;
            }
            return false;
        }
        if (format == 2)
        {
            const coverage = checkedOffset(table, subtable,
                u16(table, subtable + 2));
            if (coverageIndex(table, coverage, glyphs[position].glyphIndex) < 0)
                return false;
            const backtrackClassDef = checkedOffset(table, subtable,
                u16(table, subtable + 4));
            const inputClassDef = checkedOffset(table, subtable,
                u16(table, subtable + 6));
            const lookaheadClassDef = checkedOffset(table, subtable,
                u16(table, subtable + 8));
            const setCount = u16(table, subtable + 10);
            const firstClass = classValue(table, inputClassDef,
                glyphs[position].glyphIndex);
            if (firstClass >= setCount) return false;
            const relative = u16(table, subtable + 12 +
                cast(size_t) firstClass * 2);
            if (relative == 0) return false;
            const set = checkedOffset(table, subtable, relative);
            const ruleCount = u16(table, set);
            foreach (ruleIndex; 0 .. ruleCount)
            {
                const rule = checkedOffset(table, set,
                    u16(table, set + 2 + ruleIndex * 2));
                size_t cursorOffset = rule;
                const backtrackCount = u16(table, cursorOffset);
                cursorOffset += 2;
                ptrdiff_t before = position;
                bool match = true;
                foreach (i; 0 .. backtrackCount)
                {
                    before = nextEligible(glyphs, before, -1, gdef,
                        header.flags, header.markFilteringSet);
                    if (before < 0 || classValue(table, backtrackClassDef,
                        glyphs[cast(size_t) before].glyphIndex) !=
                        u16(table, cursorOffset + i * 2))
                    { match = false; break; }
                }
                cursorOffset += cast(size_t) backtrackCount * 2;
                if (!match) continue;

                const inputCount = u16(table, cursorOffset);
                cursorOffset += 2;
                if (inputCount == 0) continue;
                size_t[] positions = [position];
                ptrdiff_t current = position;
                foreach (i; 1 .. inputCount)
                {
                    current = nextEligible(glyphs, current, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (current < 0 || classValue(table, inputClassDef,
                        glyphs[cast(size_t) current].glyphIndex) !=
                        u16(table, cursorOffset + cast(size_t) (i - 1) * 2))
                    { match = false; break; }
                    positions ~= cast(size_t) current;
                }
                cursorOffset += cast(size_t) (inputCount - 1) * 2;
                if (!match) continue;

                const lookaheadCount = u16(table, cursorOffset);
                cursorOffset += 2;
                ptrdiff_t after = current;
                foreach (i; 0 .. lookaheadCount)
                {
                    after = nextEligible(glyphs, after, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (after < 0 || classValue(table, lookaheadClassDef,
                        glyphs[cast(size_t) after].glyphIndex) !=
                        u16(table, cursorOffset + i * 2))
                    { match = false; break; }
                }
                cursorOffset += cast(size_t) lookaheadCount * 2;
                if (!match) continue;

                const substitutionCount = u16(table, cursorOffset);
                cursorOffset += 2;
                applySubstitutionRecords(table, lookupList, cursorOffset,
                    substitutionCount, positions, featureTag, glyphs, depth);
                return true;
            }
            return false;
        }
        if (format == 3)
        {
            size_t cursorOffset = subtable + 2;
            const backtrackCount = u16(table, cursorOffset);
            cursorOffset += 2;
            ptrdiff_t before = position;
            foreach (i; 0 .. backtrackCount)
            {
                before = nextEligible(glyphs, before, -1, gdef, header.flags,
                    header.markFilteringSet);
                if (before < 0) return false;
                const coverage = checkedOffset(table, subtable,
                    u16(table, cursorOffset + i * 2));
                if (coverageIndex(table, coverage,
                    glyphs[cast(size_t) before].glyphIndex) < 0) return false;
            }
            cursorOffset += cast(size_t) backtrackCount * 2;
            const inputCount = u16(table, cursorOffset);
            cursorOffset += 2;
            if (inputCount == 0) return false;
            size_t[] positions = [position];
            ptrdiff_t current = position;
            foreach (i; 0 .. inputCount)
            {
                if (i > 0)
                {
                    current = nextEligible(glyphs, current, 1, gdef, header.flags,
                        header.markFilteringSet);
                    if (current < 0) return false;
                    positions ~= cast(size_t) current;
                }
                const coverage = checkedOffset(table, subtable,
                    u16(table, cursorOffset + i * 2));
                if (coverageIndex(table, coverage,
                    glyphs[positions[i]].glyphIndex) < 0) return false;
            }
            cursorOffset += cast(size_t) inputCount * 2;
            const lookaheadCount = u16(table, cursorOffset);
            cursorOffset += 2;
            ptrdiff_t after = current;
            foreach (i; 0 .. lookaheadCount)
            {
                after = nextEligible(glyphs, after, 1, gdef, header.flags,
                    header.markFilteringSet);
                if (after < 0) return false;
                const coverage = checkedOffset(table, subtable,
                    u16(table, cursorOffset + i * 2));
                if (coverageIndex(table, coverage,
                    glyphs[cast(size_t) after].glyphIndex) < 0) return false;
            }
            cursorOffset += cast(size_t) lookaheadCount * 2;
            const substitutionCount = u16(table, cursorOffset);
            cursorOffset += 2;
            applySubstitutionRecords(table, lookupList, cursorOffset,
                substitutionCount, positions, featureTag, glyphs, depth);
            return true;
        }
        return false;
    }

    private void applySubstitutionRecords(const(ubyte)[] table, size_t lookupList,
        size_t records, size_t count, const(size_t)[] positions,
        uint featureTag, ref ShapedGlyph[] glyphs, int depth)
    {
        // Reverse record order keeps earlier sequence indices stable if a later
        // nested lookup changes the buffer length.
        foreach_reverse (i; 0 .. count)
        {
            if (glyphs.length == 0) return;
            const record = records + i * 4;
            const sequenceIndex = u16(table, record);
            const lookupIndex = u16(table, record + 2);
            if (sequenceIndex >= positions.length) continue;
            const position = min(positions[sequenceIndex], glyphs.length - 1);
            const nested = lookupHeader(table, lookupList, lookupIndex);
            applyGsubAt(table, lookupList, nested, position, featureTag,
                glyphs, depth + 1);
        }
    }

    private bool reverseSubstitution(const(ubyte)[] table, size_t subtable,
        const(LookupHeader) header, size_t position, ref ShapedGlyph[] glyphs)
    {
        if (u16(table, subtable) != 1) return false;
        size_t cursor = subtable + 2;
        const coverage = checkedOffset(table, subtable, u16(table, cursor));
        cursor += 2;
        const index = coverageIndex(table, coverage, glyphs[position].glyphIndex);
        if (index < 0) return false;
        const backtrackCount = u16(table, cursor);
        cursor += 2;
        ptrdiff_t before = position;
        foreach (i; 0 .. backtrackCount)
        {
            before = nextEligible(glyphs, before, -1, gdef, header.flags,
                header.markFilteringSet);
            if (before < 0) return false;
            const test = checkedOffset(table, subtable, u16(table, cursor + i * 2));
            if (coverageIndex(table, test,
                glyphs[cast(size_t) before].glyphIndex) < 0) return false;
        }
        cursor += cast(size_t) backtrackCount * 2;
        const lookaheadCount = u16(table, cursor);
        cursor += 2;
        ptrdiff_t after = position;
        foreach (i; 0 .. lookaheadCount)
        {
            after = nextEligible(glyphs, after, 1, gdef, header.flags,
                header.markFilteringSet);
            if (after < 0) return false;
            const test = checkedOffset(table, subtable, u16(table, cursor + i * 2));
            if (coverageIndex(table, test,
                glyphs[cast(size_t) after].glyphIndex) < 0) return false;
        }
        cursor += cast(size_t) lookaheadCount * 2;
        const glyphCount = u16(table, cursor);
        cursor += 2;
        if (index >= glyphCount) return false;
        glyphs[position].glyphIndex = u16(table, cursor + cast(size_t) index * 2);
        return true;
    }

    private bool applyGpos(ref ShapedGlyph[] glyphs, ShapeOptions options)
    {
        const table = face.tableData(GposTag);
        if (table.length < 10) return false;
        uint[] policy = [fontTag("curs")];
        if (options.enableKerning) policy ~= fontTag("kern");
        if (options.enableMarkPositioning)
        {
            policy ~= fontTag("mark");
            policy ~= fontTag("mkmk");
            policy ~= fontTag("abvm");
            policy ~= fontTag("blwm");
        }
        policy ~= fontTag("dist");
        const features = selectFeatures(table, openTypeScriptTag(options.script),
            options.languageTag, policy);
        const lookupList = checkedOffset(table, 0, u16(table, 8));
        bool usedKern;
        foreach (feature; features)
        {
            if (feature.tag == fontTag("kern")) usedKern = true;
            foreach (lookup; feature.lookups)
                applyGposLookup(table, lookupList, lookup, glyphs,
                    options.pixelSize, options.rightToLeft, 0);
        }
        return usedKern;
    }

    private void applyGposLookup(const(ubyte)[] table, size_t lookupList,
        ushort lookupIndex, ref ShapedGlyph[] glyphs, int pixelSize,
        bool rtl, int depth)
    {
        if (depth > 12) return;
        const header = lookupHeader(table, lookupList, lookupIndex);
        if (header.type == 0) return;
        foreach (position; 0 .. glyphs.length)
            applyGposAt(table, lookupList, header, position, glyphs,
                pixelSize, rtl, depth);
    }

    private bool applyGposAt(const(ubyte)[] table, size_t lookupList,
        const(LookupHeader) header, size_t position, ref ShapedGlyph[] glyphs,
        int pixelSize, bool rtl, int depth)
    {
        if (depth > 12 || position >= glyphs.length ||
            ignoredGlyph(gdef, glyphs[position], header.flags,
                header.markFilteringSet)) return false;
        foreach (subtable; header.subtables)
        {
            ushort type = header.type;
            size_t actual = subtable;
            if (type == 9)
            {
                if (u16(table, subtable) != 1) continue;
                type = u16(table, subtable + 2);
                actual = checkedOffset(table, subtable, u32(table, subtable + 4));
            }
            bool matched;
            switch (type)
            {
                case 1: matched = singlePosition(table, actual, position,
                    glyphs, pixelSize); break;
                case 2: matched = pairPosition(table, actual, header,
                    position, glyphs, pixelSize); break;
                case 3: matched = cursivePosition(table, actual, header,
                    position, glyphs, pixelSize, rtl); break;
                case 4: matched = markToBasePosition(table, actual, header,
                    position, glyphs, pixelSize); break;
                case 5: matched = markToLigaturePosition(table, actual,
                    header, position, glyphs, pixelSize); break;
                case 6: matched = markToMarkPosition(table, actual, header,
                    position, glyphs, pixelSize); break;
                case 7: matched = contextPosition(table, lookupList, actual,
                    header, position, glyphs, pixelSize, rtl, depth); break;
                case 8: matched = chainPosition(table, lookupList, actual,
                    header, position, glyphs, pixelSize, rtl, depth); break;
                default: break;
            }
            if (matched) return true;
        }
        return false;
    }

    private bool contextPosition(const(ubyte)[] table, size_t lookupList,
        size_t subtable, const(LookupHeader) header, size_t position,
        ref ShapedGlyph[] glyphs, int pixelSize, bool rtl, int depth)
    {
        const format = u16(table, subtable);
        if (format == 1)
        {
            const coverage = checkedOffset(table, subtable,
                u16(table, subtable + 2));
            const coveragePosition = coverageIndex(table, coverage,
                glyphs[position].glyphIndex);
            const setCount = u16(table, subtable + 4);
            if (coveragePosition < 0 || coveragePosition >= setCount) return false;
            const relative = u16(table, subtable + 6 +
                cast(size_t) coveragePosition * 2);
            if (relative == 0) return false;
            const set = checkedOffset(table, subtable, relative);
            const ruleCount = u16(table, set);
            foreach (ruleIndex; 0 .. ruleCount)
            {
                const rule = checkedOffset(table, set,
                    u16(table, set + 2 + ruleIndex * 2));
                const glyphCount = u16(table, rule);
                const recordCount = u16(table, rule + 2);
                if (glyphCount == 0) continue;
                size_t[] positions = [position];
                ptrdiff_t cursor = position;
                bool match = true;
                foreach (i; 1 .. glyphCount)
                {
                    cursor = nextEligible(glyphs, cursor, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (cursor < 0 || glyphs[cast(size_t) cursor].glyphIndex !=
                        u16(table, rule + 4 + cast(size_t) (i - 1) * 2))
                    {
                        match = false;
                        break;
                    }
                    positions ~= cast(size_t) cursor;
                }
                if (!match) continue;
                const records = rule + 4 + cast(size_t) (glyphCount - 1) * 2;
                applyPositionRecords(table, lookupList, records, recordCount,
                    positions, glyphs, pixelSize, rtl, depth);
                return true;
            }
            return false;
        }
        if (format == 2)
        {
            const coverage = checkedOffset(table, subtable,
                u16(table, subtable + 2));
            if (coverageIndex(table, coverage, glyphs[position].glyphIndex) < 0)
                return false;
            const classDef = checkedOffset(table, subtable,
                u16(table, subtable + 4));
            const setCount = u16(table, subtable + 6);
            const firstClass = classValue(table, classDef,
                glyphs[position].glyphIndex);
            if (firstClass >= setCount) return false;
            const relative = u16(table, subtable + 8 +
                cast(size_t) firstClass * 2);
            if (relative == 0) return false;
            const set = checkedOffset(table, subtable, relative);
            const ruleCount = u16(table, set);
            foreach (ruleIndex; 0 .. ruleCount)
            {
                const rule = checkedOffset(table, set,
                    u16(table, set + 2 + ruleIndex * 2));
                const glyphCount = u16(table, rule);
                const recordCount = u16(table, rule + 2);
                if (glyphCount == 0) continue;
                size_t[] positions = [position];
                ptrdiff_t cursor = position;
                bool match = true;
                foreach (i; 1 .. glyphCount)
                {
                    cursor = nextEligible(glyphs, cursor, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (cursor < 0 || classValue(table, classDef,
                        glyphs[cast(size_t) cursor].glyphIndex) !=
                        u16(table, rule + 4 + cast(size_t) (i - 1) * 2))
                    {
                        match = false;
                        break;
                    }
                    positions ~= cast(size_t) cursor;
                }
                if (!match) continue;
                const records = rule + 4 + cast(size_t) (glyphCount - 1) * 2;
                applyPositionRecords(table, lookupList, records, recordCount,
                    positions, glyphs, pixelSize, rtl, depth);
                return true;
            }
            return false;
        }
        if (format == 3)
        {
            const glyphCount = u16(table, subtable + 2);
            const recordCount = u16(table, subtable + 4);
            if (glyphCount == 0) return false;
            size_t[] positions = [position];
            ptrdiff_t cursor = position;
            foreach (i; 0 .. glyphCount)
            {
                if (i > 0)
                {
                    cursor = nextEligible(glyphs, cursor, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (cursor < 0) return false;
                    positions ~= cast(size_t) cursor;
                }
                const coverage = checkedOffset(table, subtable,
                    u16(table, subtable + 6 + i * 2));
                if (coverageIndex(table, coverage,
                    glyphs[positions[i]].glyphIndex) < 0) return false;
            }
            const records = subtable + 6 + cast(size_t) glyphCount * 2;
            applyPositionRecords(table, lookupList, records, recordCount,
                positions, glyphs, pixelSize, rtl, depth);
            return true;
        }
        return false;
    }

    private bool chainPosition(const(ubyte)[] table, size_t lookupList,
        size_t subtable, const(LookupHeader) header, size_t position,
        ref ShapedGlyph[] glyphs, int pixelSize, bool rtl, int depth)
    {
        const format = u16(table, subtable);
        if (format == 1)
        {
            const coverage = checkedOffset(table, subtable,
                u16(table, subtable + 2));
            const coveragePosition = coverageIndex(table, coverage,
                glyphs[position].glyphIndex);
            const setCount = u16(table, subtable + 4);
            if (coveragePosition < 0 || coveragePosition >= setCount) return false;
            const relative = u16(table, subtable + 6 +
                cast(size_t) coveragePosition * 2);
            if (relative == 0) return false;
            const set = checkedOffset(table, subtable, relative);
            const ruleCount = u16(table, set);
            foreach (ruleIndex; 0 .. ruleCount)
            {
                const rule = checkedOffset(table, set,
                    u16(table, set + 2 + ruleIndex * 2));
                size_t cursorOffset = rule;
                const backtrackCount = u16(table, cursorOffset);
                cursorOffset += 2;
                ptrdiff_t before = position;
                bool match = true;
                foreach (i; 0 .. backtrackCount)
                {
                    before = nextEligible(glyphs, before, -1, gdef,
                        header.flags, header.markFilteringSet);
                    if (before < 0 || glyphs[cast(size_t) before].glyphIndex !=
                        u16(table, cursorOffset + i * 2))
                    { match = false; break; }
                }
                cursorOffset += cast(size_t) backtrackCount * 2;
                if (!match) continue;
                const inputCount = u16(table, cursorOffset);
                cursorOffset += 2;
                if (inputCount == 0) continue;
                size_t[] positions = [position];
                ptrdiff_t current = position;
                foreach (i; 1 .. inputCount)
                {
                    current = nextEligible(glyphs, current, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (current < 0 || glyphs[cast(size_t) current].glyphIndex !=
                        u16(table, cursorOffset + cast(size_t) (i - 1) * 2))
                    { match = false; break; }
                    positions ~= cast(size_t) current;
                }
                cursorOffset += cast(size_t) (inputCount - 1) * 2;
                if (!match) continue;
                const lookaheadCount = u16(table, cursorOffset);
                cursorOffset += 2;
                ptrdiff_t after = current;
                foreach (i; 0 .. lookaheadCount)
                {
                    after = nextEligible(glyphs, after, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (after < 0 || glyphs[cast(size_t) after].glyphIndex !=
                        u16(table, cursorOffset + i * 2))
                    { match = false; break; }
                }
                cursorOffset += cast(size_t) lookaheadCount * 2;
                if (!match) continue;
                const recordCount = u16(table, cursorOffset);
                cursorOffset += 2;
                applyPositionRecords(table, lookupList, cursorOffset,
                    recordCount, positions, glyphs, pixelSize, rtl, depth);
                return true;
            }
            return false;
        }
        if (format == 2)
        {
            const coverage = checkedOffset(table, subtable,
                u16(table, subtable + 2));
            if (coverageIndex(table, coverage, glyphs[position].glyphIndex) < 0)
                return false;
            const backtrackClassDef = checkedOffset(table, subtable,
                u16(table, subtable + 4));
            const inputClassDef = checkedOffset(table, subtable,
                u16(table, subtable + 6));
            const lookaheadClassDef = checkedOffset(table, subtable,
                u16(table, subtable + 8));
            const setCount = u16(table, subtable + 10);
            const firstClass = classValue(table, inputClassDef,
                glyphs[position].glyphIndex);
            if (firstClass >= setCount) return false;
            const relative = u16(table, subtable + 12 +
                cast(size_t) firstClass * 2);
            if (relative == 0) return false;
            const set = checkedOffset(table, subtable, relative);
            const ruleCount = u16(table, set);
            foreach (ruleIndex; 0 .. ruleCount)
            {
                const rule = checkedOffset(table, set,
                    u16(table, set + 2 + ruleIndex * 2));
                size_t cursorOffset = rule;
                const backtrackCount = u16(table, cursorOffset);
                cursorOffset += 2;
                ptrdiff_t before = position;
                bool match = true;
                foreach (i; 0 .. backtrackCount)
                {
                    before = nextEligible(glyphs, before, -1, gdef,
                        header.flags, header.markFilteringSet);
                    if (before < 0 || classValue(table, backtrackClassDef,
                        glyphs[cast(size_t) before].glyphIndex) !=
                        u16(table, cursorOffset + i * 2))
                    { match = false; break; }
                }
                cursorOffset += cast(size_t) backtrackCount * 2;
                if (!match) continue;
                const inputCount = u16(table, cursorOffset);
                cursorOffset += 2;
                if (inputCount == 0) continue;
                size_t[] positions = [position];
                ptrdiff_t current = position;
                foreach (i; 1 .. inputCount)
                {
                    current = nextEligible(glyphs, current, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (current < 0 || classValue(table, inputClassDef,
                        glyphs[cast(size_t) current].glyphIndex) !=
                        u16(table, cursorOffset + cast(size_t) (i - 1) * 2))
                    { match = false; break; }
                    positions ~= cast(size_t) current;
                }
                cursorOffset += cast(size_t) (inputCount - 1) * 2;
                if (!match) continue;
                const lookaheadCount = u16(table, cursorOffset);
                cursorOffset += 2;
                ptrdiff_t after = current;
                foreach (i; 0 .. lookaheadCount)
                {
                    after = nextEligible(glyphs, after, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (after < 0 || classValue(table, lookaheadClassDef,
                        glyphs[cast(size_t) after].glyphIndex) !=
                        u16(table, cursorOffset + i * 2))
                    { match = false; break; }
                }
                cursorOffset += cast(size_t) lookaheadCount * 2;
                if (!match) continue;
                const recordCount = u16(table, cursorOffset);
                cursorOffset += 2;
                applyPositionRecords(table, lookupList, cursorOffset,
                    recordCount, positions, glyphs, pixelSize, rtl, depth);
                return true;
            }
            return false;
        }
        if (format == 3)
        {
            size_t cursorOffset = subtable + 2;
            const backtrackCount = u16(table, cursorOffset);
            cursorOffset += 2;
            ptrdiff_t before = position;
            foreach (i; 0 .. backtrackCount)
            {
                before = nextEligible(glyphs, before, -1, gdef,
                    header.flags, header.markFilteringSet);
                if (before < 0) return false;
                const coverage = checkedOffset(table, subtable,
                    u16(table, cursorOffset + i * 2));
                if (coverageIndex(table, coverage,
                    glyphs[cast(size_t) before].glyphIndex) < 0) return false;
            }
            cursorOffset += cast(size_t) backtrackCount * 2;
            const inputCount = u16(table, cursorOffset);
            cursorOffset += 2;
            if (inputCount == 0) return false;
            size_t[] positions = [position];
            ptrdiff_t current = position;
            foreach (i; 0 .. inputCount)
            {
                if (i > 0)
                {
                    current = nextEligible(glyphs, current, 1, gdef,
                        header.flags, header.markFilteringSet);
                    if (current < 0) return false;
                    positions ~= cast(size_t) current;
                }
                const coverage = checkedOffset(table, subtable,
                    u16(table, cursorOffset + i * 2));
                if (coverageIndex(table, coverage,
                    glyphs[positions[i]].glyphIndex) < 0) return false;
            }
            cursorOffset += cast(size_t) inputCount * 2;
            const lookaheadCount = u16(table, cursorOffset);
            cursorOffset += 2;
            ptrdiff_t after = current;
            foreach (i; 0 .. lookaheadCount)
            {
                after = nextEligible(glyphs, after, 1, gdef,
                    header.flags, header.markFilteringSet);
                if (after < 0) return false;
                const coverage = checkedOffset(table, subtable,
                    u16(table, cursorOffset + i * 2));
                if (coverageIndex(table, coverage,
                    glyphs[cast(size_t) after].glyphIndex) < 0) return false;
            }
            cursorOffset += cast(size_t) lookaheadCount * 2;
            const recordCount = u16(table, cursorOffset);
            cursorOffset += 2;
            applyPositionRecords(table, lookupList, cursorOffset, recordCount,
                positions, glyphs, pixelSize, rtl, depth);
            return true;
        }
        return false;
    }

    private void applyPositionRecords(const(ubyte)[] table, size_t lookupList,
        size_t records, size_t count, const(size_t)[] positions,
        ref ShapedGlyph[] glyphs, int pixelSize, bool rtl, int depth)
    {
        foreach (i; 0 .. count)
        {
            const record = records + i * 4;
            const sequenceIndex = u16(table, record);
            const lookupIndex = u16(table, record + 2);
            if (sequenceIndex >= positions.length) continue;
            const nested = lookupHeader(table, lookupList, lookupIndex);
            applyGposAt(table, lookupList, nested, positions[sequenceIndex],
                glyphs, pixelSize, rtl, depth + 1);
        }
    }

    private struct ValueRecord
    {
        int xPlacement;
        int yPlacement;
        int xAdvance;
        int yAdvance;
    }

    private static size_t valueRecordSize(ushort format) @safe pure nothrow @nogc
    {
        size_t count;
        foreach (bit; 0 .. 8)
            if ((format & (1 << bit)) != 0) ++count;
        return count * 2;
    }

    private ValueRecord readValue(const(ubyte)[] table, size_t offset,
        ushort format, int pixelSize)
    {
        ValueRecord result;
        size_t cursor = offset;
        if (format & 0x0001) { result.xPlacement = face.scaleUnits(s16(table, cursor), pixelSize); cursor += 2; }
        if (format & 0x0002) { result.yPlacement = face.scaleUnits(s16(table, cursor), pixelSize); cursor += 2; }
        if (format & 0x0004) { result.xAdvance = face.scaleUnits(s16(table, cursor), pixelSize); cursor += 2; }
        if (format & 0x0008) { result.yAdvance = face.scaleUnits(s16(table, cursor), pixelSize); cursor += 2; }
        // Device/variation-index offsets are present in the record but static
        // rendering at integer ppem deliberately ignores their deltas.
        return result;
    }

    private static void applyValue(ref ShapedGlyph glyph, ValueRecord value)
    {
        glyph.offsetX += value.xPlacement;
        glyph.offsetY += value.yPlacement;
        glyph.advanceX += value.xAdvance;
        glyph.advanceY += value.yAdvance;
    }

    private bool singlePosition(const(ubyte)[] table, size_t subtable,
        size_t position, ref ShapedGlyph[] glyphs, int pixelSize)
    {
        const format = u16(table, subtable);
        const coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const index = coverageIndex(table, coverage, glyphs[position].glyphIndex);
        if (index < 0) return false;
        const valueFormat = u16(table, subtable + 4);
        if (format == 1)
            applyValue(glyphs[position], readValue(table, subtable + 6,
                valueFormat, pixelSize));
        else if (format == 2)
        {
            const count = u16(table, subtable + 6);
            if (index >= count) return false;
            const record = subtable + 8 + cast(size_t) index * valueRecordSize(valueFormat);
            applyValue(glyphs[position], readValue(table, record,
                valueFormat, pixelSize));
        }
        else return false;
        return true;
    }

    private bool pairPosition(const(ubyte)[] table, size_t subtable,
        const(LookupHeader) header, size_t position, ref ShapedGlyph[] glyphs,
        int pixelSize)
    {
        const format = u16(table, subtable);
        const coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const coveragePosition = coverageIndex(table, coverage,
            glyphs[position].glyphIndex);
        if (coveragePosition < 0) return false;
        const secondPosition = nextEligible(glyphs, position, 1, gdef,
            header.flags, header.markFilteringSet);
        if (secondPosition < 0) return false;
        const valueFormat1 = u16(table, subtable + 4);
        const valueFormat2 = u16(table, subtable + 6);
        const size1 = valueRecordSize(valueFormat1);
        const size2 = valueRecordSize(valueFormat2);
        if (format == 1)
        {
            const setCount = u16(table, subtable + 8);
            if (coveragePosition >= setCount) return false;
            const set = checkedOffset(table, subtable,
                u16(table, subtable + 10 + cast(size_t) coveragePosition * 2));
            const pairCount = u16(table, set);
            size_t low;
            size_t high = pairCount;
            const recordSize = 2 + size1 + size2;
            while (low < high)
            {
                const middle = low + (high - low) / 2;
                const record = set + 2 + middle * recordSize;
                const second = u16(table, record);
                if (glyphs[cast(size_t) secondPosition].glyphIndex < second) high = middle;
                else if (glyphs[cast(size_t) secondPosition].glyphIndex > second) low = middle + 1;
                else
                {
                    applyValue(glyphs[position], readValue(table, record + 2,
                        valueFormat1, pixelSize));
                    applyValue(glyphs[cast(size_t) secondPosition], readValue(table,
                        record + 2 + size1, valueFormat2, pixelSize));
                    return true;
                }
            }
            return false;
        }
        if (format == 2)
        {
            const classDef1 = checkedOffset(table, subtable, u16(table, subtable + 8));
            const classDef2 = checkedOffset(table, subtable, u16(table, subtable + 10));
            const class1Count = u16(table, subtable + 12);
            const class2Count = u16(table, subtable + 14);
            const class1 = classValue(table, classDef1, glyphs[position].glyphIndex);
            const class2 = classValue(table, classDef2,
                glyphs[cast(size_t) secondPosition].glyphIndex);
            if (class1 >= class1Count || class2 >= class2Count) return false;
            const record = subtable + 16 +
                (cast(size_t) class1 * class2Count + class2) * (size1 + size2);
            applyValue(glyphs[position], readValue(table, record,
                valueFormat1, pixelSize));
            applyValue(glyphs[cast(size_t) secondPosition], readValue(table,
                record + size1, valueFormat2, pixelSize));
            return true;
        }
        return false;
    }

    private struct Anchor
    {
        double x = 0.0;
        double y = 0.0;
        bool present;
    }

    private Anchor readAnchor(const(ubyte)[] table, size_t base,
        ushort relative, int pixelSize)
    {
        Anchor result;
        if (relative == 0) return result;
        const offset = checkedOffset(table, base, relative);
        const format = u16(table, offset);
        if (format < 1 || format > 3) return result;
        result.x = face.unitsToPixels(s16(table, offset + 2), pixelSize);
        result.y = face.unitsToPixels(s16(table, offset + 4), pixelSize);
        result.present = true;
        return result;
    }

    private double originDistance(const(ShapedGlyph)[] glyphs,
        size_t from, size_t to) const
    {
        double result = 0.0;
        if (from < to)
            foreach (i; from .. to) result += glyphs[i].advanceX;
        else
            foreach (i; to .. from) result -= glyphs[i].advanceX;
        return result;
    }

    private bool cursivePosition(const(ubyte)[] table, size_t subtable,
        const(LookupHeader) header, size_t position, ref ShapedGlyph[] glyphs,
        int pixelSize, bool rtl)
    {
        if (u16(table, subtable) != 1) return false;
        const coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const index = coverageIndex(table, coverage, glyphs[position].glyphIndex);
        const count = u16(table, subtable + 4);
        if (index < 0 || index >= count) return false;
        const neighbor = nextEligible(glyphs, position, rtl ? -1 : 1, gdef,
            header.flags, header.markFilteringSet);
        if (neighbor < 0) return false;
        const neighborIndex = coverageIndex(table, coverage,
            glyphs[cast(size_t) neighbor].glyphIndex);
        if (neighborIndex < 0 || neighborIndex >= count) return false;
        const currentRecord = subtable + 6 + cast(size_t) index * 4;
        const neighborRecord = subtable + 6 + cast(size_t) neighborIndex * 4;
        const exitAnchor = readAnchor(table, subtable,
            u16(table, currentRecord + 2), pixelSize);
        const entryAnchor = readAnchor(table, subtable,
            u16(table, neighborRecord), pixelSize);
        if (!exitAnchor.present || !entryAnchor.present) return false;
        const distance = originDistance(glyphs, position, cast(size_t) neighbor);
        glyphs[cast(size_t) neighbor].offsetX += exitAnchor.x - entryAnchor.x - distance;
        glyphs[cast(size_t) neighbor].offsetY += exitAnchor.y - entryAnchor.y;
        return true;
    }

    private bool markToBasePosition(const(ubyte)[] table, size_t subtable,
        const(LookupHeader) header, size_t position, ref ShapedGlyph[] glyphs,
        int pixelSize)
    {
        if (u16(table, subtable) != 1) return false;
        const markCoverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const markIndex = coverageIndex(table, markCoverage, glyphs[position].glyphIndex);
        if (markIndex < 0) return false;
        ptrdiff_t basePosition = position;
        do
            basePosition = nextEligible(glyphs, basePosition, -1, gdef,
                cast(ushort) (header.flags | 0x0008), header.markFilteringSet);
        while (basePosition >= 0 && gdef !is null &&
            gdef.glyphClass(glyphs[cast(size_t) basePosition].glyphIndex) == 3);
        if (basePosition < 0) return false;
        const baseCoverage = checkedOffset(table, subtable, u16(table, subtable + 4));
        const baseIndex = coverageIndex(table, baseCoverage,
            glyphs[cast(size_t) basePosition].glyphIndex);
        if (baseIndex < 0) return false;
        const classCount = u16(table, subtable + 6);
        const markArray = checkedOffset(table, subtable, u16(table, subtable + 8));
        const baseArray = checkedOffset(table, subtable, u16(table, subtable + 10));
        const markCount = u16(table, markArray);
        if (markIndex >= markCount) return false;
        const markRecord = markArray + 2 + cast(size_t) markIndex * 4;
        const markClass = u16(table, markRecord);
        if (markClass >= classCount) return false;
        const markAnchor = readAnchor(table, markArray, u16(table, markRecord + 2), pixelSize);
        const baseCount = u16(table, baseArray);
        if (baseIndex >= baseCount) return false;
        const baseRecord = baseArray + 2 +
            (cast(size_t) baseIndex * classCount + markClass) * 2;
        const baseAnchor = readAnchor(table, baseArray, u16(table, baseRecord), pixelSize);
        if (!markAnchor.present || !baseAnchor.present) return false;
        glyphs[position].offsetX += originDistance(glyphs, position,
            cast(size_t) basePosition) + baseAnchor.x - markAnchor.x;
        glyphs[position].offsetY += baseAnchor.y - markAnchor.y;
        return true;
    }

    private bool markToLigaturePosition(const(ubyte)[] table, size_t subtable,
        const(LookupHeader) header, size_t position, ref ShapedGlyph[] glyphs,
        int pixelSize)
    {
        if (u16(table, subtable) != 1) return false;
        const markCoverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const markIndex = coverageIndex(table, markCoverage, glyphs[position].glyphIndex);
        if (markIndex < 0) return false;
        ptrdiff_t ligaturePosition = position;
        do
            ligaturePosition = nextEligible(glyphs, ligaturePosition, -1, gdef,
                cast(ushort) (header.flags | 0x0008), header.markFilteringSet);
        while (ligaturePosition >= 0 && !glyphs[cast(size_t) ligaturePosition].isLigature);
        if (ligaturePosition < 0) return false;
        const ligCoverage = checkedOffset(table, subtable, u16(table, subtable + 4));
        const ligIndex = coverageIndex(table, ligCoverage,
            glyphs[cast(size_t) ligaturePosition].glyphIndex);
        if (ligIndex < 0) return false;
        const classCount = u16(table, subtable + 6);
        const markArray = checkedOffset(table, subtable, u16(table, subtable + 8));
        const ligArray = checkedOffset(table, subtable, u16(table, subtable + 10));
        const markRecord = markArray + 2 + cast(size_t) markIndex * 4;
        const markClass = u16(table, markRecord);
        if (markClass >= classCount) return false;
        const markAnchor = readAnchor(table, markArray, u16(table, markRecord + 2), pixelSize);
        const ligCount = u16(table, ligArray);
        if (ligIndex >= ligCount) return false;
        const attach = checkedOffset(table, ligArray,
            u16(table, ligArray + 2 + cast(size_t) ligIndex * 2));
        const componentCount = u16(table, attach);
        if (componentCount == 0) return false;
        const component = componentCount - 1;
        const anchorOffset = attach + 2 +
            (cast(size_t) component * classCount + markClass) * 2;
        const ligAnchor = readAnchor(table, attach, u16(table, anchorOffset), pixelSize);
        if (!markAnchor.present || !ligAnchor.present) return false;
        glyphs[position].offsetX += originDistance(glyphs, position,
            cast(size_t) ligaturePosition) + ligAnchor.x - markAnchor.x;
        glyphs[position].offsetY += ligAnchor.y - markAnchor.y;
        return true;
    }

    private bool markToMarkPosition(const(ubyte)[] table, size_t subtable,
        const(LookupHeader) header, size_t position, ref ShapedGlyph[] glyphs,
        int pixelSize)
    {
        if (u16(table, subtable) != 1) return false;
        const mark1Coverage = checkedOffset(table, subtable, u16(table, subtable + 2));
        const mark1Index = coverageIndex(table, mark1Coverage,
            glyphs[position].glyphIndex);
        if (mark1Index < 0) return false;
        const mark2Position = nextEligible(glyphs, position, -1, gdef,
            cast(ushort) (header.flags & ~0x0008), header.markFilteringSet);
        if (mark2Position < 0) return false;
        const mark2Coverage = checkedOffset(table, subtable, u16(table, subtable + 4));
        const mark2Index = coverageIndex(table, mark2Coverage,
            glyphs[cast(size_t) mark2Position].glyphIndex);
        if (mark2Index < 0) return false;
        const classCount = u16(table, subtable + 6);
        const mark1Array = checkedOffset(table, subtable, u16(table, subtable + 8));
        const mark2Array = checkedOffset(table, subtable, u16(table, subtable + 10));
        const mark1Record = mark1Array + 2 + cast(size_t) mark1Index * 4;
        const markClass = u16(table, mark1Record);
        if (markClass >= classCount) return false;
        const mark1Anchor = readAnchor(table, mark1Array,
            u16(table, mark1Record + 2), pixelSize);
        const mark2Count = u16(table, mark2Array);
        if (mark2Index >= mark2Count) return false;
        const mark2Record = mark2Array + 2 +
            (cast(size_t) mark2Index * classCount + markClass) * 2;
        const mark2Anchor = readAnchor(table, mark2Array,
            u16(table, mark2Record), pixelSize);
        if (!mark1Anchor.present || !mark2Anchor.present) return false;
        glyphs[position].offsetX += originDistance(glyphs, position,
            cast(size_t) mark2Position) + mark2Anchor.x - mark1Anchor.x;
        glyphs[position].offsetY += mark2Anchor.y - mark1Anchor.y;
        return true;
    }

    private void applyLegacyKerning(ref ShapedGlyph[] glyphs, int pixelSize)
    {
        uint previous;
        ptrdiff_t previousPosition = -1;
        foreach (i; 0 .. glyphs.length)
        {
            if (glyphs[i].hidden) continue;
            if (previousPosition >= 0)
                glyphs[cast(size_t) previousPosition].advanceX +=
                    face.kerning(previous, glyphs[i].glyphIndex, pixelSize);
            previous = glyphs[i].glyphIndex;
            previousPosition = cast(ptrdiff_t) i;
        }
    }
}

unittest
{
    assert(fontTag("GSUB") == GsubTag);
    assert(fontTag("latn") == 0x6C61746E);
}
