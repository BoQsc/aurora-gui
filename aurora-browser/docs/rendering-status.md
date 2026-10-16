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

Still open from the same family of defects, and deliberately left alone until
each has its own fixture: other auto-height sites that add the box's own padding
and border (absolute/fixed containers and the flex column and wrap-line paths).
The flex column path sums item *content* heights where it should sum their outer
heights.

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
  The Edge oracle is unaffected, because it renders fixtures offscreen at scale 1.
- **Text metrics.** Glyph advances, wrapping points and baselines differ from
  Edge's font stack, so cases are deliberately written without text where the
  question is geometry. `line-height: normal` and the selection of an installed
  family are the exception: both are pinned by corpus -15. Where text is
  unavoidable (real pages), a remaining mismatch is the substitute face's own
  metrics - at 1280x800 the `djangoproject.com` header band ends 4px higher than
  Edge's, a difference inside one line box, while the nav row and the search
  field sit at identical page coordinates.
- **Coverage breadth.** Fifty frozen cases (forty-five distinct fixtures) still cannot represent the whole CSS
  surface. `position: sticky` **is** implemented (layout maps it to `relative`
  plus `isSticky` and `paint.d` pins it while scrolling, with a unittest), but
  only its unscrolled offset has an independent reference. Writing modes and
  vertical text, scroll containers, filters and blend modes, canvas, media,
  colour management and native form control appearance are not claimed at all;
  the full list with its evidence lives in `browser-completion-profile.md`.

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

- Unicode data, the Boost-licensed GUI library, the linked D runtime and zlib
  reached through `std.zlib`/`etc.c.zlib` mean the strict CC0/0BSD distribution
  claim is **not** satisfied; every component is listed in
  `third-party-inventory.json` with the resolution it needs.
- Both `dub.json` files still declare `"license": "BSL-1.0"` with author
  `"OpenAI"`; that metadata change was explicitly set aside for now.
