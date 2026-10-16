# Browser completion profile

The finite contract this Aurora Web version is claimed against. Every entry is
either **claimed** (with the independent evidence that proves it) or **backlog**
(deliberately not claimed). Update this file whenever a corpus changes.

Scope of this profile: the engine in this checkout, rendered at device pixel
ratio 1, verified on Windows with an installed Edge (Chromium) as the external
reference. Re-run the evidence with the recipes named in each row.

## Claimed: rendering behaviours with independent Edge references

Each row is a frozen local fixture, screenshotted from Edge by
`aurora-opencode-pro/tools/capture-browser-reference.py`, and compared
pixel-for-pixel against this engine by
`aurora-opencode-pro/build/browser-reference-validation-<n>/verify.json`.
All cases pass at **0 mismatched pixels, channel tolerance 0**, together with
the engine unittests and the interaction assertions.

| Area | Claimed behaviour | Fixture (corpus) |
| --- | --- | --- |
| Box model | content-box sizing, padding/border, `border` shorthand colour | `box-model.html` (-4) |
| Layout containers | grid `gap`, flex row geometry, margin collapsing | `flex-grid.html` (-4) |
| Floats | float stays active across a non-BFC child, BFC auto height contains floats (CSS 2.1 10.6.7) | `float-context.html` (-4) |
| Floats | line boxes shorten beside a float (CSS 9.5), `vertical-align: top/bottom` | `float-line.html` (-4) |
| Typography | `font` shorthand sets size, line-height and family | `font-shorthand.html` (-4) |
| SVG | box position and viewBox mapping | `svg-position.html` (-4) |
| Positioning | absolute insets against a positioned ancestor, both-inset width, percentage insets | `position-absolute.html` (-6) |
| Inline layout | a line box grows for a taller inline-block (CSS 10.8.1) | `inline-alignment.html` (-6) |
| Sizing | percentage width/height, `margin: 0 auto`, `max-width` clamp | `size-percent.html` (-6) |
| Floats | right float, a float that drops below (CSS 9.5.1), `clear: both` | `float-clear.html` (-6) |
| Flexbox | `justify-content` (all six keywords), `align-items` against the row's cross size | `flex-align.html` (-6) |
| Inline layout | a floated row of inline-block logos grows its line and its float (CSS 10.8.1 + 10.6.7) | `inline-block-row.html` (-6) |
| Tables | table/table-row/table-cell built from generic elements, cells stretched to row height (CSS 17.5.3) | `table-layout.html` (-7) |
| Flexbox | `flex-wrap: wrap` puts the overflowing item on a second line (CSS 9.3) | `flex-wrap.html` (-7) |
| Transforms | `translate` moves without affecting layout and paints with the positioned group | `transform-translate.html` (-7) |
| Overflow | `overflow: hidden` clips an oversized child and adds no height | `overflow-clip.html` (-7) |
| Positioning | relative insets shift the box, its flow space stays (CSS 9.4.3) | `relative-offset.html` (-7) |
| Stacking | overlapping positioned boxes paint by `z-index` (CSS 2.1 App. E) | `stacking-order.html` (-7) |
| Flexbox | `align-content` distributes cross space between lines (CSS 8.5) | `align-content.html` (-8) |
| Effects | `box-shadow` offset/spread rectangle behind the box | `box-shadow.html` (-8) |
| Compositing | `opacity` on overlapping absolutely positioned boxes | `opacity-blend.html` (-8) |
| Positioning | `position: sticky` at scroll 0 satisfies its inset like `relative` | `sticky-position.html` (-8) |
| Flexbox | `align-items: stretch` (the initial value) grows an auto-cross-size item to fill its line's cross size, on a single line and per wrapped line; a stretched item's padding/border are inside that size and a percentage-height child fills the stretched box (CSS Flexbox 8.3, 9.4; CSS 10.5) | `flex-stretch.html`, `flex-stretch-auto.html`, `flex-stretch-wrap.html`, `flex-stretch-pad.html`, `flex-stretch-nested.html` (-9) |
| Flexbox | `align-content: stretch` (the `normal` initial value) grows every wrapped line by an equal share of the left-over cross space, for a single line or several (CSS Flexbox 8.5) | `align-content-stretch.html`, `align-content-stretch-mixed.html` (-10) |
| Flexbox | `flex-direction: column` — `justify-content` on the main (vertical) axis, `align-items`/`align-self` on the horizontal cross axis, and `column-reverse` packing from the bottom (CSS Flexbox 9.3-9.5) | `flex-column-center.html`, `flex-column-end.html`, `flex-column-between.html`, `flex-column-reverse.html` (-11) |
| Flexbox | `margin: auto` on a flex item absorbs the free space on that axis and overrides `justify-content`/`align-self`; both auto margins centre the item on the axis (horizontally in a row, vertically in a column), a lone top/left auto pins it to the far edge (`margin-top: auto` = footer-to-bottom), and an auto margin disables cross-axis stretching (CSS Flexbox 8.1) | `flex-margin-auto-row.html`, `flex-margin-auto-col.html`, `flex-margin-top-auto.html`, `flex-margin-left-auto.html` (-12) |
| Flexbox | the `flex: <number>` shorthand sets the grow factor (a 300px row splits 200/100), an explicit `flex-basis` is the base size left undistributed while `flex-grow` stays 0, `flex-shrink: 0` keeps its base and takes no overflow, and shrinking is weighted by each item's base size (CSS Flexbox 7.1) | `flex-basis-grow.html`, `flex-basis-length.html`, `flex-shrink-none.html`, `flex-shrink-weight.html` (-13) |
| Box model | a padded flex, grid or table container lays its items out on its own **content box**: the item region is the container's `width` (padding and border are only the content origin), grid track sizes and `gap` resolve against that content box, and an auto-height padded container reports its content-box height (CSS 10.1; Flexbox 9.2; Grid 11; CSS 17.5.3) | `flex-pad-container.html`, `grid-pad-container.html`, `table-pad-container.html` (-14) |
| Typography | `line-height: normal` resolves to the font's own normal metric rather than a fixed pixel size, and `font-family` selects the first installed family in the list, whose metrics then drive line height | `line-height-normal.html` (-15) |

