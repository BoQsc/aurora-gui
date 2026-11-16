# aurora-standard API contract

**Package:** `aurora-standard` 1.0.0  
**Standard:** Unicode 17.0.0  
**Stability:** standard (frozen within major version 1)

Everything public is listed in [api/surface.json](../api/surface.json). The
compiler must produce exactly this public symbol set; the verifier rejects
missing or extra public symbols. This document defines the behavior that the
symbols promise.

## Conventions

- Text is `const(dchar)[]`. Inputs are Unicode code points, not UTF-8 or UTF-16.
- Indices are code-point indices, not byte offsets.
- All functions are reentrant and use no global mutable state or I/O.
- Property functions never throw. An unassigned or unsupported code point gets
  the documented default for that property.
- Segmentation and bidi functions allocate their result arrays. Empty input is
  valid and returns the documented empty shape.

## `aurora.standard.text.unicode.properties`

### `UnicodeDataVersion`

`immutable string UnicodeDataVersion` is exactly `"17.0.0"`.

### Property enums

| Type | Meaning | Default for an unassigned code point |
|---|---|---|
| `GraphemeBreak` | UAX #29 grapheme-break class | `other` |
| `IndicConjunctBreak` | UAX #29 Indic conjunct-break class | `none` |
| `BidiClass` | UAX #9 bidi class | `l` |
| `LineBreakClass` | UAX #14 line-break class | `xx` |
| `Script` | Unicode script | `unknown` |
| `JoiningType` | Arabic joining type | `nonJoining` |
| `GeneralCategory` | Unicode general category | `cn` |
| `EastAsianWidth` | East Asian width class | `n` |
| `BidiBracketType` | Bidi paired-bracket kind | `none` |

The enum member sets are the Unicode 17.0.0 values. They are part of the API
surface; adding a member requires a new standard version.

### `BidiBracket`

```d
struct BidiBracket
{
    dchar pair;
    BidiBracketType kind;
}
```

For a paired bracket, `pair` is the opposite bracket and `kind` is `open` or
`close`. For a code point with no paired-bracket mapping, `pair` is the input
code point and `kind` is `none`.

### Lookup functions

```d
GraphemeBreak graphemeBreak(dchar codepoint) @safe pure nothrow @nogc;
bool isExtendedPictographic(dchar codepoint) @safe pure nothrow @nogc;
IndicConjunctBreak indicConjunctBreak(dchar codepoint) @safe pure nothrow @nogc;
BidiClass bidiClass(dchar codepoint) @safe pure nothrow @nogc;
LineBreakClass lineBreakClass(dchar codepoint) @safe pure nothrow @nogc;
Script script(dchar codepoint) @safe pure nothrow @nogc;
JoiningType joiningType(dchar codepoint) @safe pure nothrow @nogc;
GeneralCategory generalCategory(dchar codepoint) @safe pure nothrow @nogc;
EastAsianWidth eastAsianWidth(dchar codepoint) @safe pure nothrow @nogc;
bool isDefaultIgnorable(dchar codepoint) @safe pure nothrow @nogc;
uint openTypeScriptTag(Script value) @safe pure nothrow @nogc;
string scriptName(Script value) @safe pure nothrow;
dchar bidiMirror(dchar codepoint) @safe pure nothrow @nogc;
BidiBracket bidiBracket(dchar codepoint) @safe pure nothrow @nogc;
```

`openTypeScriptTag` returns the OpenType script tag for a script, or the
`DFLT` tag (`0x44464C54`) when the script has no dedicated tag.
`scriptName` returns the Unicode script name, or `"Unknown"` for an unknown
value. `bidiMirror` returns the mirrored code point, or the input code point
when Unicode defines no mirror.

## `aurora.standard.text.unicode.grapheme`

```d
size_t[] graphemeBoundaries(const(dchar)[] text);
bool isGraphemeBoundary(const(dchar)[] text, size_t index) @safe pure nothrow @nogc;
size_t previousGraphemeBoundary(const(dchar)[] text, size_t index) @safe pure nothrow @nogc;
size_t nextGraphemeBoundary(const(dchar)[] text, size_t index) @safe pure nothrow @nogc;
size_t floorGraphemeBoundary(const(dchar)[] text, size_t index) @safe pure nothrow @nogc;
size_t ceilGraphemeBoundary(const(dchar)[] text, size_t index) @safe pure nothrow @nogc;
```

### Boundary convention

`graphemeBoundaries` returns every extended grapheme-cluster boundary position,
including `0` and `text.length`, in ascending order. For empty text the result
is `[0]`.

