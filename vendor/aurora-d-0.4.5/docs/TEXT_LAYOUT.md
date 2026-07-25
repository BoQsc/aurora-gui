# Unicode text layout

Aurora-D 0.4.2 treats text layout as a renderer-neutral operation. Widgets and editors do not iterate over code points to draw one glyph at a time. They request a `TextLayout`, then both Vulkan and software rendering replay the same positioned glyphs from the shared atlas.

## Pipeline

```text
UTF-32 logical text
    │
    ├── extended grapheme boundaries (Unicode 17, UAX #29)
    ├── paragraph splitting and bidi levels (Unicode 17, UAX #9)
    ├── script itemization
    ├── complete-cluster font fallback
    ├── GDEF/GSUB/GPOS shaping
    ├── default line-break opportunities (Unicode 17, UAX #14)
    ├── width fitting and hard/soft line construction
    └── visual run reordering and caret construction
            │
            ▼
TextLayout
    ├── positioned glyphs
    ├── logical and visual runs
    ├── lines
    ├── visual clusters
    ├── affinity-aware caret states
    └── selection geometry
```

Logical source order is never replaced by visual order in the document. The layout stores mappings between them.

## Core API

```d
TextLayoutOptions options;
options.role = FontRole.ui;
options.pixelSize = 18;
options.maxWidth = 420;
options.wrap = true;
options.paragraphDirection = ParagraphDirection.automatic;
options.enableKerning = true;
options.enableLigatures = true;
options.enableContextualAlternates = true;
options.enableMarkPositioning = true;

auto layout = fontSystem.textEngine.layout(text, options);
```

`TextLayoutOptions` also supports an explicit `overrideFace`, tab width, and a four-byte OpenType language tag. A zero `maxWidth` means unconstrained layout.

The `Canvas` convenience API uses the same engine:

```d
auto layout = canvas.layoutText(text, 2, FontRole.ui,
    customFace, 420, true);
canvas.drawLayout(Point(20, 20), layout, color);
```

Use `drawLayout` for cached static text. `drawText` and `drawTextInRect` shape on demand.

## Logical indices and clusters

Aurora stores editor documents as UTF-32 and expresses source positions as UTF-32 code-point offsets. A source position is therefore not a byte offset and is not necessarily a user-perceived character boundary.

All public editor deletion and cursor entry points snap to an extended grapheme boundary. This keeps sequences such as these indivisible during ordinary editing:

- a base letter plus combining marks;
- emoji plus variation selectors;
- emoji ZWJ sequences;
- regional-indicator flag pairs;
- Indic conjunct boundaries represented by the Unicode 17 grapheme rules.

The implementation uses generated Unicode 17 properties and is checked against `GraphemeBreakTest.txt`.

## Bidirectional layout

`resolveBidi` implements paragraph direction, explicit embeddings and overrides, isolates, weak and neutral resolution, paired-bracket handling, implicit levels, and line reordering. The engine retains logical indices while arranging runs and clusters in physical display order.

`ParagraphDirection` can be:

```d
ParagraphDirection.automatic
ParagraphDirection.leftToRight
ParagraphDirection.rightToLeft
```

Automatic direction uses the paragraph's first applicable strong character. The explicit option is useful for controls that carry a known base direction.

The implementation is checked against both official Unicode 17 bidi suites:

- `BidiCharacterTest.txt`;
- `BidiTest.txt`.

## Shaping and fallback

The layout engine groups text by bidi level, script, and selected font. Font resolution is performed for a complete grapheme cluster so a base and its combining marks are not casually split across incompatible faces.

The selected face is shaped through GDEF, GSUB, and GPOS. The resulting `PositionedGlyph` records:

- font face and glyph index;
- logical cluster start and end;
- baseline position;
- X advance;
- bidi level;
- output line index.

Substitutions retain their logical cluster range. A ligature can therefore represent several source code points while still supporting hit testing and selection.

Fallback order is deterministic: the primary face, application-added faces, discovered platform candidates, and finally the emergency bitmap face.

## Line breaking and wrapping

`lineBreakOpportunities` implements Aurora's Unicode 17 default UAX #14 behavior. `TextLayoutEngine` then selects actual opportunities according to the shaped widths and `maxWidth`.

