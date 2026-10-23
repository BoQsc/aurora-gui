# Damaged glyphs: character audit and experimental fixes

22 October 2026. **C remains Aurora's shared default. No promotion is proposed.**
[Open the interactive pixel inspector](index.html).

The owner was right: the earlier whole-line averages and numeral-only tests
missed visibly damaged letters. A lower average error was insufficient evidence
to describe the rendering as corrected. This audit reproduces the problem in
the shared renderer, includes actual host/Pad++ captures, and exposes every
measured character regression. It does not claim all letters or numbers are fixed.

## Diagnosis and changes

- **Consolas 17px `e`:** IP interpolation discarded precision before a subsequent
  grid-rounding instruction. Its crossbar landed on the wrong row and compressed
  the counter. Refined D preserves precise original coordinates with a common
  denominator and rounds the interpolation result to the nearest F26.6 value.
  Phantom points retain their initial physical-grid rounding: restoring their
  unrounded advance would damage `W`, `4` and other glyphs. Other instructions'
  original-coordinate state is unchanged. The `e` error at phase 0 falls from
  **77.171 to 1.028**, with improvements across all eight phases and both themes.
- **Coarse curves:** short TrueType quadratics previously used as few as two
  straight segments. Refined D now solves quadratic scanline intersections,
  splitting at vertical extrema. This improves many bowls, diagonals and
  numerals. It also introduces individual sampling regressions, listed below.
  Vertical alignment, when applied to curves, splits at zone boundaries and
  transforms controls as well as endpoints.
- **Uninstructed simple outlines:** Aurora's vertical alignment changed design
  heights that the native reference retained. Refined D skips that adjustment
  for simple TrueType outlines without glyph instructions. Composites and
  failed-hint fallbacks retain their prior alignment. This substantially improves
  Inter; it is not a complete native auto-hinting implementation.
- **Courier New remains unfinished.** Exact curves improve its aggregate error,
  but many bowls, terminals, punctuation and digits still differ substantially.
  An attempted 8x1 legacy-gasp fallback worsened small `*` and fractional-phase
  glyphs, so it is excluded. Broader rounding, delta suppression and original-
  coordinate changes were also rejected when character checks exposed damage.

All production changes are confined to `AURORA_TEXT_EXPERIMENT=native-refined`
with natural hinting. C and reviewed D retain their pixels. Contrast, gamma,
font selection, layout, glyph IDs/origins and the 0.039 ink guard are unchanged.
The change introduces no production Windows rendering API and no per-character
or per-font exception. Existing application executables are not replaced.

