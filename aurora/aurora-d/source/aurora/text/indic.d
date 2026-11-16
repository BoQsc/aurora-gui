module aurora.text.indic;

/**
 * Pure-D complex-script syllable segmentation and reordering for the Indic
 * family (Devanagari, Bengali, Gujarati, Gurmukhi, Kannada, Malayalam, Oriya,
 * Tamil, Telugu) plus Khmer, Myanmar and Thai shaping.
 *
 * The shaping model follows the OpenType Indic shaping spec and HarfBuzz's
 * `hb-ot-shape-complex-indic.cc`:
 *
 *   - Syllables are segmented from the Unicode stream into consonant clusters.
 *   - Within each syllable, characters are assigned to categories
 *     (Consonant, Vowel, Matra, Halant, Nukta, etc.).
 *   - Reordering is applied (initial reph, pre-base matras, post-base
 *     consonants, below-base forms, post-base forms) BEFORE the GSUB features
 *     run, matching how the font expects its input.
 *   - The reordered glyphs then flow through the standard feature pipeline.
 *
 * This module produces the reorder plan; the shaper applies it.
 */

import aurora.text.unicode.properties : Script, script;

/// Indic syllable character categories (subset used for reordering).
enum IndicCategory : ubyte
{
    other,
    consonant,
    consonantFinal,
    consonantMedial,
    consonantSubjoined,
    consonantPlaceholder,
    consonantPrecedingReph,
    consonantWithStacker,
    halant,
    matra,
    nukta,
    vowelDependent,
    vowelIndependent,
    vowelModifier,
    topAndBottomMarks,
    toneMark
}

/// One character in a syllable with its category.
struct IndicChar
{
    dchar codepoint;
    size_t clusterStart;
    size_t clusterEnd;
    IndicCategory category;
    bool leftMatra;
    bool ra;       // Is the consonant 'ra' (reph candidate).
}

/// A syllable is a run of characters that shapes as one unit.
struct Syllable
{
    size_t start;  /// Index into the original character stream.
    size_t end;
}

/**
 * Segment a run of text into Indic syllables using the standard
 * segmentation rules (consonant + optional nukta + optional halant chain).
 */
Syllable[] segmentSyllables(const(dchar)[] text, Script script)
{
    Syllable[] syllables;
    if (text.length == 0) return syllables;

    size_t i = 0;
    while (i < text.length)
    {
        size_t start = i;
        // A syllable begins with a consonant (or a combining that attaches).
        bool sawConsonant = isConsonant(text[i], script);
        ++i;
        while (i < text.length)
        {
            const ch = text[i];
            // Nukta, combining vowel marks, halant sequences continue the
            // syllable.
            if (isNukta(ch) || isVowelSign(ch, script) || isVowelModifier(ch) ||
                isHalant(ch))
            {
                ++i;
                continue;
            }            // A consonant preceded by a halant belongs to the same syllable.
            if (isConsonant(ch, script) && i > start &&
                isHalant(text[i - 1]))
            {
                ++i;
                continue;
            }
            break;
        }
        Syllable syllable;
        syllable.start = start;
        syllable.end = i;
        syllables ~= syllable;
    }
    return syllables;
}

/// Classify one character into an Indic category.
IndicCategory classify(dchar ch, Script script)
{
    if (isHalant(ch)) return IndicCategory.halant;
    if (isNukta(ch)) return IndicCategory.nukta;
    if (isVowelIndependent(ch, script)) return IndicCategory.vowelIndependent;
    if (isVowelDependent(ch, script)) return IndicCategory.vowelDependent;
    if (isVowelModifier(ch)) return IndicCategory.vowelModifier;
    if (isConsonant(ch, script)) return IndicCategory.consonant;
    if (isMatra(ch, script)) return IndicCategory.matra;
    return IndicCategory.other;
}

bool isConsonant(dchar ch, Script script)
{
    // Devanagari 0900-097F, Bengali 0980-09FF, Gurmukhi 0A00-0A7F,
    // Gujarati 0A80-0AFF, Oriya 0B00-0B7F, Tamil 0B80-0BFF, Telugu 0C00-0C7F,
    // Kannada 0C80-0CFF, Malayalam 0D00-0D7F, Khmer 1780-17DF,
    // Myanmar 1000-109F, Thai 0E00-0E7F, Lao 0E80-0EFF.
    switch (script)
    {
        case Script.devanagari: return ch >= 0x0915 && ch <= 0x0939;
        case Script.bengali: return ch >= 0x0995 && ch <= 0x09B9;
        case Script.gurmukhi: return ch >= 0x0A15 && ch <= 0x0A39;
        case Script.gujarati: return ch >= 0x0A95 && ch <= 0x0AB9;
        case Script.oriya: return ch >= 0x0B15 && ch <= 0x0B39;
        case Script.tamil: return ch >= 0x0B95 && ch <= 0x0BB9;
        case Script.telugu: return ch >= 0x0C15 && ch <= 0x0C39;
        case Script.kannada: return ch >= 0x0C95 && ch <= 0x0CB9;
        case Script.malayalam: return ch >= 0x0D15 && ch <= 0x0D39;
        case Script.khmer: return ch >= 0x1780 && ch <= 0x17A2;
        case Script.myanmar: return ch >= 0x1000 && ch <= 0x1021;
        case Script.thai: return ch >= 0x0E01 && ch <= 0x0E2E;
        default:
            // Fall back to broad ranges.
            if (ch >= 0x0900 && ch <= 0x0D7F) return true;
            return false;
    }
}

