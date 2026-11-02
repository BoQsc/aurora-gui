# Long reply rendering — 0.66.29

The long-code stress fixture reproduced a 1.17–1.36 second cached repaint for a
single 12,000-character code line. Markdown soft-wrapping reused the original
shaped line for each visual segment, and Canvas replayed every glyph each time.
Clipping happened after glyph lookup/rasterization. Ordinary long paragraphs
also replayed offscreen text.

Canvas now retains a small visibility index with each shaped layout. Groups of
64 glyphs have bounds derived from actual raster ink, including fallback faces,
combining marks and italic bearings. Paint rejects invisible groups before glyph
lookup. Font system, display scale, render mode and variation changes invalidate
the index. Its lifetime is the layout's lifetime; there is no global history cache.
Color glyphs respect software-canvas translation and clipping, matching draw-list
behavior. Markdown soft wrapping also advances through clusters once instead of
rescanning the beginning of a long line for every segment.

Settled assistant bubbles retain selection/link/copy geometry between paints.
Content, width, vertical position and path resolver changes invalidate it. Text
selection and search highlighting skip offscreen runs while full selection and
copy data remain available.

## Evidence

Measurements below are local debug fixtures, not provider latency or universal
frame-rate guarantees. Reproduce with:

```text
python aurora-opencode-pro/tests/run_architecture_checks.py markdown_viewport_contracts presentation_contracts chat_performance_contracts chat_consistency_smoke history_preservation_contracts headless_pro_smoke image_latency_contracts export_reveal_ui_smoke
```

| Case | Measurement |
| --- | --- |
| 12,000-character code line, original paint | 1,169,006–1,355,393 µs median across three view positions |
| Same line, indexed paint | 8,298–8,612 µs median in the recorded comparison run |
| 600 rich paragraphs, indexed paint | 1,502–2,030 µs median |
| Real chat, 600 paragraphs plus long code; typing, forced rebuild and paint | 11,248 µs median, 17,556 µs p95 |
| Real chat, expanded 10,000-row diff; same interaction | 7,884 µs median, 9,676 µs p95 |

Baseline: `build/architecture-checks-d97ub3wx/markdown_viewport_contracts.log`.
Indexed pixel/geometry checks and timings:
`build/architecture-checks-ge0bu8i8/markdown_viewport_contracts.log`.
Real-widget allocation/interaction measurements:
`build/architecture-checks-05fw57iv/chat_performance_contracts.log`.

The renderer fixture compares indexed output against unculled output: exact
software pixels, GPU vertices/indices and color-image placement at 96, 120, 144
and 192 DPI, with translated clips and mixed-script text. Timings exclude initial
shaping; the same long line still takes about 131 ms to compose cold in this debug
run. Twenty forced long-reply rebuilds allocate about 20.7 MB, versus 27.2 MB before
target retention. Further allocation and cold-layout work remains necessary.

This closes a reproduced repaint stall, not the full execution/presentation
migration. The authoritative remaining scope is
`message-response-implementation-status.md`.

The full desktop smoke suite also runs again after fixture repairs: simulated
streams initialize their turn and flush deferred projections; background
completion supplies an actual answer; Export is checked through its current
Checkpoint reveal; task completion supplies its final response before asserting
that no handoff is needed. The simulation helper resolves the loaded conversation
before older background turns. Full smoke, image normalization/attachment and
Export reveal checks passed in `build/architecture-checks-_061hlqw/`.

## Subsequent selection correction (source, not yet deployed)

Visual slices of a wrapped code line now share one logical copy range. Select
All previously repeated the entire line for each slice. Pointer hit testing,
selection clipping and search highlights now use the visible panel bounds while
retaining the original layout coordinates. Code Copy preserves leading blank
lines, and selection preserves internal blank lines and repeated logical lines.

`wrapped_code_selection_contracts` checks exact copy text for long ASCII,
combining marks, mixed scripts and emoji, plus a real drag across two visual
wraps. It passed in `build/architecture-checks-ugxiwf2m/`, source fingerprint
`8c877dbf33094e5ae274ccfa49b4c5530c254d108c6af5dadab0a1c2f81a2eac`.
The native headless smoke and existing viewport pixel/geometry checks passed
before the final test expansion in `build/architecture-checks-w8izecto/`.

## Lazy tool groups (source, not yet deployed)

Collapsed groups retain result names, failure counts, diff totals and durations
without constructing detail widgets. Expanded groups use a nested viewport
presenter, which accounts for the group's offset within the scroll content.
Offscreen details are released; selection and search targets remain pinned.

The 180-result fixture includes roughly 6 MiB of saved textual output. It
constructs zero details while collapsed and fewer than 100 while expanded or
scrolling, releases them on collapse, and reveals an exact search target.
One recorded collapsed rebuild plus paint took 5,174 microseconds and allocated
471,968 bytes. This is a debug fixture measurement, not a general latency bound.
Proof: `build/architecture-checks-11tdcmp9/`, fingerprint
`8af0ac0d0a00549996ec39f4a20e8e43e45ceb1c29d023ac69fdcf5ae12498b8`.

The full native smoke, presentation, tool feedback, history preservation and
follow-up fixtures passed in `build/architecture-checks-60s4z5x1/`. Image,
execution and interaction-performance checks passed on the final fingerprint
in `build/architecture-checks-lfnvt4wz/`; its long-reply input/rebuild/paint p95
was 13,176 microseconds and its 10,000-row diff p95 was 13,292 microseconds.
The 16-round HTTP conversation fixture passed in
`build/architecture-checks-atnmezji/`.
