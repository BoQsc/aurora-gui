# Long-horizon reliability: 0.66.33 and 0.66.34

This release follows live failures in the active desktop assistant. The scope is
answering, durable goals, planning and compaction; the standalone actor migration
remains deferred.

> **Superseded 2026-11-05:** the agent plans every request and every first
> message becomes a persistent goal. See
> [agent-continuity.md](agent-continuity.md). The notes below remain the record of
> the 0.66.33/0.66.34 releases.

## What changed

- Compaction reserves history space after accounting for the system prompt and
  native tool definitions. The optional model summary must fit that reservation.
  A complete, unconsumed tool batch remains available when it fits, so a batch of
  source reads is not immediately replaced with a summary before the agent can
  use it. Oversized results can still be compacted. Saved history is preserved.
- Recent human decisions are quoted in both extractive and model-refined
  checkpoints. Later instructions take precedence. Durable task constraints and
  full history remain available for decisions older than this bounded window.
- Active goals explicitly use `request_input` after independent work when a
  customer-owned fact is missing. A prose question does not record a wait.
  Answer-only questions preserve an existing wait and do not restart goal work.
- Substantial goal mutations receive one forward-plan/acceptance preflight when
  a plan or its constraints are missing. It asks for behavioral acceptance rules
  from the original specification. This is a bounded intervention: a provider
  ignoring it cannot create an infinite planning gate. Small edits execute
  directly. Reasoning is expected for every task; durable tool planning is for
  work that benefits from tracking outcomes, dependencies and verification.
- Detailed `read_plan` defaults to outcome IDs when outcomes exist; action IDs
  are explicitly selected. `update_plan` accepts action-only and metadata-only
  patch updates and diagnoses IDs sent to the wrong collection. Unfinished
  outcomes and completion-evidence validation remain enforced. `unittest`,
  `pytest` and `ctest` execution steps infer a verification kind.
- Answer and goal guidance distinguish original requirements from generated
  code/tests. Limits retain their units; a nonzero limiting case is checked.
  Requirement changes identify their exact semantic delta and preserve other
  behavior. Changing an assertion requires justification from the original
  specification or an explicit user change.
- Background execution counts an admitted request as busy before the network
  worker starts. Otherwise Stop could skip a delegated child during that gap.
  This was reproduced in the regression suite and repeated against the same
  binary. The corrected cancellation check passed 30 repeated parent/child runs.

## Live evaluation

`benchmarks/long_horizon.py` creates an isolated Python billing task using only
the standard library. It requires Decimal aggregation, UTC month boundaries,
deduplication, late/out-of-order refunds, malformed-input accounting, a public
API, CLI and unchanged compatibility tests. Four stages introduce a missing
rate, account-scoped IDs, a missing currency credit cap, CSV delivery, a large
read-only audit attachment that forces compaction, and an answer-only recall
question. An independent oracle checks invoice JSON, CSV, eight API cases,
unchanged tests, goal identity/completion, forward planning and concise answers.
Independent test discovery also checks nested test directories without requiring
them to be Python packages.

The baseline is the shipped 0.66.32 image, SHA-256
`4258f3f1fbf18d1fb1a4c9193cfe0bb03db4e9e61cd556aead777ad9df2424e6`.
At a 64K configured context it reached the rate wait in 148 seconds, then spent
234 seconds on the changed requirement and stalled repeating prose instead of
recording the cap wait. It never reached final delivery. At 32K, the baseline
timed out after 300 seconds during repeated reads in the first stage.

Intermediate candidates were rejected for concrete failures: forgetting the
already-supplied rate after compaction; resuming a goal for an answer-only
question; confusing plan outcome and action IDs; applying a currency cap to
input units (Alice `0.10` instead of `0.06`); and changing identical-duplicate
handling (rejected count `3` instead of `2`). Passing self-authored tests was
not accepted as proof of correctness. Their result records remain in
`build/long-horizon-06633/`.

