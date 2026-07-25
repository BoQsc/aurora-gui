# Font rendering and OpenType shaping

Aurora-D owns its font pipeline. It reads sfnt/OpenType data in D, shapes into positioned glyph runs, rasterizes outlines into grayscale coverage, and caches that coverage in the same atlas consumed by Vulkan and software. It does not call FreeType, HarfBuzz, ICU, DirectWrite, CoreText, Fontconfig, or another runtime text library.

## Supported containers and outlines

`FontFace.load(path, faceIndex)` accepts:

- standalone sfnt/OpenType `.ttf` and `.otf` files;
- TrueType/OpenType Collections (`.ttc`/`.otc`) with a selectable face index;
- TrueType `glyf`/`loca` quadratic outlines;
- static CFF1 `CFF ` Type 2 charstrings, including name-keyed and CID-keyed faces.

A face containing only `CFF2` is rejected with an explicit exception. CFF2 is tied to the variable-font model and is not interpreted as static CFF1.

## sfnt tables

The low-level face reader uses:

| Table | Purpose |
|---|---|
| `head` | units per em, global bounds, `loca` format |
| `hhea` | ascent, descent, line gap, horizontal metric count |
| `maxp` | glyph count |
| `hmtx` | horizontal advances and side bearings |
| `cmap` | Unicode-to-glyph mapping, formats 4 and 12 |
| `loca` / `glyf` | TrueType glyph locations and quadratic outlines |
| `CFF ` | static Compact Font Format 1 outlines |
| `name` | family-name discovery |
| `kern` | legacy version-0 format-0 horizontal pairs |
| `GDEF` | glyph classes, mark sets, ligature caret positions |
| `GSUB` | glyph substitutions |
| `GPOS` | glyph positioning |

Unknown tables remain available through `FontFace.tableData(tag)` and do not need to be copied into a second buffer.

## TrueType outline support

The `glyf` reader handles:

- simple glyph flags and delta-compressed X/Y coordinates;
- implied on-curve points between consecutive quadratic controls;
- short and long `loca` formats;
- compound glyph byte/word arguments;
- signed XY offsets and point-to-point attachment;
- uniform, independent X/Y, and 2×2 transforms;
- scaled component offsets and grid-rounded component offsets;
- nested components with a recursion limit.

TrueType instructions are skipped. Aurora does not execute the bytecode virtual machine or grid-fit outlines.

## Static CFF1 support

`aurora.text.cff` parses:

- CFF headers, INDEX structures, top/private DICTs, String INDEX, and Global Subr INDEX;
- CharStrings INDEX and local/global subroutines with Type 2 subroutine bias;
- name-keyed private dictionaries;
- CID-keyed ROS, `FDArray`, and `FDSelect` formats 0, 3, and 4;
- stem/hint operators and mask lengths (hints are consumed but not grid-fitted);
- line, cubic curve, alternating curve, flex, arithmetic, stack, transient-array, and subroutine operators used by static Type 2 charstrings;
- default and nominal widths.

Cubic paths are adaptively flattened before the same nonzero-winding rasterizer used by TrueType outlines.

The CFF decoder is intentionally internal. Applications load either outline model through the same `FontFace` API.

## Shaping

`OpenTypeShaper` receives Unicode code points with source-cluster ranges and emits `ShapedGlyph` records while preserving those ranges through substitutions.

### Feature and language selection

Aurora reads ScriptList, LangSys, FeatureList, and LookupList data. It chooses an OpenType script tag from the Unicode script property, uses the requested language tag when present, falls back to the default language system, and applies required features before optional features.

The standard feature policy includes canonical/localized forms, required/common ligatures, contextual alternates, kerning, mark attachment, cursive attachment, and Arabic joining features. `TextLayoutOptions` can disable kerning, ligatures, contextual alternates, or mark positioning.

### GDEF

Supported data includes:

- glyph class definitions;
- mark attachment class definitions;
- mark glyph sets used by lookup flags;
- ligature caret lists used by `TextLayout` when a font provides explicit caret positions.

### GSUB

Implemented lookup types:

1. Single substitution
2. Multiple substitution
3. Alternate substitution (first applicable alternate)
4. Ligature substitution
5. Contextual substitution, formats 1–3
6. Chaining contextual substitution, formats 1–3
7. Extension substitution
8. Reverse chaining single substitution

Substitution keeps the union of logical source ranges. Ligature records retain component counts so caret placement can use GDEF caret data or a deterministic component fallback.

### GPOS

Implemented lookup types:

1. Single adjustment
2. Pair adjustment, glyph and class formats
3. Cursive attachment
4. Mark-to-base attachment
5. Mark-to-ligature attachment
6. Mark-to-mark attachment
7. Contextual positioning
8. Chaining contextual positioning
9. Extension positioning

Value records, coverage/class definitions, anchor formats, lookup flags, ignored glyph classes, mark filtering sets, and nested lookups are handled by the same shaper. Legacy `kern` pairs are used only when no OpenType positioning supplied pair kerning.

