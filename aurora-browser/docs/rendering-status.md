# Rendering verification status

What Aurora's rendering is checked against, what that proves, and what it does
not. Keep this file current when a corpus changes; the checklists elsewhere in
this directory describe the wider browser work.

## The independent oracle

Correctness evidence comes from an **installed Edge (Chromium) browser**, used
only as an external reference. It is never bundled and is not part of the Aurora
engine (see `third-party-inventory.json`).

`aurora-opencode-pro/tools/capture-browser-reference.py` serves frozen local
fixtures over loopback, screenshots each one in Edge at a fixed viewport
(320x240, device scale factor 1, scrollbars hidden), and writes:

- `manifest.json` — the browser path and SHA-256, the viewport, and for every
  case the fixture path, its HTML SHA-256, the reference PNG and its SHA-256;
- `verify.json` — a saved verification recipe: compile the probe, compile and
  run the engine unittests, then for each case render the fixture through
  `browser-probe.d` and compare the result pixel-for-pixel with the reference.

Run a corpus with the saved recipe (`verify` on
`aurora-opencode-pro/build/browser-reference-validation-<n>/verify.json`). A
recipe may hold at most 16 steps, and each case costs two, so **a corpus covers
at most six fixtures**. That is why the fixtures are split across two
directories rather than one growing corpus.

## Fixtures with independent references

`aurora-opencode-pro/tests/browser-fixtures/` (corpus **-4**, six cases):

| Fixture | Behaviour pinned by Edge | Metric-free because |
| --- | --- | --- |
| `box-model.html` | content-box sizing, padding/border/shorthand colour | colours and edges |
| `flex-grid.html` | grid `gap`, flex row geometry, margin collapsing | explicit sizes |
| `float-context.html` | a float in a non-BFC child stays active for later siblings; a BFC root's auto height contains its floats (CSS 2.1 10.6.7) | floats are pure geometry |
| `float-line.html` | line boxes shorten beside a float (CSS 9.5); `vertical-align: top/bottom` against the line box | atomic inline-level boxes |
| `font-shorthand.html` | the `font` shorthand sets size, line-height and family; unset shorthand changes every bar | ink-free `&nbsp;` bars encode line-height |
| `svg-position.html` | SVG box position and viewBox mapping | vector geometry |

`aurora-opencode-pro/tests/browser-fixtures-positioning/` (corpus **-6**, six
cases; -5 is the same corpus without the last row):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `position-absolute.html` | absolute insets against a positioned ancestor, both-insets width, percentage insets, out-of-flow siblings |
| `inline-alignment.html` | `vertical-align: top/bottom`, and a line box growing to contain a taller inline-block (CSS 10.8.1) |
| `size-percent.html` | percentage width/height, `margin: 0 auto` centring, `max-width` clamping |
| `float-clear.html` | right float, a left float that cannot fit and drops below (CSS 9.5.1), `clear: both` (CSS 9.5.2) |
| `flex-align.html` | `justify-content: space-between/flex-end`, `align-items: center` against the row's cross size (CSS Flexbox 8.3, 9.4) |
| `inline-block-row.html` | the row `docs.djangoproject.com`'s footer uses: a 24px label line, then inline-block logos taller than the 19px line-height, so the line box grows to 33px (CSS 10.8.1) and the float's auto height becomes 24 + 33 = 57 (CSS 10.6.7) |

`aurora-opencode-pro/tests/browser-fixtures-layout/` (corpus **-7**, six cases):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `table-layout.html` | the table display model built from generic elements: three 80px columns, and every cell stretched to its row's height (CSS 17.5.3) |
| `flex-wrap.html` | `flex-wrap: wrap` puts the item that does not fit on a second line at that line's top (CSS Flexbox 9.3) |
| `transform-translate.html` | a translated box moves without affecting layout, and paints with the positioned group above a later plain block (CSS Transforms 1; CSS 2.1 App. E) |
| `overflow-clip.html` | `overflow: hidden` clips an oversized child to the box and still contributes no extra height |
| `relative-offset.html` | `position: relative` offsets the painted box while its flow space stays put (CSS 9.4.3) |
| `stacking-order.html` | overlapping positioned boxes paint by `z-index`, not document order (CSS 2.1 App. E) |

`aurora-opencode-pro/tests/browser-fixtures-paint/` (corpus **-8**, four cases):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `align-content.html` | a wrapping row taller than its lines distributes the extra cross space (CSS Flexbox 8.5) |
| `box-shadow.html` | a zero-blur shadow offset by 10px is a solid rectangle behind the box |
| `opacity-blend.html` | two 50% black boxes over a #808080 page composite to exact rgb(64,64,64) and rgb(32,32,32) |
| `sticky-position.html` | a sticky box at scroll 0 satisfies its `top` inset like a relative offset, leaving its flow space intact |

`aurora-opencode-pro/tests/browser-fixtures-flex-stretch/` (corpus **-9**, five
cases):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `flex-stretch.html` | `align-items: stretch` (the initial value) grows an auto-height item to the row's cross size, while `align-self` overrides stay where they are placed (CSS Flexbox 8.3) |
| `flex-stretch-auto.html` | with no row height, the cross size is the tallest item and every auto item stretches to it (CSS Flexbox 9.4) |
| `flex-stretch-wrap.html` | each item stretches to its OWN line's cross size, not the container's |
| `flex-stretch-pad.html` | a stretched item's padding and border sit inside the cross size (content box 62 in an 80px row) |
| `flex-stretch-nested.html` | the stretched item re-lays out its subtree, so a `height:100%` child fills it (CSS 10.5) |

`aurora-opencode-pro/tests/browser-fixtures-align-content/` (corpus **-10**, two
cases):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `align-content-stretch.html` | the `normal`/stretch default grows each of two equal auto lines by half the left-over cross space, and `align-items: stretch` fills each line |
| `align-content-stretch-mixed.html` | lines of different natural height share the left-over space equally, moving the lower line down and growing only the auto-height item |

`aurora-opencode-pro/tests/browser-fixtures-flex-column/` (corpus **-11**, four
cases):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `flex-column-center.html` | a column's `justify-content: center` and `align-items: center` centre the item on both axes |
| `flex-column-end.html` | `justify-content: flex-end` packs to the bottom and `align-items: flex-end` to the right |
| `flex-column-between.html` | `justify-content: space-between` spreads three items to the first, middle and last positions |
| `flex-column-reverse.html` | `flex-direction: column-reverse` packs items from the bottom edge |

`aurora-opencode-pro/tests/browser-fixtures-flex-margin/` (corpus **-12**, four
cases):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `flex-margin-auto-row.html` | `margin-left: auto; margin-right: auto` centres a fixed-width item on the row's main axis |
| `flex-margin-auto-col.html` | in a column, `margin: auto` centres the item on both axes |
| `flex-margin-top-auto.html` | `margin-top: auto` pins the item to the bottom of the column while the earlier item stays at the top |
| `flex-margin-left-auto.html` | a lone `margin-left: auto` pushes the item to the right edge of the row, and the following item with it |

`aurora-opencode-pro/tests/browser-fixtures-flex-basis/` (corpus **-13**, four
cases):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `flex-basis-grow.html` | the `flex: <number>` shorthand sets the grow factor, so a 300px row splits 200/100 (CSS Flexbox 7.1.1) |
| `flex-basis-length.html` | an explicit `flex-basis` is the item's base size and left-over space is not distributed while `flex-grow` stays 0 |
| `flex-shrink-none.html` | `flex-shrink: 0` keeps its 200px base while the whole overflow falls on the shrinkable sibling (CSS Flexbox 7.1.2) |
| `flex-shrink-weight.html` | three 150px bases in a 300px row each shrink to 100, the scaled shrink factor being weighted by each base size |

`aurora-opencode-pro/tests/browser-fixtures-pad-container/` (corpus **-14**,
three cases; this is the corpus that pinned the content-box item region):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `flex-pad-container.html` | a padded flex container lays its items out on its **content box**, so the padding is subtracted exactly once |
| `grid-pad-container.html` | `grid-template-columns` track sizes and `gap` resolve against the padded container's content box |
| `table-pad-container.html` | a padded table container's columns fill its content box and its auto height is the content-box height |

`aurora-opencode-pro/tests/browser-fixtures-line-height-normal/` (corpus
**-15**, one case):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `line-height-normal.html` | `line-height: normal` is the font's own normal metric, and `font-family: Arial, sans-serif` selects that installed face and its metrics; white-on-white text leaves no ink, so the only visible geometry is where the marker lands |

`aurora-opencode-pro/tests/browser-fixtures-web-font/` (corpus
`browser-reference-web-font`, one case, kept in the checkout rather than under
`build/`):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `webfont.html` | `@font-face` is the only possible source of the two families it uses, so the shaped advance width of twenty `m`s can only match Edge if the rule was parsed, its `src` list walked past the first entry (a woff2 URL that does not exist) to the TrueType that follows, the file fetched and the resulting face used for measurement; the two identically-sized chips 12px apart also pin inline-block shrink-to-fit, baseline placement and the collapsed space between them. `color: transparent` keeps glyph rasterisation out of the pixels while the text still drives the width. |

`aurora-opencode-pro/tests/browser-fixtures-flex-cross-margin/` (corpus
**-17**, one case):

| Fixture | Behaviour pinned by Edge |
| --- | --- |
| `flex-cross-margin.html` | a flex ROW item's cross-axis margin belongs to the line and to the item's own placement: the padded row is 72px (10 + the 56px line + 6), the 36px logo starts at y=20 and the 10px marker is centred at y=33. `align-items: flex-start`/`flex-end` place the same margin box against the line's top and bottom on two further 40px rows. Every box is a flat colour and there is no text, so the comparison is exact geometry. |

Two further corpora were re-captured inside the checkout after the fixes below,
because a saved recipe pins the engine sources it was taken with:
`browser-reference-layout` (six layout cases, 0 mismatched) and
`browser-reference-line-height-normal` (one case, 0 mismatched). These three
in-checkout corpora are the current evidence; the
`build/browser-reference-validation-<n>/` corpora remain the record of what each
earlier fix pinned.

