# Agent upkeep and completion, 0.66.40

The recent saved chats exposed harness friction as well as model mistakes. A
player-export conversation contained five identical upkeep deferrals, and other
conversations repeatedly failed completion bookkeeping. This review used local
history read-only; conversations and their branches remain intact.

## Changes

- Both conversation owners now use `planprogress.d`. The newer conversation
  actor previously had no equivalent of the UI owner's upkeep reminders.
- Guidance arrives after all tool results in a batch are paired, on a mismatch
  between the current plan and editing/verification, or after ten tool results
  without parent-plan reconciliation. An unplanned investigation gets an early
  reminder. Guidance joins the next normal request; it adds no provider round.
- Reminder checkpoints live on the selected durable branch. Reload and actor
  replay preserve their budget. They participate in control-history retirement,
  so earlier-turn guidance cannot override a later human request.
- Updating a child plan no longer resets parent-plan upkeep. The harness never
  guesses that an outcome completed or manufactures checklist evidence.
- Default planning guidance does not reject useful inspection or edits. The
  explicitly selected strict planning mode retains its bounded preflight and
  upkeep gates. A plan can share a batch with independent useful tools.
- Simple answers and edits no longer receive contradictory mandatory-plan
  instructions. Substantial tasks still need early plans, timely reconciliation,
  preserved acceptance, and relevant verification.
- `goal_complete` now has consistent schema, executor and session policy:
  answer-only goals may omit tool evidence. Action goals still require actual
  recorded evidence, completed outcomes and current verification. Previously the
  executor rejected answer-only completion before session policy could accept it.

## Comparison informing the design

[Claude Code's documented loop](https://code.claude.com/docs/en/how-claude-code-works)
adapts context gathering, action and verification to the request, with steering
throughout. [Codex's long-horizon guidance](https://developers.openai.com/blog/run-long-horizon-tasks-with-codex)
uses persistent plans and milestone validation.
[OpenCode's agents](https://opencode.ai/docs/agents/) separate Build from Plan and
use separate maintenance agents. Aurora already has separate maintenance jobs;
this change repairs its own execution policy rather than copying a product's
feature list or changing providers.

These are architectural references, not a matched evaluation or evidence of
competitive parity. Deterministic provider fixtures establish lifecycle behavior;
they do not establish the quality of a hosted model's decisions on arbitrary work.

## Validation

`plan_progress_contracts` covers phase transitions, bounded reminders, replay,
child versus parent upkeep, preserved unfinished outcomes, control-history
classification, and native answer-only completion versus action evidence.
`early_plan_contracts` exercises actual widgets and native edits, including a
normal edit under a stale plan and opt-in strict gating. Existing plan, goal,
request-scope and compaction checks cover preserved task ownership and evidence.

`test_provider_roundtrip.py --actor` and `--actor-recipe` exercise real HTTP/SSE,
native tools, accepted checks, durable replay and branch preservation. They assert
that an already tracked edit does not get an unnecessary reminder and that moving
to verification does get one, within the same four normal provider requests.
