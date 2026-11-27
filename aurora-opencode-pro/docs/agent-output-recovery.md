# Agent recovery

Desktop and conversation-actor execution use the shared decision in `turnpolicy.d`
and the recovery strategy in `agentloop.d`. Failed attempts retain ownership of
unfinished work. There is no default attempt or outage deadline. Explicit Stop,
user pause, access restrictions and explicitly selected Plan mode remain binding.

Malformed tool markup, including inline and truncated DSML, never executes.
Protocol failures are recorded in history and logs. Recovery requests exclude
rejected markup and superseded no-action prose, preserve paired successful tool
results, and rotate concrete repair strategies. Repeated unsuccessful responses
back off to 30 seconds instead of spinning. Only the latest repair directive is
sent after a failure-only streak; the full saved graph remains intact.

Provider recovery defaults to persistent retries. Transport failures use a
3–30 second backoff. Authentication, unavailable routes and quota errors without
a reset time are checked at a slower 60-second cadence, with the reason visible.
A stated quota reset is honored. `AURORA_PROVIDER_OUTAGE_MS` can explicitly select
a finite outage budget; zero retains the persistent default. A finite transport
request exhausting its quick attempts cannot exhaust a persistent conversation.
Retries cannot make an invalid credential valid or make an offline service work.
They preserve pending work and automatically resume when the dependency recovers.

Tools always report their failures to the agent. Repeated identical read/search
results produce a strategy reminder without suppressing calls. Existing process
polls remain legitimate work. Unknown mutation outcomes require inspecting current
state before another mutation; this system does not blindly replay tool effects.

Storage failures preserve accepted prompts, attachments, steering and follow-ups.
The actor keeps an ordered retry queue and fences effects until preceding intents
are durable. The desktop retains a scheduled continuation through storage recovery.
A missing operation restarts from durable evidence. Recoverable reducer exceptions
fence old effects and preserve uncertain results instead of destroying the actor.
Fatal runtime errors and process termination still require process restart.

Ordinary planning is advisory. Parallel steps and parent/child status updates do
not block tools. Current verified delivery can reconcile stale advisory plan rows;
required work items, failed checks and unmet goal summaries still prevent false
completion. Explicit strict planning retains its additional validation. Ordinary
chats have no goal-completion ceremony. Persistent goals finish through validated
`goal_complete`; automatic retries cannot pause or complete them. Restart resumes
saved active work even when a supervisor note was not written. User-paused goals
remain paused.

A checker that ran successfully but lost its input snapshot is rejected proof,
not a failed behavioral assertion. It still requires current verification.
Once a current behavioral check passes, the earlier invalidated receipt cannot
reopen a completed goal. Actual failed steps remain obligations until rerun;
an unrelated passing check cannot conceal them. Both kinds remain in history.

## Diagnostics

`agent-lifecycle` records correlate requests, recovery schedules, storage recovery,
missing operations and reducer exceptions by conversation and request. Output
failures also have `agent-output` entries. Errors remain visible while the owning
turn continues. No recovery depends on enabling optional wire tracing.

`AURORA_PROVIDER_TRACE=1` enables redacted, bounded provider request/SSE samples in
`logs/errors.log`. Headers are omitted; configured keys, known credential fields
and inline data URLs are redacted. Text fields are limited to 2 KiB and each
request to 128 KiB. Other conversation/tool text can remain: inspect before sharing.

## Validation

The deterministic HTTP/SSE harness injects five consecutive malformed DSML replies,
empty replies or provider failures, then performs real native file work and a
behavioral check without user intervention:

```text
python aurora-opencode-pro/tests/test_provider_roundtrip.py --repair-output
python aurora-opencode-pro/tests/test_provider_roundtrip.py --actor --repair-output
python aurora-opencode-pro/tests/test_provider_roundtrip.py --empty-output
python aurora-opencode-pro/tests/test_provider_roundtrip.py --actor --empty-output
python aurora-opencode-pro/tests/test_provider_roundtrip.py --outage-recovery
python aurora-opencode-pro/tests/test_actor_recovery.py
python aurora-opencode-pro/tests/run_architecture_checks.py resilient_loop_contracts goal_rebuild_contracts
```

The actor fixtures also cover exact replay, access restrictions, ordinary task and
goal stalls, Stop, explicit outage deadlines, storage failure/recovery and retained
input. These finite fault-injection tests establish the tested recovery paths;
they do not guarantee model quality or progress during every external outage.

The opt-in live-provider scenario submits one six-milestone billing goal through
the native session server. Successful responses come from the configured remote
provider. It injects three initial 503s, two mid-goal 429s, a truncated real SSE
response, three late 502s and three real command exits with status 75. It requires
all deliverables, 71 independent final checks, persisted goal and turn completion,
and no input requests or Continue messages. Completion-only loops fail the run.
The provider credential stays in proxy memory; logs contain fault metadata.

```text
python benchmarks/live_goal_resilience.py --live --output ABSOLUTE_NEW_OUTPUT_DIRECTORY --timeout 1800
```

Run from the application package with an already built application and configured
remote provider. This consumes real provider usage. Artifacts include the entire
isolated conversation, fault log, progress timeline, independent final verifier
output and machine-readable result. A failed run is retained; it is never counted
as a pass after an intervention or an acceptance-checker edit.
