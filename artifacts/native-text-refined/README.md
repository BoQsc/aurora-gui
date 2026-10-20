# Native text refinement: C stays the default

20 October 2026. The owner's decision was **“Keep C; continue improving D.”**
This work adds a separate experimental profile; it does not promote D or alter
the approved standard. [Open the visual report](index.html), or compare
[live Pad++ at 96 DPI](padpp-live-96/review.html).

## Result and remaining regressions

The 144-case, nine-font corpus uses Windows DirectWrite grayscale references
with the same font files, glyph IDs and physical origins as Aurora:

| Profile | Mean absolute native error on ink pixels |
| --- | ---: |
| Approved C | 12.861947 |
| Reviewed D | 11.688842 |
| Refined D | 10.427125 |

Refined D improves **144/144 against C**, reducing the mean by **18.9%**.
Against D it improves 141 but regresses three Courier New dark cases: 12px
(+0.0581), 17px (+0.0282), and 18px (+0.2513). These are retained in the report.

A supplemental 288-case corpus tests Segoe UI, Consolas, Courier New and Inter
at 12/17/26px, with eight foreground colors on white, dark and selection
backgrounds. RGB ink error falls from 8.860259 to 7.360877: **276 improve, 12
equal, none regress against C**. The 12 ties are white-on-white controls.
Against D, 272 improve, 12 tie and four regress slightly; those are Courier
New near-white at 12/17px on dark/selection backgrounds. [All color measurements](colors.json).
The color and monochrome corpus overlap, so their counts must not be added.

These diagnostics measure pixel error, not subjective legibility. Exact native
parity remains unfinished. DirectWrite's neutral parameters still retain its
internal thin-family boost. [Accounting for that boost](thin-isolation.json)
leaves a large Courier residual, suggesting further outline/scan-conversion
work; this diagnostic does not identify a specific faulty instruction or
dropout rule. Changing gamma alone cannot close that residual.
Dropout behavior, instruction fidelity, curve precision, native shaping and
ClearType RGB subpixel output remain separate gaps. The target here is grayscale,
not every Windows program's rendering mode.

## Implementation

Set `AURORA_TEXT_EXPERIMENT=native-refined` **before startup** to opt in. Leave it
unset for approved C. `native-next` retains the reviewed D behavior and pixels.
The color correction and quantized shader require natural hinting and
foreground coverage; hinting `0` or `1` disables the experiment. With legacy
coverage, D's scan-conversion changes still apply under natural hinting.
Runtime profile changes on a live atlas/font cache are
unsupported.

The new core `aurora.text.alphacorrection` adapts
[Microsoft Terminal's grayscale alpha model](https://github.com/microsoft/terminal/blob/1283c0f5b99a2961673249fa77c6b986efb5086c/src/renderer/atlas/dwrite.hlsl)
and [gamma coefficients/thin-family behavior](https://github.com/microsoft/terminal/blob/main/src/renderer/atlas/dwrite_helpers.cpp).
The MIT notice is included under `vendor/aurora-d-0.4.5/licenses`. No DirectWrite
or other native rasterizer enters production rendering.

Correction uses straight foreground intensity and brightness. The existing
contrast 0.5 maps to native grayscale contrast 1.0. Contrast zero still returns
raw masks. Experimental gamma is 1.8 by default; `AURORA_TEXT_GAMMA` rounds to
0.1 steps and clamps to 1.0–2.2, with invalid values falling back to 1.8. This
matches this machine's measured native settings, not an automatic monitor query.
Other monitor gamma/contrast combinations have mathematical tests, not a
native visual-parity claim.

The color key has at most 136 classes (17 intensity × 8 contrast), excluding
opacity. Only requested masks are allocated; one raw outline is rasterized per
glyph/size/phase. Normal/thin transfer banks use 68 KiB per experimental atlas.
C keeps its existing 16 classes and 4 KiB bank. The 17³ RGB cache sweep reaches
41 feasible classes, tests atlas growth from 32×32, and confirms opacity creates
no extra masks. Unit tests cover all 136 classes even when unreachable by that
RGB sweep. Known thin families come from bounded OpenType name-table parsing;
a renamed Courier file verifies that filenames do not choose the policy.

Software rounds `tint alpha × A8 coverage` to A8 before blending. The refined
Vulkan glyph shader now does the same. Two live frames with changing markers,
colored/translucent text and selection backgrounds match software **exactly**
at actual 96 DPI; no stale frames were accepted. C/D shader arrays are unchanged,
and the RGBA image shader's words are unchanged. This is a two-frame probe on
this GPU, not a cross-device or all-DPI guarantee.

## Validation and provenance

- [Framework checks and isolated release builds](validation.json): 1,872
  font/size/phase checks per C/refined profile, cache/growth/profile/metadata,
  immediate/retained Canvas agreement, unit tests, 96/120/144/192 DPI and window
  geometry, 7,200 Windows glyph/size checks per profile plus default equivalence
  and reverse replay with no blanks; standards audit and 14 Python tests pass.
- [Full host and live Pad++ workflows](ui-validation.json) pass for C and the
  refinement, retaining the approved **0.039** ink guard. Both isolated release
  builds pass. The unrelated older Notepad drag/restore smoke failure from
  [D's record](../native-text-next/older-notepad-validation.json) remains open;
  this report does not claim that full suite passes.
- [Application captures](captures.json): older Notepad and host light/dark,
  Pad++ light, all at real 96/144 DPI framebuffers. All ten C images are byte
  identical in RGB to the reviewed C images. C and reviewed D's full 144-image
  font corpus is also unchanged.
- The desktop changed from 125% to 100% since D's live review. Current C and
  refined Pad++ images are both 1180×760 at 96 DPI. The preserved D-era host
  binary run in C mode at today's scale gives **identical** C live pixels.
  Earlier 1475×950 images were not resized or compared as if the scales matched.
- [Compatibility](compatibility.json): both themes, Segoe/Courier, hinting `0`
  and `1` all stay pixel-identical with the refinement requested.
- [Source/font hashes and measurements](measurements.json),
  [final source and protected-review audit](source-audit.json), and
  [vendor manifest audit](vendor-manifest-audit.json). The three untouched vendor
  checksum mismatches remain, and the preexisting mismatch in the now-touched
  Vulkan file is retained explicitly as historical debt.

No installed application executable is replaced. Existing Pad++ windows are
left running. Builds and full raw corpora are isolated under ignored
`build-validation/native-text-refined`; selected original pixels and review
pages are preserved here. The reviewed D package is retained separately.

From the repository root, on Windows with DMD, DUB, Python and Pillow:

```text
python artifacts/native-text-refined/production.py
python artifacts/native-text-refined/colors.py
python artifacts/native-text-refined/validate.py
python artifacts/native-text-refined/compatibility.py
python artifacts/native-text-refined/thin_isolation.py
python artifacts/native-text-refined/capture.py
python artifacts/native-text-refined/ui_validate.py
python artifacts/native-text-refined/update_vendor_manifest.py
python artifacts/native-text-refined/package.py
```

Run the two UI capture/workflow scripts sequentially. Their temporary windows
close after the checks. No default promotion is proposed by this package.