Supporting claims, all passing with the same artifacts:

- The engine unittest suite: `56 modules passed` (`dub test --compiler=dmd` in `aurora-web`).
- The application smoke suite (`aurora-browser/tests/verify-render.json`):
  navigation, history, tabs, async/timer JS, bookmarks, hit testing, hover,
  click, focus, keyboard, wheel, right/double click, scrolling and the
  frameless window, all `PASS`.
- Interaction: a click reaching its handler and link hit-testing returning the
  destination, asserted through the DOM in every corpus (`interaction.html`).

## Claimed: performance
## Claimed: loading over HTTP

`aurora-opencode-pro/tools/loading_server.py` serves crafted responses on
loopback and `loading_check.py` compares Edge's screenshot of each route with
this engine's own render (through `urlprobe.d`, which drives the real fetch
path) at 320x240, device pixel ratio 1. Fifteen routes, **all at 0 mismatched
pixels**:

| Route | What it proves |
| --- | --- |
| `/plain` | control: fetch, parse, style, layout |
| `/gzip` | RFC 9110 `Content-Encoding: gzip` decoded (the engine requests `Accept-Encoding: gzip, deflate`) |
| `/deflate` | zlib-wrapped deflate decoded |
| `/rawdeflate` | raw deflate decoded (the second form servers send) |
| `/chunked` | RFC 9112 chunked transfer decoded |
| `/redirect301`, `/redirect302` | redirect followed, `Location` resolved, final body rendered |
| `/bom` | a UTF-8 BOM is stripped, not shown |
| `/cp1252-meta`, `/cp1252-header` | a windows-1252 declaration, in a `<meta>` or in `Content-Type`, drives decoding (otherwise the class names it declares cannot match a UTF-8 stylesheet's selectors) |
| `/latin1-unlabelled` | unlabelled non-UTF-8 bytes decode as windows-1252, as browsers do |
| `/css-charset-header` | a **subresource's** own `Content-Type` charset is honoured, and a selector with a non-ASCII class name parses (CSS Syntax 4.3.9) and matches |
| `/css-charset-inherit` | an unlabelled stylesheet inherits the referring document's encoding (CSS 4.4) |
| `/data-css-charset` | a `data:` URL's own media-type parameters decide how its decoded bytes become text (RFC 2397) |
| `/notfound` | a 404 body is still rendered |

Decoding itself is unit tested in `auroraweb/encoding.d` (windows-1252 table
including the 0x80-0x9F range, UTF-16 both byte orders, BOM handling, the
`latin1`/`iso-8859-1` aliases, invalid-UTF-8 detection covering overlong forms
and stray continuation bytes). The engine's suite is now `39 modules passed`.
The two `css-charset-*` routes were added first and FAILED (1200 pixels each:
Edge red, this engine blue), which is what pinned the three real defects behind
them - the linked-stylesheet loader bypassing decoding altogether with
`toUTF8Decode`, an unlabelled sheet not inheriting the document's encoding, and
a subresource's `Content-Type` never reaching the loader - plus the ASCII-only
CSS identifier rule in `css.d`. All four are fixed and the routes are green.
The same cycle was then run again for `data-css-charset`, which failed the same
way (1200 pixels) because the `data:` branch decoded with `toUTF8Decode` and
ignored the URL's charset; it now decodes through `decodeStyleSheet` with the
media type taken from before the comma.

## Claimed: performance

Measured on the user's own large page `https://boqsc.eu/` (183 KB of HTML,
~7 MB of subresources) at 1080x680 with a release build
(`dmd -m64 -O -inline -release`):

