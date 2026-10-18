# Pixel compatibility

How this engine claims pixel compatibility, and what that claim is allowed to
mean. The goal behind it is eventual replacement of a general-purpose browser:
for that, the target cannot be "matches Chromium's output" but "matches the web's
behaviour", proven case by case and frozen.

Two rules carry everything else:

- **Exactness is the default, and it is a per-class claim.** Geometry and flat
  colour are compared at `channelTolerance 0` with no exceptions. Where a class
  cannot be exact, the reason and the budget are recorded in the case that needs
  them - never a global tolerance that would hide a geometry bug.
- **An independent engine is the oracle, the engine's own earlier output is only
  a regression baseline.** A frame captured from this engine can prove a change
  happened; it can never prove correctness. Correctness comes from the clause and
  from the reference engine's own output.

## 1. What can be pixel-exact

| Class | Examples | Acceptance |
| --- | --- | --- |
| **A. Geometry** | box model, padding/border, `min`/`max` sizing, absolute/relative/static placement, inset solving, flex/grid/table item regions, floats, margin collapsing, `overflow` clipping, transforms with integer translations | **0 differing pixels** at `channelTolerance 0`, **and 0 rect deltas** at `--tolerance 0` against the reference engine's `getBoundingClientRect` table |
| **B. Flat colour and alpha** | solid fills, `opacity` over a flat page, layered alpha compositing | **0 differing pixels**: same sRGB blending, no resampling involved |
| **C. Images** | decoded raster resources drawn at integer offsets and scale | **0 differing pixels**, given the same decoded bytes and no smoothing choice |
| **D. Rasterised edges and effects** | antialiased diagonal/rounded edges, `box-shadow`, gradients, `filter`, `mask` | Per-case budget with the reason recorded (rasteriser differences), applied only to the affected channels/region and never to geometry |
| **E. Text** | glyph shaping, advance widths, line breaking, ink coverage | Never byte-exact across engines. Pin the faces the page serves (WOFF/WOFF2), then assert **metrics and ink bands** (advance widths, line-box positions, per-row ink extents) against an independent engine frame within a stated pixel count; line-box and box geometry stays class A |
| **F. Engine policy** | scrollbar width and overlay, `prefers-color-scheme`, quirks mode, form-control chrome, `position:fixed` against the layout viewport | Not a spec question. Decided per feature, recorded here with the comparison geometry that makes it observable (for example: a fixed box must be measured against a page-only viewport, because a headless reference browser's layout viewport is smaller than the requested window) |

The boundary between A/B/C and D/E is what makes "pixel perfect" measurable: it is
exact where the web specifies a value, budgeted only where rasterisation is
genuinely engine-specific.

## 2. What a fixture must satisfy to claim a class

- **No script.** The committed fixture carries none; the capture tool injects its
  measurement code into a scratch copy only, so this engine never runs measurement
  code to produce its own expected values.
- **No text that inks.** Cases carry no text nodes, or set `font-size: 0`, so no
  glyph and no font fallback can decide a pixel.
- **Solid rectangles.** Each case paints a flat rectangle (fill, or a visible
  border ring plus fill) so a divergence is visible in the frame as well as in its
  rect row - no case hides behind a rect-only ledger.
- **Integer, viewport-independent placement.** Pixel insets, no `position:fixed`,
  no viewport units, no percentage that resolves against the viewport, so the case
  cannot depend on the reference browser's window versus layout viewport.
- **One clause per case**, with a comment naming the rule (for example
  "CSS 2.1 10.5", "CSS 2.1 10.6.4", "CSS Box Sizing"). Where the case set also
  has a rect oracle (`*.edge.tsv` beside the fixture), every measured element
  carries a `data-rect` name, so the numbers and the frame come from one capture
  of the same input. A pixel-only fixture needs no names.
- **A class-D case records its own budget.** Where the difference is genuinely
  rasterisation - a gradient ramp, an antialiased edge - the fixture states the
  class, the reason and the measured budget in a comment, and its recipe compares
  at exactly that budget with `maxDifferentPixels 0`, so the tolerance admits the
  rounding and nothing else. `aurora-browser/tests/check-pixel-compatibility.py`
  refuses such a budget on any case that does not declare it. A budget may never
  cover geometry: a class-D case still pins its flat colours and its geometry at
  tolerance 0.

## 3. Oracle provenance

Every reference records, in the recipe's `referenceSource` and in
`docs/rendering-status.md`: the engine and executable, the headless flags, the
loaded dimensions, the device scale factor, the colour scheme, the scrollbar
policy, and the fact that the fixture was captured through the same page viewport
this engine renders. Where a fixture has both, the frame and the rect table come
from one capture run of the reference engine - `aurora-browser/tests/
capture-edge-rects.py` emits both - so a rect row and a pixel cannot disagree
about their own input; a pixel-only fixture is captured with the same headless
flags, minus the injected measurement script. A reference may be refreshed only by recapturing
from the reference engine - never by copying this engine's output - and a changed
reference requires its own review and an explanation of which expectation moved
(`aurora-browser/docs/IMPLEMENTATION-BRIEF.md`, "Reference policy").

## 4. Arbitration when engines disagree

1. Read the clause. If it decides the question, follow it, and record the engine
   that does not.
2. If the engines agree, treat their shared behaviour as the target - that is
   web-compatible behaviour, not one browser's habit.
3. If the clause is silent and engines split, choose the behaviour that keeps the
   frozen corpus stable, record the choice here, and never tie-break silently.
4. Reference output can itself be wrong. A case may be deliberately excluded from
   the corpus when the comparison cannot be fair at all (the viewport-relative
   fixed-position case is excluded for exactly this reason, and says so in the
   fixture) - excluded with a reason, never left as an unexplained mismatch.

## 5. Current state

Four corpora exist, each anchored to an independent headless-Edge capture of its
own fixture at the same geometry. Three are class A and compared exactly; the
fourth is class D and exact everywhere except the quantisation of a ramp, which
it records:

- `aurora-browser/tests/reference/box-geometry.html` - 22 rects against
  `box-geometry.edge.tsv` at `--tolerance 0`, and a frame at
  `channelTolerance 0` (0 of 819,200 pixels, `AD21B644…`).
- `aurora-browser/tests/reference/flex-geometry.html` - 0 of 816,640 pixels
  (`99A4A532…`).
- `aurora-browser/tests/reference/flow-sizing.html` - 0 of 816,640 pixels
  (`6C33FC27…`).
- `aurora-browser/tests/reference/article-panel.html` - class A geometry, the
  hero's clamped flex item inside a grid item: 0 of 816,640 pixels (`13AB4D92…`)
  at `channelTolerance 0`.
- `aurora-browser/tests/reference/linear-gradient.html` - **class D, the one
  recorded budget in the corpus**: four `linear-gradient` forms and the fading
  mask the hero page itself uses, compared at `channelTolerance 1` with
  `maxDifferentPixels 0`, because 17,430 of the 57,600 ramp pixels differ by
  exactly 1 channel unit and none by more (`B702DDB2…`). Its mask case, its cell
  geometry and its colours at a stop are exact at tolerance 0.

Real pages are class-E-and-class-A mixes: they can only ever be a regression
baseline for this engine (`aurora-browser/tests/verify-render.json`'s
djangoproject.com frame), never a correctness oracle.

## 6. Growth path

1. **Fix as a fixture.** Every real-page divergence that is fixed becomes a
   fixture in this corpus, so the same bug cannot return silently. This is the
   ratchet that closed the box-model, flex, flow-sizing, out-of-flow padding,
   absolute box-metric, clamped-flex-item-width and gradient-rasterisation gaps.
2. **Second engine.** Capture the same fixtures from a second independent engine
   (Firefox, or a second Chromium channel). Where it and the current reference
   agree, the case is web behaviour; where they differ, use section 4 to decide,
   and keep both captures as evidence. That is what turns "matches Edge" into
   "matches the web".
3. **Breadth.** Run a subset of the Web Platform Tests reftests (CSS2, css-box,
   flexbox, grid) through the same comparator: reftests are already the
   two-files-must-render-identically model used here, and their expectations are
   maintained by the browser vendors, which is far more coverage than hand-written
   cases can reach. WPT is BSD-3-Clause: keep it a **separate acquisition outside
   this CC0/0BSD tree**, referenced and not copied, exactly as
   `aurora-browser/docs/IMPLEMENTATION-BRIEF.md` section 5.4 requires.
4. **Budget per class.** Record any class-D/E budget against the specific case, so
   a future failure is attributable to a clause instead of being absorbed by a
   tolerance.

The replacement criterion follows from the same four steps: class A/B/C exact,
class D within recorded budgets, class E by metrics, a second engine agreeing on
the fixtures it can capture, and the real-page acceptance baseline green.
