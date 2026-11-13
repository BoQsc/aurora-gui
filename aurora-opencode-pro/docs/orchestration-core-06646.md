# Orchestration core 0.66.46

Follow-up in 0.66.47: optional planning is encouraged again. Multi-step work gets
an early provisional-plan suggestion, and both execution owners suggest reviewing
the plan every five substantive tool results. Updating the plan resets the count;
process/status polling does not count. Ignoring a reminder never blocks tools,
forces reconciliation, or adds a completion round. Finished work is not nudged.
The plan badge says “review plan”. Shared-policy, real UI, execution, projection,
and queued-follow-up contract checks pass for this behavior.

The active desktop and headless paths now share an outcome ledger in
`executioncontrol.d`. Existing task contracts, plans, tool events and receipts
remain the durable storage; there is no second independently mutable task model.

## Execution changes

- One end-of-response decision handles completion, outstanding outcomes,
  recovery, steering and essential input. The separate prose-audit recovery
  interceptors no longer run before that decision.
- Searches, changed arguments, patches and rewritten completion claims do not
  reset recovery. Completed outcomes count distinct supporting evidence rather
  than duplicated plan rows. Productive work has no fixed tool-round limit.
- Repeated unresolved completion attempts get a focused recovery and diagnosis;
  continued failure becomes an explicit failed turn with the task preserved,
  rather than another successful-looking final response or an endless prose loop.
- A failed behavioral checker remains outstanding until that checker passes.
  An unrelated green test does not erase it. Stale checker receipts remain
  rejected. Receipt metadata distinguishes execution of a checker from proof
  of physical input.
- New user failure reports invalidate earlier passing verification. Explicit
  `approved` replies resume the prepared work. Desktop restrictions come from
  preserved human messages, survive plan replacement, and apply at tool admission.
  A negated request to resume does not lift the restriction.
- The selected working project is persisted in the task contract. An explicitly
  named project is no longer ignored merely because its message is an analysis.
- Passing checks survive scratch/output cleanup when their tracked inputs remain
  unchanged. Mutating checked inputs still invalidates those checks.
- Completed, verified outcomes lead directly to a final-answer request without
  tools. This prevents a further audit, exploratory search or cleanup cycle after
  completion. Newly discovered unfinished outcomes keep tools available.
- Removed automatic periodic plan upkeep, forced plan reconciliation, the extra
  per-request outcome-check prompt, and default planning prerequisites. Explicit
  experimental strict planning remains opt-in. Old control messages remain saved
  but obsolete reminders are excluded from provider history.
- Durable desktop checkpoints use a stable state hash and change with actual
  outcome/plan/user state, rather than every tool result.
- Repaired implementations require behavioral tests. Incidental words such as
  “layout” no longer manufacture separate compile/render/interaction receipt
  obligations. Specific behaviors remain outcome acceptance criteria.

## Real-provider replay

The benchmark uses the configured `deepseek/deepseek-v4.1-flash`, real tools,
historical recorder sources from `01da5d0`, and private application state, output
and Git copies. It does not read or modify TerraForest. Recorder changes made by
the replay stay in those copies; the ongoing original recorder edits are excluded
from this release.

Requests come from `t-m639300051903800675-1863`:

| Request/message | Run | Result |
|---|---|---|
| Fast video, 4652 | Intermediate core | 900 s timeout, 148 tools; cleanup/check churn remained |
| Fast video, 4652 | Revised core | Completed in 195.1 s, 36 tools, 0 failures; independent test then caught an insufficient repair |
| Still fast, 4856 | Correction with actual failing check | Completed in 285.2 s, 44 tools; independent encoder test passed afterwards |
| Wrong window selection, 3433 | Intermediate core | 900 s timeout, 115 tools; mandatory receipt-category churn remained |
| Wrong selection, 3433 | Revised core | Completed in 411.8 s, 98 tools; independent widget check caught long-path clipping |
| Broken selector UI, 3580 | Correction with independent check | Completed in 264.3 s, 57 tools; independent widget/layout check passed afterwards |
| Speed complaint, 4856 | Optimized final host, already-correct copy | Completed in 52.3 s, 9 tools, no failures or source edits; current check recorded with `no_change_needed` |

These are individual stochastic runs, not a controlled general speedup estimate.
Intermediate hosts and replay context differ. Earlier failed runs are retained
in private benchmark artifacts; completion alone is not considered acceptance.
Final successful runs have no native path escapes or forbidden desktop/rebuild
operations. `AURORA_TOOL_ROOT` supplies an opt-in structured native-tool path
boundary for replays; it is not an OS sandbox for arbitrary subprocess code.

### Independent acceptance

The timing check executes the actual D `ScreenEncoder` at 30 and 60 fps. A small
test wrapper runs real FFmpeg and suspends that process for one second, producing
real pipe back-pressure. FFprobe duration is compared with six seconds of
monotonic capture time. The historical encoder failed at 60 fps: 6.000 s wall
time produced 4.966667 s video. After the correction:

| FPS | Wall time | Video duration | Difference |
|---|---:|---:|---:|
| 30 | 6.012 s | 6.033333 s | +0.021333 s |
| 60 | 6.003 s | 5.983333 s | -0.019667 s |

The independent D acceptance sources remained unchanged.

The picker check compiles the actual `RecorderRoot` in AuroraHeadless, dispatches
coordinate clicks through its widgets, checks arming/cancel and absence of an
automatic target, validates all visible controls against the surface with a long
path, and checks activation/release/target click-state sequences. It initially
failed because “Change…” started at x=815 in a 760-pixel-wide surface. It passed
after correction. This establishes offscreen interaction/layout and click-state
behavior; it does not establish physical desktop/game window selection.

Reproduce with `benchmarks/replay_orchestration.py --live` and the independent
`check_recorder_timing.py` / `check_recorder_picker.py` commands. Provider secrets
and copied chat state stay outside the repository; temporary settings are deleted.

## Local validation and overhead

Relevant execution, input, checkout, verification freshness, history, queued
follow-up, ownership, mailbox, scheduler shutdown and performance contracts pass.
The revised fixtures retain strict-mode checks where strict mode is explicitly
enabled, and assert that default execution no longer produces retired controls.

With 100 conversations and 1,502 selected messages, five optimized UI-tick trials
measured medians of 39/33/31/31/32 microseconds and p95s of
107/98/92/90/95 microseconds. This excludes painting, persistence and provider
latency. Separate debug performance checks measured long-reply input/rebuild/paint
at 9.893 ms median and 17.505 ms p95. These finite client measurements are not
claims about hosted model or network latency.
