#!/usr/bin/env python3
"""Generate compact Aurora-D Unicode 17.0 property tables.

Input files are official Unicode Character Database files. The generated source
contains only normalized ranges and does not require the text files at runtime.
"""
from __future__ import annotations

import argparse
import pathlib
import re
from collections import OrderedDict

MAX_CP = 0x10FFFF
VERSION = "17.0.0"


def parse_range(token: str) -> tuple[int, int]:
    token = token.strip()
    if ".." in token:
        a, b = token.split("..", 1)
        return int(a, 16), int(b, 16)
    n = int(token, 16)
    return n, n


def parse_property(path: pathlib.Path, include_missing: bool = False):
    missing = []
    explicit = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if include_missing and stripped.startswith("# @missing:"):
            body = stripped[len("# @missing:"):].strip()
            left, right = body.split(";", 1)
            missing.append((*parse_range(left), right.strip().split()[0]))
            continue
        line = raw.split("#", 1)[0].strip()
        if not line or ";" not in line:
            continue
        left, right = line.split(";", 1)
        explicit.append((*parse_range(left), right.strip().split()[0]))
    return missing, explicit


def apply_ranges(default: str, missing, explicit) -> list[str]:
    values = [default] * (MAX_CP + 1)
    for first, last, value in missing:
        values[first:last + 1] = [value] * (last - first + 1)
    for first, last, value in explicit:
        values[first:last + 1] = [value] * (last - first + 1)
    return values


def compress(values: list[str], default: str, omit_default: bool = True):
    out = []
    start = 0
    value = values[0]
    for i in range(1, len(values) + 1):
        if i == len(values) or values[i] != value:
            if not omit_default or value != default:
                out.append((start, i - 1, value))
            if i < len(values):
                start = i
                value = values[i]
    return out


def ident(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9]+", "_", value).strip("_")
    if not value:
        return "unknown"
    pieces = value.split("_")
    result = pieces[0].lower() + "".join(p[:1].upper() + p[1:] for p in pieces[1:])
    if result[0].isdigit():
        result = "v" + result
    if result in {"default", "version", "scope", "body", "align", "ref", "out", "in", "is"}:
        result += "Value"
    return result


def enum_block(name: str, values: list[str], type_name: str, aliases: dict[str, str] | None = None) -> str:
    aliases = aliases or {}
    lines = [f"enum {name} : {type_name}", "{"]
    for value in values:
        lines.append(f"    {aliases.get(value, ident(value))},")
    lines.append("}")
    return "\n".join(lines)


def dchar_literal(cp: int) -> str:
    return f"cast(dchar) 0x{cp:X}"


def ranges_block(name: str, ranges, enum_name: str, map_name=lambda x: ident(x)) -> str:
    lines = [f"private immutable PropertyRange!{enum_name}[] {name} = ["]
    for first, last, value in ranges:
        lines.append(
            f"    PropertyRange!{enum_name}({dchar_literal(first)}, {dchar_literal(last)}, {enum_name}.{map_name(value)}),"
        )
    lines.append("];")
    return "\n".join(lines)


def parse_script_aliases(path: pathlib.Path) -> dict[str, str]:
    result = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or not line.startswith("sc ;"):
            continue
        parts = [part.strip() for part in line.split(";")]
        if len(parts) >= 3:
            short = parts[1]
            long = parts[2]
            result[long] = short
    return result


def parse_binary_property(path: pathlib.Path, property_name: str):
    result = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line or ";" not in line:
            continue
        left, right = line.split(";", 1)
        if right.strip().split()[0] == property_name:
            first, last = parse_range(left)
            result.append((first, last))
    return result


def compress_bool_ranges(ranges):
    ranges = sorted(ranges)
    out = []
    for first, last in ranges:
        if out and first <= out[-1][1] + 1:
            out[-1] = (out[-1][0], max(last, out[-1][1]))
        else:
            out.append((first, last))
    return out


