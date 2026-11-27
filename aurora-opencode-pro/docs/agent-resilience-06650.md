# Agent lifecycle replacement — 0.66.50

Desktop and conversation-actor settlement now share a persistent recovery loop.
An unsuccessful attempt schedules another operation with changing guidance and
backoff. The default two-minute provider outage deadline, terminal three-output
repair budget, ordinary-task Continue stop, missing-operation failure and silent
restart goal pause no longer abandon unfinished work. User Stop and explicitly
selected restrictions remain authoritative.

The implementation also replaces terminal actor storage admission with an ordered
persistence retry queue, retains uncertain tool outcomes for reconciliation,
repairs repeated context-limit rejection, filters broken output out of recovery
requests while preserving history, and keeps ordinary planning advisory. Goal
completion still requires real action evidence, current checks and no declared
unmet work; current verified completion reconciles stale advisory plan rows.

The reported inline/truncated DSML form is recognized as unusable output. It is
logged and recovered automatically; text-form calls are never executed.

## Verification

Native contracts passed for persistent recovery, output parsing, shared settlement,
goal completion/restart/holds, required work, advisory planning, long-task context,
queued input, continuation ownership, storage failure and recovery, tool/result
pairing, unchanged observations, process polling, current verification and chat
performance. HTTP/SSE fixtures recovered from five consecutive malformed replies,
empty replies and provider failures before completing actual file work and a
behavioral check. Both desktop and actor paths also completed a persistent goal
after malformed output without a separate plan-closing round. Actor traces replayed
offline to the same full state. Explicit Stop ended otherwise persistent recovery.

The full core `dub test` ran 49 modules: 48 passed. The unchanged vendor text-editor
clipboard round-trip assertion at `texteditor.d:1555` failed in this environment.
It is outside the execution-loop change and was not weakened or edited.

### Real provider tasks

The isolated app-path benchmark used the configured OpenCode gateway with
`deepseek-v4.1-flash`. Each task produced source that was independently compiled
and exercised with hidden behavior assertions after the agent settled.

| Task | Result | End-to-end seconds |
| --- | --- | ---: |
| Add and demonstrate clamp | Passed | 26.35 |
| Repair bounded counter and reset | Passed | 187.03 |
| Implement and demonstrate interval merge | Passed | 43.97 |

These are individual runs, including provider/network time, not a speed guarantee.
Token accounting was unavailable in this legacy benchmark report and is unknown.
An earlier candidate was interrupted after reproducing a real verifier defect:
non-Git project files were mistaken for separate checkouts. The fix accepts files
owned by a plain task directory while retaining nested Git and outside-path
isolation. A native regression now covers that case. The interrupted run was not
counted as a pass; its temporary credential state was removed.

Local performance fixtures separately measured UI work, including input-to-paint
on long replies and large diffs. Provider wait and generation are not counted as
client overhead. The HTTP round-trip fixture also records first-token-to-apply and
apply-to-paint timings. Release delivery verifies source provenance, rebuild,
relaunch and public binary download separately.

See [the replacement architecture and guidance sources](resilient-agent-loop.md)
and [recovery behavior and reproduction commands](agent-output-recovery.md).
Finite tests cannot guarantee model quality or progress while every available
external dependency is unavailable. Such failures remain visible with work retained
and automatic recovery pending; no success is fabricated to clear the goal.
