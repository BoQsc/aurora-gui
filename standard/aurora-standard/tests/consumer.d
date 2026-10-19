module aurora_standard_consumer;

/**
 * Consumer acceptance test for the documented aurora-standard API.
 *
 * This file deliberately uses only the public modules and symbols described in
 * docs/api.md. If a consumer would need to read the implementation to use the
 * standard, this test is incomplete.
 */

import aurora.standard.text.unicode.bidi;
import aurora.standard.text.unicode.grapheme;
import aurora.standard.text.unicode.linebreak;
import aurora.standard.text.unicode.properties;

import std.stdio : writeln;

int main()
{
    assert(UnicodeDataVersion == "17.0.0");

    // Unicode property lookups.
    assert(graphemeBreak('a') == GraphemeBreak.other);
    assert(isExtendedPictographic(cast(dchar) 0x1F600));
    assert(bidiClass(cast(dchar) 0x05D0) == BidiClass.r);
    assert(lineBreakClass(' ') == LineBreakClass.sp);
    assert(script('A') == Script.latin);
    assert(generalCategory('A') == GeneralCategory.lu);
    assert(eastAsianWidth(cast(dchar) 0x4E00) == EastAsianWidth.w);
    assert(openTypeScriptTag(Script.latin) == 0x6C61746Eu);

    // Grapheme boundaries: "a" plus combining acute is one cluster.
    const acute = "a\u0301"d;
    const boundaries = graphemeBoundaries(acute);
    assert(boundaries.length == 2);
    assert(boundaries[0] == 0);
    assert(boundaries[1] == 2);
    assert(isGraphemeBoundary(acute, 0));
    assert(!isGraphemeBoundary(acute, 1));
    assert(isGraphemeBoundary(acute, 2));
    assert(previousGraphemeBoundary(acute, 2) == 0);
    assert(nextGraphemeBoundary(acute, 0) == 2);
    assert(floorGraphemeBoundary(acute, 1) == 0);
    assert(ceilGraphemeBoundary(acute, 1) == 2);

    // Line-break opportunities use one flag per code-point boundary.
    const latin = lineBreakOpportunities("hello world"d);
    assert(latin.length == 12);
    assert(!latin[0]);
    assert(latin[6]);
    assert(latin[$ - 1]);
    assert(mandatoryBreakAfter("a\n"d, 2));
    const empty = lineBreakOpportunities(""d);
    assert(empty.length == 1);
    assert(empty[0]);

    // Bidi result shape and visual ordering.
    const hebrew = resolveBidi("\u05D0\u05D1\u05D2"d);
    assert(hebrew.paragraphLevel == 1);
    assert(hebrew.levels.length == 3);
    assert(hebrew.visualOrder.length == 3);
    assert(hebrew.visualOrder[0] == 2);
    assert(hebrew.visualOrder[1] == 1);
    assert(hebrew.visualOrder[2] == 0);
    assert(!hebrew.removed(0));

    // Bidi mirroring and bracket metadata.
    assert(bidiMirror('(') == ')');
    const bracket = bidiBracket('(');
    assert(bracket.pair == ')');
    assert(bracket.kind == BidiBracketType.open);

    writeln("aurora-standard consumer: OK");
    return 0;
}
