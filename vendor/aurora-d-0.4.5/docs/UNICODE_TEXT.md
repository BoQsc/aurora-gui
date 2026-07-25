# Unicode text architecture

Aurora-D 0.4.2 replaces the former one-code-point/one-glyph path with a renderer-neutral text layout. Unicode algorithms and OpenType shaping run before either renderer sees a glyph.

## Pipeline

```text
UTF-32 source
    │
    ├── extended grapheme segmentation
    ├── paragraph bidi resolution
    ├── script itemization
    ├── cluster-level font fallback
    ├── GDEF / GSUB / GPOS shaping
    ├── line-break opportunity resolution
    └── wrapping and visual run placement
            │
            ▼
        TextLayout
        ├── PositionedGlyph[]
        ├── GlyphRun[]
        ├── TextLine[]
        ├── VisualCluster[]
        └── CaretPosition[]
```

The original source remains in logical order. Visual reordering affects only layout records. Copying a bidi selection therefore preserves logical text order.

## Generated Unicode 17 data

`tools/generate_unicode.py` reads official Unicode 17.0.0 files from `tools/unicode/17.0.0` and emits `source/aurora/text/unicode/properties.d`.

Generated properties include:

- Grapheme_Cluster_Break;
- Indic_Conjunct_Break;
- Extended_Pictographic;
- Bidi_Class, paired brackets, and mirroring pairs;
- Line_Break and East_Asian_Width inputs used by LB1 resolution;
- Script;
- Joining_Type;
- General_Category and default-ignorable data needed by the algorithms.

Ranges are coalesced and binary-searched at runtime. The generator is deterministic, and the release validation compares a regenerated file byte-for-byte.

Unicode data is included under the terms in `LICENSE-UNICODE.txt`.

## Extended grapheme clusters

`aurora.text.unicode.grapheme` implements the extended grapheme rules in UAX #29, including:

- CR/LF and control handling;
- Hangul syllable sequences;
- combining extensions and spacing marks;
- prepend characters;
- emoji ZWJ sequences with Extended_Pictographic;
- paired regional indicators;
- Indic conjunct sequences through Indic_Conjunct_Break.

Public helpers:

```d
auto boundaries = graphemeBoundaries(text);
auto previous = previousGraphemeBoundary(text, index);
auto next = nextGraphemeBoundary(text, index);
auto safe = floorGraphemeBoundary(text, index);
```

The text editor uses these helpers for left/right logical movement, Backspace, Delete, selection normalization, and word-command safety. A decomposed accent, emoji family sequence, flag, or recognized Indic conjunct is not split by a normal character deletion.

## Bidirectional algorithm

`aurora.text.unicode.bidi.resolveBidi` implements UAX #9 through rule L2. It covers:

- paragraph level selection;
- explicit embeddings and overrides;
- isolates and isolating run sequences;
- weak-type resolution;
- paired-bracket neutral resolution;
- implicit levels;
- paragraph/segment separator resets;
- visual reordering and visual run construction.

```d
auto result = resolveBidi(text, ParagraphDirection.automatic);
foreach (logicalIndex; result.visualOrder)
    use(text[logicalIndex]);
```

Mirroring pairs are available to the shaping layer. Bidi formatting characters that are removed by rule X9 retain source indices but do not produce visible clusters.

### Dual carets and affinity

At an LTR/RTL boundary, one logical insertion offset can have two visually different caret positions. `CaretPosition` carries `CaretAffinity.upstream` or `.downstream` so hit testing and arrow navigation can preserve the intended visual state.

```d
auto caret = layout.hitTestCaret(x, y);
caret = layout.visualCaretMove(caret, +1);
```

The editor stores both the logical index and affinity. This prevents a visual arrow command from stalling at a bidi boundary or jumping to the opposite edge of a run.

## Line breaking and wrapping

`aurora.text.unicode.linebreak.lineBreakOpportunities` implements the Unicode line-breaking rules and returns a boundary decision for every source offset. The layout engine then chooses the last allowed break that fits `maxWidth`; when no allowed break fits, it falls back to an extended-grapheme boundary rather than splitting a cluster.