Hard paragraph separators always produce a line boundary. Soft wraps preserve logical text and can produce two visual carets for one logical insertion position: one at the end of the previous visual line and one at the beginning of the next.

The line breaker is checked against all boundaries in `LineBreakTest.txt`.

Aurora does not currently add language-specific hyphenation, dictionary segmentation for scripts such as Thai, or locale-specific UAX #14 tailoring. Emergency wrapping keeps grapheme clusters intact.

## Carets and affinity

A logical insertion index can have more than one valid visual representation. This occurs at mixed-direction boundaries and soft wraps. `CaretPosition` therefore contains:

```d
struct CaretPosition
{
    size_t logicalIndex;
    size_t lineIndex;
    double x;
    double y;
    double height;
    CaretAffinity affinity;
}
```

Callers that implement visual navigation should retain the complete caret state, not only the logical index:

```d
auto caret = layout.hitTestCaret(mouseX, mouseY);
caret = layout.visualCaretMove(caret, 1);   // physically right
caret = layout.visualCaretMove(caret, -1);  // physically left
```

`CaretAffinity.upstream` and `CaretAffinity.downstream` distinguish ambiguous insertion states. `TextEditor` retains this value across keyboard movement and undo/redo.

The compatibility `visualMove(logicalIndex, delta)` API guarantees progress but cannot represent all duplicate visual occurrences of one logical boundary. New editor code should use `CaretPosition`.

## Hit testing and selection

`hitTestCaret(x, y)` selects the nearest physical caret on the nearest line. `hitTest(x, y)` returns only its logical index.

`selectionRects(first, last)` returns one or more rectangles. A logically contiguous selection can be visually discontinuous on a mixed-direction line, so callers must not assume one rectangle per line.

`lineEdgeCaret(line, rightEdge)` implements physical Home/End behavior for a laid-out line rather than assuming that its logical start is on the left.

## Caching and invalidation

A `TextLayout` is cacheable and should be treated as read-only by callers. It can be reused while all of these remain unchanged:

- source text;
- layout options and available width;
- primary/fallback font collections;
- font pixel size and feature choices.

`FontSystem.revision` changes when primary faces or fallback collections change. `TextEditor` includes this revision in its layout cache dependencies.

The glyph atlas is independent of a particular `TextLayout`: glyphs are rasterized lazily by `(face identity, glyph index, pixel size, render mode)`. Aurora 0.4.2 uses the render-mode field for `sharp` versus `smooth` grayscale coverage; the variation-instance hash remains reserved.

## Conformance commands

```sh
dub run --config=unicode-conformance --build=debug -- \
  tools/unicode/17.0.0

dub run --config=text-boundaries --build=debug
dub run --config=text-system-test --build=debug
```

The first command uses the official Unicode data retained in the repository. `tools/generate_unicode.py` regenerates the compiled property tables from those same files.

## Current boundaries

The layout architecture supports positioned glyph runs and contextual OpenType lookups, but 0.4.2 does not include every higher-level typographic model:

- no full Indic/USE syllable machine and language-specific reordering for every complex script;
- no vertical writing or vertical OpenType metrics;
- no dictionary line breaking, hyphenation, justification, or locale tailoring;
- no UAX #29 word/sentence engine; editor word commands use a simple grapheme-safe heuristic;
- no rich-text spans with multiple sizes/styles in one layout;
- no IME composition ranges.

These are layout-policy additions. They do not require changing the Vulkan/software glyph-quad interface.

## Primary references

- Unicode Standard Annex #29, *Unicode Text Segmentation*, Unicode 17.0.0, revision 47: <https://www.unicode.org/reports/tr29/tr29-47.html>
- Unicode Standard Annex #9, *Unicode Bidirectional Algorithm*, Unicode 17.0.0: <https://www.unicode.org/reports/tr9/>
- Unicode Standard Annex #14, *Unicode Line Breaking Algorithm*, Unicode 17.0.0, revision 55: <https://www.unicode.org/reports/tr14/tr14-55.html>
- OpenType 1.9.1 specification: <https://learn.microsoft.com/en-us/typography/opentype/spec/>
