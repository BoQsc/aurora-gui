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

- The engine unittest suite: `39 modules passed` (the corpus harness's
  `engine-checks`; the library-wide `dub test --compiler=dmd` in `aurora-web`
  reports 56).
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
and stray continuation bytes). The engine's suite is now `56 modules passed`.
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

### Measured: time to first content (progressive loading)

The load used to be a single blocking call: the stylesheet, every web font and
every image were fetched before any frame, so the page showed nothing until the
last byte. Measured with `loadtime.d`, the unoptimized probe whose numbers
`rendering-status.md` records, at the same viewports:

| Measurement | One blocking load | First paint split from images | Now: images streamed, no pass waits for them |
| --- | --- | --- | --- |
| boqsc.eu, first content on screen | 8502 ms | 1758 ms (document + first layout) + 30 ms (first frame) | 1669.9 ms (1641.0 ms document + first layout, 28.8 ms first frame) |
| boqsc.eu, settled | ~9.6 s | 7.99 s (best of four runs; 2.2 s of it is the page's own 3.5 MB PNG, 1.2 s the 24 pooled web-font files, 2.4 s the pass that re-measures the text once the real faces are registered) | 5978.5 ms after 49 frames; 2338.9 ms of it is the page's own 3.5 MB PNG, and the frame that collects and decodes that image is 148.0 ms |
| djangoproject.com, first content | 1642 ms | 1308 ms (document + first layout) + 19 ms | 1274.3 ms (1255.2 ms document + first layout, 19.0 ms first frame) |
| djangoproject.com, settled | 1934 ms | 1679 ms | 1628.2 ms after 6 frames |

What changed: a document's first passes fetch no network image and each later pass
fetches a ramped number of them (2, then 4, 8, 16); a pass's images go out
**together** on worker threads instead of one after another - the trace shows one
shared start offset for a whole batch (boqsc.eu's two images at 2160.3 ms and its
next three at 3462.8 ms, djangoproject.com's three at 1460.0-1460.2 ms, each
against a 1.3-2.2 s transfer, so they overlap), and the profiler process now
exits 0; `font-display: swap` faces wait for a painted frame
(`WebPage.notePaint`, called from `WebPageView.onPaint`) before downloading and
re-measuring; and the UA advertises woff2, which the engine decodes, so Google
Fonts negotiates woff2 subsets instead of ~1.4 MB of full TrueType faces. The
fidelity evidence is unchanged: `verify-render.json` still renders
djangoproject.com to the same frame (`3571CCE5...`, 0 mismatched) and the three
Edge corpora still pass 0 mismatched.

The image batch then stopped blocking the pass that started it. A pass records the
URLs it would fetch, hands them to a worker (`WebPage.startImageBatch`) and
returns to paint; a later pass collects the responses and decodes them on the main
thread (`collectImageBatch`, both in `aurora-web/source/auroraweb/package.d`).
Measured on `loadtime.d` at the same viewports: on djangoproject.com the two
requests went out at 1311.4 ms while frames 2-5 took 19-29 ms, and on boqsc.eu the
two icons went out at 1709.5 ms while frames 3-48 took 40-61 ms each, against a
1167.0 ms and a 2338.9 ms transfer no frame waited for. Only the pass that
collects a landed batch pays: 24.1 ms on djangoproject.com, 1587.3 ms on boqsc.eu
for the 1.65 MB icon pair and the 3.5 MB PNG it then decodes.

Two elements naming one image no longer fetch it twice. The collect-only walk
that sizes the next batch recorded a URL whose response the same pass was about
to decode, and `mayFetch` charged budget for a URL already in the resource cache,
so djangoproject.com's footer logo - the same SVG its header names - cost a fresh
78-90 ms request for bytes in hand. After the fix each page requests every image
URL exactly once, djangoproject.com's two batches are (logo, heart) then
(threespot, andrevv), and its settle fell from 1859 ms to 1628 ms.

**What the batch costs, measured.** The worker-exit path is understood now: a
worker must not leave a *pooled* connection behind, because the process then dies
at shut-down with 0xC0000005 (re-measured this session with an engine-linked
probe: two workers fetching one-shot exit clean, two workers pooling fault). So
every worker request is one-shot (`Connection: close`) and pays a handshake of
its own. That is cheap against a fast host - the image batches above overlap two
and three ways - and expensive against a slow one. A worker batch of the 24
web-font files to fonts.gstatic.com returned nothing at all: every request
stalled 26 s and came back an empty response, and capping the batch at six still
failed. A standalone probe measured the limit: 2 concurrent one-shot fetches to
that host 2/2 in 3.9 s, 4 concurrent 4/4 in 9.9 s, 6 concurrent 0/6 in 13.2 s.
The batch therefore runs in groups of at most six (`prefetchResponses`), and the
web-font files are deliberately *not* batched: on the main thread's pooled
connection the same 24 files cost 20-86 ms each after one 1211 ms handshake,
about 1.2 s in total, against 13-26 s as a worker batch. Batching them was tried
this session and reverted for exactly that reason.

**The document itself left the click path, and then every stylesheet.** The last
blocking call was the one the navigation made: `openUrlAtStartup` fetched the
document, parsed it and laid it out before it returned, so no frame could be
painted until it finished - the 1641.0 ms and 1255.2 ms of "document + first
layout" in the table above. The document, and then each external stylesheet a
document names, is now fetched by a worker and applied by a later pass
(`WebPage.beginNavigate`/`serviceNavigation` and the style batch
`serviceStylesheets` in `aurora-web/source/auroraweb/package.d`), so that call
returns at once and the browser paints the loading state, and then the page, on
the frames that follow; `navigationPending()` covers the navigation in flight -
the document and the stylesheets the document itself names. Font faces are still
queued only once a frame has been painted, which is now a contract with the
driver and not an internal detail: a headless driver that never paints never
opens that gate, and the faces it should have registered stay unregistered until
it does.

Measured on the current sources, 1080x680, unoptimized probe builds - `loadtime.d`
for the call a click makes and `loadprobe.d` for a frame-paced loop that splits
every frame into its engine pass and its paint:

| Measurement | Before this change | Now |
| --- | --- | --- |
| boqsc.eu, the navigation call (document fetch + parse + first layout) | 1641.0 ms | 0.6179 ms (`loadtime.d`), 0.0 ms (`loadprobe.d`) |
| boqsc.eu, first paint | nothing before the call returned | frame 0, 0.0 ms |
| boqsc.eu, the document applied (parsed, styled, laid out, painted) | in the call | frame 6 at 719.0 ms |
| boqsc.eu, settled | 5978.5 ms after 49 frames | 4711.0 ms after 65 frames (`loadtime.d` 4539.19 ms) |
| djangoproject.com, the navigation call | 1255.2 ms | 0.8231 ms (`loadtime.d`), 0.0 ms (`loadprobe.d`) |
| djangoproject.com, first paint | nothing before the call returned | frame 0, 0.0 ms |
| djangoproject.com, the document applied | in the call | frame 4 at 1036.0 ms |
| djangoproject.com, settled | 1628.2 ms after 6 frames | 2177.0 ms after 18 frames (`loadtime.d` 2304.41 ms) |

No frame in either load waits for the network any more. boqsc.eu's document is
292.4 ms out, its `fonts.googleapis.com` sheet goes out at 323.0 ms and lands
1389.1 ms later, its two image pairs overlap (1420.1 ms of transfer alongside
245.7 ms, then 1361.5 ms alongside 317.0 ms) and its own 3.5 MB PNG takes
2367.1 ms - and the document is applied on frame 6 while that sheet is still in
flight. djangoproject.com's render-blocking `output.bd0f2d884efe.css`
(135,162 bytes) fetches in 108.6 ms with frames painting through it, and its
eight woff2 faces cross the pooled connection one after another in 50.7-81.6 ms
each. The settled repaint costs 17-19 ms on boqsc.eu and 14-15 ms on
djangoproject.com.

Two measured consequences. The first layout no longer waits for a stylesheet, so
a document is laid out and painted without the sheet and laid out again when it
lands: the page can show its unstyled body over that window, where a browser
holds the paint instead. And the pass that *applies* a document, a stylesheet or
a set of faces is still one frame of CPU work - 778 ms for djangoproject.com's
document together with its stylesheet (frame 4 of 18, the stylesheet landing as
that frame ends), 489 ms for its face registration (frame 16), and on boqsc.eu
467 ms for the pass that decodes and registers its served woff2 faces and
re-shapes the text (its pass 467 ms, its paint 331 ms, frame 62 of 65). Under
`loadtime.d`, which measures the pass alone with no paint, djangoproject.com's
last four passes are 126.9, 124.4, 140.2 and 90.6 ms and boqsc.eu's final batch
collect and 3.5 MB decode is 93.6 ms. Every other load frame is 18-94 ms on
boqsc.eu and 19-86 ms on djangoproject.com. So the network no longer blocks a
frame on either page and what is left per frame is the apply work itself -
parse, cascade, layout, script and shape in one slice; making it incremental is
what would take the largest frame below a quarter second on a page this heavy.

What is left is the page's own weight and third-party latency rather than
serialisation the engine could remove: a 3.5 MB PNG takes 2.2 s wherever it is
fetched, and Google Fonts' CSS alone costs 1.3-1.5 s of the blocking document
load on boqsc.eu.

**Profiled: the pass that registers the new faces, and the pass that waits for an
image batch.** Timed in pieces on boqsc.eu, the 2.26-2.36 s pass that follows the
first paint is 2.19-2.29 s of its face-registration loop against 68-120 ms of
cascade and layout and 0 ms of image work, and inside that loop each of the 24
faces costs a 20-85 ms fetch (1185 ms for the first, which pays the connection
handshake) plus a 1-14 ms woff2 decode, under 1 ms of staging and a 4-6 ms font
load. So that pass is waiting on the network, not decoding or re-measuring: 24
files crossing one pooled keep-alive connection in sequence. A pass that started an
image batch used to wait the same way and for the same reason - measured at
1006-1166 ms inside `loadImages` for the two-image batch and 2183-2190 ms for the
three-image one, against 25-30 ms of cascade and layout and 0-83 ms of image work
in the passes with nothing to wait for. That wait is gone, see the streaming
numbers above. Neither wait was CPU the engine could speed up;
the lever is fewer and better-overlapped requests (Google Fonts serves three to
six `unicode-range` subsets per weight, of which a Latin page needs one), not a
faster pass.

## Backlog: explicitly not claimed

- **Glyph-exact text.** Advances, baselines and wrap points differ from
  Chromium's text stack, so every claimed fixture above is deliberately free of
  text metrics. Text is rendered, but not claimed to break lines identically.
  `line-height: normal` and the selection of an installed `font-family` are the
  exception and are claimed (-15); on a real page the remaining difference is the
  substitute face's own metrics, measured at 5px of header band height on
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
  Their captures are built with `-version=AuroraHeadless`, so the frame they
  write is exactly the requested logical size whatever the display's scale: a
  1280x800 request writes 1280x800. Driving a real window instead writes that
  window's framebuffer, logical size x display scale (1600x1000 at 125%), which
  no 1:1 reference can be compared against - the app is correct there too, and
  Edge at the same 125% device scale puts the same page at the same coordinates.
  The Edge corpora are unaffected - the probe renders offscreen at scale 1.
  Last confirmed on 2026-10-17: `aurora-browser-new.exe` was rebuilt clean from
  this tree and run as `--url https://www.djangoproject.com/ --screenshot …`,
  and the shell's own frame reproduced the engine's header at the same 1080x680
  viewport (band 96 physical = 76.8 logical against the engine's 77; nav ink page
  21.6..46.4 against 22..47; x 66..195 against 53..156 scaled).