All these corpora also run `interaction.html`, which asserts through the DOM that a
click reaches its handler and that link hit-testing returns the right
destination.

## Engine fixes pinned by these corpora

- **Content-box item region (-14, and the padded case in -9).**
  `element.box.width` is already the content box, but `layoutFlex`,
  `layoutGrid` and `layoutTable` subtracted the container's own padding and
  border from it a second time, so every padded flex, grid or table container
  laid its items out too narrow by that padding (the `djangoproject.com` header
  `.container` is a padded flex row, and the whole page shifted because of it).
  The item region is now exactly `width`, with `innerX`/`innerY` remaining the
  border+padding content origin; grid tracks and `gap` resolve against that same
  content box, and an auto-height padded container reports its content-box
  height.
- **`line-height: normal` (-15).** The fallback was the font size plus 8 pixels
  (24px for 16px text) instead of the font's own normal metric (about 18.4px for
  a 16px Arial), which inflated every line box and pushed real pages taller than
  Edge. It now asks the shaping face for its normal line height.
- **CSS `font-family` (-15).** The engine ignored `font-family` and shaped
  everything in its UI face. Families, weights and styles now resolve through the
  vendor system-font inventory, falling through the list when a family is not
  installed, and the resolved face is threaded through measurement, shaping,
  painting and line height.

- **`@font-face` webfonts (`browser-reference-web-font`).** The engine parsed
  `@font-face` rules but never fetched a face, so a page whose text depends on a
  webfont was shaped in whatever installed family came next and came out wider
  than Edge. `src` entries are now resolved in order - a candidate the engine
  cannot decode is skipped exactly as a browser skips a source it cannot parse -
  then fetched, registered as a face and used by layout, measurement, shaping and
  painting. The engine decodes the uncompressed `sfnt` (TrueType/OpenType)
  containers and unwraps a WOFF 1.0 one (`woff.d`, reached through `css.d`
  pickFontSrc), and decodes a WOFF 2.0 one (`woff2.d` over `brotli.d`, reached
  the same way); `embedded-opentype` and the legacy `svg` font format are
  skipped, so the fixture's second family still pins the walk past a woff2 whose
  URL does not exist to the TrueType that follows it, and the fixture as a whole
  pins the path with a family no machine installs. Verified on a real page as
  well: `djangoproject.com`'s nav icons come from FontAwesome's woff-only face
  and land where Edge's do (see "Known-site measured status").

- **WOFF 2.0 webfonts (the `djangoproject.com` text faces).** The site's
  stylesheet declares every text face as `woff2` alone - all seven `@font-face`
  rules carry a single `src:url(...woff2) format("woff2")`, and only the
  FontAwesome icon face is served as `woff` - so until now the page fell through
  its family list to an installed substitute and every text band was shaped with
  the wrong glyphs and the wrong advances. `brotli.d` is a from-scratch RFC 7932
  decoder (stream header, meta-block loop, prefix codes, context maps, repeat
  codes, ring-buffer distances) and `woff2.d` is the container: header and
  `UIntBase128`/`255UInt16` directory, the transformed `glyf`/`loca` triplet
  form, `hmtx` reconstruction and sfnt assembly with recalculated checksums.
  Evidence against the file the site itself serves
  (`Roboto-Light.4b97d1da126a.woff2`, SHA-256
  `2772d27df0741ab3683a2f581c84edae744918d64249098eb2387db81c24bdbe`): its
  Brotli stream decodes to the 139743 bytes the header declares, the
  reconstructed `glyf` is byte-identical to `fontTools`' independent woff2
  decode for all 1321 glyphs, and the assembled font's whole-font checksum
  matches the sfnt's own `0x2981146554`. On the live page the shaped advances
  are then Edge's: with the stylesheet's `letter-spacing:-1px`, the CTA label
  `Get started with Django` at 18px inks 167 against an independent Edge frame's
  166, and the tagline's first word at 36px inks 101 against Edge's 102.

- **Inline and inline-block geometry (same corpus).** Five conventions were
  wrong at once. An auto-height inline-block was sized from the containing
  block's line box instead of its own content (21px where Edge has 14px). Its
  shrink-to-fit width was truncated rather than rounded (197 where Edge has
  198). A whitespace-only text run advanced a hard-coded half-em
  (`pixelSize / 2`, 8px at 16px) instead of the face's own space (about 4px),
  which moved every inline box after such a run to the right. `box.y` is the
  border-box origin used for painting, but an inline-block's baseline placement
  did not subtract its top padding and border (2px low) and its content flow did
  not add them (a bordered box's text started at the border edge). And the line
  box did not grow to contain a padded inline-block's border box (CSS 10.8.1).
  The fixture's two chips now land on Edge's exact coordinates.

- **Flex row items' cross-axis margins, and a padded row's auto height (-17).**
  A row item's vertical margins were ignored twice over: the line's cross size
  was the item's border box rather than its outer box (CSS Flexbox 9.4), and
  alignment placed that border box instead of its margin box (9.6). With
  `header .logo{margin:10px 4px}` contributing nothing, `djangoproject.com`'s
  header came out 36px where Edge makes it 56, and the wordmark landed at the
  line's start instead of 20px down. Both now follow the standard. Re-measuring
  the same fixture then exposed the other half of the pair: the single-line row
  path took its auto height from `clampedContentHeight`, which deliberately
  omits a border-box element's padding and border, so a padded row came out one
  padding-and-border SHORT of Edge - `padding:10px 0 6px` around a 56px line is
  72px in Edge, not 56. That path now uses `contentBoxHeight` (CSS 10.4), as the
   item, column and wrap paths already did. The fixture then matched Edge byte
   for byte, 0 mismatched pixels. (Corrected below: the height was never the
   fault - advancing the flow past the row ignored the row's own padding and
   border. See "Padded containers: the content box and the border box".)

- **A flex item's aligned content moves with its box (real page, `layout.d`
  unittest).** Cross-axis alignment set the aligned item's own `box.y` but left
  everything inside it at the position the unaligned layout had given it, so an
  aligned item's box and its own content disagreed by exactly the distance
  alignment moved the box: the item's background and border sat in the right row
  while its text, images and inline-block content painted up to 8px above it.
  The alignment sites (`flex-start`, `flex-end` and centre) now shift the item's
  whole box tree by the same delta that moves its box (`placeItemY`,
  `shiftBoxTreeY`), which is what the main-axis path already did.
  `djangoproject.com`'s header nav row is the case that exposed it: its labels'
  ink moved from page y 23..38 to y 31..46 against an independent Edge frame's
  33..41, and the row's light-ink columns then agreed with Edge within 1..4px
  across x 395..1279. The `flex-cross-margin` fixture cannot catch this class -
  every box in it is a flat colour with no text, so nothing inside a placed item
  can be left behind - so the pin is a `layout.d` unittest asserting that a
  centred flex item's text moves with its box.

- **Padded containers: the content box and the border box (-18).** `box.width`
  and `box.height` store the CONTENT box, and `paint.d` adds the element's padding
  and border when it draws - a convention already pinned by a unittest for a
  border-box element. Two separate paths broke it:

  * `layoutBlock`'s AUTO height stored the BORDER height: it added the box's own
    bottom padding and border after measuring an inner flow that already starts at
    the content origin. `paint.d` then padded that value a second time, so every
    auto-height padded block drew one padding-and-border too tall - a
    `padding:10px;border:5px` box drew 110px where Edge draws 80, and an
    auto-height padded *empty* box drew 60 where Edge draws 30.
  * Every flow advance used the stored content box without the container's own
    padding and border, so the next sibling started at the content bottom:
    `layoutBlock` (`const bottom = layoutTop + element.box.height + …`), the
    flex row path, and the grid/table paths. A `height:50px;padding:10px;
    border:5px` block advanced the flow by 50 where Edge starts the next sibling
    at 80.

  A helper, `borderBoxHeight`, now makes the second half explicit and is used by
  the block and flex-row advances. With the auto height corrected, an
  auto-height padded container's *layout* is unchanged (its advance adds exactly
  what its height no longer includes), so the fix is a paint correction plus a
  real advance correction for definite-height containers.
  `browser-fixtures-pad-advance/pad-advance.html` pins both against Edge with flat
  colours and no text: `.p` (`height:50px;padding:10px;border:5px`) must have its
  sibling at y=80, `.q` (the same box, auto height, a 50px child) must draw its
  child at y=115..164 and its sibling at y=150. Corpus `-18` renders it at 0
  mismatched pixels, and the same fixture shape is what `djangoproject.com`'s
  padded header uses.

Still open from the same family of defects, and deliberately left alone until
each has its own fixture: the flex COLUMN and WRAP-line paths still store the
border height (they call `contentBoxHeight`) and their advances still use the
stored box, so a padded container stays self-consistently wrong there rather than
half-fixed; the absolute/fixed container path has the same open question.

## Last full re-run

2026-10-17: the whole frozen set passed. Corpora `-4` … `-15` each reported
`passed: true` with 0 mismatched pixels on every render step and unchanged
recipes (`failing: []`, `changedRecipes: []`). The app recipe
`aurora-browser/tests/verify-render.json` reported a clean compile, smoke
`ALL PASSED`, and render `mismatchedPixels 0` against its re-frozen baseline
(`inputsSha256 A87741D9…`, `recipeSha256 BB739184…`, frame sha `AA417E05…`).
The same recipe also compiles `aurora-browser-new.exe` and runs it on
`djangoproject.com`; the corpus `-15` recipe passes with its interaction step and
`39 modules passed unittests` from the corpus harness's engine-checks.

Later the same day, after the webfont and inline-layout fixes below:
`browser-reference-web-font` reported `passed: true` with `mismatchedPixels 0`
(`inputsSha256 808CE3C1…`, `recipeSha256 17CF7208…`, reference `E5564566…`,
frame `AB5E409B…`) with `39 modules passed unittests` and its interaction step
passing. Re-captured with that same engine, `browser-reference-layout` reported
0 mismatched on all six cases and `browser-reference-line-height-normal` 0 on
its one case, so the shared inline code paths did not regress the earlier Edge
references. The app recipe `aurora-browser/tests/verify-render.json` pins the
engine sources, so it must be re-frozen against this engine before it can pass
again; its last run, before these fixes, was clean (smoke `ALL PASSED`,
`mismatchedPixels 0`, `inputsSha256 A87741D9…`).

