# Refined D shared default — 2026-10-23

The owner requested **“Make D default”**. The latest refined D, including the
instruction and curve fixes in the preceding conformance audit, is now selected
without an environment override. This is an approved default change, **not a
claim that every font or glyph is correct**.

OpenCode Pro was rebuilt through its detached application helper, relaunched,
and published to its configured update channel. Required public download
verification passed. Its binary provenance matches source commit
`62b7762cad246390f01f96d9fcf9e8ec04ac6a40`; see `delivery.json`. Publication
does not change the incomplete native quality result.

`aurora.text.renderpolicy` now owns selection for TrueType geometry/sampling,
atlas alpha correction and Vulkan blending. All Aurora packages use the same
canonical core. `AURORA_TEXT_EXPERIMENT=compatible-c` selects the former C;
`native-next` preserves the original D review; `native-refined` explicitly
selects the new default. Empty and unset overrides agree. Hinting `0`/`1`
diagnostics retain their earlier behavior.

## Why OpenCode Pro remained damaged after rebuilding

The app's rebuild succeeded. Before this change, its recorded source fingerprint
and binary SHA-256 matched the current checkout exactly (`before.json`). Its
manifest includes the canonical Aurora source directly. The problem was not
fixed by rebuilding because the default still selected C; the refined repairs
were opt-in. The chat uses Segoe UI and Consolas on this machine.

The earlier natural-hinting default change also left the Pro smoke test assuming
that an unset hinting variable meant “off.” It actually meant natural. That test
now reads the shared policy and retains its historical missing-stroke guard.
The guard alone never established correct rendering of other letters or digits.

An isolated capture uses the actual shared chat markdown painter, including
inline code pills and code blocks. In a 17px dark-theme native reference probe,
Consolas `2` ink error falls from 39.872 (C) to 1.385 (refined D), and `e` from
63.293 to 0.306. These are finite measured improvements, not exact parity.
See `chat-font-diagnosis.json` and the [pixel review](index.html).

## Verification

- `promotion.py` compares the new default against the preserved pre-promotion
  refined D source across nine fonts, visible ASCII at every size 1–96, and
  every 17px phase in both themes. It also checks explicit C, original D and
  both diagnostic hinting modes. Exact results are in `promotion.json`.
- `validate.py` records framework font, coverage, DPI, hinting and unit checks,
  isolated host/Notepad release builds, and repository standards checks.
- `capture_apps.py` compares 15 whole-app captures at 96/120/144 DPI and tests
  software/Vulkan agreement in two real live states.
- `ui_validate.py` records full host and live Pad++ workflows with C and the
  new default. `pro_validate.py` exercises the actual Pro widgets and markdown;
  all failures and C controls are retained in `pro-validation.json`.
- The Pro chat-consistency fixture reports “Latest activity is missing” with
  both the new default and explicit C. This is an existing fixture/UI failure,
  not a rendering acceptance pass.
- The broader Pro smoke passes its glyph/inline-code/markdown assertions, then
  fails “Continuing on a restored branch did not append to it” with both
  profiles. Its full run is not reported as passing.

The strict native comparison gates in the frozen
[conformance report](../native-text-conformance/README.md) still fail. They
cover 111,192 all-glyph cases, 81,216 ASCII size cases and 13,536 phase/theme
cases; individual regressions remain visible. Missing dropout scan conversion,
composite child hinting and legacy gasp behavior remain open. Windows grayscale
references do not certify every Windows rendering mode, script or other platform.

Historical evidence packages were preserved. Only owned vendor manifest entries
were updated; the three inherited platform/window mismatches remain documented
in `vendor-manifest-audit.json`.

The CPU-only chat fixture also measures first composition/paint and 120 cached
software paints in three separate processes per profile. Refined D's cached
paint averages range from 1.699–1.779ms per run, with 517 glyph rasterizations
cached in each process. These finite samples exclude provider/network time and
do not establish an absolute latency minimum (`render-performance.json`).
