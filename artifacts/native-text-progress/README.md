# Aurora native text fidelity — 20 October 2026

The owner approved **C as the shared Aurora default** on 2026-10-20:
“Make C the default.” C combines foreground-aware coverage B with repaired
natural grayscale hinting and font-selected sampling. The approved host ink
guard is `0.039`. [Decision and reviewed image hashes](decision.json).

Rebuilt Aurora-D applications inherit C automatically. `AURORA_HINTING=0`
restores unhinted B; `AURORA_TEXT_COVERAGE=legacy` separately restores the older
coverage transfer. The host no longer supplies its private `0.75` contrast.
Exact Windows grayscale and ClearType parity remain unachieved.

[Open the visual report](index.html). It includes the fonts, resolved regressions,
actual application layouts, and the full measurement table.
Start with the [real Pad++ comparison at 125% DPI](padpp-live-120/review.html).

## Further work implemented

The experimental pure-D TrueType hinter had several correctness faults:

- MSIRP, SCFS and ISECT consumed operands in the wrong order. A negative MSIRP
  distance in Consolas became a negative point index and caused a process-ending
  array error. Operand and twilight-coordinate handling now follows the
  [OpenType instruction specification](https://learn.microsoft.com/en-us/typography/opentype/spec/tt_instructions).
- MINDEX used overlapping D slice assignment, causing an array error in Arial.
  It now rotates the stack range explicitly.
- Point-zone reads and writes now abort through `HintAbort` when indices are
  outside allocated outline/maxp limits, allowing the existing raw-outline
  fallback instead of an array error or uncontrolled point allocation.
- Hinted outlines now normalize to their fractional left phantom origin. This
  corresponds to the origin adjustment in the
  [FreeType TrueType loader](https://raw.githubusercontent.com/freetype/freetype/master/src/truetype/ttgload.c).
- Natural-mode DELTAP/SHPIX now suppress legacy horizontal/untouched delta
  dents, preserve vertical composite accent placement, and honor the font's
  INSTCTRL native-mode opt-out. The behavior follows Microsoft's
  [instruction compatibility description](https://learn.microsoft.com/en-us/typography/cleartype/truetypecleartype).
  INSTCTRL flags are independent; prep-only flags and the graphics-state reset
  selector are respected.
- Natural mode now respects version-1 `gasp` grid-fitting and symmetric smoothing
  choices. Generated-font native probes verify GETINFO bit 18 changes with the
  smoothing flag; absent/version-0 tables retain the observed native default.
  This fixes the Calibri 20 px regressions. See the
  [gasp specification](https://learn.microsoft.com/en-us/typography/opentype/spec/gasp)
  and [native probe results](native-getinfo.json). These generated fonts are
  reference tools, never installed system fonts.
- Sampling now follows the font's asymmetric (8×1) or symmetric (4×4) smoothing
  choice. Canvas and direct glyph calls snap to the same phase grid, including
  a carry to the next pixel. Direct native phase probes exposed the former
  unsnapped half-step ink loss; the Inter phase test now passes unchanged.
  See [native-phases.json](native-phases.json) and [the probe](phase_native_probe.py).

Focused instruction tests accompany the fixes. The Windows sweep renders
7,200 glyph/size combinations across eight fonts, then repeats glyphs in reverse
order to detect leaked interpreter state. All complete without blank output;
reported attempts all succeed without fallback. Sizes are 9, 11, 12, 13, 17, 18,
20, 26 and 34 physical px. See [sweep.txt](sweep.txt).

## Native comparison

The separate native corpus covers Segoe UI, Consolas, Arial, Calibri, Tahoma,
Verdana, Courier New, Times New Roman and bundled Inter at 11, 12, 13, 17, 18, 20, 26 and 34 px,
in light/dark themes. Windows DirectWrite renders identical glyph IDs and origins
to isolate rasterization. This does not test native shaping equivalence.

Natural hinting improves **all 144** paired font/size/theme cases across nine
fonts. Average error falls from 30.56 to 12.86 (58%). Before the
delta compatibility repair, only 98 improved and 30 regressed; that
[checkpoint](measurements-before-delta-compat.json) is preserved. Respecting
gasp smoothing improves the subsequent [125/128 checkpoint](measurements-before-gasp.json).
The [127/128 checkpoint](measurements-before-sampling-profile.json) predates
the font-selected sampling grid, which resolves Tahoma 18 px (28.31 → 6.03 light,
25.03 → 3.21 dark). Bundled Inter also improves at every tested size/theme.
No complete monitor-reference capture is pixel-exact.
The metric is mean absolute RGB error on the union of ink pixels; lower is closer
to this machine's DirectWrite grayscale reference, not a readability verdict.
ClearType references are also measured, but Aurora remains a grayscale renderer.

At 13 px:

| Font | Default light | Natural light | Default dark | Natural dark |
|---|---:|---:|---:|---:|
| Segoe UI | 27.66 | 10.21 | 23.80 | 6.91 |
| Consolas | 40.62 | 6.44 | 34.69 | 3.46 |
| Arial | 30.38 | 27.12 | 27.34 | 22.80 |
| Calibri | 22.27 | 7.67 | 18.18 | 4.66 |
| Tahoma | 45.31 | 23.20 | 39.93 | 19.16 |
| Verdana | 41.29 | 15.89 | 36.57 | 12.91 |
| Courier New | 78.34 | 31.22 | 70.01 | 28.67 |
| Times New Roman | 39.74 | 23.92 | 32.92 | 19.72 |
| Bundled Inter | 21.66 | 17.62 | 18.55 | 13.34 |

**Natural hinting C is now the owner-approved default.** A trial of
16 horizontal origin phases worsened all 32 Segoe/Consolas comparisons and was
removed. Increasing sampling is not an established fix.

The native settings on this display are gamma 1.8, grayscale enhanced contrast
1.0 and ClearType contrast 0.5. Font hashes, settings, source hashes and all
144 comparisons are in [measurements.json](measurements.json). A separate
[transfer probe](native-transfer.json) checks native foreground/background
behavior at two sizes; its 44 cases do not disprove scalar A8 compositing within
one channel level. It does not establish a native transfer model.

An isolated Segoe `H` diagnostic matches neutral gamma-1/contrast-0 native
coverage in 14/16 size/theme cases. Those neutral references are not the monitor
reference used above and do not establish native rendering parity.
The [individual-glyph diagnostic](glyph-diagnostic.json) was captured before
the gasp fix to distinguish outline placement from coverage transfer; it is
historical diagnostic evidence, not the final comparison.

## Applications and renderers

Fresh previous-B / approved-C captures cover older Aurora Notepad and host
editor light/dark layouts at 96/144 DPI, and the actual Pad++ light scene at
both scales. Text includes selection, Latin, Ukrainian, Greek and accents.
The headless fixture populates Pad++ without invoking its Python client.
These are corrected captures: the original test platform discarded injected
scale, so the original images labeled 144 DPI were actually 96 DPI. The
headless platform now retains logical client metrics and DPI independently of
presented physical pixels; UiTestDriver updates that readback before dispatch.
Each capture asserts its actual DPI/framebuffer. Pad++ now measures 1180×760
at 96 DPI and 1770×1140 at 144 DPI. A full-window regression verifies physical
frames, logical sizes and return-to-96-DPI pixel equality. Original approved
images remain intact with [an erratum](../text-coverage-candidate/capture-errata.json).

Separate actual-screen Vulkan captures validate two changing marker states for
each mode at 120 DPI. Previous B differs from software at 28 pixels
over two frames, maximum channel error 1. Natural hinting matches software
exactly in both frames. Occluded/stale frames are rejected, never substituted
with software screenshots. An earlier occluded run was rejected; the final
probe keeps only its own temporary window visible and reports zero rejected
frames in the accepted runs. GPU parity at 144 DPI is not claimed.
An earlier accepted 96 DPI probe found 12 differing B pixels with the
same maximum error 1; natural hinting also matched software at that scale.

The real Pad++ client also passes its full interaction test with the approved
default: menus, tabs, find/replace, zoom, tooltips, save/open and the 2,001-line,
214 KB editor workflow. The host's full verifier passes. Existing user windows
were kept running; release executables were built under `build-validation`.
C also passes the full Pad++ workflow. In the pre-promotion 120 DPI run its
2,001-line load takes 0.34 s versus 0.10 s for B; switching
takes 0.20 s versus 0.10 s. These are single local measurements, not throughput
guarantees. [Reviewed C metrics](padpp-natural-metrics-120dpi.json) and
[Previous B metrics](padpp-metrics-120dpi.json) retain memory and timing details.

The golden images now record approved C at 125% DPI: Pad++ is 1475×950
physical pixels (1180×760 logical), and the workbench is 1225×800 physical
(980×640 logical). Previous B references are archived here. The same-size
legacy/B workbench pair isolates coverage weight at 96 DPI. Render recipes
require the display scale documented in their reference metadata.

## Validation and limits

See [validation.json](validation.json). Coverage/cache/opacity/growth tests,
1,872 existing font regressions, instruction unittests, the Windows sweep,
120/144/192 DPI tests, standards audit, Python tests, host verification, Pad++
self-test and representative release builds pass. Earlier Vulkan retained
interaction evidence remains in the approved coverage review.
The preserved [strict B-profile verifier](validation-natural-strict.json) stopped
at `0.0416 < 0.045` at 120 DPI. C is lighter than B's `0.0473` fixture at that
scale. Before approval, the [full proposed C verifier](validation-natural-pre-promotion.json)
passed with an explicit review-only `0.039` profile, including later canvas
and live redraw checks. The owner then approved C and that guard after the
[live Pad++ review](padpp-live-120/review.html). Normal verification now uses
the approved `0.039` guard without a candidate flag. The post-promotion Pad++
screenshot is pixel-identical to the reviewed C image; see
[default reference metadata](default-references.json).

[Post-promotion validation](validation.json) exercises the unset shared default,
unhinted compatibility, fonts, phases, DPI, the host and Pad++ workflow. The
Windows font sweep additionally checks default/natural pixel equivalence for
every tested glyph. The [approved proposal](promotion-proposal.json) records
the precise default and compatibility choice.
The existing Inter font regression initially failed in natural mode at `l`, 21 px,
phase 1/8: ink 7793 → 6817 exceeds the area-conservation bound. The default
passes all 1,872 cases. The native experiment uses a quarter-pixel horizontal
sample lattice above 20 px; Canvas paints quarter-pixel phases there, while the
public atlas test exercises all eighth-pixel phases. An isolated eight-sample
variant passes that test but worsens 43 native comparisons (5 improve, 80 equal),
so it was rejected rather than trading native fidelity for a passing test.
See [sampling-variants.json](sampling-variants.json). Matching native phase
snapping fixes the failure without increasing samples or relaxing the bound.
The default and natural modes now both pass all 1,872 cases, including the
off-grid requests and pixel-carry checks. The original failure is preserved in
[validation-natural-before-phase-fix.json](validation-natural-before-phase-fix.json).

One earlier concurrent UI run failed Pad++'s hover-hint check while a Vulkan
probe was opening; that [failed attempt](validation-concurrent-ui.json) is
preserved. Serialized B and C Pad++ runs subsequently pass.

The older Notepad full smoke still has the pre-existing drag/restore assertion
at `tests/headless_smoke.d:120`, reproduced in legacy and foreground modes.
It is separate from these text changes; the full repository is not reported green.

Remaining work is to complete instruction/rounding fidelity and measure the native
coverage transfer across foregrounds/backgrounds without tuning to a single
font. Broad font/DPI/application comparison and owner review are required before
enabling a new default. Exact Windows rasterization and ClearType equivalence
remain unachieved.

## Reproduce

From `vendor/aurora-d-0.4.5`:

```text
dub run --config=text-coverage-test
dub run --config=hinting-windows-test
```

From the repository root (Windows, installed fonts, DMD, Python and Pillow):

```text
python -B artifacts/native-text-progress/audit.py
python -B artifacts/native-text-progress/capture.py
python -B artifacts/native-text-progress/package.py
python scripts/audit-aurora-standards.py
```

The corpus and capture scripts build isolated binaries. The capture script
briefly shows its own Vulkan window. Leave `AURORA_HINTING` unset for the
approved shared default C, or use `AURORA_HINTING=0` to compare unhinted B.
`python -B artifacts/native-text-progress/validate.py` runs post-promotion
checks, including explicit unhinted compatibility.
Generated-font diagnostics additionally require `fontTools`. The changed text
patch's vendor checksums are verified; four unrelated pre-existing digest
mismatches remain recorded in [vendor-manifest-audit.json](vendor-manifest-audit.json).
