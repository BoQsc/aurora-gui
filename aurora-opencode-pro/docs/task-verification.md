# Task execution and verification

## Ownership

An explicit existing Git checkout in a real user message becomes that task's
workspace. Quoted paths and spaces are supported. Internal messages, tool output
and rebuild notices cannot retarget it. Ambiguous references to multiple checkouts
preserve the previous workspace. Sidebar project membership is preserved.
Subpackage checks map to their checkout. A D compiler running in a temporary
directory maps to the task only when its source/include paths name that checkout.
Unrelated checks cannot satisfy it.

On restart, the recorded owner receives its specific cause and build result.
Other interrupted chats receive a neutral notice and resume their own objective
and guidance. Another chat's application rebuild does not verify their outputs.

## Saved verification sequences

Save a recipe with native file tools, then call
`verify({"recipe":".aurora/verify.json"})`. The runner executes a finite sequence
in one supervised operation, with progress and cancellation. Arguments are
literal arrays. Recipe commands stay foreground until their deadline; they do
not automatically detach at thirty seconds. Execution stops at the first failure.

```json
{
  "inputs": ["source", "tests"],
  "steps": [
    {"kind":"compile","command":{"program":"dmd","args":["-i","-Isource","-of=build/check.exe","tests/check.d"],"timeout":120000}},
    {"kind":"tests","command":{"program":"build/check.exe","args":[]}},
    {"kind":"prepare","command":{"program":"build/capture.exe","args":["tests/page.html","320","240","build/actual.ppm"]}},
    {"kind":"render","reference":"tests/reference.png","actual":"build/actual.ppm","referenceSource":"Independent browser; frozen HTML hash; 320x240; device scale 1"},
    {"kind":"interaction","command":{"program":"build/check.exe","args":["--interaction"]}}
  ]
}
```

Paths resolve from the task checkout; command `workdir` may override that.
`inputs` must cover the source/tests actually used. Exclude generated outputs.
The recipe and inputs are hashed before and after execution. Reference hashes
are frozen before commands run. Changes invalidate the result. Receipts record
commands, results, source/recipe hashes, reference provenance, image dimensions,
image hashes and mismatched pixels.

Types: `compile`, `tests`, `render`, `interaction`, `prepare`. Preparation alone
supplies no verification. Compilation requires a recognized compiler/build
attributable to the task checkout. Test/interaction commands must execute real
assertions with meaningful exit codes. A recipe is a declared contract, not proof
that its author chose complete assertions.

Rendering tasks require compile, test and render evidence. Rendering requests
that include browser interaction additionally require interaction evidence.
The successful recipe must supply the relevant set. Generic nonvisual tasks
retain existing checker behavior.

Images are compared as decoded RGBA, including PNG/PPM combinations. Dimensions
must match. Comparison is exact by default. Optional `channelTolerance` is 0..8;
`maxDifferentPixels` is at most 2% of the frame. Both are recorded. Choose them
from independent expectations, never to hide a known defect. A mismatch attaches
both reference and actual pixels to the next request, even on tool failure.

Bounds: 64 KiB recipe, 16 steps, 64 input roots, 20,000 traversed entries, 64 MiB
source inputs, 32 MiB encoded images, 16 million decoded pixels. Input symlinks
and paths outside the task checkout are rejected. Failed, detached, cancelled or
timed-out commands cannot certify success.

## Independent browser corpus

Original frozen fixtures cover box sizing/borders/padding, flex/grid positions,
SVG placement and button/link behavior. They use no external assets or fonts.
Capture references with an explicitly selected installed Edge/Chromium browser:

```powershell
python tools/capture-browser-reference.py --browser "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe" --output build/browser-references --verify
```

This uses a private temporary profile and a local fixture server. The manifest
records browser/HTML/reference hashes, viewport and device scale. Existing
references are never overwritten. `--verify-existing` checks frozen hashes and
runs the current engine without recapture. The generated `verify.json` also works
with Aurora's native tool. The probe captures page content without window chrome
at the matching viewport. Interaction assertions check actual click dispatch and
link destinations.

The first comparison on 16 October 2026 passed 38 engine-test modules but failed
the independent box-model frame by 14,200 of 76,800 pixels. Both images confirmed
wrong border color and width. This is an existing browser-engine discrepancy;
the new runner correctly keeps rendering verification failed. Passing client
regressions does not mean the browser corpus passes.

## Progress, context and diagnostic review

Continuation measures completed outcomes and accepted verification. Novel
queries, no-match results, repeated builds and plan rewrites alone cannot reset
stagnation. Three stalled continuations trigger a new diagnosis using a reduced
case, independent expectations and contradictory evidence. Three further stalls
require attention, preserving work/history. Actual outcome progress resets the
window. Productive tool work has no fixed round cap.

The model/context button's context menu exposes two controls:

- **Use 128k working context for long tool tasks**: enabled by default. After
  32 tool rounds, when automatic compaction is enabled for that model, the
  working context is capped at 128k or the user's smaller
  target. Compaction retains the full transcript/branches on disk. Disable the
  checkbox to retain the selected target. `AURORA_WORKING_CONTEXT_TOKENS=0`
  disables this cap; a value >=16000 selects another cap.
- **Use this model for stalled-task diagnosis**: off until explicitly selected.
  A configured reviewer gets at most four requests and a 64k context ceiling
  through the current provider. Only inspection tools are advertised/accepted;
  the scheduler rejects mutation/execution even if requested. The main model
  resumes after the diagnosis. Aurora never automatically chooses a more
  expensive model or changes the task's main model.

Checklist reminders allow sixteen results instead of four, and remain bounded
per refresh cycle. Identical durable checkpoints are coalesced. History is kept.

## Network inactivity and checks

Each WinHTTP completion wait has an application-level inactivity deadline.
Default: 120 seconds per operation. Continuing data starts fresh windows; there
is no total generation cap. `AURORA_NETWORK_INACTIVITY_MS` accepts 100..600000 ms.
Per-request cancellation and callback/handle lifetime guarantees remain intact.

Regression coverage includes actual GUI/scheduler scope acceptance, wrong pixels
after green tests, two-chat resume isolation, distinct-search stagnation, changed
recipe inputs, preparation-only checks, reviewer routing/write rejection,
callback inactivity/connection release, conversation flow and preserved history.
Reviewer accuracy with real models remains an experiment. These checks establish
no universal latency or browser-correctness guarantee.

```powershell
python tests/run_architecture_checks.py task_policy_contracts task_policy_ui_contracts task_continuation_contracts early_plan_contracts history_preservation_contracts execution_ui_contracts
python tests/test_task_diagnosis.py
python tests/test_latency_transport.py
python tests/test_conversation_flow.py
```
