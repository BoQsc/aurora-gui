# Agent recovery

Completed tool batches that cannot fit with their provider-required reasoning
are projected as exact quoted execution data, retaining call IDs, arguments,
results and failed status. The complete original protocol exchange stays saved;
an incomplete tool batch is never rebased. This avoids losing every fresh file
when a large write or multi-read batch overflows a small context window.

Native reads and writes may attach a source byte identity. Source memory can
retain multiple observed ranges and confirmed written text. After unrelated
artifact changes, it reuses a resource only if its current complete bytes match
the native snapshot. External changes, failed refreshes, unknown identities and
out-of-root resources remain conservative. Snapshot metadata supplies no
behavioral verification. Memory uses the available context after reserving the
fresh batch, and the first checkpoint includes newly retired source immediately.
Repeated-inspection reminders are advisory and retain every ordinary tool.
Byte-validated entries explicitly identify their freshness at request preparation;
a complete stamped read supersedes older ranges of the same file. Unresolved
failed-check commands appear during normal work, so the agent can fix and batch
them before attempting completion. Large commands remain exact in saved history;
the enforcing ledger is never shortened or waived. Filesystem-host IPC lives in
application state, separate from the task's temporary files and inventories.
Confirmed write bodies and exact source excerpts are language independent,
including Markdown, Godot scripts, TypeScript and CSS. Legacy unstamped writes
still supply only their old declaration-level context, never invented file bytes.

Read-only diagnosis retains intentionally failing test receipts as observations,
without requiring an unrequested repair. Implementation checks and mutations
still require verification. Numerical answers distinguish a test's observed
assertion expectation from the independently computed required result: only
explicit assertion-expectation fields can use an expected literal from a real
read of the requested test source; computed values still require calculation
output. Comments, examples, assertion inputs and receipt metadata supply none.

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
Recovery explicitly distinguishes a reconstructed function in `python -c` from
executing the referenced module. It asks the agent to replace the copied
definition with an import and reuse its inputs and independent expected formula.
The existing module-execution requirement is unchanged.
Simple questions, supplied arithmetic, explicit no-execution requests and
execution-disabled reviews retain their lightweight paths; unavailable execution
is reported as a limitation rather than becoming an endless analysis retry.
A literal built-in dynamic import followed by a function call counts
as execution of the named module; importing it without invoking a function does
not. This prevents a valid observed answer from entering completion recovery
because the probe used a different Python import spelling.

Successful numerical probes are reused when they agree with the inspected code
and inputs; changed sources, inputs or concrete contradictions still justify
further checks. A small source-and-output handoff keeps the successful probe
beside the answer contract without removing tools. It also quotes the actual
probe command so expected formulas can be compared with the original rule's
components, exclusions and operation order. Executing a formula does not prove
that it implements the requested rule. A corrected relevant probe supersedes
an earlier incorrect expected calculation; it does not pin the original error.
A difference from the required rule alone is not a reason to debug imports or
the interpreter.
Concrete failures and changed sources clear that handoff.
The same probe computes and labels requested expected values
independently from the original rule. Decimal-string and integer JSON claims
must also appear in successful calculation output; arguments, expression text,
receipt metadata and failed tools do not provide that evidence. Decimal identity
is exact, including equivalent exponent notation, without a float tolerance.
Unavailable execution and unsupported floating JSON serialization retain their
existing reporting paths. Read-only answers do not acquire a plan-creation reminder from
tool count alone.

Rolling context checkpoints retain small source observations with their actual
call IDs and quoted output. Known writes/edits invalidate the affected snapshot;
unknown workspace changes invalidate the set. These are historical context, not
freshness claims or verification receipts, and never remove inspection tools.
failed tracked checks retain local observations only when native before/after
snapshots prove the complete bounded workspace byte-identical. The failed check
remains unresolved and supplies no passing receipt. Partial effects, files or
directories outside declared checker inputs, incomplete snapshots and references
outside the observed workspace remain conservative. Program output cannot claim
that the workspace is unchanged.
Successful Python writes also retain explicitly labeled requested declarations;
oversized Python reads can retain observed declarations. These small outlines
preserve API names through compaction without pretending to retain full bodies
or to establish behavior. Failed rewrites invalidate the earlier outline.
User-named sources take priority under context pressure and retain the scoped
authority the user gave them; quoting a delegated specification does not retire
its acceptance criteria.
Fresh tool batches take priority over this optional memory. Allocation reserves
the complete latest envelope and rolling-checkpoint space first, so retained
context cannot displace a new source result that would otherwise fit. Live
request observations record tool-result byte counts/hashes without content or
credentials, making projection loss visible.
Failed-check recovery supplies the actual pending program and arguments rather
than requiring reconstruction from a call ID. Named checks still have to pass;
the inline-hypothesis correction path is suggested only when it is applicable.
Repeated failures of the same named invocation share one recovery description,
with every original call ID retained. The failure ledger and rerun requirements
are unchanged; the control context no longer repeats the whole instruction for
each unsuccessful attempt.
For a multi-step recipe, only its failed step is pending; earlier successful
steps are not turned into fresh obligations by the recovery note.
Plan updates do not consume that source result or move its protection window.
The default architecture checks include these source-retention and numerical
grounding regressions.
Compact tool schemas preserve timeout units, cursor indexing, checked-run mode
and receipt-input requirements. Read-only numerical probes use an ordinary run;
checked runs still require their actual declared inputs. Successful research
fetches are reused for unchanged facts; redirect/network diagnostics need a
concrete evidence or freshness gap. Context byte
budgets do not impose a limit on productive tool use.

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
The numerical review compares exact two-decimal text for string or numeric JSON
values, as its prompt specifies string keys rather than a value type. Incorrect
values, missing precision, exponent notation and extra keys still fail.
Buffered unittest execution may report its actual TestResult failure/error
counts instead of printing a traceback. The observer ties those printed counts
to the real runner result and named test loader; literal counters do not qualify.
For goal-duration measurements, `AURORA_MATRIX_WAIT_FOR_GOAL=1` retains the
existing time target as an explicit overrun flag and keeps observing until
native completion. It sends no Continue or extra prompt and does not waive loop
detection, user-input detection or the independent final checks.