```d
TextLayoutOptions options;
options.maxWidth = 360;
options.wrap = true;
auto layout = engine.layout(text, options);
```

Hard paragraph separators create new lines. Soft wrap boundaries can create two carets at one logical index, distinguished by affinity.

Dictionary segmentation, language-specific hyphenation, and locale tailoring are not included.

## Script itemization

The layout engine assigns Unicode Script values and propagates Common/Inherited characters into neighboring script runs where appropriate. It maps common Unicode scripts to OpenType tags, then splits shaping runs when script, font, bidi level, or paragraph state changes.

This gives OpenType tables the script and direction context they require while retaining original cluster ranges.

## Font fallback

Fallback is resolved for one extended grapheme cluster at a time. The first face that supports every renderable code point in the cluster is selected. Default ignorables, variation selectors, ZWJ/ZWNJ, and other shaping controls do not independently force another face.

The layout engine can therefore produce a paragraph containing multiple fonts while keeping each cluster internally coherent.

## OpenType shaping and clusters

`ShapeInput` records a code point and its logical cluster range. GSUB substitutions preserve or merge those ranges:

- a ligature gets the union of all participating source clusters;
- a multiple substitution keeps the source range on every output glyph;
- contextual substitutions do not discard source mapping;
- hidden/default-ignorable glyphs remain non-rendering but source-addressable.

After GPOS, `TextLayout` groups glyph geometry back into visual clusters. Ligature carets use GDEF data when available; otherwise the cluster width is divided deterministically among grapheme components.

## Selection geometry

A logical selection can be visually discontinuous on a bidi line. `TextLayout.selectionRects` gathers the visual clusters whose logical source ranges overlap the selection and coalesces only adjacent spans:

```d
foreach (rect; layout.selectionRects(anchor, cursor))
    canvas.fillRect(rect, theme.selection);
```

The text editor uses those rectangles directly, so painted selection and mouse hit testing use the same shaped data.

## Editor integration

`TextEditor`/`TextArea` caches line layouts from the host window's `FontSystem`. It no longer estimates positions with a fixed character width.

Implemented behaviors include:

- visual horizontal arrows through shaped LTR/RTL runs;
- grapheme-safe Backspace/Delete;
- vertical movement using the prior visual X coordinate;
- shaped mouse hit testing;
- bidi selection rectangles;
- Unicode soft wrapping;
- scroll offsets measured in pixels;
- GDEF/fallback-aware caret placement;
- logical-order copy and paste.

The editor still stores UTF-32 code points and exposes indices in that coordinate system.

## Conformance data

The repository includes and runs the official Unicode 17 corpora:

- `GraphemeBreakTest.txt`;
- `LineBreakTest.txt`;
- `BidiCharacterTest.txt`;
- `BidiTest.txt`.

Recorded release results are in `docs/VALIDATION.md`.

## Current boundaries

The Unicode segmentation, bidi, and line-break algorithms are conformance-tested. The following higher-level capabilities remain outside 0.4.2:

- UAX #29 word and sentence boundary engines;
- locale tailoring and dictionary word/line segmentation;
- normalization as an automatic document mutation;
- full script-specific syllable/reordering engines for every complex script;
- vertical layout and ruby/annotation positioning;
- IME composition and accessibility text interfaces.

## Primary references

- Unicode Standard Annex #29, Unicode Text Segmentation: <https://www.unicode.org/reports/tr29/>
- Unicode Standard Annex #9, Unicode Bidirectional Algorithm: <https://www.unicode.org/reports/tr9/>
- Unicode Standard Annex #14, Unicode Line Breaking Algorithm: <https://www.unicode.org/reports/tr14/>
- Unicode Character Database 17.0.0: <https://www.unicode.org/Public/17.0.0/ucd/>
- Unicode conformance requirements: <https://www.unicode.org/versions/Unicode17.0.0/ch03.pdf>