Re-run against this engine, the recipe's **tests** step is clean:
`headless_smoke: ALL PASSED`, 91 checks, including the real-input ones that route
a pointer through `UiTestDriver.moveTo` / `wheel` / `doubleClick` / `rightClick`
(`headless_smoke.d` 449-520 - the `:hover`, `onmouseenter`, `onwheel`,
`ondblclick` and `oncontextmenu` page callbacks). An earlier run of this recipe
reported `7 FAILURES` on exactly those checks while `click`, `text` and
`pressKey` in the same block passed; the current sources pass all of them. That
earlier failure was not isolated - the failing path was the window's hover/wheel
routing, and the fixture those checks drive is laid out by the same inline code
this work changed, so a stale control position is the likely link - and it is
recorded here as history, not as an open defect: the checks pass now.

The recipe's own render step then ran in-recipe: `mismatchedPixels 0` of
1,024,000, reference and frame carrying the same SHA-256
(`8DD90E904C81F931202C4DD1D6C56665E22BA41ABF52D5E644CD44B3741E7BEC`), plus the
release `aurora-browser-new.exe` compile and the live `djangoproject.com` capture
step (`inputsSha256 41ECE571…`, `recipeSha256 CB2CC00C…`).

The frozen reference had to be re-frozen first, and the reason was not the live
page's content - it was the platform colour scheme. `django29ref.ppm` predates
the `prefers-color-scheme` fix (see "Colour scheme" above) and therefore encodes
the LIGHT theme, which this machine no longer sees: `AppsUseLightTheme = 0`, and
an independent Edge frame captured for the same 1280x800, 1x request
(`edge-django-today.png`) is a dark page - green header band with the wordmark
and the `OVERVIEW … SPONSOR` nav row, near-black hero with the tagline on two
lines, the green `Get started with Django` CTA, the dark `Meet Django` section
carrying the green `Download latest release: 6.1.2` card, `Support Django!` and
the fundraiser row. Against that Edge frame the engine differs in 2478 of 40832
cells (6.1%, rows 638 x 64 cells), and every divergent band is a text or control
band - page rows 12, 23..42 (the nav row), 46, 76..83 (the search field), 231,
233..259 and 279..306 (the tagline), 362..422 (the CTA), 538, 588..610, 612 -
the substitute-font metric class recorded above, not layout or palette. The
superseded light frame is kept beside the new one as
`django29ref-pre-color-scheme.ppm`.

Later the same day, after the WOFF 2.0 webfont fix (see "Engine fixes pinned by
these corpora"): the app recipe ran clean against a re-frozen baseline -
`passed: true`, smoke `ALL PASSED` (91 checks, measured by counting the suite's
own PASS lines), render `mismatchedPixels 0` of 1,024,000 with reference and
frame both carrying SHA-256
`CBAC1963BBEFB00D83E455EE3420B15154254D44723F8B03047D7E0F9907DFE0`, plus the
release `aurora-browser-new.exe` compile and the live `djangoproject.com`
capture (`inputsSha256 FD534029…`, `recipeSha256 9C5B8C7D…`). This re-freeze is
for the decoder, not for the page: the superseded frame was captured while the
site's text faces were still undecodable, so it records substitute-face text,
and it is kept beside the new one as `django29ref-pre-woff2.ppm` (SHA-256
`A76F187028EFF991DA3FF057D2D027A85297B5E66E7609A68D8401D468164517`). Against
the independent Edge frame `edge-live-new.png` (page-only 1280x638, SHA-256
`f1daf365c218968859cec146fe5dc99c31bc74397b81268312d52e4ff136534b`) the new
frame differs in 2249 of 40832 64-cell rows (5.5%) against the superseded
frame's 1631 (4.0%), and the measured cause of that increase is one line break
in the hero: the tagline string through `apps` measures 698.05px with the
stylesheet's own `letter-spacing:-1px` and the served Roboto Light, against the
rule's `max-width:700px`, so Edge breaks two pixels the other side of that
edge. Independent of that break, the same-string glyph advances now agree with
Edge - the CTA label `Get started with Django` at 18px inks 167px against 166,
the tagline's first word at 36px inks 101px against 102 - which is the coupling
the substitute faces could not produce.

The decoder did not disturb the Edge-referenced fixtures. Re-run after it,
`browser-reference-web-font` - the corpus whose `src` list walks past a woff2 -
matched its frozen Edge reference at `mismatchedPixels 0` of 76,800,
`browser-reference-layout` matched at 0 on all six of its cases and
`browser-reference-line-height-normal` at 0 on its one case, each reporting
`43 modules passed unittests` and `PASS independent click-handler and
link-destination assertions`.

Two further consequences of the real faces, measured in the same Edge pair.
The dark green header band now ends at page y=137 against Edge's 138 - it ended
at 132 while the text faces were undecodable, which is the 5px residue this
document recorded as a line-box height difference of the substitute stack, so
the real Roboto line boxes closed it. And the CTA button's box is `506..773`:
the label's own advance plus `padding:1em 50px`, centred on the 1280px content
box, which is what the stylesheet declares. Edge's is `545..834` - 62px of side
padding, its centre 49.5px right of the page centre - while the label inside it,
the same string at the same size, inks 166px against this engine's 167px. That
difference is therefore in the button box Edge paints, not in the text or its
metrics, and it is left open as an Edge-side residue rather than matched by
changing the engine away from the declared padding.

What the decoder costs: 12.63 ms per face, measured over twenty decodes of the
site's own 67,608-byte `Roboto-Light` woff2 to a 152,492-byte sfnt
(`woff2time.d` in the capture directory, run with `dmd -run`). A page using half
a dozen faces therefore pays tens of milliseconds, against end-to-end probe
captures of `djangoproject.com` at 1280x800 with eight repaints taking
1.33-1.61 s and the heavier `boqsc.eu` 8.58-8.99 s, so the network and paint
phases still dominate a page open.

Re-run against the engine with the non-blocking image batch and the shared-URL
fetch fix in `aurora-web/source/auroraweb/package.d`, the three in-checkout
corpora are green with every render step at `mismatchedPixels 0`, each reporting
`43 modules passed unittests` and `PASS independent click-handler and
link-destination assertions`: `browser-reference-layout` (`inputsSha256
3FB3894B…`, six cases - flex-wrap, overflow-clip, relative-offset,
stacking-order, table-layout, transform-translate),
`browser-reference-line-height-normal` (`B1CD800E…`) and
`browser-reference-web-font` (`A3460888…`, its frame `AB5E409B…` unchanged from
the fixture-corrected re-freeze). The app recipe
`aurora-browser/tests/verify-render.json` ran green end to end against the same
engine at `inputsSha256 35CC2D40…`: compile, the smoke suite `ALL PASSED`, both
captures, render `mismatchedPixels 0` of 1,024,000 with the frame byte-identical
to its baseline (`CBAC1963…`), the release `aurora-browser-new.exe` compile and
the live `djangoproject.com` capture - so the batching change moved no painted
pixel. Its load effect is in `browser-completion-profile.md` (boqsc.eu first
content 1669.9 ms and settle 5978.5 ms; djangoproject.com 1274.3 ms and
1628.2 ms, from 1859 ms before the shared URL stopped being fetched twice).

## What those tools cannot see

- **Live pages.** `boqsc.eu` and `djangoproject.com` are checked by rendering
  this engine and inspecting boxes (`boxdump`/`pageshot-probe`) plus the
  Aurora-to-Aurora baseline in `aurora-browser/tests/verify-render.json`. That
  detects a change; it can never prove correctness. The independent oracle only
  covers frozen local fixtures, so a defect that needs a real page's data or
  scripts to appear can be missed.
  Those captures are built with `-version=AuroraHeadless`, so the frame they
  write is exactly the requested logical size whatever the display's scale: a
  1280x800 request writes 1280x800. Driving a real window instead writes that
  window's framebuffer, logical size x display scale (1600x1000 at 125%), which
  no 1:1 reference can be compared against - the app is correct there too, and
  Edge at the same 125% device scale puts the same page at the same coordinates.
  That scale is the platform's, never a stretched bitmap: the process selects
  `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` in a `shared static this()` before
  any HWND exists (`vendor/aurora-d-0.4.5/source/aurora/platform/win32.d:195-242`),
  the client area is created from the requested logical size through
  `_displayScale.logicalToPhysical` (`win32.d:1068-1070`, re-applied by
  `resizeClientToLogical` at `win32.d:1150` when the monitor DPI differs), and
  layout stays in 96-DPI units while glyphs rasterize at the monitor's physical
  size (`vendor/aurora-d-0.4.5/source/aurora/canvas.d:389-392`). Measured on this
  machine on 2026-10-17: the desktop is 120 DPI (125%), an unaware process on it
  reports a 1536x864 screen while an aware one reports 1920x1080, so a 1080x680
  request is a 1350x850 physical client laying out 1080x680 CSS pixels - the same
  convention Edge follows, which is why no other browser's window shows the page
  at a different size or with Windows-stretched text here.
  The Edge oracle is unaffected, because it renders fixtures offscreen at scale 1.
- **Text metrics.** Glyph advances, wrapping points and baselines differ from
  Edge's font stack, so cases are deliberately written without text where the
  question is geometry. `line-height: normal` and the selection of an installed
  family are the exception: both are pinned by corpus -15. Where text is
  unavoidable (real pages), a remaining mismatch is the substitute face's own
   metrics - the `djangoproject.com` header box is 132 rows where Edge's band is
   138, a difference of about 2px per line box, while the nav row (66) and the
   search field (240x46, centred in its row at page y=76) sit at Edge's own
  field sit at identical page coordinates. At the app's own 1080x680 capture
  viewport the header instead resolves to a single row: the nav ink is the same
  104px wide and within 2px of Edge's x, but the band is 5px shorter and the ink
  sits about 11px higher than Edge's - measured, not pinned.
- **Coverage breadth.** Fifty frozen cases (forty-five distinct fixtures) still cannot represent the whole CSS
  surface. `position: sticky` **is** implemented (layout maps it to `relative`
  plus `isSticky` and `paint.d` pins it while scrolling, with a unittest), but
  only its unscrolled offset has an independent reference. Writing modes and
  vertical text, scroll containers, filters and blend modes, canvas, media,
  colour management and native form control appearance are not claimed at all;
  the full list with its evidence lives in `browser-completion-profile.md`.

## The in-repo independent geometry corpus

The `aurora-opencode-pro/` checkout the corpora below were built in is no longer
present, so their recipes cannot be re-run. The corpus that pins the box-model
work that replaced them lives in this repository and needs no checkout:

- `aurora-browser/tests/reference/flex-geometry.html` - five cases in a
  1280x638 viewport: an absolutely positioned flex container with
  `padding:0 25px`, the same for a grid container, a padded `display:table`
  container whose only child is a bare `display:table-cell`, a padded
  `display:grid` container whose two `1fr` tracks fill the content box, and a
  unitless-zero `box-shadow` spread beside a 10px offset.
- `aurora-browser/tests/reference/flex-geometry.edge.png` - the reference: a
  1280x638, device scale factor 1 headless Edge capture of that fixture
  (4,055 bytes).
- `aurora-browser/tests/verify-flex-geometry.json` - the recipe: it compiles
  `aurora-browser/tests/pageshot-probe.d`, runs the engine's layout module with
  `-unittest -main` (21 modules pass), renders the fixture through the same
  probe at the same viewport and compares the two frames pixel-for-pixel at
  channel tolerance 0.

It was written to measure a defect an Aurora-to-Aurora baseline cannot see: an
out-of-flow element never takes the in-flow child path that runs
`resolveBoxMetrics`, so `position:absolute; left:20px; width:300px;
padding:0 25px` painted a 300px box with **no padding at all** and started its
flex/grid/table items at the border edge, where Edge starts them 25px inside a
360px padding box. `layoutAbsolute` now resolves an element's own box metrics
against its containing block width before the width and inset math,
`layoutTable` no longer re-places an out-of-flow table's box (that step added
the padding a second time, moving x=20 to x=45), and bare cell children of a
table container are wrapped in the anonymous table row of CSS 17.2, without
which such a table laid out as an all-zero box.