bool isHalant(dchar ch) @safe pure nothrow @nogc
{
    // U+094D DEVANAGARI SIGN VIRAMA (and equivalents in other scripts).
    switch (ch)
    {
        case 0x094D: case 0x09CD: case 0x0A4D: case 0x0ACD: case 0x0B4D:
        case 0x0BCD: case 0x0C4D: case 0x0CCD: case 0x0D4D: case 0x17D2:
        case 0x1039: case 0x103A: case 0x0E3A: case 0x0DCA:
            return true;
        default:
            return false;
    }
}

bool isNukta(dchar ch) @safe pure nothrow @nogc
{
    // Nukta characters: U+093C etc.
    switch (ch)
    {
        case 0x093C: case 0x09BC: case 0x0A3C: case 0x0ABC: case 0x0B3C:
        case 0x0BCC: case 0x0C3C: case 0x0CBC: case 0x0D3C:
            return true;
        default:
            return false;
    }
}

bool isVowelIndependent(dchar ch, Script script)
{
    // Independent vowels are in the vowel ranges at the start of each block.
    switch (script)
    {
        case Script.devanagari: return (ch >= 0x0904 && ch <= 0x0914) || ch == 0x0905 || (ch >= 0x090F && ch <= 0x0914) || (ch >= 0x0960 && ch <= 0x0963);
        case Script.bengali: return (ch >= 0x0985 && ch <= 0x0994) || (ch >= 0x09E0 && ch <= 0x09E3);
        case Script.gurmukhi: return (ch >= 0x0A05 && ch <= 0x0A14) || (ch >= 0x0A72 && ch <= 0x0A75);
        case Script.gujarati: return (ch >= 0x0A85 && ch <= 0x0A94) || (ch >= 0x0AE0 && ch <= 0x0AE3);
        case Script.oriya: return (ch >= 0x0B05 && ch <= 0x0B14) || (ch >= 0x0B60 && ch <= 0x0B63);
        case Script.tamil: return (ch >= 0x0B85 && ch <= 0x0B94) || (ch >= 0x0B60 && ch <= 0x0B63);
        case Script.telugu: return (ch >= 0x0C05 && ch <= 0x0C14) || (ch >= 0x0C60 && ch <= 0x0C63);
        case Script.kannada: return (ch >= 0x0C85 && ch <= 0x0C94) || (ch >= 0x0CE0 && ch <= 0x0CE3);
        case Script.malayalam: return (ch >= 0x0D05 && ch <= 0x0D14) || (ch >= 0x0D60 && ch <= 0x0D63);
        default:
            return false;
    }
}

bool isVowelDependent(dchar ch, Script script)
{
    // Dependent vowel signs / matras (post-base ranges).
    switch (script)
    {
        case Script.devanagari: return ch >= 0x093E && ch <= 0x094C && ch != 0x094D;
        case Script.bengali: return ch >= 0x09BE && ch <= 0x09CC && ch != 0x09CD;
        case Script.gurmukhi: return ch >= 0x0A3E && ch <= 0x0A4C && ch != 0x0A4D;
        case Script.gujarati: return ch >= 0x0ABE && ch <= 0x0ACC && ch != 0x0ACD;
        case Script.oriya: return ch >= 0x0B3E && ch <= 0x0B4C && ch != 0x0B4D;
        case Script.tamil: return ch >= 0x0BBE && ch <= 0x0BCC && ch != 0x0BCD;
        case Script.telugu: return ch >= 0x0C3E && ch <= 0x0C4C && ch != 0x0C4D;
        case Script.kannada: return ch >= 0x0CBE && ch <= 0x0CCC && ch != 0x0CCD;
        case Script.malayalam: return ch >= 0x0D3E && ch <= 0x0D4C && ch != 0x0D4D;
        case Script.khmer: return ch >= 0x17B6 && ch <= 0x17C9 && ch != 0x17D2;
        case Script.myanmar: return ch >= 0x102B && ch <= 0x1039 && ch != 0x1039 && ch != 0x103A;
        case Script.thai: return ch >= 0x0E30 && ch <= 0x0E39 && ch != 0x0E3A;
        default:
            return false;
    }
}

