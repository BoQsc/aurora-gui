module unicode_conformance;

/**
 * Full Unicode 17.0 conformance runner for Aurora's boundary and bidi code.
 *
 * The input files under tools/unicode/17.0.0 are unmodified official Unicode
 * test data and are covered by LICENSE-UNICODE.txt.
 */

import aurora.text.unicode.bidi : ParagraphDirection, resolveBidi;
import aurora.text.unicode.grapheme : graphemeBoundaries;
import aurora.text.unicode.linebreak : lineBreakOpportunities;

import std.algorithm : splitter;
import std.conv : to;
import std.path : buildPath;
import std.stdio : File, stderr, writefln, writeln;
import std.string : indexOf, startsWith, strip;

private struct Result
{
    size_t cases;
    size_t passed;
    size_t boundaries;
    size_t matchedBoundaries;

    bool successful() const @safe pure nothrow @nogc
    {
        return cases == passed && boundaries == matchedBoundaries;
    }
}

private ulong parseHex(const(char)[] token) @safe pure nothrow @nogc
{
    ulong value;
    foreach (ch; token)
    {
        if (ch >= '0' && ch <= '9') value = value * 16 + ch - '0';
        else if (ch >= 'A' && ch <= 'F') value = value * 16 + ch - 'A' + 10;
        else if (ch >= 'a' && ch <= 'f') value = value * 16 + ch - 'a' + 10;
    }
    return value;
}

private const(char)[] withoutComment(const(char)[] raw)
{
    const comment = raw.indexOf('#');
    return strip(comment >= 0 ? raw[0 .. cast(size_t) comment] : raw);
}

private Result testBreakFile(string path, bool grapheme)
{
    auto input = File(path, "r");
    char[] buffer;
    Result result;
    size_t shown;
    while (input.readln(buffer))
    {
        const line = withoutComment(buffer);
        if (line.length == 0) continue;

        dchar[] text;
        bool[] expected;
        size_t boundary;
        foreach (token; line.splitter())
        {
            if (token == "÷")
            {
                if (expected.length <= boundary) expected.length = boundary + 1;
                expected[boundary] = true;
            }
            else if (token == "×")
            {
                if (expected.length <= boundary) expected.length = boundary + 1;
                expected[boundary] = false;
            }
            else
            {
                text ~= cast(dchar) parseHex(token);
                ++boundary;
            }
        }
        expected.length = text.length + 1;

        bool[] actual;
        if (grapheme)
        {
            actual.length = text.length + 1;
            foreach (position; graphemeBoundaries(text)) actual[position] = true;
        }
        else
            actual = lineBreakOpportunities(text);

        ++result.cases;
        result.boundaries += expected.length;
        bool passed = actual.length == expected.length;
        foreach (i; 0 .. expected.length)
        {
            if (i < actual.length && actual[i] == expected[i])
                ++result.matchedBoundaries;
            else
                passed = false;
        }
        if (passed)
            ++result.passed;
        else if (shown++ < 12)
            stderr.writefln("%s: break mismatch in case %d: %s",
                path, result.cases, line);
    }
    return result;
}

private Result testBidiCharacters(string path)
{
    auto input = File(path, "r");
    char[] buffer;
    Result result;
    size_t shown;
    while (input.readln(buffer))
    {
        const line = withoutComment(buffer);
        if (line.length == 0) continue;
        const(char)[][] fields;
        foreach (field; line.splitter(';')) fields ~= strip(field);
        if (fields.length != 5) continue;

        dchar[] text;
        foreach (token; fields[0].splitter())
            text ~= cast(dchar) parseHex(token);

        ParagraphDirection direction;
        switch (fields[1])
        {
            case "0": direction = ParagraphDirection.leftToRight; break;
            case "1": direction = ParagraphDirection.rightToLeft; break;
            default: direction = ParagraphDirection.automatic; break;
        }

        ubyte[] expectedLevels;
        foreach (token; fields[3].splitter())
            expectedLevels ~= token == "x" ? ubyte.max : token.to!ubyte;
        size_t[] expectedOrder;
        foreach (token; fields[4].splitter()) expectedOrder ~= token.to!size_t;

        const actual = resolveBidi(text, direction);
        const passed = actual.paragraphLevel == fields[2].to!ubyte &&
            actual.levels == expectedLevels && actual.visualOrder == expectedOrder;
        ++result.cases;
        result.boundaries += expectedLevels.length;
        if (actual.levels.length == expectedLevels.length)
            foreach (i; 0 .. expectedLevels.length)
                if (actual.levels[i] == expectedLevels[i]) ++result.matchedBoundaries;
        if (passed)
            ++result.passed;
        else if (shown++ < 12)
        {
            stderr.writefln("%s: bidi character mismatch in case %d", path,
                result.cases);
            stderr.writefln("  paragraph expected %s actual %s", fields[2],
                actual.paragraphLevel);
            stderr.writefln("  levels expected %s actual %s", expectedLevels,
                actual.levels);
            stderr.writefln("  order expected %s actual %s", expectedOrder,
                actual.visualOrder);
        }
    }
    return result;
}