Measured on 2026-10-17: the corpus went from 38,404 mismatched of 816,640
(`actualSha256 52A3D4CA…` against `referenceSha256 99A4A532…`) to **0 of
816,640**, with the engine's layout unittests passing in the same run. The
`aurora-opencode-pro/` corpora listed below are now the record of what earlier
fixes pinned and cannot be re-verified, so this corpus is the current
independent evidence for the box-model item region.

`aurora-browser/tests/verify-render.json` is the Aurora-to-Aurora regression
baseline, not an oracle. The same change moved it by 3 pixels of 1,024,000 (page
rows 213-214 and 732), so its baseline was re-frozen to frame `3571CCE5…`, with
the superseded frame kept beside it as `django29ref-pre-padbox.ppm`.

A second corpus in the same repository pins real **flow** sizing, the paths a
box-model fixture does not reach:

- `aurora-browser/tests/reference/flow-sizing.html` - six cases at the same
  1280x638 viewport, each in its own absolutely positioned cell so a divergence
  can be attributed by coordinate: margin collapsing between block siblings, a
  50% width resolving against the containing block's content box, `min-width`
  and `max-width` clamping, a shrink-to-fit `inline-block` taking its widest
  content with a second one beside it on the same line, two left floats with a
  `clear:left` block starting below the taller one, and a `table-layout: fixed`
  table giving 25% and 75% of its 300px width to one column each. Every case is
  a solid rectangle, so no glyph can decide a pixel.
- `aurora-browser/tests/reference/flow-sizing.edge.png` - the independent
  reference: a 1280x638, device scale factor 1 headless Edge capture of it.
- `aurora-browser/tests/verify-flow-sizing.json` - the recipe, the same shape as
  the flex one: compile the probe, run `layout.d` with `-unittest -main` (21
  modules pass), render the fixture through the probe, compare at channel
  tolerance 0.

It closed two defects. An interrupted edit had left `layoutDirectText` calling
`layoutInlineBlockChildren` with a `positionedAncestor` parameter that function
no longer takes, so an inline-block's contents were laid out against the wrong
containing block: the two chips of case 4 painted 16x18 instead of Edge's 80x20
and 60x20 at x 30 and x 110. `layoutTable` also split a table's columns equally
and ignored the first row's declared widths, so case 6's 25% column painted the
same 150px as its neighbour's `auto` column; under `table-layout: fixed` the
declared width now decides its own column and the leftover space is shared by
the `auto` columns. The declaration is honoured only under `table-layout:
fixed` (`Style.tableLayout`, set in `layout.d` applyDeclaration), because
honouring it unconditionally regressed this repository's flex corpus: a
`display:table` whose only cell declares `width:100px` inside a 300px table
must still fill 300px, the behaviour CSS's `auto` algorithm specifies and Edge
paints.

Measured on 2026-10-17: 0 mismatched of 816,640, the frame's
`actualSha256 6C33FC27…` equal to its `referenceSha256 6C33FC27…`, with the
layout unittests passing in the same run, and the flex corpus still 0 of
816,640 (`actual == reference == 99A4A532…`). The rule is pinned from both
sides by a `layout.d` unittest - 75/225 with `table-layout: fixed`, 150/150
without it.

A third corpus in the same repository pins **numbers** rather than pixels: the
box-model and positioning rules as `getBoundingClientRect` rects, so a divergence
is a value to compare clause by clause instead of a region of pixels to eyeball.

- `aurora-browser/tests/reference/box-geometry.html` - twelve cases at the same
  1280x638 viewport, each a solid rectangle that carries no text and each placed
  with pixel insets: a content box whose padding and border grow the border box,
  `left`/`top` placing the margin edge, a `left:20px; right:40px; width:auto`
  stretch solved inside a definite 400px containing block, percentage width and
  height resolving against a containing block's content box, `min-width` and
  `max-width` clamping, collapsed adjacent margins, a `position:relative` offset
  that consumes no flow space, an absolutely positioned child resolved against
  its ancestor's padding box, `margin:0 auto` centring between both insets, and
  `box-sizing:border-box`.
- `aurora-browser/tests/reference/box-geometry.edge.tsv` - the oracle: 22 rects
  (`name x y width height`) measured by `getBoundingClientRect` in headless Edge
  at the same viewport, captured together with the frame below by
  `aurora-browser/tests/capture-edge-rects.py`, which injects its measurement
  script into a scratch copy of the fixture so the committed fixture stays
  script-free and the engine never runs measurement code.
- `aurora-browser/tests/reference/box-geometry.edge.png` - the pixel oracle from
  the same run: a 1280x638, device scale factor 1 headless Edge capture.
- `aurora-browser/tests/pageshot-probe.d --rects` - the engine side: the same
  probe's subtree walk writes `name x y width height` per `data-rect` element,
  reconstructing the border box from what layout stores (`box.x/y` is the
  border-box origin and `box.width/height` is the content box, the arithmetic
  `paint.d` and `borderBoxInViewport` already use).
- `aurora-browser/tests/compare_rects.py` - the comparison: every row must match
  the Edge oracle within `--tolerance` (0 here, so the numbers must be equal, not
  merely close). It still accepts an explicit `--known-open` ledger for a corpus
  that has one to carry; this corpus passes none.
- `aurora-browser/tests/verify-box-geometry.json` - the recipe: compile the probe,
  run `layout.d` with `-unittest -main` (21 modules pass), dump the engine's rects
  and frame, compare the rect table, then compare the frames at channel
  tolerance 0.

Measured on 2026-10-17: 22 compared, 22 equal to Edge exactly, 0 of 819,200
pixels differing (`actualSha256 AD21B644…` equal to its `referenceSha256
AD21B644…`), with the layout unittests passing in the same run. No row is held
aside any more.

The two rows this corpus once recorded as **known open** are fixed, each against
Edge's own numbers:

- `j1-child-50-percent-height`: the engine resolved `height: 50%` against its own
  containing block - the empty body, whose height is 0 - instead of against the
  containing block's content height. `layoutAbsolute` in `layout.d` now hands its
  children the element's own content height whenever it has one, and both
  renderers report `800 200 40 40` for the child.
- `l1-border-box-sizing`: the absolutely positioned path stored a declaration as
  the content height even under `box-sizing:border-box`, so its border box came
  out 48 tall. The declared height now goes through the shared
  `resolveDefiniteHeight` helper - the rule `resolveHeight` already applied in
  flow, which the fixed path uses too - and both renderers report
  `20 520 200 40`.

Both cases paint now: the percentage-height child carries a background, and the
border-box case paints a 4px ring around its 152x32 content fill. A regression in
either rule therefore shows up as pixels as well as in those two rect rows, which
is why the frame this corpus compares was recaptured from Edge.

Neither rule moves the real page the acceptance recipe measures: captured from
the fixed engine at 1280x800 and device scale 1, djangoproject.com's frame is
byte-identical to its pre-fix baseline (`3571CCE5…`), 0 of 1,024,000 pixels
differing, so that frozen baseline stands unmodified.