| Measurement | Result |
| --- | --- |
| navigate (fetch + parse + first layout) | 1114 ms |
| one full layout pass afterwards | 6-11 ms |
| second load of the same page | 429 ms, with 6 cached subresources (6.9 MB) |

Larger numbers for an unoptimized probe build (1998 ms / 14-24 ms / 745 ms) are
recorded in `rendering-status.md`.

## Backlog: explicitly not claimed

- **Glyph-exact text.** Advances, baselines and wrap points differ from
  Chromium's text stack, so every claimed fixture above is deliberately free of
  text metrics. Text is rendered, but not claimed to break lines identically.
  `line-height: normal` and the selection of an installed `font-family` are the
  exception and are claimed (-15); on a real page the remaining difference is the
  substitute face's own metrics, measured at 4px of header band height on
  `djangoproject.com`.
- **Live pages have no oracle.** `boqsc.eu` and `djangoproject.com` are covered
  by DOM probes and Aurora-to-Aurora baselines only, which detect change and
  never prove correctness.
- **`position: sticky` under scroll.** The pinning is implemented and unit
  tested, but only the unscrolled offset has an independent reference.
- Multi-line `align-content` on the main axis (a wrapping column) remains
  unimplemented. (`align-items`/`align-self`, `align-content: stretch` for rows,
  column-direction `justify-content`, and `margin: auto` on flex items are
  implemented and Edge-verified in corpora -9, -10, -11 and -12.)
- **Auto-height boxes that add their own padding and border** in the
  absolute/fixed, flex column and flex wrap-line paths. The content-box item
  region itself is fixed and claimed (-14); these neighbouring paths were left
  alone until each has a fixture of its own, and the flex column path still sums
  item *content* heights where it should sum their outer heights.
- **Writing modes / vertical text**, `direction: rtl` bidi ordering.
- **Scroll containers**: nested scrolling, scroll anchoring, `overscroll`, and
  scrollbar styling beyond the engine's own thumb.
- **`filter`, `backdrop-filter`, blend modes** and `mix-blend-mode` (gradient
  and mask support is separate and not covered here).
- **Canvas, media, plugins** and `<iframe>` content rendering.
- **Colour management** (ICC profiles, `color()` spaces).
- **Native form control appearance.** The engine draws its own controls; Edge's
  widget rendering is UA-defined and is not a comparable target.
- **Cross-platform verification.** This profile is verified on Windows only;
  the engine and transport are platform-neutral D.
- **Loading, still open.** Brotli (`br`) is neither requested nor decoded;
  the client speaks HTTP/1.1 only, so an HTTP/2-only origin is unreachable;
  conditional requests and caching headers (ETag, Last-Modified, 304,
  Cache-Control) are ignored - the resource cache is an in-process memo and
  never revalidates; a subresource's own response headers are not available to
  the loader (it returns bytes), so a stylesheet's `Content-Type` charset is
  not consulted and it falls back to BOM plus the UTF-8/windows-1252 rule;
  cookie policy details (expiry, Secure, SameSite, host scoping) and
  `document.cookie` are not implemented; `Content-Encoding: zstd`, multipart
  bodies and `Content-Range` are not handled. In markup: `<iframe>`/frames,
  `<meta http-equiv="refresh">`, `<object>`/`<embed>` and script-driven
  `fetch`/XHR/WebSocket are absent, and form submission is not implemented.
  Decoding covers the UTF-8, UTF-16 (either byte order) and windows-1252
  families; the legacy CJK encodings (Shift_JIS, GBK, Big5, EUC-KR) are not in
  the table.
- **Licensing.** The strict CC0/0BSD distribution claim is **not** satisfied:
  Aurora-D is BSL-1.0 plus Unicode License V3 data, the linked D runtime and
  Phobos are BSL-1.0, and zlib is reached through `std.zlib`/`etc.c.zlib`. See
  `third-party-inventory.json`; both `dub.json` files still declare
  `"license": "BSL-1.0"`.

## How to re-run the evidence

```
verify aurora-opencode-pro/build/browser-reference-validation-4/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-6/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-7/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-8/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-9/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-10/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-11/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-12/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-13/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-14/verify.json
verify aurora-opencode-pro/build/browser-reference-validation-15/verify.json
verify aurora-browser/tests/verify-render.json
```

A recipe holds at most 16 steps and each fixture costs two, so a corpus covers
at most six fixtures; new fixtures go into a new corpus directory. The baselines
in `verify-render.json` are Aurora-to-Aurora regression baselines, not oracles.
Their captures go through the app's own paint surface, so they only compare at
device scale 1: at a 125% display scale the same 1280x800 request writes a
1600x1000 frame and the dimension check refuses to compare it with a 1:1
reference. The Edge corpora are unaffected - the probe renders offscreen at
scale 1.