The interpretation was checked against [Microsoft's instruction specification](https://learn.microsoft.com/en-us/typography/opentype/spec/tt_instructions)
and [ClearType compatibility description](https://learn.microsoft.com/en-us/typography/cleartype/truetypecleartype).
The actual Windows probes and per-character images establish the observed
behavior; those documents alone do not prove native parity.

## Character evidence and remaining failures

The pixel inspector includes the approved C default, previous refined D, updated
refined D and Windows, so defects in the existing default remain visible.

The broad sweep tests 94 non-space printable ASCII characters, nine fonts and
eight physical sizes at phase 0 in light mode: **6,768 comparisons**.

| Corpus | Improved | Equal | Regressed | Mean error before → after |
| --- | ---: | ---: | ---: | ---: |
| Broad characters | 3,557 | 2,656 | **555** | 10.086 → 7.846 |
| Focused 17px, both fonts | 1,632 | 1,121 | **255** | 15.064 → 13.647 |
| Focused Consolas 17px | 716 | 695 | **93** | 4.500 → 2.934 |
| Focused Courier New 17px | 916 | 426 | **162** | 25.627 → 24.360 |

The focused sweep tests every character at eight horizontal phases and two
themes: 3,008 comparisons across Consolas and Courier New. The corpora overlap;
do not add their counts. Error is 8-bit mean absolute error over the union of
ink pixels, not a readability score. Original pixels are available at 1x and
nearest-neighbor enlargement in the inspector; browser-rendered text is not
used as evidence.

**The visual gate remains incomplete.** For example, Segoe UI 12px `?` increases
from 3.579 to 14.905, and Inter 20px `=` from 0.378 to 13.289. Tahoma/Arial small
round glyphs also regress. Courier New 17px `)` still has large error. All
regressions, including fractional-phase cases, are in [regressions.json](regressions.json),
with complete before/after data in [character-matrix.json](character-matrix.json).
The numeral subset also has regressions: 24/160 Consolas and 19/160 Courier
cases. Its mean errors decrease from 2.834 to 2.250 and 31.734 to 29.702,
respectively. Neither average certifies the numbers as correct.

The 144-case whole-line corpus improves 134 and regresses 10 against the prior
refinement. All 144 improve against C; 139 improve and five regress against D.
The ten regressions are Arial 11/12px and Tahoma 11/12/13px, both themes. Mean
error falls from 10.011 to 7.499. The 288-case RGB corpus improves all 276 visible
cases, with 12 white-on-white controls equal; mean error falls 6.938 to 4.511.
Those averages are secondary diagnostics, not acceptance criteria.

## Verification and reproduction

- [Framework/build checks](validation.json): font, phase, DPI, hinting replay,
  cache/coverage, instruction, rasterizer, alpha and font-profile checks pass.
  Standards audit and all 14 Python tests pass. Separate host and Notepad
  release builds pass without replacing the repository's executable.
- [Full application checks](ui-validation.json): host and live Pad++ workflows
  pass for C and refined D with the existing ink guard. Live C pixels match the
  earlier C capture at 120 DPI. The older Notepad's previously recorded full
  drag/restore smoke failure is outside this fix; this report does not claim
  every repository test passes.
- [Captured software/Vulkan evidence](captures.json): ten C application captures
  remain identical at 96/144 DPI. Two accepted live Vulkan frames per profile
  match software exactly at 120 DPI.
- [Independent generated-font probe](native-ip-probe.json): four vertical IP/grid
  boundary cases become exact Windows matches; eight controls are unchanged.
  One unchanged negative horizontal case still has error 85, and three
  horizontal boundary cases retain error 0.667. Those limitations are preserved.
- [Compatibility modes](compatibility.json): refinement is inactive under
  hinting `0` and `1`; all eight checked images remain identical.
- [Source/evidence audit](source-audit.json): C/D's 144-image corpora and protected
  D review pixels remain unchanged. Original source is preserved in
  `before-source`, from commit `ac99ba030dd4e4613057b82036191fae6ec98c55`.
- [Vendor digest audit](vendor-manifest-audit.json): only the three owned text
  source files and font documentation are re-digested. Existing unrelated
  manifest mismatches and the historical Vulkan debt ledger are preserved.

From the repository root:

```text
python artifacts/native-text-audit/character_matrix.py
python artifacts/native-text-audit/native_ip_probe.py
python artifacts/native-text-audit/production.py
python artifacts/native-text-audit/colors.py
python artifacts/native-text-audit/validate.py
python artifacts/native-text-audit/capture.py
python artifacts/native-text-audit/compatibility.py
python artifacts/native-text-audit/ui_validate.py
python artifacts/native-text-audit/package.py
```

Run application/GPU captures serially; keep other user windows/processes intact.
DMD/DUB, Python, Pillow, fontTools and the recorded Windows fonts are required.
Windows supplies the reference renderer only. Current evidence is local to
these font versions, native settings and DPI. Shaping parity, RGB ClearType
output, complete composite hinting and exact native scan conversion remain open.

The [research summary](research-summary.json) records rejected variants and the
reason each was excluded. Their raw scripts/outputs are retained locally under
`build-validation/native-text-audit/exploration`, outside the review package.
They are not current-renderer or acceptance evidence. The final matrix and
production source hashes identify the implemented variant. The earlier glyph
report has a correction banner; its original presentation and manifest are
retained here, and all its measurement/image files remain unchanged.
