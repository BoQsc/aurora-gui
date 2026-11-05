# Agent and chat baseline revision — 2026-11-04

This revision targets planning, turn completion, repeated tool dispatch, request
prefixes and the live chat throughput display. It does not replace the entire
application or claim parity with private implementations.

## Upstream behavior checked

- [Codex plan schema](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/plan_spec.rs):
  optional `explanation`, a `plan` array, and `step`/`status` per row. Status values
  are `pending`, `in_progress`, `completed`.
- [Codex plan handler](https://github.com/openai/codex/blob/81e180044d91c42f20818c43fbc2558603e4361d/codex-rs/core/src/tools/handlers/plan.rs):
  parse the update, emit the plan event and return `Plan updated`. Plan updates do
  not require command receipts, evidence categories or custom outcome IDs.
- [Codex turn loop](https://github.com/openai/codex/blob/d84c872464aca4821dc5cb548a651651aefd84fa/codex-rs/core/src/session/turn.rs)
  and [stream event handling](https://github.com/openai/codex/blob/main/codex-rs/core/src/stream_events_utils.rs):
  tool calls and pending input drive follow-up work. Stop hooks are a separate
  extension, rather than proof that every final response needs another audit.
- [Claude Agent SDK transport/control source](https://github.com/anthropics/claude-agent-sdk-python/blob/d38e51e81dc770d2ff0edc302f781ef2c9670754/src/claude_agent_sdk/_internal/query.py)
  and [Anthropic's loop documentation](https://code.claude.com/docs/en/agent-sdk/agent-loop):
  tool results feed the next evaluation; a response without tool calls finishes
  the ordinary loop. The public SDK delegates the internal execution loop to a
  bundled Claude Code binary; this audit does not pretend its private source was
  available.

## Resulting behavior

> **Superseded 2026-11-05:** every first message now creates a persistent goal
> and the agent plans every request. The plan/goal bullets below record the
> 2026-11-04 revision. See [agent-continuity.md](agent-continuity.md) for the
> current defaults.

- Normal `update_plan` uses the same basic argument structure and acknowledgement
  as Codex. Full snapshots can revise order, add necessary follow-up work, remove
  obsolete rows and complete steps without receipt-management errors. Empty plans
  are accepted. Stored plan history remains available.
- Checklist status and actual verification are independent. Marking a checklist
  complete cannot clear a required or failed verification result. The existing
  receipt-enforcing plan mode remains explicitly opt-in.
- Normal goal mutations execute without a synthetic planning preflight. Prompt
  instructions request updates at meaningful phase changes, rather than before
  every response. Initial action requests no longer acquire persistent goals by
  default; the existing setting and explicit goal controls remain available.
- A no-action automatic continuation settles the turn, preserves unfinished work
  and the active goal, and adds no failure bubble or nested recovery request.
  This stop check takes precedence over replay recovery. Actual tool work has no
  global turn-count cap.
- Repeat detection examines the preceding batch before recording the pending
  batch. Internal task checkpoints do not impersonate new user instructions.
  Ordinary rereads remain possible; an unchanged streak of three successful
  read/control batches causes the next duplicate to be skipped. Failure retries,
  branch isolation and mutation boundaries retain their separate rules.
- The answer contract precedes changing history, keeping the original instruction
  prefix intact even when a local server requires one leading system message.
  Incoming append-only request-projection changes were preserved and tested.
- Routine reads no longer append full task checkpoints merely because the recent
  evidence brief changed. Their original tool results remain in history;
  compaction and explicit task-state reads still include fresh evidence. Plan,
  verification and goal changes continue to append authoritative checkpoints.
  Newly completed outcomes also reset the stall counter without receipt IDs.
- Bounded working context quotes actual earlier user updates on the active task
  branch. Supplied values and corrections override outdated assumptions in the
  original goal. Input requests explicitly require checking earlier user replies
  before declaring a fact missing; evidence is not invented from generated files.
- Live throughput uses a 400 ms trailing window re-sampled every 50 ms, including
  during provider silence, so a change in decode speed reaches the readout in
  about a third of a second instead of lagging a full second. A slow decode
  extends the window (up to one second) until it holds enough tokens to measure,
  so the number does not jump by whole-token steps. Stalled rates still expire
  and restart on fresh output, and window boundaries do not produce periodic
  zero-rate flicker. Final messages retain the whole response mean. Token counts
  still use a local estimate when the provider has not supplied completion usage;
  this is not an exact provider tokenizer.

## Verification

`tests/agent_baseline_contracts.d` exercises real widget/dispatcher paths as well
as deterministic speed samples. It covers full plan revisions, necessary
follow-ups, independent verification, first goal mutations, repeated reads,
silence, resumption and paint.

The production application is also exercised by local HTTP providers:

```text
python tests/test_plan_review.py
python tests/test_no_action_continuation.py
python tests/test_goal_input.py
python tests/test_activity_liveness.py
python tests/test_latency_transport.py --delivery --release
```

The ordinary plan/write/check/completion fixture uses five HTTP requests, with
zero tool errors and no additional completion round. The identical no-action
goal fixture used six requests on the previously running binary and three on
the candidate, preserving an active unfinished task without a phantom running
turn. These are specific regression measurements, not universal speed claims.

Six native GUI deliveries over one reused TCP connection measured token receipt
to paint at 9.9 ms median and 13.2 ms maximum. The fixture injects 100 ms of
provider delay, which is excluded from that client-overhead figure. This finite
sample does not establish an absolute latency minimum.

An isolated live-provider conversation completed four user turns: casual advice,
constraint correction, document creation/readback, and reproducing/fixing a code
defect. Independent unittest verification passed, with zero redundant
verification continuations. The dinner-time assertion evaluates the actual
45-minute bound instead of requiring the literal string `45` in a valid
35-minute recipe.

The live long-horizon task changes billing rules, waits twice for user-owned
values, forces compaction with irrelevant historical rows, and verifies exact
JSON/CSV paths against eight independent numerical/API cases. A 48K-context run
passed all four phases and the independent checks. Earlier 32K runs exposed an
incorrect CSV filename and a 300-second phase timeout; those runs are retained
as failures, rather than counted as successful delivery. They motivated exact
deliverable instructions and the redundant-checkpoint fix. A later 32K run
created the exact outputs and passed all numerical cases but incorrectly asked
for confirmation of an already supplied rate, leaving the goal active. That
exposed the stale-original-goal versus later-user-facts issue, now covered by
branch-scoped context retention tests. These tests do not
establish that every model or context setting completes every long task.

The final 32K-context rerun with fact retention passed all four phases, all eight
independent API cases, exact `invoice.json` and `invoice.csv` validation, separate
unittest execution and final JSON-answer validation. Both missing-input waits
resumed correctly; the original goal finished and remained completed during the
answer-only follow-up. The run retained compaction, rather than bypassing it.
