> **Correction, 22 October 2026:** the owner's inspection found damaged letters
> and numerals in both the images and running applications. The measurements
> below cover the stated lines/digits; they did not establish general glyph
> fidelity. The expanded [character audit](../native-text-audit/README.md)
> reproduces a misplaced Consolas `e` crossbar, applies further experimental
> fixes, and exposes every remaining character regression. C stays the default.

# Refined D: Courier regressions and Consolas 17px numerals

20 October 2026. **C remains the approved default**, as requested. The existing
`AURORA_TEXT_EXPERIMENT=native-refined` profile now contains the stem-distance
fix described below. Reviewed D (`native-next`) and the previous refinement's
evidence are preserved. [Open the visual report](index.html).

## What was fixed

The natural hinter applied CVT cut-in only when MIRP requested rounding. Native
horizontal MIRP also rejects a CVT distance that differs too far from the
outline when rounding is off. Keeping that mismatched CVT distance distorted
Consolas numeral stems, especially **1, 2, 5 and 8 at 17px**.

The fix applies only to refined D's natural horizontal glyph instructions. It
uses the existing cut-in value, with its one-sixteenth horizontal scaling.
Vertical distances, size-program behavior, native INSTCTRL opt-outs, contrast,
gamma, metrics, layout, font selection and C/D rendering remain unchanged.
There is no font-name or size-specific adjustment and no native rendering API
in production.

[Sixteen independently rendered generated-font cases](native-probe.json)
confirm the change: all eight horizontal cases improve against DirectWrite;
eight vertical controls are unchanged. Six horizontal cases match exactly;
the two half-pixel cases retain a 0.5 ink-error residual from scan conversion.
Signed instruction tests cover negative distances, cut-in boundary equality,
profile isolation, vertical vectors, size programs and native opt-outs.
[Microsoft's compatibility description](https://learn.microsoft.com/en-us/typography/cleartype/truetypecleartype)
provides the horizontal cut-in context; the native probes establish the
unrounded behavior used here.

## Measurements

The same-origin monochrome corpus covers nine fonts, eight sizes and two themes:

| Comparison | Improved | Equal | Regressed |
| --- | ---: | ---: | ---: |
| New refined D versus previous refined D | 40 | 104 | 0 |
| New refined D versus reviewed D | 144 | 0 | 0 |
| New refined D versus approved C | 144 | 0 | 0 |

Mean native ink error is **10.011293**, down from the previous refinement's
10.427125, reviewed D's 11.688842 and C's 12.861947. All three reported Courier
New monochrome regressions against D are removed.

The 288-case opaque RGB corpus improves 161 versus the previous refinement,
leaves 127 equal and regresses none. Against both C and reviewed D, 276 improve
and 12 white-on-white controls tie. **All four reported RGB regressions against
D are removed.** RGB mean error is 6.938424, down from 7.360877 in the previous
refinement. [Full RGB results](colors.json).

The focused 17px corpus tests each numeral separately at all eight horizontal
phases and in both themes (320 comparisons across two fonts):

| Font | Improved | Equal | Regressed | Mean native error, before → after |
| --- | ---: | ---: | ---: | ---: |
| Consolas | 64 | 96 | 0 | 23.789528 → 2.834327 |
| Courier New | 0 | 160 | 0 | 31.734317 → 31.734317 |

Consolas' numeral error falls **88.1%**. The complete 17px text line improves
from 14.357 to 4.896 in light mode, and 12.492 to 4.422 in dark mode.
Courier's measured whole-line regressions are fixed through other affected
glyphs; **its isolated numerals are not improved by this patch**. Their shape
gap remains visible in the report. [Every digit/phase result](digits.json).

These are 8-bit mean absolute errors over the union of ink pixels, not
readability scores. The corpora overlap and their counts must not be added.
Same glyph IDs and origins isolate rasterization from shaping. Exact native
grayscale parity, Courier outline fidelity and ClearType RGB subpixel output
remain unfinished.

## Checks and preserved evidence

- [Framework/build checks](validation.json): C and refined D each pass the
  1,872-case font/size/phase test, 7,200 Windows glyph/size cases plus reverse
  replay and default equivalence, coverage/cache checks, 96/120/144/192 DPI and
  window geometry, alpha/profile tests and instruction unit tests. Standards
  audit and all 14 Python tests pass. Both isolated release builds pass.
- [Full host and live Pad++ workflows](ui-validation.json) pass for C and refined
  D with the approved 0.039 ink guard. C's live pixels match the preserved C
  binary at the same 120 DPI scale. The two existing user Pad++ processes were
  not stopped or replaced. The older Notepad's preexisting drag/restore full
  smoke failure remains documented in the earlier evidence, outside this fix.
- [Captured application and GPU checks](captures.json): all ten C app images
  at 96/144 DPI remain unchanged. The actual 120-DPI GPU probe captures two
  changing live frames per profile, both matching software exactly.
- All 144 C and reviewed D corpus images retain identical RGB bytes. The
  entire earlier refinement package and the protected D review images are
  checksum-verified by [the source audit](source-audit.json).
- [Compatibility](compatibility.json): Segoe/Courier, both themes, hinting `0`
  and `1` retain the same pixels with refinement requested.
- [Vendor digest audit](vendor-manifest-audit.json): only hinter, TrueType
  adapter and font documentation entries are updated. The inherited three
  untouched vendor mismatches and historical Vulkan debt remain recorded.

Finer quadratic flattening reduced aggregate error but regressed Arial/Tahoma
and other cases. Suppressing post-IUP deltas regressed ten cases. Curve-flag
propagation variants produced no change in this corpus. Those hypotheses are
preserved in `*-experiments.json` and **are not included** in the fix.

Sources before this change are preserved in `baseline-refined/`; the audit
records their hashes and Git revision. The old reports are not rewritten.
Raw corpora and isolated binaries live under ignored
`build-validation/native-text-glyphs`.

From the repository root, with Windows, DMD/DUB, Python, Pillow and fontTools:

```text
python artifacts/native-text-glyphs/production.py
python artifacts/native-text-glyphs/colors.py
python artifacts/native-text-glyphs/digits.py
python artifacts/native-text-glyphs/native_probe.py
python artifacts/native-text-glyphs/validate.py
python artifacts/native-text-glyphs/compatibility.py
python artifacts/native-text-glyphs/capture.py
python artifacts/native-text-glyphs/ui_validate.py
python artifacts/native-text-glyphs/update_vendor_manifest.py
python artifacts/native-text-glyphs/package.py
```

Run the two UI scripts sequentially. `experiments.py` and `hypotheses.py`
optionally reproduce research variants from the preserved sources. Default
promotion is not proposed by this package.
