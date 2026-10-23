# Pure-D text conformance — incomplete

C remains Aurora’s shared default. The owner selected continued work on the
portable pure-D renderer. The changes here remain opt-in through
`AURORA_TEXT_EXPERIMENT=native-refined`; native Windows APIs are reference
instrumentation only. No application-specific rendering policy was added.

Open [the glyph viewer](index.html). It shows original 17px pixels for every
visible ASCII character in nine fonts, all eight horizontal phases, and both
themes. The 1×/4× canvases compensate for display/browser DPI and use nearest
sampling. “Previous refinement” is the frozen source at the beginning of this
work, including the earlier damaged-glyph audit. It is not approved C.

**Exact native parity still fails.** The final scopes are:

| Scope | Comparisons | Exact | Failed |
| --- | ---: | ---: | ---: |
| Every glyph in nine fonts, 13/17/26px, phase 0, light | 111,192 | 2,798 | 108,394 |
| Visible ASCII in nine fonts, every integer size 1–96px, phase 0, light | 81,216 | 2,001 | 79,215 |
| Visible ASCII at 17px, nine fonts, eight phases, both themes | 13,536 | 394 | 13,142 |

The ASCII scopes cover U+0021–U+007E: 94 visible characters. Whitespace advance
widths and shaping are separate. The scopes overlap. They cover regular face files for Segoe UI, Consolas, Arial,
Calibri, Tahoma, Verdana, Courier New, Times New Roman and bundled Inter Variable
at its default axes. This is finite coverage, not a claim about all fonts,
weights, scripts, sizes or platforms. Glyph-ID enumeration bypasses shaping to
isolate rasterization. It includes blank and unencoded glyphs; an exact blank
case does not establish readable text.

Every unequal RGB pixel fails the strict gate. Cell-edge ink also fails pending
a larger capture. The gate never substitutes a mean, a tolerance, a nonblank
check or application-test success for native parity. The native reference uses
the same glyph IDs, physical sizes, origins and colors; its settings and source
hashes are in [status.json](status.json).

The changes repair several distinct defects:

- SPVTL/SFVTL use the moved line. SDPVTL retains a separate original dual vector.
  Diagonal projections use the natural grid’s extra rounding/cut-in resolution.
- Axis MDRP subtracts original endpoints before scaling/rounding their distance.
  Early endpoint rounding had crossed a subpixel rounding boundary in Consolas
  `2` at 17px. Its phase-0 light ink error falls from 9.179 to 1.744; it still
  fails exact parity.
- IUP retains original ratios and Windows’ signed rounding, while preserving
  the rounded interval guards. A prototype that removed those guards was
  rejected. Increasing, decreasing, exact-division and outside cases are covered
  by native generated-font probes in symmetric and asymmetric modes.
- Curve-changing FLIP instructions survive the hinted result and reach scan
  conversion. Range instructions pop their highest point first.
- Quadratic roots use the monotone segment direction. Floating-point residue
  at a horizontal extremum had selected the wrong root and cut away curves.
- At 1px the refinement skips glyph instructions and retains the initial scaled
  grid. All 846 real-font visible ASCII glyphs tested at that size remain pixel-identical;
  [their image hashes](one-pixel-controls.json) are retained.

These are instruction/geometry fixes, without weight or gamma tuning. They do
not make the whole pipeline native. The all-glyph 13/17/26px matrix records
24,411 lower-error cases, 84,173 equal-error cases and **2,608 higher-error
cases**. The 1–96px ASCII sweep records 40,561 lower, 37,851 equal and **2,804
higher**. These error counts are diagnostics; every exact-parity failure still
fails. [comparison.json](comparison.json) and [regressions.json](regressions.json)
retain the complete results. Each `full-final/*.json` / `full-final-sizes/*.json`
contains every native failure, its glyph ID, mapped codepoints, differing-pixel
count, largest channel error and ink error. No default promotion is proposed.

The most concrete remaining defect is dropout scan conversion. Native Times
`>` probes largely agree on hinted point coordinates, while native SCANTYPE 2
removes the extra stroke coverage and reproduces Aurora’s gaps. Aurora records
SCANCTRL/SCANTYPE but does not yet apply them in its scan converter. The initial
dropout prototypes failed independent controlled shapes and were not adopted.
Composite child hint programs also remain unexecuted, version-0 gasp behavior
still differs, and further outline/coverage differences remain. Other weights,
fallback, script shaping and other-platform output require separate coverage.

[validation.json](validation.json) records framework font/coverage/DPI checks,
instruction/curve units, Windows hinting regression, isolated host/Notepad release
builds, standards and Python checks. [captures.json](captures.json) records 15
matched Notepad/host/Pad++ app captures at 96/120/144 DPI: approved C is unchanged.
Both live Vulkan/software states match exactly at 120 DPI. The full host and live
Pad++ workflows are in [ui-validation.json](ui-validation.json). These are
functional/backend checks, not visual-quality approval. Executables were built
under `build-validation/native-text-conformance`; the user’s host executable was
not replaced.

[compatibility.json](compatibility.json) confirms 288 complete sheets are
pixel-identical for C, reviewed D, unhinted mode and diagnostic hinting across
nine fonts and eight sizes.

Browser automation was unavailable because local browser use is disabled in
Work settings. The viewer JavaScript and all 432 source images passed integrity
checks; the PNGs were inspected directly. Interactive controls were not exercised
in a browser. See [viewer-validation.json](viewer-validation.json).

The native semantic probes retain mismatches as well as improvements:

- `native_vector_probe.py`, `native_diagonal_probe.py`, `native_curve_probe.py`;
- `native_original_distance_probe.py` (120 exact native cases);
- `native_iup_initial_probe.py` (288 cases, no increased error, unresolved tiny
  cases retained), and `native_iup_asymmetric_probe.py` (144 exact native cases).

Together these probe vector, cut-in, curve-flag/root, original-distance and IUP
behavior. Their regression assertions passing does not imply that every probe
matches every pixel. The JSON files expose residuals, including degenerate
outlines and tiny glyphs.

Reproduction requires Windows, DMD/DUB, Python, Pillow and fontTools. From the
repository root, with the source hashes listed in `status.json`:

```text
python artifacts/native-text-conformance/conformance.py --label final --source-dir artifacts/native-text-conformance/after-source --sizes 13 17 26
python artifacts/native-text-conformance/conformance.py --label final-sizes --source-dir artifacts/native-text-conformance/after-source --charset ascii --min-size 1 --max-size 96
python artifacts/native-text-conformance/focus.py
python artifacts/native-text-conformance/compatibility.py
python artifacts/native-text-conformance/validate.py
python artifacts/native-text-conformance/capture_apps.py
python artifacts/native-text-conformance/ui_validate.py
python artifacts/native-text-conformance/package.py
```

The strict conformance commands deliberately exit 1 while failures remain. Use a
new label for new source. `before-source` / `after-source` retain the text modules;
final fixtures record their compiled module and executable hashes. Every helper
build snapshots all text modules so a prior prototype cannot shadow current
source. Windows font files remain in ignored local test output, not this report.

`final`, `final-sizes`, `focus`, `status`, `comparison` and `regressions` are the
final evidence. Other `before`, `after`, `current`, hypothesis and probe files
are intermediate research, including rejected approaches. Earlier approved C,
reviewed D and `native-text-audit` evidence remain historical and unchanged.

Primary instruction references: [OpenType instructions](https://learn.microsoft.com/en-us/typography/opentype/spec/tt_instructions)
and [Microsoft ClearType compatibility](https://learn.microsoft.com/en-us/typography/cleartype/truetypecleartype).