def parse_unicode_data(path: pathlib.Path):
    values = ["Cn"] * (MAX_CP + 1)
    range_start = None
    range_category = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw:
            continue
        parts = raw.split(";")
        cp = int(parts[0], 16)
        name = parts[1]
        category = parts[2]
        if name.endswith(", First>"):
            range_start = cp
            range_category = category
        elif name.endswith(", Last>"):
            if range_start is None:
                raise ValueError("UnicodeData range end without start")
            values[range_start:cp + 1] = [range_category] * (cp - range_start + 1)
            range_start = None
            range_category = None
        else:
            values[cp] = category
    return values


def parse_incb(path: pathlib.Path):
    explicit = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(";")]
        if len(parts) >= 3 and parts[1] == "InCB":
            first, last = parse_range(parts[0])
            explicit.append((first, last, parts[2].split()[0]))
    return explicit


def parse_arabic_shaping(path: pathlib.Path):
    explicit = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(";")]
        if len(parts) >= 3:
            cp = int(parts[0], 16)
            explicit.append((cp, cp, parts[2]))
    return explicit


def parse_pair_map(path: pathlib.Path, value_index=1):
    result = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(";")]
        if len(parts) > value_index:
            result.append((int(parts[0], 16), int(parts[value_index], 16), parts[2] if len(parts) > 2 else ""))
    return result


