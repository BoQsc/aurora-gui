# Aurora Pad++

A separate, app-owned Notepad++-style workbench built on the generic
[aurora-host](../aurora-host/) experiment. The host supplies the window,
retained widgets, editor, dialogs, rendering, and JSON control channel. This
folder supplies every document rule: tabs, dirty state, file paths, language
metadata, search policy, status text, and benchmark behavior.

The point is not feature parity with Notepad++. It is a stress test of the host
as an application substrate: can a client assemble a real editor without adding
editor policy to the host?

## Features

- Eight app-owned document slots with active-tab and dirty markers.
- A Windows-style chrome stack: menu bar, icon toolbar, document tab strip,
  docked find/replace bar, editor, and segmented status bar.
- Six dropdown menus with separators, shortcut labels, and a cascading Zoom
  submenu. Every command is dispatched back to the application.
- An editor right-click menu for find, replace, select-all, wrap, and case.
- New, Open, Save, Save As, and Close Tab workflow.
- Generic host file dialogs for open and save paths; no app-specific dialog code
  in the host.
- Multi-line editor with live `change` and `cursor` events.
- Find Next with wrap-around; literal matching with optional case sensitivity.
- Replace current match and Replace All through the host selection API.
- Language metadata for Plain Text, Python, C++, D, JSON, and Markdown, with
  automatic mode selection from common file suffixes.
- Character, word, line, cursor, and document-status reporting.
- UTF-8 file reading and writing through the application model.
- A repeatable large-document benchmark that measures editor load, text round
  trip, tab switch, and a search that selects near the end of the document.
- A self-test that drives the real host process and verifies tab switching,
  editing events, find/replace, save/open round trips, menu and context popups,
  exact reference pixels, and performance.

Not implemented: syntax coloring, split views, session restore, column
selection, tab reordering or drag-out, native tooltips, docking, and a full
Notepad++ shortcut map. Shortcut text is a menu label only; the application does
not yet bind every accelerator. The host supplies a generic tab strip, but no
document model: tab labels, active state, dirty state, and activation policy
remain application-owned.

## Build and run

From `experiments/aurora-host`, build the host. Use release mode for performance
measurements:

```text
dub build -b release
```

Then run the application:

```text
cd ../aurora-host-notepadpp
python -B padpp.py
python -B padpp.py --file path/to/document.py
```

`--host` selects another host executable. `AURORA_HOST_EXE` is also honored.

## What the host owns

The scene contains only generic nodes: menus, buttons, a tab strip, rows,
columns, labels, two text fields, and one multi-line text area. The application
owns:

- the eight-slot tab list and which document is active;
- file paths, dirty flags, language names, and status strings;
- when text is pushed into or captured from the editor;
- find/replace semantics, including literal and case policy;
- the benchmark workload and its pass gate.

The host owns no `notepad`, `document`, or `syntax` capability and keeps no
document policy. It exposes generic menu, tab, chrome-style, context-menu, and
editor capabilities. Editor state travels through generic commands and events:

```json
{"command":"getEditorState","node":"editor"}
{"command":"setSelection","node":"editor","start":120,"end":132}
{"command":"setText","node":"editor","text":"...","notify":false}
```

The host emits `editor` events with `kind` `change` or `cursor`, plus `cursor`,
`anchor`, `length`, `line`, and `column`. The application reacts by recapturing
text and updating its own labels; the host never mutates client labels on its
own.

## Verification

```text
python -B padpp.py --self-test
```

The default gate uses 2,000 generated lines (about 214 KB). A run must complete
the full menu, tab, edit, find, replace, save, and open workflow, then produce
PNG screenshots and metrics JSON:

- `build/padpp.ppm` and `build/padpp.png` - live host screenshot;
- `build/padpp-menu.ppm` and `build/padpp-menu.png` - open File menu;
- `build/padpp-context.ppm` and `build/padpp-context.png` - editor context menu;
- `build/padpp-metrics.json` - measured phases and host working set.

The generated artifacts are not committed. The reviewed main screenshot is
stored as [samples/padpp-reference.png](samples/padpp-reference.png) and used as
an exact-pixel regression reference by [verify.json](verify.json). That recipe
runs the host unit/demo tests, this application's interaction test, and the
reference render.

Measured on Windows with a release host build:

| Phase | 2,000 lines / 214 KB |
| --- | ---: |
| Initial editor load | 1.5-1.8 s |
| `getText` round trip | 0.03 s |
| Switch away and back | 1.6-1.7 s |
| Find at end and select match | 11-12 s |
| Host working set | 380-430 MB |

Normal small-document editing is responsive. Large-document behavior is not
Notepad++-class yet: the first full text layout dominates load and selecting near
the end, and the retained text editor grows memory quickly. A 5,000-line run
reached about 709 MB and did not finish its end-of-file selection promptly; a
100,000-line run was stopped after the host passed 1.8 GB. This is the main host
scaling limitation exposed by the experiment, not an application bug hidden by
the benchmark.

The self-test checks chrome heights, popup panels, menu/context contents, tab
activation, editor text colors, screenshot brightness, and absence of a blank or
monochrome render. Its performance gate stops at 20 s for load and 30 s for the
switch and find phases. Those are correctness/termination limits, not a claim of
good performance. A larger `--bench-lines` value reproduces the scaling limit
deliberately; expect long runs and high memory use.

## Files

```text
padpp.py             application model, host client, workflow, and self-test
padpp.scene.json     generic host scene used by the workbench
build/               ignored screenshots and metrics
```
