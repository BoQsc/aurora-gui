# Agent continuity and context recovery — 0.66.28

This change addresses reproduced causes of unnecessary continuation, lost
context, false input pauses, and expensive compaction. It preserves the saved
conversation graph and the existing tool, verification, transport and repository
owners. It is not a complete actor-engine rewrite or a guarantee of model quality.

## Behavior

- Every first message becomes the conversation's persistent goal, including
  greetings, questions and analysis, so planning is goal-oriented from the
  first turn. The behavior is on by default and migrated for existing settings;
  users can still turn it off. Explicit `/goal` and the goal controls accept any
  completion condition.
- Planning is the default path: the agent records a plan for every request
  (one step is enough for a direct answer), the plan-first gate covers
  substantial or multi-call work, and stale-plan reminders fire earlier. The
  agent revises the plan in the same turn as evidence changes. Every revision,
  including replaced and completed outcomes, is kept in plan history, and
  `read_plan view=history` recovers earlier plans and reasons.
- Automatic goal continuation requires tool access and an action goal. Answer
  and analysis goals settle after their reply, and a goal that cannot call
  `goal_complete` does not keep issuing continuation turns.
- A goal waits only at the same validated `request_input` boundary used by task
  continuation. Phrases such as “please confirm” in assistant prose no longer
  silently pause it. Waiting retains the active goal; replying with the missing
  information releases the wait. Explicit Stop still pauses the goal.
- A rebuild or restart resumes an active goal whose turn had already settled, not
  only a `running` transport turn: the rebuild ended the turn, not the objective.
  Paused and completed goals, a validated input wait, finished work and a plain
  relaunch without a rebuild/crash note still stay stopped.
- Shared tool schedulers now join their workers and watchdogs before runtime
  teardown. A post-rebuild multi-turn test exposed an intermittent shutdown
  access violation; the minidump identified a still-running queue watchdog.
  Late admissions during shutdown cannot leave a new worker pool running.
- `read_history` searches exact saved text on the selected branch and pages
  complete messages or saved tool arguments using message IDs and byte offsets.
  Results label failed tools and historical status. Other branches, internal
  control messages, reasoning and recursive recall results are excluded.
  Recall cannot count as new execution or verification evidence.
- Checkpoints name message IDs and explain how to retrieve omitted details.
  The summary model receives more of a user message when it fits. Accepted
  summaries retain authoritative task context, including the goal, constraints,
  current position and evidence, outside the generated summary.
- Compaction projects history once and accumulates suffix costs once, replacing
  repeated projections for every candidate cutoff. The meter and selector share
  request accounting, including reasoning, tools and image estimates.
- Summarization has a 45-second deadline and 24,000-byte output cap. Errors,
  cancellation, incomplete finish reasons, changed branches and changed task
  identities keep the deterministic checkpoint. Normal execution resumes from
  that checkpoint; the saved transcript remains available to `read_history`.

The input classifier is conservative English parsing, not a semantic authority
for arbitrary language. Summaries remain lossy; retrieval provides access to
the exact retained evidence rather than pretending every detail fits the context.

## Verification

The new tests use private state/workspaces and a deterministic local HTTP/SSE
provider. They do not contact a hosted model or use real user chats as fixtures.

| Scenario | Observed result |
| --- | --- |
| Fact in the middle of omitted history | Exact fact recovered through search and message paging; five main HTTP requests, one summary request; original accepted text retained |
| Active goal needs an unavailable fact | Waits, resumes on an ordinary reply, writes the requested artifact and completes; five HTTP requests |
| Truncated, oversized, timed-out or stale summary | Existing checkpoint retained; successful summary retains constraints, current outcome and goal |
| UTF-8 paging, branch and internal-message isolation | Exact byte reconstruction and inaccessible-message rejection pass |
| Context selection across budgets and tool envelopes | Same cutoff as the previous algorithm, including complete and incomplete tool groups |
| 1,603-message optimized cutoff microbenchmark | Previous selector 147,843 µs; new selector 621 µs in one measured sample |
| Existing conversational flow | 16 HTTP rounds cover corrections, actual failed/passing checks, steering, queued follow-ups, Stop/resend, background chat and reload |
| Repeated full-conversation shutdown | Eight consecutive candidate runs exit cleanly after compaction and recall; scheduler shutdown before initialization and late admissions also pass |
| Native delivery fixture | Six streamed GUI deliveries over one reused connection; first paint before completion |

The previous conversation fixture still required a redundant closing-summary
round even though production already preserves a healthy final answer. Its
assertion now requires no additional summary request. Fixtures testing ordinary
task continuation explicitly disable automatic goals; separate goal fixtures
exercise that feature and its default setting.

Reproduce from the repository root:

```text
python aurora-opencode-pro/tests/run_architecture_checks.py goal_mode_contracts goal_ui_smoke compaction_validation long_task_context_contracts context_continuity_contracts history_preservation_contracts agent_workflow_contracts task_continuation_contracts scheduler_shutdown_contracts
python aurora-opencode-pro/tests/run_architecture_checks.py --release context_continuity_contracts
python aurora-opencode-pro/tests/test_history_recall.py
python aurora-opencode-pro/tests/test_goal_input.py
python aurora-opencode-pro/tests/test_input_recovery.py
python aurora-opencode-pro/tests/test_conversation_flow.py
python aurora-opencode-pro/tests/test_goal_send_contracts.py
python aurora-opencode-pro/tests/test_parallel_tool_batch.py
python aurora-opencode-pro/tests/test_provider_roundtrip.py --production
python aurora-opencode-pro/tests/test_latency_transport.py --delivery --release --vulkan
```

The two new HTTP tests accept `--executable PATH` for an isolated candidate.
Their result files record the tested executable hash, elapsed time and request
counts. The architecture runner records source and executable fingerprints.

These measurements establish local behavior and overhead for the stated cases.
They do not establish provider latency, visual correctness of arbitrary generated
artifacts, or removal of every reported long-transcript rendering stall. The
remaining actor/presenter migration is tracked in
`message-response-implementation-status.md`.
