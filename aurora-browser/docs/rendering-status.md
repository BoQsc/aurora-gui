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

Both corpora also run `interaction.html`, which asserts through the DOM that a
click reaches its handler and that link hit-testing returns the right
destination.

## What those tools cannot see

- **Live pages.** `boqsc.eu` and `djangoproject.com` are checked by rendering
  this engine and inspecting boxes (`boxdump`/`pageshot-probe`) plus the
  Aurora-to-Aurora baseline in `aurora-browser/tests/verify-render.json`. That
  detects a change; it can never prove correctness. The independent oracle only
  covers frozen local fixtures, so a defect that needs a real page's data or
  scripts to appear can be missed.
- **Text metrics.** Glyph advances, wrapping points and baselines differ from
  Edge's font stack, so cases are deliberately written without text where the
  question is geometry. Where text is unavoidable (real pages), a mismatch may
  be font selection rather than layout.
- **Coverage breadth.** Eleven fixtures cannot represent the whole CSS surface:
  tables, multi-line flex, `align-content`, writing modes, scrolling, sticky
  positioning, transforms, filters, canvas/media and colour management are not
  independently checked today.

## Superseded corpora

- `browser-reference-validation/` (v1): box-model, flex-grid, svg-position.
  Still passing; the three cases are byte-identical to the same cases in -4.
- `browser-reference-validation-2/` and `-3/`: **superseded.** Their
  `float-context` case used the original text-bearing fixture, which measured
  glyph metrics rather than geometry, and then an intermediate inline-block
  version. Re-running them reports a fixture-changed mismatch by design.
  `-4` replaces that case with the floats-only fixture, and `-5` adds the
  positioning corpus.
- `browser-reference-validation-4/` and `-6/`: current. Keep them.
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