One case is deliberately absent rather than recorded as a failure: `position:
fixed` is viewport-relative, and Edge's headless layout viewport is 1256x598 for
a 1280x638 window (measured: `html`'s rect is 1256 wide with `--hide-scrollbars`)
against the engine's requested 1280x638, so a fixed box cannot agree across the
two. Every other case is placed with pixel insets, so none of them depends on the
viewport.

The fixture, the probe's rect-dump mode, `capture-edge-rects.py` and
`compare_rects.py` are original work of this repository under the same CC0/0BSD
terms as the rest of the corpus; Edge is only the oracle that produced the
committed numbers and frame.

Two further corpora in the same repository pin the two real-page divergences the
boqsc.eu campaign started from, each against an independent Edge capture of its
own fixture at the same geometry:

- `aurora-browser/tests/reference/article-panel.html` - class A geometry: the
  hero's clamped flex item, a `max-width:544px` panel inside a grid item whose
  content is far wider. Case A is the page's own `38% / 1fr` columns of a 1000px
  cell with a 544px clamp, case B a 300px/1fr split with a 480px clamp and case C
  the page's own `minmax(0, calc(0.38 * 100%))` column form. Every case sits in
  an absolutely positioned cell of fixed width, so nothing depends on the
  viewport.
- `aurora-browser/tests/reference/article-panel.edge.png` - the independent
  reference: `msedge.exe --headless=new --force-device-scale-factor=1
  --window-size=1280,638 --hide-scrollbars --no-first-run
  --no-default-browser-check --user-data-dir=<scratch> --screenshot=<file>
  file:///<repo>/aurora-browser/tests/reference/article-panel.html`, i.e. a
  1280x638 page viewport at device scale factor 1, no browser chrome, no scaling,
  scrollbars hidden and the platform colour scheme as served - which the fixture
  cannot observe, because every case declares its own colours. The frame is the
  oracle, and Edge's own boundaries were read inside it (panels A and C end at
  x=944, panel B at x=800, i.e. exactly the clamps): `capture-edge-rects.py`'s
  rect-dump path returned an empty DOM for every fixture on this machine that
  day, so this fixture carries no committed rect table. It is a pixel-only
  fixture and needs no `data-rect` names.
- `aurora-browser/tests/verify-article-panel.json` - the recipe: compile the
  probe, run `layout.d` with `-unittest -main` (21 modules pass), render the
  fixture through the probe at the same 1280x638 viewport and compare at channel
  tolerance 0.

It closed the **clamped flex item**: `layoutFlex` grew an item's used width to the
item's own content after its children had been laid out and never re-applied
`min`/`max-width`, so the `max-width:544px` panel came out 1920px wide and painted
over the whole column where Edge's is 544px. On boqsc.eu the same rule painted the
hero's right column at its full 779px content width. `resolveFlexItemWidth` now
re-clamps the used width with `clampMinMaxWidth` after `layoutContents` and
re-lays the children out when the clamp changed it. Measured on 2026-10-17: 0
mismatched of 816,640 (`actualSha256 13AB4D92…` equal to its `referenceSha256
13AB4D92…`), with the engine's own rect dump reporting 544, 480 and 544 for the
three panels, 620 and 600 for the two grid items and 120 tall for all three cells.
Known open, not covered by this corpus: each grid item declares its own height,
because an item whose `align-items:flex-start` did not stretch to its row still
painted white below each panel where Edge paints the void background; that is a
separate defect with its own plan row.

The gradient corpus is the repository's one **class D** case, and the only one
compared with a tolerance:

- `aurora-browser/tests/reference/linear-gradient.html` - five cases, each a
  solid rectangle in an absolutely positioned 120x120 cell at integer insets:
  (A) `linear-gradient(180deg, #000, #fff)`, (B) the same with no angle at all,
  (C) the horizontal `90deg` form, (D) three stops with an explicit 70% position
  (`#000 0%, #f00 70%, #00f 100%`) and (E) the fading-mask form boqsc.eu's own
  `body::before` and `.hero__topography` use -
  `linear-gradient(180deg, rgba(0,0,0,0.55), rgba(0,0,0,0.12) 70%, transparent)`.
  Its header records the class, the reason and the measured budget; the fixture
  itself is script-free and paints no text.
- `aurora-browser/tests/reference/linear-gradient.edge.png` - the independent
  reference frame, `msedge.exe --headless=new --force-device-scale-factor=1
  --window-size=1280,638 --hide-scrollbars --no-first-run
  --no-default-browser-check --user-data-dir=<scratch> --screenshot=<file>
  file:///<repo>/aurora-browser/tests/reference/linear-gradient.html`, the same
  geometry as the engine's own frame.
- `aurora-browser/tests/verify-linear-gradient.json` - the recipe, the same shape
  as the others except that its render step is `channelTolerance 1` with
  `maxDifferentPixels 0`, which is the whole point of the class: the budget
  admits the ramp's rounding and nothing else, so a moved edge, a wrong colour or
  a two-unit divergence still fails.

It closed two defects that had one symptom. `package.d` rasterised a CSS gradient
only inside the `url(` branch of background loading, so a plain `background:
linear-gradient(...)` set `backgroundGradient` but reached no rasteriser and
every such box painted the gradient's first stop flat through `layout.d`'s
fallback colour; the rasterisation is now hoisted out of that branch. Separately,
`svg.d`'s default linear-gradient direction started the gradient line at the box
centre (`y1 = 0.5`) instead of the top edge, so `linear-gradient(a, b)` with no
angle painted its first stop flat over the top half. With both fixed, case A
reports y=65 `rgb(12,12,12)`, y=120 `rgb(129,129,129)` and y=175
`rgb(245,245,245)` against Edge's 12, 128 and 246, and case D's three stops
report `rgb(17,0,0)`, `rgb(184,0,0)` and `rgb(32,0,223)` against Edge's 17, 183
and 32,0,223 - every stop interpolated, none painted flat.

Measured on 2026-10-17: 17,430 of the fixture's 57,600 ramp pixels differ by
exactly 1 channel unit and 0 differ by more than 1 (`actualSha256 B702DDB2…`),
the fading-mask case is exact at 0 of its 14,400 pixels, and the five cells'
rects are the committed integer insets. The same change is visible on the page
the campaign started from: compared with the campaign's own earlier page-only
engine frame (`eng-boqsc.ppm`) against the Edge frame of boqsc.eu
(`edge-boqsc.png`, 1280x638, window `--window-size=1280,638 --hide-scrollbars`),
the 64-cell structural profile of `site-struct.py` falls from 13,730 to 9,323
differing cells of 40,832 (33.6% to 22.8%) on a fresh 25-paint capture from the
fixed engine at the same geometry. What remains there is not the gradient: the
hero's photograph still does not load into this engine, and the residual bands
are the text and control bands this document already records as the
substitute-font class. The two gradient fixes moved no other baseline: on the
repository's acceptance recipe, djangoproject.com at 1280x800 is byte-identical
to its frozen frame (`3571CCE5…`, 0 of 1,024,000 pixels).

The fixture, the recipes and the Edge captures above are original work of this
repository under the same CC0/0BSD terms as the rest of the corpus; Edge is only
the oracle that produced the committed frames.

## Superseded corpora

- `browser-reference-validation/` (v1): box-model, flex-grid, svg-position.
  Still passing; the three cases are byte-identical to the same cases in -4.
- `browser-reference-validation-2/` and `-3/`: **superseded.** Their
  `float-context` case used the original text-bearing fixture, which measured
  glyph metrics rather than geometry, and then an intermediate inline-block
  version. Re-running them reports a fixture-changed mismatch by design.
  `-4` replaces that case with the floats-only fixture, and `-5` adds the
  positioning corpus.
- `browser-reference-validation-4/`, `-6/`, `-7/`, `-8/`, `-9/`, `-10/`, `-11/`, `-12/`, `-13/`, `-14/` and `-15/`: current. Keep them.
  `-5/` is the positioning corpus before `inline-block-row.html` existed; its
  five cases are byte-identical to the same cases in `-6/`.

## Performance evidence

Measured with a release build (`dmd -m64 -O -inline -release`) on the user's own
large page, `https://boqsc.eu/` (183 KB of HTML, ~7 MB of assets, 1080x680):

| Measurement | Result |
| --- | --- |
| navigate (fetch + parse + first layout) | 1114 ms |
| one full layout pass afterwards | 6-11 ms |
| second load of the same page | 429 ms (resource cache: 6 entries, 6.9 MB) |
| same page, unoptimized probe build | navigate 1998 ms, 14-24 ms per pass, second load 745 ms |

So a full relayout of a large real page is well inside a 16.7 ms frame in a
release build, and a repeat load costs about a third of the first one because
subresources are served from the bounded cache instead of being re-fetched.

## Known limitations carried forward

- Unicode data, the linked D runtime and Phobos (BSL-1.0), and zlib reached
  through `std.zlib`/`etc.c.zlib` mean the strict CC0/0BSD distribution claim is
  **not** satisfied; every component is listed in `third-party-inventory.json`
  with the resolution it needs.
- Both `dub.json` files and the Aurora-owned vendor packages now declare
  `"license": "0BSD"`. Unicode, Microsoft Terminal MIT, DMD/Phobos and
  system-runtime terms remain separate from that grant.
- Web faces are supported in the uncompressed `sfnt` (TrueType/OpenType) form, in
  a WOFF 1.0 container and in a WOFF 2.0 container. `woff.d` unwraps the WOFF 1.0
  container to that same sfnt: header and table directory, then each table's
  stream inflated with `std.zlib` where the container says it is compressed. Its
  unittests cover compressed tables, tables stored verbatim, and a malformed
  container being rejected. `woff2.d`, over `brotli.d`, decodes the WOFF 2.0
  container instead of carrying it: the transformed `glyf`/`loca` pair and `hmtx`
  are rebuilt and the table data stream is Brotli-decoded from scratch, and its
  unittests cover `UIntBase128`, `255UInt16` and the triplet decoding table while
  `brotli.d`'s cover an uncompressed meta-block, the specification's published
  literal context tables and a damaged stream being reported rather than thrown.
  `embedded-opentype` and the legacy `svg` font format are what remains skipped,
  exactly as a browser skips a source it cannot parse. Measured on a real page
  rather than reasoned about:
  `djangoproject.com`'s nav icons can only come from FontAwesome's woff face, and
  their ink columns match an independent Edge frame's within 1..4px, the heart
  icon at x 1071..1078 against Edge's 1074..1080.
- The WOFF *decode* path is pinned by those unittests and by that live page; it
  has no frozen fixture that would fail if the engine stopped unwrapping
  containers, because the `browser-reference-web-font` corpus's two families use
  a TrueType source and a woff2-then-TrueType `src`, and both resolve the same
  way with or without woff support. A family no machine installs whose only
  candidate source is a woff is the fixture that would pin it; it is not in the
  tree yet. The WOFF 2.0 path is pinned the same way the live page pins it: every
  text face `djangoproject.com` serves is woff2-only, so a decode that stops
  working drops the page onto a substitute face, moves the measured advances
  above by whole percent, and fails `verify-render.json`'s frozen capture of that
  page.