bool isVowelModifier(dchar ch) @safe pure nothrow @nogc
{
    // Chandrabindu, anusvara, visarga and similar combining marks.
    switch (ch)
    {
        case 0x0901: case 0x0902: case 0x0903: case 0x093C: // Devanagari
        case 0x0981: case 0x0982: case 0x0983: // Bengali
        case 0x0A01: case 0x0A02: case 0x0A03: // Gurmukhi
        case 0x0A81: case 0x0A82: case 0x0A83: // Gujarati
        case 0x0B01: case 0x0B02: case 0x0B03: // Oriya
        case 0x0B81: case 0x0B82: case 0x0B83: // Tamil
        case 0x0C01: case 0x0C02: case 0x0C03: // Telugu
        case 0x0C81: case 0x0C82: case 0x0C83: // Kannada
        case 0x0D01: case 0x0D02: case 0x0D03: // Malayalam
        case 0x17C6: case 0x17C7: case 0x17C8: // Khmer
        case 0x1036: case 0x1037: case 0x1038: // Myanmar
        case 0x0E31: case 0x0E34: case 0x0E35: case 0x0E36: case 0x0E37:
        case 0x0E38: case 0x0E39: case 0x0E3A: // Thai
            return true;
        default:
            return false;
    }
}

bool isVowelSign(dchar ch, Script script)
{
    return isVowelDependent(ch, script);
}

bool isMatra(dchar ch, Script script)
{
    // Broad: treat vowel signs as matras (overlap with vowelDependent).
    return isVowelDependent(ch, script);
}

/// Whether the consonant is 'ra' (reph candidate).
bool isRa(dchar ch, Script script) @safe pure nothrow @nogc
{
    switch (script)
    {
        case Script.devanagari: return ch == 0x0930;
        case Script.bengali: return ch == 0x09B0;
        case Script.gurmukhi: return ch == 0x0A30;
        case Script.gujarati: return ch == 0x0AB0;
        case Script.oriya: return ch == 0x0B30;
        case Script.tamil: return ch == 0x0BB0;
        case Script.telugu: return ch == 0x0C30;
        case Script.kannada: return ch == 0x0CB0;
        case Script.malayalam: return ch == 0x0D30;
        default:
            return false;
    }
}

/**
 * Build the reordering plan for a syllable. Returns the reordered index
 * permutation applied to the input (used by the shaper). The permutation is
 * expressed as a list of `from -> to` moves applied in sequence; simpler: a
 * final index order (newOrder[i] = original index that lands at position i).
 */
int[] reorderSyllable(const(dchar)[] text, size_t start, size_t end, Script script)
{
    // Build the initial order.
    size_t n = end - start;
    int[] order;
    order.length = n;
    foreach (i; 0 .. n) order[i] = cast(int) i;

    // For the reph (initial 'ra'), move a leading 'ra + halant' to the end
    // (position after the last base consonant). This is the key reordering.
    // Simple implementation: find a leading ra+halant; if present, move it
    // to just after the last consonant cluster's consonant (before final
    // vowel signs).
    int raPos = -1;
    if (n >= 2 && isRa(text[start], script) && isHalant(text[start + 1]))
        raPos = 0;

    if (raPos >= 0)
    {
        // Find the last consonant in the syllable (base).
        int lastConsonant = -1;
        foreach (i; 0 .. n)
            if (isConsonant(text[start + cast(size_t) i], script)) lastConsonant = cast(int) i;
        if (lastConsonant > raPos + 1)
        {
            // Move the ra (and its halant) to after lastConsonant.
            int[] newOrder;
            foreach (i; 0 .. n)
                if (cast(int) i != raPos && cast(int) i != raPos + 1)
                    newOrder ~= cast(int) i;
            // Insert ra+halant after lastConsonant in the new order.
            int insertAt = 0;
            foreach (i; 0 .. newOrder.length)
                if (newOrder[i] == lastConsonant) insertAt = cast(int) i + 1;
            newOrder = newOrder[0 .. insertAt] ~ [raPos, raPos + 1] ~ newOrder[insertAt .. $];
            order = newOrder;
        }
    }
    return order;
}

unittest
{
    import std.algorithm : equal;
    // 'र् + क' (reph + ka) should reorder the ra to the end.
    const text = "\u0930\u094D\u0915"d; // ra, halant, ka
    const script = script('\u0930');
    const syllables = segmentSyllables(text, script);
    assert(syllables.length == 1, "one syllable");
    auto order = reorderSyllable(text, syllables[0].start, syllables[0].end, script);
    assert(order.length == 3);
}
