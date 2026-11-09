# Agent flow simplification, 0.66.42

The previous real player-model ZIP replay took 794.5 seconds, 133 tool results
and 75 model tool rounds. Inspection of that saved conversation found a handoff
had expanded into a packaging framework, a 2,115-line contract, separate
handoff/return validators, multiple manuals, hypothetical future model tests,
and thirteen history searches for completion evidence.

## Removed and simplified

Across 11 production modules: 547 lines removed, 254 added (293 fewer net).

- Removed the keyword-based framing gate that discarded useful tool batches
  until the assistant supplied prescribed framing prose.
- Deleted six overlapping global prompt sections and unrelated task-specific
  lectures. The rendered global prompt is 5,439 bytes versus 13,629 previously
  (60% smaller), with a 251-byte ordinary response footer. Project instructions
  remain intact and are additional to this measurement.
- Ordinary chats no longer automatically create a persistent goal and its
  second completion protocol. The v3 forced-on preference migrates once;
  explicit goals, saved histories and v4 opt-in preferences remain supported.
  Ordinary task continuation, verification and plans still operate.
- Default plans use short step/status lists without evidence-ID bookkeeping.
  Strict planning remains opt-in. Removed repeated unchanged-phase reminders;
  real transitions request reconciliation in the next useful tool batch,
  including outcomes with unknown inferred kind. Reminders never fabricate
  completion or stop useful tools.
- Programs may package artifacts and generate related bulk output together;
  source edits still prefer context-checked native edits. This removes the
  policy pressure toward separate copy/write/move/rename calls for one export.
- Verification accepts inline inputs and commands. A saved recipe is optional;
  no recipe file, separate checker framework or second identical run is needed.
  Inline receipts are revalidated from saved arguments and original workspace,
  including after continuation/reload and for inputs over 64 MiB.
- Native text reads reject binary data before emitting decoded junk. Images,
  hashes and genuinely needed format metadata have appropriate alternatives.
- Removing temporary output preserves an explicit recipe's proof only when its
  actual tracked inputs still hash identically and required coverage is met.
  Missing/changed checked inputs invalidate it; direct command receipts remain
  bound to their original source revision.

## Real provider checks

All cold runs use the original request, `deepseek/deepseek-v4.1-flash`, and the
saved **high** reasoning route. No canned responses, artificial smaller assets,
task-specific model steering, lowered effort or substituted model are used.
Each run starts from the same manifest of 5,661 files / 1,536,480,419 bytes in
its own copied workspace, app state and temporary directory outside Aurora.
Only existing snapshots are read. The original TerraForest project is not used.

| Run | Seconds | Tool results | Tool rounds | Observation |
| --- | ---: | ---: | ---: | --- |
| Previous 0.66.41 | 794.5 | 133 | 75 | Valid ZIP; large unrequested handoff framework and receipt hunt |
| First simplification | 640.1 | 77 | 46 | Valid ZIP; revealed inline receipt recovery bug and late plan transition |
| Receipt recovery repair | 396.8 | 89 | 43 | Valid ZIP; further exposed temporary-output cleanup invalidation and delayed reconciliation |
| Final cold replay before the last plan correction | 502.0 | 72 | 47 | Independent checks passed; one accepted verify, no history searches or goal-completion calls |
| Final plan correction, real saved checkpoint | 2 | 1 requested plan update | 1 | Investigation completed, assembly active, verification pending; no file operations executed |

The final cold run used binary SHA-256 `bd7b69c11675e828e376e52ef7d9e3c05cea5455bb40a77ca615194d0bf6c7b9`. It reduced elapsed time by
36.8% and tool results by 45.9% versus 0.66.41. Its longest gap between plan updates fell from 61 to 34 results, but
it still caught up late. The last correction therefore places one bounded system
instruction after working history when a real phase reminder is ignored. All
useful tools remain available. An unchanged plan retains its work phase, and
moving back from verification to editing is recognized.

A rejected experiment restricted the available tools for that request. The real
model emitted an unavailable write and continued with unnecessary packaging work;
that approach was discarded. Its actor continuation changed generated files in
the isolated replay copy after the cold run had already been independently
checked; source model/code assets remained unchanged. The successful final test
uses the actual saved 98-message checkpoint and sends one real provider request,
asserting its first response is the correct plan update without executing file
operations. It is a targeted repair test, not another full cold-run timing.

Production delivery uses the detached rebuild helper, verifies the public
upload, and measures client delivery separately from these hosted-model times.
The intermediate failures were retained and repaired rather than removed from
the comparison. Model choices and provider timing vary; these are observations,
not a universal latency guarantee.

Independent checks retain the earlier asset standard: ZIP integrity and safe
unique entries, source-byte-identical Blender/GLB, 59 joints and 71 runtime clips,
embedded dependencies, unchanged source assets, a README, actual ZIP coverage
in an accepted verifier receipt, and a completed task/checklist. An ordinary
chat does not need an artificial persistent goal to pass.

Private run roots are under
`%LOCALAPPDATA%/Temp/aurora-agent-replays/player-handoff-lean*-06642`.
Assets, raw conversations and provider settings are not committed.

## Regression coverage

Focused checks cover inline receipts through continuation, a 65 MiB tracked
artifact, changed-input/failing-command rejection, harmless cleanup versus
deleting the deliverable, timely advisory plan transitions, bounded reminders,
binary text reads, settings migration, explicit goals, history preservation,
follow-up ownership, paused work and 32K compaction. Shipping-image HTTP/SSE
round trips supplement the hosted-model replays; deterministic tests alone
are not the evidence for improved model behavior.