`isGraphemeBoundary` is true at `0` and at `text.length`. Indices greater than
`text.length` are false. It is safe to call with any `size_t` index.

`previousGraphemeBoundary` returns the nearest boundary strictly before
`index`, clamped to `0`. `nextGraphemeBoundary` returns the nearest boundary
strictly after `index`, clamped to `text.length`.

`floorGraphemeBoundary` snaps an arbitrary index to the preceding boundary.
`ceilGraphemeBoundary` snaps it to the following boundary. Both are clamped to
the valid range.

The implementation follows UAX #29 extended grapheme clusters, including CRLF,
prepend, Hangul syllables, regional-indicator flags, emoji ZWJ sequences, and
Indic conjunct boundaries.

## `aurora.standard.text.unicode.linebreak`

```d
bool[] lineBreakOpportunities(const(dchar)[] text) @safe pure;
bool mandatoryBreakAfter(const(dchar)[] text, size_t boundary) @safe pure nothrow @nogc;
```

### Array convention

`lineBreakOpportunities` returns one flag per logical code-point boundary.
The result length is `text.length + 1`. Index `0` is always `false`. The final
index (`text.length`) is `true`. A `true` entry inside the array means a line
break is allowed before the code point at that index.

For empty text, the result is `[true]`.

Mandatory breaks are reported as `true` opportunities and are identified by
`mandatoryBreakAfter`. A CRLF pair is not a mandatory break after the CR alone;
the break belongs after the LF.

The implementation follows UAX #14 default line breaking, including hard
breaks, combining sequences, emoji classes, East Asian width rules, and the
Unicode 17.0.0 line-break classes. It does not apply locale tailoring,
dictionary line breaking, hyphenation, or justification.

## `aurora.standard.text.unicode.bidi`

### `ParagraphDirection`

```d
enum ParagraphDirection : ubyte
{
    automatic,
    leftToRight,
    rightToLeft
}
```

### `BidiResult`

```d
struct BidiResult
{
    ubyte paragraphLevel;
    ubyte[] levels;
    BidiClass[] resolvedTypes;
    size_t[] visualOrder;
    size_t[] logicalToVisual;
    BidiVisualRun[] visualRuns;

    bool removed(size_t logicalIndex) const @safe pure nothrow @nogc;
}
```

- `paragraphLevel` is the resolved paragraph embedding level.
- `levels`, `resolvedTypes`, and `logicalToVisual` have the same length as the
  input text.
- `visualOrder` lists logical code-point indices in visual order.
- `logicalToVisual[logicalIndex]` is the visual position of that logical index.
- `removed(logicalIndex)` is true when the code point is removed by the bidi
  algorithm or when the index is out of range. Removed entries carry the
  internal removed-level marker in `levels`.
- `visualRuns` describes contiguous visual ranges and their embedding level.
  `BidiVisualRun.rightToLeft()` is true for odd levels.

### `resolveBidi`

```d
BidiResult resolveBidi(const(dchar)[] text,
    ParagraphDirection direction = ParagraphDirection.automatic);
```

`resolveBidi` resolves exactly one paragraph. The caller is responsible for
splitting text at paragraph separators. `automatic` derives the paragraph
level from the first strong character; `leftToRight` and `rightToLeft` force the
base direction.

The implementation follows UAX #9 through rule L2, including explicit
embeddings and overrides, isolates, bracket pairing, weak/neutral resolution,
and mirrored characters. It produces ordering metadata only; it does not shape
or paint glyphs.

## Examples

```d
import aurora.standard.text.unicode.grapheme;
import aurora.standard.text.unicode.linebreak;
import aurora.standard.text.unicode.bidi;

const cluster = "a\u0301"d;          // a + combining acute
assert(graphemeBoundaries(cluster) == [0UL, 2UL]);

const breaks = lineBreakOpportunities("hello world"d);
assert(breaks.length == 12);
assert(breaks[6]);                    // before "world"

auto rtl = resolveBidi("\u05D0\u05D1\u05D2"d);
assert(rtl.paragraphLevel == 1);
assert(rtl.visualOrder == [2UL, 1UL, 0UL]);
```

## What is intentionally not promised

- Performance beyond linear allocation for the result arrays and table lookups
  for properties.
- Word/sentence segmentation, locale tailoring, or typographic shaping.
- Rendering, font selection, or widget behavior.
- Compatibility with Unicode versions other than 17.0.0.

Those are separate layers. Keeping them out is what makes this contract small
enough to freeze.