private dchar representative(const(char)[] name)
{
    switch (name)
    {
        case "L": return 'a';
        case "R": return cast(dchar) 0x05D0;
        case "AL": return cast(dchar) 0x0627;
        case "EN": return '1';
        case "ES": return '+';
        case "ET": return '$';
        case "AN": return cast(dchar) 0x0661;
        case "CS": return ',';
        case "NSM": return cast(dchar) 0x0300;
        case "BN": return cast(dchar) 0x00AD;
        case "B": return cast(dchar) 0x2029;
        case "S": return cast(dchar) 0x0009;
        case "WS": return ' ';
        case "ON": return '"';
        case "LRE": return cast(dchar) 0x202A;
        case "RLE": return cast(dchar) 0x202B;
        case "PDF": return cast(dchar) 0x202C;
        case "LRO": return cast(dchar) 0x202D;
        case "RLO": return cast(dchar) 0x202E;
        case "LRI": return cast(dchar) 0x2066;
        case "RLI": return cast(dchar) 0x2067;
        case "FSI": return cast(dchar) 0x2068;
        case "PDI": return cast(dchar) 0x2069;
        default: assert(false, name);
    }
}

private ubyte[] parseLevels(const(char)[] value)
{
    ubyte[] result;
    foreach (token; value.splitter())
        result ~= token == "x" ? ubyte.max : token.to!ubyte;
    return result;
}

private size_t[] parseOrder(const(char)[] value)
{
    size_t[] result;
    foreach (token; value.splitter()) result ~= token.to!size_t;
    return result;
}

private Result testBidiClasses(string path)
{
    auto input = File(path, "r");
    char[] buffer;
    ubyte[] expectedLevels;
    size_t[] expectedOrder;
    Result result;
    size_t shown;
    while (input.readln(buffer))
    {
        const line = withoutComment(buffer);
        if (line.length == 0) continue;
        if (line.startsWith("@Levels:"))
        {
            expectedLevels = parseLevels(strip(line[8 .. $]));
            continue;
        }
        if (line.startsWith("@Reorder:"))
        {
            expectedOrder = parseOrder(strip(line[9 .. $]));
            continue;
        }
        if (line[0] == '@') continue;
        const separator = line.indexOf(';');
        if (separator < 0) continue;

        dchar[] text;
        foreach (token; strip(line[0 .. cast(size_t) separator]).splitter())
            text ~= representative(token);
        const bitset = strip(line[cast(size_t) separator + 1 .. $]).to!uint;
        foreach (bit; [1u, 2u, 4u])
        {
            if ((bitset & bit) == 0) continue;
            const direction = bit == 1 ? ParagraphDirection.automatic :
                bit == 2 ? ParagraphDirection.leftToRight :
                    ParagraphDirection.rightToLeft;
            const actual = resolveBidi(text, direction);
            const passed = actual.levels == expectedLevels &&
                actual.visualOrder == expectedOrder;
            ++result.cases;
            result.boundaries += expectedLevels.length;
            if (actual.levels.length == expectedLevels.length)
                foreach (i; 0 .. expectedLevels.length)
                    if (actual.levels[i] == expectedLevels[i])
                        ++result.matchedBoundaries;
            if (passed)
                ++result.passed;
            else if (shown++ < 12)
            {
                stderr.writefln("%s: bidi class mismatch in case %d: %s",
                    path, result.cases, line);
                stderr.writefln("  levels expected %s actual %s", expectedLevels,
                    actual.levels);
                stderr.writefln("  order expected %s actual %s", expectedOrder,
                    actual.visualOrder);
            }
        }
    }
    return result;
}

private void report(string name, Result result)
{
    writefln("  %-22s %d/%d cases; %d/%d boundaries", name,
        result.passed, result.cases, result.matchedBoundaries,
        result.boundaries);
}

int main(string[] args)
{
    const root = args.length > 1 ? args[1] : buildPath("tools", "unicode", "17.0.0");
    const grapheme = testBreakFile(buildPath(root, "GraphemeBreakTest.txt"), true);
    const line = testBreakFile(buildPath(root, "LineBreakTest.txt"), false);
    const bidiCharacters = testBidiCharacters(buildPath(root,
        "BidiCharacterTest.txt"));
    const bidiClasses = testBidiClasses(buildPath(root, "BidiTest.txt"));

    writeln("Unicode 17.0 conformance results:");
    report("GraphemeBreakTest", grapheme);
    report("LineBreakTest", line);
    report("BidiCharacterTest", bidiCharacters);
    report("BidiTest", bidiClasses);

    return grapheme.successful() && line.successful() &&
        bidiCharacters.successful() && bidiClasses.successful() ? 0 : 1;
}
