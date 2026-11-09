# Agent output recovery

Aurora detects printed tool invocations and no-progress replies while tools are
available. Fenced examples remain ordinary text; printed invocations never
execute. Malformed responses stay in saved history for diagnosis and are excluded
from later provider requests.

Desktop and conversation-actor execution use one bounded recovery budget: three
consecutive unsuccessful repairs. A task or goal audit starts a fresh interval
through its recovery marker, preserving the budget. Useful successful tools and
new human instructions reset it; plan chatter does not. Stop still cancels work.

Recoverable task/goal audits retain the original reply without adding a failure
bubble. They continue the specific unfinished work using ordinary tools. There
is no separate idle hold, automatic goal pause, or extra goal-completion audit
protocol. If repairs keep producing no progress, Aurora reports an explicit
failure while preserving the task, goal and history. The session server reports
an unexpected post-start idle state as `turn_stalled`, not `turn_not_started`.

Completed plans and current accepted checks trigger a short outcome check in the
existing final request. It keeps the exact user's triggers and constraints in
view; it adds no separate review request and does not restrict tools. The model
must close any actual missing behavior, then answer without additional audits.

Exact-call suppression is removed. Repeated process polls, fresh file reads and
useful mixed batches execute normally. Repetition diagnosis compares actual
source facts rather than changing search headings. Distinct substantive edits
and accepted checks count as progress while a plan step remains active.

Ordinary chats do not create a persistent goal automatically. Explicit goals
still finish through `goal_complete`; a summary that declares outstanding work
cannot certify completion. Old audit markers remain readable in saved history.
The selected context target and full saved message graph remain intact.

## Provider diagnostics

Start Aurora with `AURORA_PROVIDER_TRACE=1` in its environment to capture opt-in
request and SSE evidence in the normal `logs/errors.log`. Entries have the
`provider-wire` prefix, request ID, selected model, and request/SSE kind. This
shows whether invocation markup arrived inside `delta.content` or a provider
returned actual `delta.tool_calls`. `agent-output` entries link failures and
recovery decisions to the request and thread.

Headers are omitted. The configured API key, known credential fields, and
inline data URLs are redacted. Text fields are limited to 2 KiB and each
request to 128 KiB; the normal log rotation still applies. This is a diagnostic
sample, not a complete raw capture. Other conversation and tool text can remain
in the logs, so inspect them before sharing. Tracing is off by default.

## Validation

Local HTTP/SSE tests cover native calls, paired results, streamed argument bursts,
cancellation, four-round normal settlement, and bounded task/goal recovery.
A varying-prose goal stalls explicitly after eleven main requests; it does not
return silently to idle. The ordinary task uses four requests.

```text
python aurora-opencode-pro/tests/test_provider_roundtrip.py --actor --stream-tools
python aurora-opencode-pro/tests/test_provider_roundtrip.py --goal-audit-stall
python aurora-opencode-pro/tests/run_architecture_checks.py output_recovery_contracts goal_hold_contracts checked_run_contracts
```

These lifecycle fixtures complement the real-provider isolated tasks documented
in [the execution-flow report](agent-execution-flow-06643.md). They do not measure
hosted-model reasoning quality or end-to-end task speed.
