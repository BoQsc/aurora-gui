# Agent output recovery

When tools are enabled, Aurora detects repeated prose and XML invocations of
offered tools printed in the answer channel. Fenced code and quoted examples
remain ordinary text. Printed invocations are never converted to executable
calls. Detection covers growing streams and settled responses, including a
single complete invocation with no structured call.

The failed response stays in the saved chat for diagnosis but is excluded from
subsequent provider requests. Aurora retains tool schemas and successful tool
results while requesting a valid action or supported answer. Recovery can route
to the configured diagnostic reviewer. Three consecutive unsuccessful recovery
requests expose a provider failure while retaining the active goal and saved
work. Useful successful tools reset the counter; plan chatter does not. Stop
still cancels execution.

Whole-answer replays with only a small addition also use this recovery path.
For llama.cpp, folding a trailing system continuation now adds a wire-only user
boundary, avoiding accidental prefill of the preceding assistant answer.
Hosted providers retain chronological instruction messages.

The 2026-11-02 source work also detects short repeated goal replies and repeated
goal audits without useful action. Useful work no longer hits a 64-turn goal
cap. Output recovery preserves the active goal; it does not silently convert
provider failure into a user pause. A new human instruction opens a fresh
recovery boundary. These changes are not yet deployed.

Provider outage recovery and terminal resend now share typed policy decisions.
The configured outage budget also bounds backoff; an exhausted provider attempt
cannot restart through UI resend. Explicit reset-time waits and manual Retry
remain available. Provider failures retain the persistent goal. Verification-only
work changes diagnosis after stalled attempts instead of silently settling with
checks outstanding. Goal completion rejects invented and failed evidence IDs.

A local HTTP fixture reproduced 68 requests when its provider wrote and checked
the requested artifact but kept answering `READY` without `goal_complete`.
The corrected path settles after eight main requests with a visible provider
failure and the goal still active. The ordinary task explicitly disables goals
and completes in four requests. Optional title generation waits for the opening
request's durable admission, then can run between requests during a long task.

The identical-call limit counts executions since the latest real user
instruction or successful file mutation. Source edits, including comment and
whitespace changes, release an identical build command. No-op and failed edits
do not release it.
An exhausted call is skipped and recovery requests a different action or
hypothesis. Its repeated effects are never executed, and its limit does not
terminate the user's whole plan.

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

## Offline checks

From the repository root:

```text
python scripts/check-opencode-agent-loops.py
python scripts/check-opencode-agent-loops.py --snapshot C:/path/to/chat-snapshot.zip
python scripts/check-opencode-chat.py --pro
python aurora-opencode-pro/tests/test_provider_roundtrip.py
python aurora-opencode-pro/tests/test_provider_roundtrip.py --goal-stall
python aurora-opencode-pro/tests/run_architecture_checks.py output_recovery_contracts
```

The first check uses a local HTTP/SSE fixture and separate test executables.
It verifies recovery, no execution of printed XML, continued recovery after repeated
failure, prose-loop recovery, replay detection, diagnostic redaction, and build
guard resets. The optional snapshot replays the three identified archived
responses. These checks do not contact a model provider or replace the live app.

The goal variation checks preserved verification and goal status, paired tool
results, persisted reload, and twelve actual stalled-stream cancellations. The
pure recovery fixture covers changing prose, plan chatter, new user boundaries
and 100 useful goal continuations.

Latest goal HTTP proof: `build/architecture-checks-zn397i0i/`, source fingerprint
`3d81653690efea4b05f2b8897de84c63e879d4d4ec9359dc150103b9eea7cf2b`.
The legacy HTTP loop driver also passed: three requests for recovered XML,
four for repeated malformed XML followed by a usable response, and two for
prose recovery. Compaction validation passed on the same source fingerprint in
`build/architecture-checks-salqczf7/`.

All 37 default architecture fixtures passed in `build/architecture-checks-26xxct18/`
on that fingerprint. After the verification-continuation and queued-message ID
fixes, task, policy, native headless and goal UI checks passed in
`build/architecture-checks-_9fw6k9j/`; the 16-round HTTP conversation scenario
passed in `build/architecture-checks-6fw7s2sx/`, fingerprint
`a62fd91debf0528637629afd3d6eed426039284778099fba247a9b8d7d25cdaa`.
The real HTTP transport proof in `build/architecture-checks-8w9d05af/` verifies
one request for a 100 ms busy budget, three attempts for repeated 503s, typed
exhaustion, cancellation and connection reuse.