- The `file://` scheme is supported by both the engine and the browser shell. It
  was not: the loader served only `http`/`https`, so an engine-level navigation to
  a local page left its "Navigation failed" document in place (a capture of it
  held no page ink at all), and the shell's own navigation routed only
  `auroraweb:`, `http` and `https`, showing an "Unsupported scheme" page for
  anything else. Both now handle local files: drive-letter, POSIX and UNC paths,
  percent-escaped names, `Content-Type` from the extension, and relative
  references resolving against the file base. Verified: the engine's `file://`
  capture of `inlineblock-margin.html` is **byte-identical** to its
  `http://127.0.0.1` capture of the same file (equal SHA-256), and against Edge's
  own `file://` frame of it the structural rows agree exactly as in the HTTP pair
  below. Unit tests in `net.d` cover parsing, the filesystem path, discriminant
  Content-Types, a real file read, a missing file (an error, not a throw) and
  relative resolution; `dub test` passes 57 modules.
- `aurora-browser/tests/verify-render.json` passes end to end on the current
  sources: compile, `headless_smoke: ALL PASSED` (91 checks, the real-input hover,
  wheel, double-click, right-click and scroll-listener checks included), the
  engine's `django` capture against its baseline with `mismatchedPixels 0` of
  1,024,000 (reference and frame SHA-256 `3571CCE5…`, the out-of-flow
  padding-box re-freeze recorded under "Last full re-run"), the release app
  compile and the live app capture. That baseline is an Aurora-to-Aurora
  regression check - it detects a change and cannot prove correctness. The WOFF
  2.0 webfont fix is why its text is no longer substitute-face text: with the
  site's woff2 faces decoded, the same-string CTA label inks 167px against an
  independent Edge frame's 166px and the tagline's first word 101px against
  Edge's 102px, and whole-page structural agreement against that same Edge frame
  is 5.5% of 64-cell rows where the substitute-face frame had 4.0% - the increase
  being the hero tagline's knife-edge line break (698.05px of the stylesheet's own
  metrics against its `max-width:700px`), not a regression. The re-freeze history
  and the earlier colour-scheme measurement are recorded under "Last full re-run".

## Inline-level margin collapse, re-measured against Edge (2026-10-17)

Two layout defects that `djangoproject.com`'s homepage exposes were fixed and
then measured in `inlineblock-margin.html`: a `p` inside a `div` holding two
`margin: 15px 0` inline-block links, each overridden to `margin-bottom: 40px` /
`60px` by two- and three-compound rules, with a marker block whose top edge is
the banner's own height.

- A block's auto height is now measured from the flow origin captured before the
  inner flow ran, not from the mutated flow cursor, so a leading margin no longer
  moves the block's own top edge.
- `firstInFlowChild` / `lastInFlowChild` returned inline-level children, so a
  block absorbed an inline-block child's top and bottom margins. CSS 8.3.1
  collapses margins only between BLOCK-level boxes: both the top-collapse path
  and the bottom-escape path are now gated on `!isInlineLevelBox(...)`.

Measured at a 1280x400 viewport, device scale 1, page origin 0, with the engine
(`urlprobe`, page-only capture) and Edge
(`msedge --headless=new --force-device-scale-factor=1 --hide-scrollbars
--window-size=1280,400 --screenshot`) loading the same fixture over loopback HTTP
minutes apart. `--fixture` captures come from the app path; at the time the
engine's own `WebPage.navigate` had no `file://` handler (since implemented, see
the schemes note above), so both frames were taken over HTTP. The engine's
`file://` and HTTP captures of this fixture are in any case byte-identical, so
the pair below is unaffected.

| Quantity | Edge | Aurora |
| --- | --- | --- |
| the two pills' bounding box, top edge | y=15 | y=15 (y=30 before the fix) |
| the two pills' bounding box, width | 154 (x=0..153) | 153 (x=0..152) |
| the two pills' bounding box, height | 43 (y=15..57) | 43 (y=15..57; 66 before the wrap fix) |
| marker top edge = banner height | 118 | 118 (141 before the wrap fix) |

The banner height is the last inline-block's margin box bottom in **both**
engines: Edge 15 + 43 + 60 = 118, Aurora 15 + 43 + 60 = 118. The
margin-collapse half matches Edge exactly, including the last child's
`margin-bottom` being counted inside the paragraph, and chasing the last 23px
then exposed a second, independent defect behind it.

What the residue was: **a shrink-to-fit inline-block re-wrapped its own label**,
so an auto-height box counted a phantom second line (one 23px line reported as
2x23). The chain, each step from the engine's own dumps:

- `fstdbg` (prints every run's `layoutX/layoutY/layoutWidth/lineIndex`) showed
  `a.btn`'s box at 28x46 while its single 18px run sat on one line, so the box,
  not the text, was claiming two lines.
- Instrumenting the shaped pass showed the run *advancing* a line inside the box
  (`cx=20 cy=48 ... lines=2`), and dumping the shaper's own line array was
  unambiguous: `two` came back as `line 0: start=0 end=2 w=18` plus
  `line 1: start=2 end=3 w=10` - the last cluster alone on a second line.
- The cause is rounding, not fonts: the label's fractional advance is 28.4px,
  the shrink-to-fit content width rounds that to 28 (`resolveWidth`), and the box
  then handed the rounded 28 to *its own* interior layout as the wrap limit
  (`sub.lineEnd`). CSS 10.3.5 sizes such a box from its max-content width, so
  laying that content out at a width a fraction narrower than the content itself
  is exactly what wrapped it.
- `layoutInlineBlock` then grew the box to `sub.contentBottom` (46 rather than
  23) - the whole 23px banner residue - and the shared line cursor advanced below
  the label.

The fix (shaped inline pass in `layout.d`) gives the interior of an **auto-width**
inline-block the content's own max-content width as its wrap limit, so a
shrink-to-fit box can never wrap its own content. An explicit `width` still wraps
normally, and the used width itself is unchanged, so no other inline-block's
paint geometry moves.

The same fixture exposed a missing UA default: the engine painted an `a`'s label
in the inherited colour with no underline, where Edge applies
`a:-webkit-any-link { color: -webkit-link; text-decoration: underline }`.
`applyUserAgentDefaults` now applies `#0000EE` plus `underline` to any anchor that
actually carries an `href` (an `href`-less anchor is a placeholder, not a link);
the author cascade still overrides both.

Re-measured at the same 1280x400 viewport, origin 0, engine page-only capture
(`urlprobe`) against a fresh same-session Edge frame of the same loopback HTTP
URL:

| Quantity | Edge | Aurora |
| --- | --- | --- |
| pills' bounding box | x=0..153, y=15..57 (154x43) | x=0..152, y=15..57 (153x43) |
| banner height = marker top edge | 118 | 118 |
| marker rows | 118..125 (8 rows) | 118..125 (8 rows, 10240 px) |
| link ink (label + underline) | blue from row 29 | blue from row 30 |

`bandcmp` over rows 0..159 agrees exactly at every sampled structural row - 0
(page top), 15 (pill top), 58 (below the pill), 118 (marker top) and 126 (below
the marker), in colour and in differing-pixel count - so pill height, banner
height and marker position all now match Edge. The residuals are cosmetic and
sub-pixel-scale:

- the label's glyphs rasterise about 2px lower and the underline one row higher
  than Edge's (a substitute face's own ascent and underline metric, the same
  class as the 2px-per-line note below); total blue ink 10564 px against Edge's
  10539;
- the pill is 153 wide against Edge's 154, the shrink-to-fit rounding question
  above (round-to-nearest versus a ceiling). The height - the defect - now
  matches, and the used-width rounding is deliberately left as a measured 1px
  residue, because it also decides where every following inline-block starts.

Engine state: `dub test --compiler=dmd` in `aurora-web` passes 57 modules with
the new reduction (paragraph height = line bottom minus content top) passing.

## Known-site measured status (independent Edge reference)

Measured in a 1280x800 window at device scale 1, whose page area is 1280x638
(the browser chrome takes the other 162 rows), against independent Edge captures
(`msedge --headless=new --force-device-scale-factor=1
--window-size=1280,638`, plus `--virtual-time-budget=10000` for `boqsc.eu` so
that the heavy page finishes loading; without the budget Edge screenshots that
page before it paints). The comparison reduces every page row to a coarse
content/background profile over 64 columns, so it does not measure glyph
rasterisation: **two independent Edge captures of the same page score 0.0%
divergence**, which is the control for every number below. Cells differing, as
a share of the 638-row page area:

| Site | Cells differing vs Edge | Notes |
| --- | --- | --- |
| `djangoproject.com` | 9.1% page-only (origin 0, 638 rows) / 10.4% app capture (origin 162, 476 rows) | Re-measured after the generated-content fixes below. The earlier 15.1% came from a mismatched viewport and is superseded. The header's own geometry is confirmed correct against Edge by the engine's box dump, which the same probe prints (`pageshot <url> 1280 800 <out> 8 <needle> header`): `header` 1280x132, `nav` 854x66, and `header-tools` is the second flex line at page y=76 - 10px of container padding plus the 66px first line, which is exactly Edge's own search row - with `search` 240x46 centred inside it, `input` 192x30 and `a.logo` 104x36. The logo is drawn and sits in the row Edge puts it in: `django-logo.svg` declares `width="104px" height="36px" viewBox="0 0 104 36"`, so its intrinsic size is the box itself, and on page-only frames (origin 0) its ink occupies page y 20..55 x 61..164 against Edge's page y 20..55 x 63..166 - the same stem, x-height and descender on each of those rows, with per-row ink counts (12, 12, 32, 87, 65, 65, 75, 12, 22, 8 against Edge's 12, 12, 34, 87, 65, 66, 75, 12, 22, 9) that differ by one column at most. The 19-rows-higher reading this row used to record came from an app capture at page origin 162 and is superseded: the element's own box (`header .logo{margin:10px 4px;margin-left:10px}`) is in the row Edge puts the wordmark in. Two measured residues remain in this header and neither moves a box: the nav labels' ink band is page y 31..46 where Edge's is 33..41 (the alignment fix in "Engine fixes pinned by these corpora" moved it 8 rows down from 23..38, and the engine's substitute face covers a taller band at those x positions than Edge's face), and the nav `ul`'s own top edge lands on a half-pixel boundary at its aligned position, so the engine paints one row there that Edge does not: x 383..1222 at page y 20, rgb(16,97,66) against the header's rgb(12,75,51), 22 apart in one channel. Everywhere else the header's light-ink columns agree with Edge's within 1..4px across x 395..1279, including the FontAwesome icons that only the page's own woff face can supply - the heart at engine x 1071..1078 against Edge's x 1074..1080. The remaining cells are text: the engine and Edge now agree on the dark palette, and the only measured layout gap is the header's total, 132 against Edge's 138 - the substitute font's own line box, about 2px per line, the same class of difference recorded below. With the inline-formatting fixes (below) in place, re-measured page-only (origin 0, 638 rows) against an Edge frame captured minutes apart, the same front page scores 9.5% (3864 of 40832 cells, worst row 63), in the same bands: 23..41 (nav marker and nav ink), 235..259, 279..306, 357..422, 485..549 (the largest, 1272 cells) and 591..627. |
| `docs.djangoproject.com` | 15.3% page-only (origin 0) | Pair comparison re-run after the generated-content fixes; the earlier 17.1% was at a mismatched viewport and is superseded. Reproduces the homepage's differing header rows, 9..46, 62..75 and 108..121, so its nav ink and search rows sit where Edge's do with the same substitute-face metric gap, over the docs sidebar and TOC layout. |
| `boqsc.eu` (the required integration target) | 28.0% app capture (origin 162, 476 rows) | Re-measured after the generated-content fixes: the same engine frame captured without waiting (page-only, origin 0) scores 46.8%, so most of that figure is the heavy page still loading, not a layout fault. It is not a geometry oracle: the page's hero is a carousel and two captures legitimately show different slides (its first band measures 0..28 in the engine and 0..40 in Edge on these frames). The box-level measurements in "Confirmed defect" remain the comparable figures for it. |

Re-measured on 2026-10-17 with the wrap fix and the UA link defaults in place:
engine page-only `urlprobe` captures at 1280x638 (page origin 0, the comparison's
default 138-row chrome offset and 64 columns) against `msedge --headless=new
--hide-scrollbars --window-size=1280,638` frames captured in the same session
give `djangoproject.com` 16.4% (5261 of 32000 cells, worst row 35) and
`docs.djangoproject.com` 21.4% (6835 of 32000, worst row 54). Both are higher
than the 9.5% / 15.3% above, and the reason is capture churn rather than layout:
two engine builds minutes apart on the same live front page - one from before the
wrap fix, one after - differ from each other by 16.7% with the identical band
structure (76..121, 141..158, 224..296, 362..499), which is the signature of the
page's webfonts and content resolving differently between captures (substitution
alone moves every text line). Live-site percentages from different sessions are
therefore not comparable with one another; only same-session pairs are, and the
fixture's structural rows above are the geometry evidence.

Each engine frame is named with its capture path and origin: a page-only frame
starts at the page's own row 0, while the app's own screenshot includes 162 rows
of chrome. Engine-to-Edge pairs are only compared when both sides cover the same
page rows from the same origin.

An app capture is also device-scale dependent: on a 1.25-scale desktop the same
1280x800 window yields a 1600x1000 image, and the page begins about 202 rows
down, not 162 - the page *area* is still 1280x638 logical rows. Read an app
frame's own scale off its pixel size before naming an origin, or capture
page-only with `urlprobe` (origin 0) where the comparison does not need chrome.

These percentages bound the remaining difference rather than proving layout
faults: a page whose layout matches exactly still differs in a minority of
cells wherever text rasterises differently, and the figures above were taken
with both frames in the same dark theme. Each defect below was therefore
confirmed by a second, layout-level measurement - for the real pages, the
engine's own box dump against the Edge frame's band boundaries.

### Colour scheme (`prefers-color-scheme`)

The engine answered `@media (prefers-color-scheme: dark)` with a query that never
matched, and treated a `light` query as adding no constraint. This machine's
platform prefers dark (registry `HKCU\Software\Microsoft\Windows\CurrentVersion\
Themes\Personalize\AppsUseLightTheme = 0`), which is why the independent Edge
reference is a dark page: the difference was never a layout fault. Ignoring the
query also let a page's dark block apply *on top of* its light rules, mixing both
themes.

`css.d` now records the condition on the media query and answers it from the live
preference in `matches`, so a stylesheet parsed earlier is re-filtered if the
preference changes; `light` and `dark` are equally real constraints. The
preference is read natively from the platform at startup (`initialPrefersDark`,
registry only - no shell, no network) and a host application can override it with
`setPrefersDarkScheme`. A unit test covers dark-only, light-only and dark combined
with `min-width`, in both preference states, and no fixture in the tree is
affected: none of the 97 HTML files contains a `prefers-color-scheme` block, so the
stored Edge references stay valid.

Verified against Edge on `djangoproject.com`: the engine's dark frame matches
Edge's palette exactly at sampled points (header `rgb(12,75,51)`, body
`rgb(14,17,23)`) and its page-region mean luminance is 42 against Edge's 33, so the
residual is ink distribution, not colour.

Confirmed defect:

- `boqsc.eu` toolbar height. Before the inline-layout fixes the engine laid
  `.site-toolbar` out at 47px (`.site-toolbar__inner` 46px plus its 1px bottom
  border) where Edge's toolbar background ends at row 39, for a 7px offset of
  everything below. After them `.site-toolbar__actions` measures 44px (from
  46px) and the toolbar about 45px, so the offset is down to roughly 5px but the
  row still does not match Edge: the actions box is 241px wide and holds items
  of 54, 52, 60 and 51px with 24px of gap and margin, so the fourth wraps to a
  second row at y=26 where Edge keeps one row inside a 40px box. The box itself
  is a flex item that is allowed to shrink, so its width is not the fault; the
  item advances are, and the site's text faces are why they are wider than
  Edge's.
- `boqsc.eu` text faces. The site's faces are served as woff2 - which is what
  Google Fonts' current CSS does - and the engine used to skip those (`css.d`
  walked `src` and skipped the woff2 ones) and shape its text in an installed
  substitute, which is wider. That skip is closed: `css.d` now accepts a `woff2`
  source and `woff2.d` decodes it (see "Known limitations carried forward"), so
  this page shapes in the faces Google's CSS asks for. The toolbar's remaining
  advance difference was attributed to substitute-face metrics, which that
  mechanism can no longer explain; the page is captured by `verify-render.json`
  and needs re-measuring against an Edge frame of its own before that residue is
  called explained.

Ruled out, with the evidence that ruled it out:

- An image-format gap on `boqsc.eu`. The greyscale hero image was first read as
  a `<picture>` fallback from an unsupported WebP/AVIF candidate, but the served
  page contains no `image/avif`, `image/webp`, `srcset`, `<picture>` or
  `<source>` at all, and the hero is a carousel, so two captures legitimately
  show different slides.
- A wrong page origin. The 7px toolbar difference is not a capture offset: it
  appears both in the framebuffer row signature and in the engine's own boxes,
  and the frames agree on the toolbar's x extent (the full 1280px) and on its
  background within one unit (engine `rgb(11,11,13)`, Edge `rgb(10,10,12)`),
  while the rows either side of the boundary disagree by 7.
- A degenerate Edge reference for `djangoproject.com`. The stored Edge frame was
  suspected of being a header over a black band; inspecting it shows Edge's
  whole dark-theme page, so the 12.6% is a genuine theme difference and not a
  broken capture. That difference is now closed: the engine answers
  `prefers-color-scheme` from the platform and renders the same dark palette
  (see "Colour scheme" above).

### `djangoproject.com` logo: presentation attributes on a group

The header's wordmark is a stylesheet background image, `django-logo.svg`, whose
paths sit inside `<g transform="translate(-8,-5)" fill="#FFFFFF">`. The engine
painted the wordmark in the page's text colour instead of white, and it was first
diagnosed as a 404 on the stylesheet-relative URL. That was wrong, and so were
`text-indent`, the background pipeline and shorthand expansion: URL resolution
(`resolveUrl`/`absolutizeUrls`/`normalizeUrlPath`), `text-indent` parsing and
application, and background painting all existed and were unit-tested.

The real defect was in `svg.d`. `applyPresentationAttributes` wrote into a local
copy of the paint context, and the element walk passed only the container's
transform down, so a group's `fill` never reached its paths; they fell back to
`ctx.fill`, which the caller had set to `currentColor`. Presentation attributes
are now inherited down the tree exactly as transforms already were. The engine's
own frame of the site then draws the wordmark white, 36 rows tall and 104px wide
at Edge's x within 2px, where before it drew a dark shape. The rule itself is
pinned by the fixtures, not by the live page: `-17` proves the flex geometry that
positions it, and `browser-reference-validation/` (v1) carries the SVG box
mapping.

### Generated content: inheritance, inline measurement and `content` escapes