Comparable live runs use the actual console route, resolved as
`deepseek/deepseek-v4.1-flash`, thinking off, concise responses and the same 64K
context. Earlier fixture runs accidentally used the GUI's High reasoning
profile, or lacked native helper subprocess dispatch. Those runs are excluded
from timing comparisons; the fixture now matches the production console entry
point. GUI preferences are unchanged.

The final answering/planning candidate passed all four stages in 444.4 seconds
end to end, with 122 tool calls and 13 plan updates. The rate and cap waits took
198.9 and 86.0 seconds; final delivery took 156.7 seconds and the recall answer
2.2 seconds. Its eight independent API cases, JSON, CSV and independent test runs
passed. Compaction occurred, the exact original goal was retained and completed,
the plan was complete, and the final delivery used 54 words. The implementation
contained 45 passing tests. This establishes a successful demanding task, not a
lower initial-response time: its first stage was slower than the baseline.

| Observed check | Shipped 0.66.32 | Revised candidate |
| --- | --- | --- |
| Changed requirement, cap still missing | Repeated prose, then blocked | Recorded wait, goal stayed active |
| Original goal after compaction | Did not reach delivery | Exact text retained and completed |
| Invoice and CSV | Did not reach delivery | Alice `0.06`, Bob `0.09`, rejected `2` |
| Answer-only recall | Did not reach final question | Exact JSON; original reference and April refund month |
| Delivery concision | No final delivery | 54 words |

An intermediate candidate finished but returned Alice `0.10`; another returned
correct charges with rejected `3`. Those are failed candidates, not baseline
answers. The passing candidate returned:

```json
{"reference":"RECON-Q7-8162","alice":"0.06","bob":"0.09","refund_month":"2026-04"}
```

## Reproduction and limits

The 0.66.33 production repeat did **not** reproduce the candidate's success: it
timed out at 300 seconds in stage one. It generated incorrect test expectations,
observed the implementation returning `17.00` for two 10-unit charges at rate 1
with a maximum refund credit of 3, then argued for `7.00` using a wrong charge
operand. Other generated cap tests also had incorrect expectations. The package's
passing candidate run is therefore insufficient evidence of reliable semantic
performance. The failed production workspace and original generated tests are
retained in `build/long-horizon-06633/rejected-production-workspace/`.

0.66.34 addresses that recovery path. Failed assertion results retain their
failure/verification status and exact observed output, followed by a clearly
separate instruction to recover the original rule, identify operands/units and
compute the expected value independently before editing. Generated assertions
remain hypotheses: correcting them is appropriate when justified by the original
rule and independent computation. User-owned tests remain protected. The same
distinction is part of the post-history answer contract, so compaction cannot
remove the recovery policy. The change does not treat a failed assertion as proof
that implementation or runtime is defective. Final 0.66.34 evidence is stored
separately under `build/long-horizon-06634/`.

Run `python benchmarks/long_horizon.py --live --context 64000 --output <new-private-directory>`
after building. `--exe` selects an isolated image. Live checks use the configured
provider and record the binary hash. Credentials are scrubbed from temporary
settings after the run. End-to-end timings include provider/network time and
are not measurements of client overhead or a general speedup.

The architecture suite includes constrained working-set and desktop planning
checks. The HTTP/SSE conversation fixture covers 16 rounds, including changed
requirements, real tool failure/recovery, steering, queued follow-ups, Stop/resend,
background work and reload. Local-provider checks separately exercise goal
wait/resume and exact recovery from saved history after compaction.

This is a demanding but finite scenario, not proof of universal accuracy or
arbitrary-duration reliability. Matched-profile intermediate 32K runs still
timed out; reliable completion at that size is not claimed. Prompt guidance
improves behavior but cannot mechanically establish semantic correctness of
arbitrary generated programs. The final rebuilt-image results, regression logs
and deployment provenance are retained under `build/long-horizon-06633/`.
