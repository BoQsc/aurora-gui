# Aurora native text: candidate D, 20 October 2026

**The owner chose “Keep C; continue improving D.” C remains the shared default.**
The reviewed D implementation remains opt-in; its images and source snapshot
are preserved. [Decision record](decision.json).
Set `AURORA_TEXT_EXPERIMENT=native-next` before application startup to inspect D.
Leave that variable unset for C. `AURORA_HINTING=0` continues to select unhinted B;
the new experiment is inactive in that mode. No host-specific override is used.

[Open the visual report](index.html), starting with the
[live Pad++ C/D comparison at 125% DPI](padpp-live-120/review.html).
The [proposal](proposal.json) states exactly what promotion would change.

## Implemented in the shared renderer

- Closing outline edges include a sample exactly on the boundary. Generated,
  unhinted rectangle fonts showed Windows retaining that sample where C's
  half-open scanline discarded it. Samples across disjoint or overlapping spans
  form a union, preventing duplicate coverage at shared boundaries. Zero-width
  contours retain zero ink. This uses the same 8×1/4×4 font-selected grids as C.
- Exact half-alpha quantization ties round down in D: half coverage is 127,
  matching the observed native result, while C retains its existing 128.
- Recognized TypeMan VacuFormRound functions read storage 8 as zero after IUP
  on both axes, following Microsoft's documented compatibility rule. The exact
  function signature is required; the function number alone is insufficient.
  INSTCTRL selector 3 preserves a font's native instruction behavior. Reads do
  not mutate storage. The rule is limited to the opt-in glyph interpreter.

The default C path is unchanged. Production verification compares every C
font/size/theme image with its pre-change capture and finds identical pixels.
The old/new application captures also preserve approved C pixels at 96/144 DPI.
The existing coverage transfer, bounded atlas color variants, layout, metrics,
maximum contrast 0.5 and host ink guard 0.039 are unchanged.

The native corpus has **134 improvements, 10 equal cases and no regressions**
against C. Mean absolute grayscale error over the union of ink pixels falls
from **12.862 to 11.689**, another **9.1%**. It covers nine fonts, eight sizes,
and light/dark themes. Glyph IDs and origins match the DirectWrite reference;
this isolates rasterization and does not establish shaping parity.
[Measurements and source hashes](measurements.json).

## Validation

[Validation outputs](validation.json) cover C and D: coverage/cache behavior,
1,872 font regressions per profile, DPI and full-window DPI checks, 7,200
Windows-font glyph/size cases per profile plus reverse replay, instruction and
scan-conversion unit tests, standards/Python tests, full host interactions and
the complete Pad++ workflow. Read each recorded exit status for the final result.

Software app captures cover older Notepad and the host in light/dark themes,
plus the actual Pad++ scene, at 96/144 DPI. Actual framebuffer sizes are asserted.
Two validated live Vulkan states were also captured per profile at 120 DPI.
C matches software exactly; D differs at 232 pixels over both frames with a
maximum channel error of 1. One stale/obscured C frame was rejected and excluded
before the two accepted states. No GPU/native pixel-exact claim is made.
[Capture outputs](captures.json).

The older Notepad full smoke has an existing unrelated drag/restore failure;
its isolated rendering fixture is covered here. The full repository is not
reported green. The existing user-owned Pad++ process is left running.

## Other hypotheses tested and retained as evidence

These experiments are isolated under ignored `build-validation/native-text-next`.
They do not change C or enter D:

The immutable `baseline-C` sources keep these hypotheses reproducible after
the opt-in implementation changes. They are reference fixtures only, excluded
from application source paths. Their provenance records compiler snapshots,
newline normalization and the original vendor hashes.

| Experiment | Improved | Regressed | Main finding |
|---|---:|---:|---|
| Unrounded MIRP cut-in | 40 | 2 | Better average, but incomplete compatibility |
| Exploratory MSIRP cut-in | 6 | 0 | Initial half-pixel cutoff does not match small native probes |
| Legacy function signatures | 22 | 0 | Only the recognized VacuFormRound rule affects this corpus |
| Post-IUP movement suppression with cut-in | 78 | 4 | Broad suppression is insufficiently faithful |
| Rounded interpreter arithmetic | 101 | 26 | A blanket arithmetic change is unsafe |
| Unscaled original coordinates with rounding | 71 | 57 | Requires coordinated interpreter changes |
| Finer curves plus VacuFormRound | 132 | 10 | Exposes other errors, particularly in Tahoma |
| Scanline dropout retention plus VacuFormRound | 136 | 2 | Native dropout controls/directionality need further work |

Full results are in `*-experiments.json`. The instruction-level minimum-width
trial was discarded: generated fonts without glyph instructions reproduce the
thin-stroke behavior, locating it in scan conversion. D includes closing-edge
ties but does **not** add an arbitrary minimum stroke width or dropout heuristic.
Generated-font zero-width MIRP/MSIRP cases are diagnostic only: duplicate contour
endpoints can change the glyph's point count and make those cases ambiguous.

The published Microsoft Terminal alpha-correction model is also promising.
Applied to native neutral masks, it reproduces monitor-reference color transfer
with mean error about 0.25. Applied to C's masks it improves 136 cases but
regresses eight; it is not part of D. A runtime design still needs accurate
color-dependent correction with bounded cache growth, plus broader foreground,
opacity and monitor-gamma validation. The diagnostic adaptation includes
[Microsoft Terminal's MIT notice](MICROSOFT-TERMINAL-LICENSE.txt).

## Remaining gaps

Exact Windows grayscale and ClearType parity remain unachieved. Remaining work
includes dropout scan conversion, instruction/rounding fidelity, coordinated
curve precision, and color-dependent alpha correction. D does not advertise
ClearType RGB subpixel output or use a native rasterizer in production.

Primary references:

- [Microsoft instruction compatibility](https://learn.microsoft.com/en-us/typography/cleartype/truetypecleartype)
- [Microsoft Terminal grayscale alpha model](https://github.com/microsoft/terminal/blob/1283c0f5b99a2961673249fa77c6b986efb5086c/src/renderer/atlas/dwrite.hlsl)
- [Microsoft Terminal gamma coefficients and thin-family handling](https://github.com/microsoft/terminal/blob/main/src/renderer/atlas/dwrite_helpers.cpp)
- [FreeType interpreter for comparison](https://github.com/freetype/freetype/blob/master/src/truetype/ttinterp.c)

## Reproduce

From the repository root on Windows with DMD, Python and Pillow:

```text
python -B artifacts/native-text-next/production.py
python -B artifacts/native-text-next/capture.py
python -B artifacts/native-text-next/validate.py
python -B artifacts/native-text-next/package.py
```

Build the isolated host release at `build-validation/native-text-next/host-release`
before validation. Capture and live validation show their own temporary windows;
run them serially so those windows cannot obscure each other's screenshots.
Generated-font reference probes additionally require `fontTools`. Never rerun a
review into an approved folder with different image bytes; the review helper
rejects that operation.
