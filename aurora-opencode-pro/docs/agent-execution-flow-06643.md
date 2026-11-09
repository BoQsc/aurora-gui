# Agent execution flow, 0.66.43

This release changes execution and settlement, rather than adding another
planning protocol. Real-provider Aurora tasks exposed two harness failures:
successful direct tests could leave verification required, and the desktop
owner could silently hold unfinished work in an idle turn. A third failure
followed deletion of a declared checker input: the agent received generic GUI
verification advice instead of the actual reason its proof expired.

## Runtime changes

- Removed whole-batch duplicate-call rejection and successful read/control
  suppression. Useful new calls are no longer discarded because another call
  repeated. Fresh reads and long-running process polling still execute.
- Removed the desktop audit-hold map, its continuation override, automatic goal
  pause, and the separate goal-completion-audit request. Both execution owners
  use bounded no-progress recovery. Recovery markers open a fresh audit interval
  while retaining the three-repair budget. Exhaustion is an explicit, visible
  failure with Retry; task, goal and history remain available.
- Centralized verification/completion transitions in `advanceToolTaskState`.
  The actor now preserves current tracked proof through harmless cleanup and
  handles stale unrelated checks like the desktop owner. Changed or missing
  checked inputs still revoke proof; direct receipts remain generation-bound.
- Conventional Python test scripts, Aurora's architecture runner and compiled
  test executables produce normal receipts. They also count as verification
  rather than unknown workspace mutations. Help, collection and the architecture
  runner's pruning mode are excluded; Python byte compilation supplies compile
  evidence only.
- A custom foreground `run` can carry `check` and `inputs`, using the same
  tracked-input engine as `verify` in one execution. Saved recipe files are
  optional. An explicit `no_change_needed` behavioral check can support an
  already-satisfied outcome; compilation alone cannot do so.
- Missing-input feedback identifies the actual absent declared path. It is
  scoped to the task checkout, recorded through the actor's fact mechanism,
  and does not weaken input validation. Removed the blanket assertion that a
  helper test cannot establish a GUI change.
- Actual substantive edits and accepted checks count as progress while a plan
  step stays active. Repetition diagnosis compares numbered source facts,
  excluding changing grep headings. An already tracked edit phase receives no
  false phase reminder.
- The existing final request compares completed work with the exact requested
  triggers and constraints. It adds no separate review round or tool filter.
- Actor clients see bounded tool-argument preparation: at most 64 previews,
  2 KiB each, coalesced at 50 ms. No tool executes before complete arguments;
  completion, stop and errors clear the previews.
- The session server distinguishes a post-start stall from `turn_not_started`.
  Project instructions no longer invent a fixed round budget or encourage a
  partial delivery merely to fit that budget.

The earlier [Claude Code, Codex and OpenCode comparison](agent-upkeep-20261109.md)
informed this direction. These changes are not evidence of competitive parity.
Plans remain useful work state, with strict planning opt-in.

## Real tasks and results

The requests came from saved Aurora chats. Each cold run restored tracked Aurora
source from the historical pre-change revision into its own Git checkout,
APPDATA and temporary directory. The empty-Send input contains 837 files from
`7235259`; Export contains 650 from `f73c558`. No TerraForest project files or
snapshots were used. Isolated task patches were not imported into production.

All hosted runs used the saved `deepseek/deepseek-v4.1-flash` route with configured
high effort. Title/suggestion maintenance was disabled consistently in replay
settings. The agent used real native tools and the real provider, with no canned
task responses. Independent checks compiled the resulting source and exercised
actual widget pointer/hover paths. Their small local HTTP responder tests the
Continue transport path, not the agent's task decisions.

Timings include application startup and shutdown. They are individual
observations with provider and model variance, not a general speed guarantee.

| Run | Seconds | Tool results | Model tool rounds | Outcome |
| --- | ---: | ---: | ---: | --- |
| 0.66.42 empty-Send baseline | 592.0 | 151 | 87 | Completed; independent observable checks passed |
| 0.66.42 Export baseline | 376.4 | 94 | 72 | Completed; independent hover check passed |
| First empty-Send candidate | 793.7 | 221 | 132 | Completed; slower candidate retained in results |
| Whole-observation candidate, empty Send | 1038.3 | 144 | 114 | Completed; no latency win |
| Whole-observation candidate, Export | 1202.2 | 230 | 171 | Timed out with verification outstanding |
| Partial-overlap candidate, empty Send | 679.7 | 149 | 94 | Completed; no general speed win |
| Partial-overlap candidate, Export | 415.2 | 87 | 60 | Falsely completed: hover was omitted |
| After removing context prototypes, empty Send | 887.6 | 201 | 134 | Failed after passing scripts produced no accepted receipt and the UI held the turn |
| After removing context prototypes, Export | 327.0 | 79 | 56 | Completed; independent hover check passed |
| Direct-test recognition and shared recovery, empty Send | 581.5 | 172 | 79 | Completed with current native receipts; independent checks passed |
| Direct-test recognition and shared recovery, Export | 543.8 | 108 | 71 | Explicit failure after a declared checker was deleted; repaired below |