def generate(root: pathlib.Path, output: pathlib.Path):
    # Grapheme cluster break and emoji Extended_Pictographic.
    _, gb_explicit = parse_property(root / "GraphemeBreakProperty.txt")
    gb_values = apply_ranges("Other", [], gb_explicit)
    gb_ranges = compress(gb_values, "Other")
    gb_names = ["Other", "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator",
                "Prepend", "SpacingMark", "L", "V", "T", "LV", "LVT"]

    ep_ranges = compress_bool_ranges(parse_binary_property(root / "emoji-data.txt", "Extended_Pictographic"))

    incb_explicit = parse_incb(root / "DerivedCoreProperties.txt")
    incb_values = apply_ranges("None", [], incb_explicit)
    incb_ranges = compress(incb_values, "None")
    incb_names = ["None", "Consonant", "Linker", "Extend"]

    # Bidi class includes @missing ranges.
    bidi_missing, bidi_explicit = parse_property(root / "DerivedBidiClass.txt", include_missing=True)
    bidi_alias = {
        "Left_To_Right": "L", "Right_To_Left": "R", "Arabic_Letter": "AL",
        "European_Terminator": "ET",
    }
    bidi_missing = [(a, b, bidi_alias.get(v, v)) for a, b, v in bidi_missing]
    bidi_values = apply_ranges("L", bidi_missing, bidi_explicit)
    bidi_ranges = compress(bidi_values, "L")
    bidi_names = ["L", "R", "AL", "EN", "ES", "ET", "AN", "CS", "NSM", "BN", "B", "S", "WS", "ON",
                  "LRE", "LRO", "RLE", "RLO", "PDF", "LRI", "RLI", "FSI", "PDI"]

    # Line break class includes @missing ranges.
    lb_missing, lb_explicit = parse_property(root / "LineBreak.txt", include_missing=True)
    lb_values = apply_ranges("XX", lb_missing, lb_explicit)
    lb_ranges = compress(lb_values, "XX")
    lb_names = ["XX"] + sorted({v for v in lb_values if v != "XX"})

    # Script property and ISO 15924 aliases.
    _, script_explicit = parse_property(root / "Scripts.txt")
    script_values = apply_ranges("Unknown", [], script_explicit)
    script_ranges = compress(script_values, "Unknown")
    script_names = ["Unknown"] + sorted({v for v in script_values if v != "Unknown"})
    script_aliases = parse_script_aliases(root / "PropertyValueAliases.txt")

    # Default ignorables, Arabic joining, mirror and bracket maps.
    ignorable = compress_bool_ranges(parse_binary_property(root / "DerivedCoreProperties.txt", "Default_Ignorable_Code_Point"))
    joining_explicit = parse_arabic_shaping(root / "ArabicShaping.txt")
    joining_values = apply_ranges("U", [], joining_explicit)
    joining_ranges = compress(joining_values, "U")
    joining_names = ["U", "R", "L", "D", "C", "T"]

    general_values = parse_unicode_data(root / "UnicodeData.txt")
    general_ranges = compress(general_values, "Cn")
    general_names = ["Cn"] + sorted({v for v in general_values if v != "Cn"})

    eaw_missing, eaw_explicit = parse_property(root / "EastAsianWidth.txt", include_missing=True)
    eaw_values = apply_ranges("N", eaw_missing, eaw_explicit)
    eaw_ranges = compress(eaw_values, "N")
    eaw_names = ["N"] + sorted({v for v in eaw_values if v != "N"})
    mirror_pairs = parse_pair_map(root / "BidiMirroring.txt")
    bracket_pairs = parse_pair_map(root / "BidiBrackets.txt")

    aliases_gb = {"Other": "other", "Regional_Indicator": "regionalIndicator", "SpacingMark": "spacingMark"}
    aliases_incb = {"None": "none", "Consonant": "consonant", "Linker": "linker", "Extend": "extend"}
    aliases_bidi = {v: v.lower() for v in bidi_names}
    aliases_lb = {v: ident(v) for v in lb_names}
    aliases_join = {"U": "nonJoining", "R": "rightJoining", "L": "leftJoining", "D": "dualJoining", "C": "joinCausing", "T": "transparent"}
    aliases_gc = {v: v.lower() for v in general_names}
    aliases_eaw = {v: v.lower() for v in eaw_names}

    lines = [
        "module aurora.text.unicode.properties;",
        "",
        "/**",
        " * Generated Unicode property tables for Aurora-D.",
        f" * Unicode version: {VERSION}.",
        " * Source: official Unicode Character Database files under tools/unicode/17.0.0.",
        " * Regenerate with tools/generate_unicode.py; do not edit manually.",
        " */",
        "",
        f'enum UnicodeDataVersion = "{VERSION}";',
        "",
        enum_block("GraphemeBreak", gb_names, "ubyte", aliases_gb),
        "",
        enum_block("IndicConjunctBreak", incb_names, "ubyte", aliases_incb),
        "",
        enum_block("BidiClass", bidi_names, "ubyte", aliases_bidi),
        "",
        enum_block("LineBreakClass", lb_names, "ubyte", aliases_lb),
        "",
        enum_block("Script", script_names, "ushort", {"Unknown": "unknown"}),
        "",
        enum_block("JoiningType", joining_names, "ubyte", aliases_join),
        "",
        enum_block("GeneralCategory", general_names, "ubyte", aliases_gc),
        "",
        enum_block("EastAsianWidth", eaw_names, "ubyte", aliases_eaw),
        "",
        "enum BidiBracketType : ubyte",
        "{",
        "    none,",
        "    open,",
        "    close,",
        "}",
        "",
        "private struct PropertyRange(T)",
        "{",
        "    dchar first;",
        "    dchar last;",
        "    T value;",
        "}",
        "",
        "private struct CodePointRange",
        "{",
        "    dchar first;",
        "    dchar last;",
        "}",
        "",
        "struct BidiBracket",
        "{",
        "    dchar pair;",
        "    BidiBracketType kind;",
        "}",
        "",
        "private struct CodePointPair",
        "{",
        "    dchar codepoint;",
        "    dchar pair;",
        "}",
        "",
        "private struct BracketPair",
        "{",
        "    dchar codepoint;",
        "    dchar pair;",
        "    BidiBracketType kind;",
        "}",
        "",
        ranges_block("graphemeRanges", gb_ranges, "GraphemeBreak", lambda v: aliases_gb.get(v, ident(v))),
        "",
        ranges_block("indicConjunctRanges", incb_ranges, "IndicConjunctBreak", lambda v: aliases_incb[v]),
        "",
        ranges_block("bidiRanges", bidi_ranges, "BidiClass", lambda v: aliases_bidi[v]),
        "",
        ranges_block("lineBreakRanges", lb_ranges, "LineBreakClass", lambda v: aliases_lb[v]),
        "",
        ranges_block("scriptRanges", script_ranges, "Script"),
        "",
        ranges_block("joiningRanges", joining_ranges, "JoiningType", lambda v: aliases_join[v]),
        "",
        ranges_block("generalCategoryRanges", general_ranges, "GeneralCategory", lambda v: aliases_gc[v]),
        "",
        ranges_block("eastAsianWidthRanges", eaw_ranges, "EastAsianWidth", lambda v: aliases_eaw[v]),
        "",
        "private immutable CodePointRange[] extendedPictographicRanges = [",
    ]
    lines += [f"    CodePointRange({dchar_literal(a)}, {dchar_literal(b)})," for a, b in ep_ranges]
    lines += ["];"]
    lines += ["", "private immutable CodePointRange[] defaultIgnorableRanges = ["]
    lines += [f"    CodePointRange({dchar_literal(a)}, {dchar_literal(b)})," for a, b in ignorable]
    lines += ["];"]
    lines += ["", "private immutable CodePointPair[] mirrorPairs = ["]
    lines += [f"    CodePointPair({dchar_literal(a)}, {dchar_literal(b)})," for a, b, _ in mirror_pairs]
    lines += ["];"]
    lines += ["", "private immutable BracketPair[] bracketPairs = ["]
    for a, b, kind in bracket_pairs:
        k = "open" if kind == "o" else "close"
        lines.append(f"    BracketPair({dchar_literal(a)}, {dchar_literal(b)}, BidiBracketType.{k}),")
    lines += ["];"]

    # Script tag arrays align with enum ordinal.
    lines += ["", "private immutable uint[] scriptTags = ["]
    for name in script_names:
        if name == "Unknown":
            code = "Zzzz"
        else:
            code = script_aliases.get(name, "Zzzz")
        # ISO code is four ASCII chars. OpenType script tags are lowercase; DFLT for Common/Inherited/Unknown.
        if name in {"Common", "Inherited", "Unknown"}:
            tag_text = "DFLT"
        else:
            tag_text = code.lower().ljust(4)[:4]
        n = sum(ord(ch) << (24 - i * 8) for i, ch in enumerate(tag_text))
        lines.append(f"    0x{n:08X}u, // {name}: {tag_text}")
    lines += ["];"]
    lines += ["", "private immutable string[] scriptNames = ["]
    lines += [f'    "{name}",' for name in script_names]
    lines += ["];"]

    lines += [
        "",
        "private T lookupProperty(T)(const(PropertyRange!T)[] ranges, dchar codepoint, T fallback)",
        "    @safe pure nothrow @nogc",
        "{",
        "    size_t low;",
        "    size_t high = ranges.length;",
        "    while (low < high)",
        "    {",
        "        const middle = low + (high - low) / 2;",
        "        const range = ranges[middle];",
        "        if (codepoint < range.first) high = middle;",
        "        else if (codepoint > range.last) low = middle + 1;",
        "        else return range.value;",
        "    }",
        "    return fallback;",
        "}",
        "",
        "private bool inRanges(const(CodePointRange)[] ranges, dchar codepoint)",
        "    @safe pure nothrow @nogc",
        "{",
        "    size_t low;",
        "    size_t high = ranges.length;",
        "    while (low < high)",
        "    {",
        "        const middle = low + (high - low) / 2;",
        "        const range = ranges[middle];",
        "        if (codepoint < range.first) high = middle;",
        "        else if (codepoint > range.last) low = middle + 1;",
        "        else return true;",
        "    }",
        "    return false;",
        "}",
        "",
        "GraphemeBreak graphemeBreak(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return lookupProperty(graphemeRanges, codepoint, GraphemeBreak.other);",
        "}",
        "",
        "bool isExtendedPictographic(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return inRanges(extendedPictographicRanges, codepoint);",
        "}",
        "",
        "IndicConjunctBreak indicConjunctBreak(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return lookupProperty(indicConjunctRanges, codepoint, IndicConjunctBreak.none);",
        "}",
        "",
        "BidiClass bidiClass(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return lookupProperty(bidiRanges, codepoint, BidiClass.l);",
        "}",
        "",
        "LineBreakClass lineBreakClass(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return lookupProperty(lineBreakRanges, codepoint, LineBreakClass.xx);",
        "}",
        "",
        "Script script(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return lookupProperty(scriptRanges, codepoint, Script.unknown);",
        "}",
        "",
        "JoiningType joiningType(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return lookupProperty(joiningRanges, codepoint, JoiningType.nonJoining);",
        "}",
        "",
        "GeneralCategory generalCategory(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return lookupProperty(generalCategoryRanges, codepoint, GeneralCategory.cn);",
        "}",
        "",
        "EastAsianWidth eastAsianWidth(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return lookupProperty(eastAsianWidthRanges, codepoint, EastAsianWidth.n);",
        "}",
        "",
        "bool isDefaultIgnorable(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    return inRanges(defaultIgnorableRanges, codepoint);",
        "}",
        "",
        "uint openTypeScriptTag(Script value) @safe pure nothrow @nogc",
        "{",
        "    const index = cast(size_t) value;",
        "    return index < scriptTags.length ? scriptTags[index] : 0x44464C54u;",
        "}",
        "",
        "string scriptName(Script value) @safe pure nothrow",
        "{",
        "    const index = cast(size_t) value;",
        "    return index < scriptNames.length ? scriptNames[index] : \"Unknown\";",
        "}",
        "",
        "dchar bidiMirror(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    size_t low;",
        "    size_t high = mirrorPairs.length;",
        "    while (low < high)",
        "    {",
        "        const middle = low + (high - low) / 2;",
        "        if (codepoint < mirrorPairs[middle].codepoint) high = middle;",
        "        else if (codepoint > mirrorPairs[middle].codepoint) low = middle + 1;",
        "        else return mirrorPairs[middle].pair;",
        "    }",
        "    return codepoint;",
        "}",
        "",
        "BidiBracket bidiBracket(dchar codepoint) @safe pure nothrow @nogc",
        "{",
        "    size_t low;",
        "    size_t high = bracketPairs.length;",
        "    while (low < high)",
        "    {",
        "        const middle = low + (high - low) / 2;",
        "        if (codepoint < bracketPairs[middle].codepoint) high = middle;",
        "        else if (codepoint > bracketPairs[middle].codepoint) low = middle + 1;",
        "        else return BidiBracket(bracketPairs[middle].pair, bracketPairs[middle].kind);",
        "    }",
        "    return BidiBracket(codepoint, BidiBracketType.none);",
        "}",
        "",
        "unittest",
        "{",
        "    assert(UnicodeDataVersion == \"17.0.0\");",
        "    assert(graphemeBreak('\\r') == GraphemeBreak.cr);",
        "    assert(graphemeBreak(cast(dchar) 0x0301) == GraphemeBreak.extend);",
        "    assert(isExtendedPictographic(cast(dchar) 0x1F600));",
        "    assert(indicConjunctBreak(cast(dchar) 0x094D) == IndicConjunctBreak.linker);",
        "    assert(bidiClass(cast(dchar) 0x05D0) == BidiClass.r);",
        "    assert(lineBreakClass(' ') == LineBreakClass.sp);",
        "    assert(generalCategory('A') == GeneralCategory.lu);",
        "    assert(eastAsianWidth(cast(dchar) 0x4E00) == EastAsianWidth.w);",
        "    assert(script('A') == Script.latin);",
        "    assert(openTypeScriptTag(Script.latin) == 0x6C61746Eu);",
        "    assert(bidiMirror('(') == ')');",
        "}",
    ]

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {output} ({output.stat().st_size:,} bytes)")
    print(f"ranges: grapheme={len(gb_ranges)}, incb={len(incb_ranges)}, bidi={len(bidi_ranges)}, line={len(lb_ranges)}, scripts={len(script_ranges)}, joining={len(joining_ranges)}, gc={len(general_ranges)}, eaw={len(eaw_ranges)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="tools/unicode/17.0.0", type=pathlib.Path)
    parser.add_argument("--output", default="source/aurora/text/unicode/properties.d", type=pathlib.Path)
    args = parser.parse_args()
    generate(args.data, args.output)


if __name__ == "__main__":
    main()
