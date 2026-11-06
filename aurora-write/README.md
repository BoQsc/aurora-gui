# Aurora Write

A plain English writing surface with an inline concision optimizer that answers
on the keystroke, then refines with a language model once the writer pauses.

## What it does

- **Instant pass (no thinking).** Every keystroke resolves one span at the caret
  — the longest known wordy phrase containing it (`due to the fact that`), else
  the word itself, including regular inflections (`utilizes` → `uses`). A
  built-in table of wordiness fixes returns shorter rewrites with a one-sentence
  definition and a gloss per choice. This pass is pure, table-driven and never
  touches the network.
- **Caret card.** A floating panel appears **above the line being typed** (it
  flips below only when the top of the page leaves no room), anchored to the
  caret the editor actually paints. It shows the target, the one-sentence
  definition, up to eight numbered choices of six to eight concise words, and
  the highlighted choice's own gloss.
- **Model pass (only after a pause).** Once typing stops for 450 ms, the same
  span and its sentence go to any OpenAI-compatible `/chat/completions`
  endpoint on a worker thread. The reply replaces the instant drafts only while
  the same span is still under the caret. `Ctrl+T` sends
  `reasoning_effort: high` for the "high thinking" pass; with it off, requests
  carry no effort knob for hosted routes (or the provider's explicit "off"
  where that is known to be accepted), because results are meant to arrive
  without thinking first.

## Keys

| Key | Action |
| --- | --- |
| `Tab` / `Shift+Tab` | Cycle the shortlist |
| `Ctrl+Enter` | Apply the highlighted choice |
| `Ctrl+1` … `Ctrl+8` | Apply a specific choice |
| `Esc` | Hide the card |
| `Ctrl+T` | Toggle high thinking for the model pass |
| `Ctrl+.` | Toggle the optimizer itself |
| `Ctrl+,` | Provider sheet (endpoint, model, key) |
| `Ctrl+D` | Dark theme |
| `Ctrl+N` / `Ctrl+O` / `Ctrl+S` | New / open / save |

Applying a choice is one ordinary edit: `Ctrl+Z` restores the original words.

## Provider

Settings live in `%LOCALAPPDATA%\AuroraWrite\settings.json`. When they do not
name a provider, Aurora Write borrows the one Aurora OpenCode already
configured (`%APPDATA%\Aurora OpenCode\settings.json`), read-only, preferring the
per-endpoint key over the root key. Environment overrides:
`AURORA_WRITE_BASE_URL`, `AURORA_WRITE_API_KEY`, `AURORA_WRITE_MODEL`,
`AURORA_WRITE_THINKING`, `AURORA_WRITE_OFFLINE`, `AURORA_WRITE_SETTINGS`.

## Layout

| File | Role |
| --- | --- |
| `source/app.d` | Entry point, `--screenshot` and `--probe-llm` modes |
| `source/aurorawrite/writeroot.d` | Writing column, status line, keys, refinement state machine |
| `source/aurorawrite/concision.d` | Instant pass: table, morphology, span resolution |
| `source/aurorawrite/llmclient.d` | Chat-completions request, reply validation, worker job |
| `source/aurorawrite/suggestioncard.d` | The caret card: layout, paint, hit-testing |
| `source/aurorawrite/settingssheet.d` | Provider sheet |
| `source/aurorawrite/settings.d` | Settings, environment overrides, OpenCode fallback |
| `source/aurorawrite/theme.d`, `titlebar.d` | Palette and window chrome |

`TextEditor.caretRect()` was added to the shared framework
(`vendor/aurora-d-0.4.5/source/aurora/widgets/texteditor.d`) because any
completion UI anchored to the caret needs the geometry the editor paints; an
application-side copy drifts as soon as the field scrolls.

## Verification

```
VERIFY-WINDOWS.bat
```

1. Unit tests for the concision engine and reply parser (`dmd -unittest`).
2. `tests/headless_smoke.d` — 60 checks through real event dispatch: instant
   analysis, card placement above/below the caret, `Tab` cycling, `Ctrl+Enter`
   apply, undo, word savings, offline switch, focus retention on chip clicks,
   and the debounce → worker → apply wiring against a closed port (a failed
   refinement keeps the instant choices, reports the error and never edits the
   document).
3. Offline screenshot: `aurora-write --screenshot` writes Netpbm P6 (the
   software renderer's own format), so `tools/ppm-to-png.py` converts it to
   `artifacts/aurora-write-suggestions.png` next to a `.txt` report of the card
   and the status line.

The live provider path is probed separately, on purpose:

```
aurora-write.exe --probe-llm "We utilize a short checklist in order to keep it tight." utilize probe.txt
```

Measured against `deepseek/deepseek-v4.1-flash` on 2026-11-06:

| Probe | Effort | Result |
| --- | --- | --- |
| `utilize` | quiet | 1.6 s, 3 choices, definition returned |
| `utilize` | `high` | 5.4 s, 5 choices |
| `due to the fact that` | `high` | 9.2 s, 8 choices |
| borrowed loopback endpoint (down) | quiet | clean `Request failed (12029)` error, no hang |

The thinking probe first exposed a real defect: 500 output tokens were spent on
reasoning before the JSON started, so the answer was cut off. The deliberate
pass now asks for 2 048 tokens, and reply extraction scans every balanced
`{...}` block (and every text field a thinking gateway may use) instead of
assuming the first brace starts the object.