The last cold pair used binary SHA-256
`eb6a99a1ce8b4e8d1e1b64e86d7da06514af7efcf43fffb7c3f52f2d1537cb95`.
The final missing-input feedback and terminal-error presentation corrections
were verified afterward through real saved checkpoints and native UI/HTTP tests.

The empty-Send pristine copy already passed the independent idle, whitespace
and explicit-Continue checks. That probe does not establish the reported bug in
every possible state. The agent still spent substantial time on defensive
changes. None of those speculative UI/actor patches is part of this release.

### Repairing the actual failure checkpoints

No additional repair instructions were supplied to the hosted model. The native
actor resumed the original request and durable tool history with the updated
runtime, using normal tools until verified completion.

| Checkpoint | Seconds | New tool results | Verified result |
| --- | ---: | ---: | --- |
| Export falsely marked complete without hover | 262 | 41 | Actual hover implemented; independent widget check passed |
| Empty-Send verification/continuation stall | 45 | 1 | Current tracked check accepted; task completed |
| Export proof lost after checker deletion | 39 | 6 | Missing checker restored and retained; compile/interaction check accepted; task completed |

The first attempt at the empty-Send checkpoint had two filesystem-host errors in
the replay fixture, then completed in 96 seconds with three tools. The fixture
was fixed to dispatch filesystem-helper mode before loading state, matching the
application entry point. That attempt is retained and excluded from the clean
checkpoint timing above.

Final independent checks passed for both latest isolated outputs: empty and
whitespace Send stay inert, typed Send and busy Stop remain available, explicit
Continue reaches the provider, Export takes no toolbar space, and Checkpoint
hover exposes an enabled Export action that dismisses on an outside click.

These results establish repairs to reproduced harness stalls. They do not
establish a general end-to-end speedup. Model over-exploration remained visible,
and a faster incorrect answer is not counted as a successful improvement.

## Removed experiments

Wire-only observation reuse saved roughly 2–6% of tool text on the measured
histories and did not establish a latency win. Its projection/cache machinery
was removed. Source-fact comparison remains only for stagnation diagnosis.

An automatic 128k working-context cap was stopped after about 97 seconds in each
trial and removed because it contradicted the selected-context guarantee. Those
trials are recorded as rejected, not successful timings. The selected context
target, reasoning controls and full saved history remain intact. A qualified
long-task regression now checks that tool count cannot reduce the chosen target.

## Regression and delivery checks

Native checks cover direct-test receipts and actual single-process custom
checks, changed/missing inputs, harmless cleanup, no-change outcomes, explicit
bounded recovery with a rendered Retry action, source-fact stagnation, current
task ownership, queued follow-ups, phase tracking, and context-target retention.
HTTP/SSE tests cover four-round normal settlement, fragmented argument bursts,
bounded varying-prose goal recovery and durable actor replay.

The production delivery uses the detached rebuild helper after source commit
and maintainer-branch verification. The rebuilt image is relaunched and checked
separately from the isolated candidates; publishing includes public download
verification. Client token-to-paint delivery is measured separately from hosted
model/network task time.

Private artifacts live under `%LOCALAPPDATA%/Temp/aurora-flow-replays/` with the
run labels above. They include input manifests, raw histories, result metadata,
binary hashes and independent checks. Credentials are scrubbed, and raw chats,
settings and generated task assets are not committed.

The opt-in replay driver requires a local chat identifier instead of publishing
user-specific IDs:

```text
python benchmarks/replay_agent_flow.py --task export-menu --chat-id LOCAL_CHAT_ID --label local-run --exe PATH_TO_CANDIDATE
python benchmarks/check_agent_flow.py PATH_TO_REPLAY
```

`benchmarks/reconcile_agent_flow.d` runs the real native actor from an existing
premature-completion checkpoint. These commands contact the configured provider.
