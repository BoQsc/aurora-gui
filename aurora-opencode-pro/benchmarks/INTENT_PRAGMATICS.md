# Intent inference: pragmatic understanding probe

`requestintent.requestIntent` parses an utterance. `resolvedRequestIntent` turns
that parse into a turn intent using the session's work state. The turn intent is
not advisory: it decides whether tools stay available, whether a paused goal
resumes, whether evidence is required, and what the model is told about the
current request.

Run the probe from the package root (deterministic, offline, no app launch):

```text
dmd -Isource -i -of=tmp/intent_pragmatics_probe.exe benchmarks/intent_pragmatics_probe.d
tmp/intent_pragmatics_probe.exe
```

It does not assert a shipping contract; it reports mismatches so the gap is
visible and comparable between builds. It exits non-zero only when the harness
breaks.

## Result

| measurement | before | now |
| --- | --- | --- |
| natural utterances labelled correctly (62) | 20 | **62** |
| mismatches that remove requested work | 41 | **0** |
| bare imperatives recognised (80 verbs) | 9/9 listed, 0/72 unlisted | **80/80** |
| approval / hold / permission guard probes | 6 miss | **0 miss** |
| lookups kept a tool channel after a passed task | 3 miss | **0 miss** |

The old failure was one-sided: text the parser could not place became
`conversation`, which returns before any objective exists
(`source/auroraopencode/taskflow.d`), and `clarification` additionally told the
model the request "asks for an explanation" (`source/auroraopencode/contextpolicy.d`).

## Design

**Parse, then resolve.** `requestIntent` now returns two values that are not turn
decisions:

- `changeRequest` — the utterance asks for a change but carries no imperative it
  recognizes.
- `indeterminate` — no cue at all.

`resolvedRequestIntent(parsed, workActive)` maps them with the session's state:

| parse | work unfinished | nothing unfinished |
| --- | --- | --- |
| `indeterminate` | continuation | conversation |
| `changeRequest` | continuation | implementation |

`workActive` is an active goal, or an objective whose task is not completed.
`requestIntentName` still stores only the six turn values, so restored sessions
and older builds read the same contract.

**What counts as a change request without a verb**

- Capability frames: "can you X", "could you X", "is it possible to X", "would it
  be hard to X", "is there a way to X". A wh-word inside the sentence keeps it a
  question ("can you tell me what is left").
- Indicative-mood cues: "is too…", "needs to", "should be", "would be nice",
  "i'd like", "keeps…", "forgets", "jumps", "flickers", "hangs", "crashes",
  "is slow", "is wrong", "used to", "no way to", "always", "never",
  "from now on", "scrap that", "go back to", "roll back".
- Elided instructions: "same for …", "the other one", "the second one",
  "do 2 and 3", "do the same".
- Sentence position: a bare imperative does not need to be enumerated. This is
  what removed the vocabulary cliff — the verb list is no longer the boundary.

**Capability questions are split from fact questions.** "Can you support pasting
images" is a request; "does the updater support a rollback channel" is a
question. A wh-word anywhere keeps the utterance a question.

**Answer-only means "no code change", not "no tools".** The tool-free final
answer now requires an explicit explanation request or a question whose answer is
recorded state (`stateQuestionRequest`: left/remaining/status/steps/plan/goal/
progress/queue/summary/cost/tokens/turns/chats/objective/blocker). "what's in the
log?" keeps a read channel after a passed task.

**Guards.** Approval accepts delegation ("you decide", "up to you", "whatever you
think is best") and prefixed approvals ("sounds good, go ahead"). A hold is a
work restriction ("hold off", "hold on", "not yet", "don't do anything", "let me
check", "pause for now"), so an active goal stops instead of running on.
`permissionQuestionReply` matches phrases before the question-mark check, so "I
can do that if you want." is not recorded as a completed outcome.

## Deliberate limits

- A `changeRequest` and an unplaced statement both continue unfinished work; the
  model still sees the exact text and decides what to change. Starting a new
  objective from them was the earlier failure mode.
- An `indeterminate` message does **not** resume a paused goal
  (`source/auroraopencode/turnpolicy.d`); only an action intent or an approval
  does.
- Cues are phrase-level, not grammatical. "I can't reproduce it" reads as a
  change request, which mid-task is the conservative side.
- `paddedLower` drops sentence punctuation, not apostrophes, so "don't" and
  "i'd" stay intact.

## Guard rails

These contracts encode the safety cases a change here must preserve, and all of
them pass:

- `tests/diagnosis_intent_contracts.d` — a why-question authorizes the repair;
  accountability questions and explain-only requests stay answer-only.
- `tests/request_scope_contracts.d` — a correction resumes and invalidates a
  passed check; a status question does not take over the objective.
- `tests/conversation_quality_contracts.d` — action wording, hypothetical
  questions, negation and approved investigation.
- `tests/work_brief_contracts.d` — "can we improve" is work; "should we change"
  is a question.
- `tests/goal_settle_contracts.d` — an explain-only request withholds goal turns.
- `tests/agent_workflow_contracts.d` — planning and plan-evidence boundaries
  (requires tracked plan mode).
- `tests/execution_control_contracts.d` — recovery, the final-answer gate and
  approval of a finished investigation.

Run them with `python tests/run_architecture_checks.py <fixture>…`; all seven pass
on this build (`agent_workflow_contracts` needs `AURORA_STRICT_PLAN=1`).