Three defects in generated `::before`/`::after` boxes were fixed and are pinned
by the unit test in `layout.d` ("generated pseudo-element boxes inherit their
originating element and lay their glyphs out"):

1. A generated box did not inherit from the element it decorates.
   `buildPseudoElement` built the pseudo's style from the resolved cascade alone,
   so `font-family` stayed at the unset sentinel and every icon box measured and
   painted in the fallback face. Both style paths now share
   `inheritStyleFromParent`, so the icon faces (`font-family: FontAwesome` on the
   originating element) reach the glyph, while a pseudo's own `font-size` still
   wins over the inherited one. Measured on `djangoproject.com` with the engine's
   own box dump: `::before ... fam=FontAwesome box=261,72 19x20 d=inline`, where
   the same probe previously printed `fam="" box=0,0 0x0`.
2. Inline-level generated boxes were never laid out. `layoutInlineChildren`
   iterated the element's own children, so an inline `i.icon` never measured its
   generated glyph. `withGeneratedBoxes` splices the generated boxes into the
   child lists for the duration of the inline sub-flow and restores them
   afterwards, in the inline and the inline-block paths alike.
3. CSS escapes in `content` were not decoded, so FontAwesome's
   `content: "\f0f6"` laid out the six literal characters. `decodeCssContentEscapes`
   implements CSS Syntax 3, 4.3.7 - up to six hex digits with one optional
   whitespace character consumed with them, `\<char>` for anything else, U+FFFD
   for a value that is not a Unicode scalar - and the same unit test covers a
   hex escape and its terminating space. Measured on `docs.djangoproject.com`:
   the sidebar glyph box is now `box=876,1874 12x22 codes=[61686]` where the
   unfixed engine printed `29x22` with `codes=[48, 102, 48, 102, 54]` - the six
   characters of `\f0f6`.

The independent check for all three is the Edge frame at the same viewport:
`djangoproject.com`'s header now carries the same generated search magnifier and
theme-toggle glyphs as Edge's own capture, in the same place and colour, and its
wordmark, nav ink and search field register with Edge's.

Still open from the same comparison, with what is measured so far:

- **Resolved: there is no current-section marker to paint.** The earlier reading
  was Edge's own subpixel text anti-aliasing, not a declaration. Scanning both
  frames for pixels within 8 of `rgb(12,155,196)` finds 122 of them in Edge,
  scattered over columns 290..1192 with at most 17 in any one row and at most 9
  in any one column - glyph-edge fringing along the nav labels, because
  `ClearType` varies the channels, so a white glyph edge over the `#0C4B33` bar
  lands on values like `(12,154,196)`, which is the colour that was read. The
  engine frame has none: its text rasterises with grayscale anti-aliasing. A
  painted 2px rule would show one contiguous run of 60+ pixels in a two-row band
  instead, which neither frame has. Consistently, the site's own stylesheet
  contains no such colour at all - 0 occurrences of `9bc4`, `rgb(12,155,196)`
  or `--accent` in `output.bd0f2d884efe.css` - so nothing is missing from its
  cascade or parse and no gap is left here to close. The nav itself is drawn
  correctly: the sheet hides it (`nav{display:none;max-height:0}`) and shows it
  from `@media screen and (min-width:1280px)` up, and the engine's own frame at
  that width paints the whole nav row.
- `docs.djangoproject.com` rows 486..623 are 2601 cells of the engine frame's
  6230-cell divergence, and have no box-level diagnosis yet.
- The substitute-font line boxes: the engine's header is 132px against Edge's
  138, about 2px per line, the same class of difference recorded above. The same
  cause accounts for the homepage's larger bands, and cropping both frames at the
  same page rows shows it directly: Edge's hero headline sits at page row ~240 and
  the engine's at ~252, the engine then fits a smaller next element by ~272 where
  Edge is still inside the headline, and by rows 476..556 the engine has already
  drawn the section rule that Edge draws at ~550 - roughly 70 rows of accumulated
  text height from line breaking plus line pitch. The structural boxes keep their
  order and place on both sides (bar the header's own 6px total recorded above),
  so these bands are text metrics, not a missing declaration. Per-element box
  comparison against Edge is the measurement to carry forward, and the fix
  belongs with font selection and metrics rather than the cascade.
- Measured pixels localise the drift to one arithmetic error with two halves,
  both fixed in `layout.d` and pinned by `dub test` (57 modules pass). A line
  box must contain an inline-block's MARGIN box (CSS 10.8.1), not just its
  border box. The hero's second paragraph is `p box=(290,361 700x47)` on the
  live homepage, but the `a.cta` inline-block inside it carries
  `pad=18,50,19,50` over a 23.4px content height - a 60.4px border box - plus
  `margin:15px 0` and a higher-specificity `margin-bottom:40px`, so its margin
  box is 115.4px and Edge's paragraph is about 115px. The engine's 47px was
  therefore short by most of the page's drift, not a 5px effect. The second
  half was placement: a baseline-placed box whose border box was itself taller
  than the strut went to `baseline - height - padding`, so it painted ABOVE its
  own paragraph (the fixture's button at y=-23 while the paragraph measured
  0px). Both now follow the standard: the margin box enters the line bottom,
  and the box is clamped so its margin box never starts above the line's top.
- Re-measured against a same-session Edge frame at 1280x400 with origin 0, on
  the fixture inlineblock-margin.html: the engine painted the button at y=-23
  before the fix and at y=30 after it, where Edge has 15; the engine's button
  also resolves to two 23.4px lines (66px border box) where Edge fits the label
  on one, so its inline-block shrink-to-fit width is still narrow for this
  face. Edge's paragraph height is 101px against the engine's 71px, so the
  line bottom's content-versus-border-box accounting (the line adds
  `paddingBottom + borderBottom` to a height that is already the content box)
  is the next thing to check. The earlier reading here - that the 47px
  paragraph "merely lets a taller inline-block overflow it, a 5px effect, not
  the page's drift" - measured the pre-fix engine and is superseded.
- That same fixture then isolates a third defect, at the box rather than the
  line. The paragraph's 81px is exactly the line with all four `pad=10,20`
  insets and NO bottom margin, and the parent banner's 156px is 15 + 81 + 60 -
  so the descendant-margin path reads `.btn2`'s 60px from the cascade, while
  `box.marginBottom` for the same inline-block measures 0 where the line reads
  it. Both buttons sit on the same shorthand (`margin:15px 0`, whose top margin
  does reach the box: the used value is 15), so the value is either lost in a
  box copy taken before `resolveBoxMetrics` fills it, or zeroed on the inline
  path. Note that the parent's 60 does NOT come from `.homepage .btn`'s own
  40px override, so which of the two cascade values each box ends up with is
  not yet established; printing `box.marginBottom` for both buttons is the next
  measurement. djangoproject.com's `.homepage .copy-banner a.cta` has the same
  shape, so this is likely the remaining piece of the ~55px step.
- Also re-measured on that fixture: the engine wraps the button's label onto
  two 23.4px lines where Edge fits it on one, so an inline-block's
  shrink-to-fit width is still narrow for the substitute face.
- Run against Edge: the fixture (parent-margin.html) confirms the engine's
  block/margin arithmetic is otherwise correct - the section's content height
  202px equals 36 (the first child's collapsed top margin) + 130 (the child
  block) + 36 (the last child's bottom margin), counted once. The hero headline
  agrees too: the engine's run sits at layoutY 225 against Edge's ~226. A
  row-ink profile alignment (rowprof.py, 32-row bands) localises the rest:
  the engine tracks Edge within +6/+7px through the hero (bands 224..255 and
  352..415), and takes a +54..57px step over engine rows 480..543, so about 55px
  is lost between the CTA paragraph and the next section boundary.

### Inline formatting: a block in an inline context, and a dropped space

Found while closing the nav marker above, with a fixture that has since grown to
seven rows (`inline-border.html`, captured with
`pageshot --fixture <path> 640 400 <out.ppm>`, page origin 0 - fixture mode reads
the file straight off disk, so no HTTP server and no `file://` URL are involved)
and an independent Edge capture of the same file
(`msedge --headless=new --force-device-scale-factor=1 --window-size=640,400
--screenshot=… --virtual-time-budget=4000 file:///…/inline-border.html`).

Two engine defects, both Edge-verified. Both are fixed in `layout.d` now and each
fix carries a unit test there ("collapsible text keeps a leading separator at an
inline-box boundary", "a text run that begins a line before a block registers as
its own line"). Both frames then agree: the engine draws the space in row 1 and
row 6, and the block below its own label in row 2 and row 7, with the fixture's
border colour (12,155,196) on the same rows in each frame - engine 45..46 (165
ink columns), 135..136 (220), 326..327 (165), 389..390 (54) against Edge 45..46
(164), 135..136 (220), 328..329 (164), 391..392 (54). Row 7 falls below the fold
in both frames, so it is compared through that border-row signature alone.

1. **A block-level box inside a line box is laid out before the inline text that
   precedes it.** The fixture's second row is
   `<div>2 block:<span class="block-border">DOCUMENTATION</span></div>` and the
   `span` is `display:block`. Edge draws `2 block:` first and the underlined
   `DOCUMENTATION` on the next line; the engine draws the underlined
   `DOCUMENTATION` first and `2 block:` underneath it. CSS 2.1 9.2.1.1 makes the
   preceding text an anonymous block box that keeps document order, so the inline
   sub-flow is emitting the nested block's line before the anonymous one. The
   smoke test's "inline-block keeps document order before a block" check covers
   the `inline-block` case only; this is the `block` case. **Fixed**: a pending
   text run now flushes as its own line when it begins a line, so the anonymous
   block box keeps document order instead of the nested block jumping ahead.
2. **A collapsible space between an inline element and following text is
   dropped.** The first row is
   `1 inline: <a class="inline-border">DOCUMENTATION</a> end`. Edge renders
   `DOCUMENTATION end`; the engine renders `DOCUMENTATIONend`. The space is in
   the parent's text, not inside the `a`, so the parent's own text run is losing
   a word separator at an inline-box boundary, which CSS 2.1 16.6.1 keeps: it is
   not at the start or end of a line. Read at original detail in both frames.
   **Fixed**: a run keeps its leading separator when it starts a line, and a
   whitespace-only node between two inline boxes becomes that separator. The
   added rows pin the neighbouring cases against Edge too - a space before the
   inline element (row 5) and between two inline elements (row 6, `NEWS CODE`).

Whole-suite check after the change: `dub test --compiler=dmd` in `aurora-web`
reports `ok 57 modules passed unittests`, which includes both new tests.

What the same fixture rules **out**: inline borders paint. The first row's 2px
`#0c9bc4` `border-bottom` and the third row's 4px `#ffcc00` left and right
borders on an inline `a` both appear in the engine's frame where Edge puts them,
so the nav marker above is not a paint gap for inline borders.
