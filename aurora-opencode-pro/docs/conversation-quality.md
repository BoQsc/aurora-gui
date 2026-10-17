# Conversation quality

The current request and its durable task have separate intent and identity.
Questions and investigations preserve the parent objective, plan and work position without resuming implementation. Explicit task switches
archive the old contract and start fresh requirements. Completed tasks get a new
objective on the next action request. Continuation can restore archived work.
Intent recognition is conservative local English parsing; the full instruction
remains available to the model. It is not a general natural-language classifier.

Plans keep stable IDs, acceptance conditions (`done`), categories, evidence and
blockers. Updates preserve omitted metadata, restore omitted completed steps in their original relative order, and reject dropped unfinished
outcomes at every plan size. Completed steps need compatible successful tool
evidence. Verification steps additionally need an accepted current check.
Unfinished substeps prevent parent/task completion. A short living plan is the
default for meaningful multi-step or ongoing work. Steps adapt at phase changes
and detours while preserving objectives and completed outcomes. Direct answers,
quick exploration and single edits need no plan. Plan maintenance is advisory:
missing a plan never pauses normal tools or adds a completion round. Strict
checklist enforcement requires an explicit opt-in.
New outcomes are appended after existing items automatically, even when the
model submits them at the beginning or in the middle. Their relative order is
preserved. Tool feedback reports the applied order. Explicit user-directed plan
replacement can establish a new order.
Existing plans require an explanation for additions, changed acceptance,
reordering, or pausing/skipping unfinished work. Normal completed-to-next progress
needs no explanation. Completed outcomes can reopen only with an explicit
`reopen_steps` ID and a reason; their old completion evidence is cleared. Stable
IDs cannot silently change, duplicate outcomes are rejected, and completed
acceptance cannot change while remaining checked. Reasons accompany durable
decisions; an explained focus switch retains the paused outcome's return point.
Entering editing or accepted verification prompts early internal reconciliation
when the active item still describes an earlier phase. Reminders stay bounded
and do not block tools, ask permission, or tick work without evidence.
An accepted optional check also records a passed verification result, so an
explicit verification outcome can complete even when no code change required it.
Action evidence and required verification remain necessary. Evidence shows what executed;
it cannot establish that a model chose complete behavioral assertions.

`update_plan.work_context` records the current action, next action and a detour's
reason, completion condition and return point under its stable parent step ID.
This context survives storage, copies, branches and compaction, and resets when
the active outcome changes. Nested work follows its parent's stable ID across
renames and reordering. Original requested outcomes accompany model-written
objective summaries so compaction cannot silently narrow the scope.

An empty action task cannot settle merely because the model said it was done.
Stagnation resets on newly supported evidence or accepted verification, not the
number of checked rows. Stalled replies trigger recurring diagnosis changes;
tools without new findings/effects get a recovery checkpoint every sixteen calls.
Neither limit ends authorized work or asks the user to restart. Exact repeated
calls remain suppressed; unusable output recovers with a different action.
Verification guidance names accepted checker formats and saved recipes so a
testing choice does not become a request for user intervention.
Analysis checkpoints request supported findings and never steer toward edits.
Native implementation tools reject analysis-only requests. Delegated work uses
the same completion gate and reports application-recorded evidence to its parent.

`request_input` replaces the advertised blocker tool. It accepts one essential
user-owned fact only after the agent records inspected sources/alternatives and
finishes independent work. Permission-to-continue questions and external-error
reports are rejected with recovery guidance. Genuine absent information remains
`waiting_input`; it is never certified as completed. A supplied fact resumes the
same objective. The legacy `task_blocker` name follows these same rules.
Provider/account outages and unavailable essential facts cannot be solved by
removing a completion gate; failures and incomplete work remain honestly recorded.

Task metadata survives normal storage, journal replay, copies, compaction and
branch selection. Earlier contracts and transcripts are retained. The active
plan's acceptance condition is available in its objective tooltip. Structured
constraints, decisions, rejected hypotheses and evidence accompany compaction.

New settings default to Concise. Explicit existing verbosity choices are kept.
The base prompt also requests concise, useful progress and final answers.
Verbosity controls visible language independently of reasoning effort. Tool
batching, the stable prompt prefix and image retirement remain supported.

## Verification and measurement

`tests/conversation_quality_contracts.d` covers intent, scope switches,
questions/blockers, unsupported completion, evidence reuse, short-plan loss,
pending substeps, persistence, replay, branches, tool-loop stagnation and a
5,000-message performance fixture. Its timing measures local decision overhead,
without provider requests.

Run the existing HTTP/SSE suites for actual scheduler, UI and transport behavior:

```text
python tests/run_architecture_checks.py plan_consistency_contracts conversation_quality_contracts task_continuation_contracts task_policy_contracts early_plan_contracts tools_test history_preservation_contracts
python tests/test_conversation_flow.py
python tests/test_task_continuation.py
python tests/test_task_diagnosis.py
```

The opt-in live evaluation exercises analysis, implementation, a question and a
constraint-preserving correction in one conversation. It independently checks
artifacts and records resolution, model requests, tool calls, available token
usage, answer length and end-to-end latency. Question-line counts are a heuristic
for unnecessary questions, not a semantic judgment. Live latency includes the
provider and network and must not be presented as local client overhead.
It also requires accepted verification, completed task state and at most 100
words per reply. `--headless-loop-json` frames settled replies independently of
model-authored markers; live runs do not depend on the model repeating a sentinel.

```text
python benchmarks/conversation_quality.py --live
```

Use the same executable/model route, prompts and repetitions for comparisons.
One passing run establishes no universal model-quality or latency guarantee.