### Arabic joining

Unicode joining types are generated from the official `ArabicShaping.txt` data. Aurora assigns isolated, initial, medial, and final feature masks before GSUB, while transparent joining characters remain in the shaping context. This supports the standard positional joining model used by Arabic and the other scripts covered by that property data.

## Font collections and fallback

A `FontCollection` is ordered. Resolution happens for a complete extended grapheme cluster:

```d
auto collection = new FontCollection(FontFace.load("/fonts/Primary.otf"));
collection.add("/fonts/NotoSansArabic-Regular.ttf");
collection.add("/fonts/NotoSansCJK-Regular.ttc", 0);
```

Window convenience API:

```d
window.addFontFallback(FontRole.ui, "/fonts/NotoSansArabic-Regular.ttf");
window.addFontFallback(FontRole.ui, "/fonts/NotoSansCJK-Regular.ttc", 0);
```

Variation selectors, join controls, and default-ignorable code points do not force a fallback by themselves. A base and its marks are not deliberately split between unrelated faces.

`FontCollection.system` uses known platform font paths, then adds the built-in emergency face. It is path-based discovery, not a complete query of the operating system's font database.

## Layout boundary

Shaping is not performed directly by widgets. `TextLayoutEngine` combines grapheme boundaries, bidi levels, script runs, font fallback, OpenType shaping, and line breaks into a cacheable `TextLayout`.

```d
TextLayoutOptions options;
options.pixelSize = 18;
options.maxWidth = 480;
options.wrap = true;

auto layout = window.fontSystem().textEngine.layout(text, options);
```

A layout contains positioned glyphs, visual runs, lines, visual clusters, caret states, and selection/hit-test geometry. The renderers only replay the positioned glyphs.

## Rasterization

For a requested glyph and pixel size Aurora:

1. decodes a quadratic or cubic outline;
2. applies component/CFF transforms in font units;
3. adaptively flattens curves to edges;
4. computes pixel bounds and baseline bearings;
5. evaluates a nonzero winding fill on a 4×4 sample grid;
6. stores 0–255 A8 coverage.

The deterministic supersampled path favors cross-platform consistency over TrueType grid fitting. Aurora 0.4.2 adds two coverage policies: `smooth` retains the raw samples, while `sharp` expands intermediate A8 contrast. At high DPI the glyph is rasterized at monitor-pixel size rather than enlarging a 96-DPI bitmap. Small text can still differ from a native hinted renderer because TrueType bytecode and LCD subpixel rendering are not executed.

## Rasterization modes

`WindowOptions.fontRenderMode` defaults to `FontRenderMode.sharp`. The mode can be changed with `GuiWindow.setFontRenderMode`, which clears size/mode-dependent atlas entries and invalidates the window. `AURORA_FONT_RENDER_MODE=sharp|smooth` provides a process-level override.

Sharp mode changes only intermediate coverage values; zero and 255 remain exact. It remains grayscale, deterministic, and renderer-independent. It is not an implementation of TrueType bytecode hinting or DirectWrite/ClearType.

## Glyph atlas

`GlyphAtlas` starts at 512×512, shelf-packs one-pixel-padded glyphs, and grows while preserving existing coordinates up to 4096×4096. Its cache key contains:

```text
face identity + glyph index + pixel size + render flags + variation hash
```

The render-flags field distinguishes `FontRenderMode.smooth` and `FontRenderMode.sharp`. The variation hash remains reserved for future variable-font instances.

Vulkan stores the atlas as `VK_FORMAT_R8_UNORM`. Vulkan and software sample the physical-size, pixel-snapped glyph quad with nearest filtering so the rasterizer's coverage bytes are not blurred a second time.

## Current font boundaries

Not implemented in 0.4.2:

- CFF2 and variable-font deltas/axis selection;
- TrueType bytecode hinting;
- COLR/CPAL, CBDT/CBLC, `sbix`, SVG, or other color-glyph rendering;
- vertical metrics/layout;
- script-specialized syllable machines for every Indic and Southeast Asian script;
- optical sizing, justification, hyphenation, or locale-specific typography.

Generic GSUB/GPOS lookup execution is broad, but complete shaping for every script can additionally require script-specific Unicode preprocessing and reordering.

## Primary references

- OpenType specification, font file: <https://learn.microsoft.com/typography/opentype/spec/>
- OpenType GDEF: <https://learn.microsoft.com/typography/opentype/spec/gdef>
- OpenType GSUB: <https://learn.microsoft.com/typography/opentype/spec/gsub>
- OpenType GPOS: <https://learn.microsoft.com/typography/opentype/spec/gpos>
- OpenType CFF: <https://learn.microsoft.com/typography/opentype/spec/cff>
- Type 2 Charstring Format: <https://adobe-type-tools.github.io/font-tech-notes/pdfs/5177.Type2.pdf>
