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
The newest pending repair survives a constrained control-history boundary until
a tool result or new human instruction takes over. Compaction retains the actual
user request when the remaining history contains only internal instructions, so
the next provider request has a conversational turn and the current repair.

Provider recovery defaults to persistent retries. Transport failures use a
3–30 second backoff. Authentication, unavailable routes and quota errors without
a reset time are checked at a slower 60-second cadence, with the reason visible.
A stated quota reset is honored. `AURORA_PROVIDER_OUTAGE_MS` can explicitly select
a finite outage budget; zero retains the persistent default. A finite transport
request exhausting its quick attempts cannot exhaust a persistent conversation.
Retries cannot make an invalid credential valid or make an offline service work.
They preserve pending work and automatically resume when the dependency recovers.

Tools always report their failures to the agent. Repeated identical read/search
results first produce a specific strategy reminder. Repeated ignored reminders
temporarily focus the next implementation decision on a command, behavioral
check or edit. Where available, the focused step uses tracked `verify` commands
and edits; direct program file viewers cannot bypass it. Already-passed checks on
unchanged inputs do not reset recovery. Normal inspection returns after a real
edit, new check result or a checker failure;
read-only diagnoses retain their inspection tools. Existing process
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
Python's interpreter-only `-B` flag does not create a different checker identity.
A validated `goal_complete` in the current turn leads to a final response with no
further tool audit; a later human request receives its normal tools.

Requests to calculate a value are analysis, including applying a discount or
adding shipping. They do not require creating an artifact solely to obtain a
verification receipt. Explicit requests to save or implement still own delivery.
JSON response-field names such as `repair` and `test` cannot authorize changes.
Explicit global no-edit instructions keep research and diagnosis read-only even
when they ask to resolve conflicting claims or execute a failing reproducer.
A subsequent explicit implementation request can lift that restriction.

A passing inline Python parameter-table revision can correct generated expected
values while resolving the original failed check. Every original input tuple,
the assertion body, imports, interpreter arguments and surrounding guards must
remain. Unrelated checks, dropped cases and weakened assertions do not qualify;
unsupported syntax keeps exact command matching. Original failures and revised
executions both remain in the transcript.
Equality assertions can also revise a typed literal expectation while retaining
the assertion subject, operator and every other line. Removing assertions,
changing their subjects or relaxing a comparison cannot resolve the old check.
Parameter tables also support literal nested argument tuples and generator-based
comparisons. The original calls and comparison logic remain required.
Receipt revalidation uses the same ownership rule as initial verification:
plain task directories own their descendants, while external paths and nested
Git checkouts remain excluded. Cleanup outside declared inputs preserves valid
proof; changed verified bytes and saved recipes still invalidate it.
For other erroneous model-generated inline checks, `verify.check_revisions`
records the failed call ID and correction rationale alongside a passing current
behavioral check covering every original input. Native settlement validates the
correction before the outcome ledger accepts it. Named tests, saved recipes,
unrelated inputs, stale proof and invented IDs cannot use this path. Failures,
correction reasons and replacement executions all remain logged. Recovery with
an unresolved ledger gap requests an action or check correction before a final
reply, rather than inviting the same completion claim again.
Repeated identical inspection in an implementation task focuses the next decision
after its first recovery reminder. Read-only work keeps its inspection tools;
new edits, meaningful checks and concrete execution failures update recovery.
Explicit independent numerical questions about local Python code require a safe
read-only probe of that implementation, keeping observed results separate from
the requested rule. A calculator expression copied from intended behavior is
not an observation of current code. This adds no artifact or verification recipe.
Simple questions, supplied arithmetic, explicit no-execution requests and
execution-disabled reviews retain their lightweight paths; unavailable execution
is reported as a limitation rather than becoming an endless analysis retry.

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
The provider credential stays in proxy memory; logs contain fault metadata and
request fingerprints. The proxy remains on loopback and preserves the hosted
wire profile. Three identical requests that omit the pending repair, or a
system-only task request, fail the run. Saved snapshots can lag the runtime;
a newer repair for the same cause supersedes the saved marker. Mismatches retain
the actual request body and marker metadata for diagnosis, without credentials.
The harness enables the native `AURORA_TOOL_ROOT` boundary, omits self-maintenance
and desktop tools, and fails sustained identical-observation loops. Its progress
boundary uses actual workspace bytes and independently passed milestones, so
program viewers and redundant checks cannot reset the loop detector. This boundary
checks structured tool paths; arbitrary programs are not an OS sandbox. An
unconfigured developer source cannot make an unrelated task invoke Aurora's own
rebuild tool.

```text
python benchmarks/live_goal_resilience.py --live --output ABSOLUTE_NEW_OUTPUT_DIRECTORY --timeout 1800
```

Run from the application package with an already built application and configured
remote provider. This consumes real provider usage. Artifacts include the entire
isolated conversation, fault log, progress timeline, independent final verifier
output and machine-readable result. A failed run is retained; it is never counted
as a pass after an intervention or an acceptance-checker edit.

The broader opt-in matrix measures simple conversation, decimal calculation,
unknown-fact lookup, small edits, implementation boundaries, code review,
read-only failing-test diagnosis, primary-source and conflicting-source research,
multi-turn scope, native download/archive/data/checksum/background processes, and
a verified project goal. Real source/command/provider failures are exercised.
Independent checks own correctness; efficiency budgets are reported separately
and never cut off productive execution. Each isolated case receives only its
declared user request(s), without continuation or repair hints from the runner.

```text
python benchmarks/agent_task_matrix.py --live --output ABSOLUTE_NEW_OUTPUT_DIRECTORY --jobs 3
```

Use `--cases NAME ...` and `--repeats N` for repeated comparisons against the
same built executable. Reports retain binary/source hashes, provider timing,
tool counts, repeated results, final state, replies, grounding checks and
workspace hashes. Source outages use controlled HTTP documents; primary-source
research fetches the actual public Python and SQLite documentation.
