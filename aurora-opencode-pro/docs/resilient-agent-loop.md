# Persistent agent execution

The previous execution flow had independent ways to abandon work: a finite default
provider outage budget, terminal output-repair counters, ordinary task settlement
with a Continue instruction, storage admission failures, missing-operation failures,
and startup code that paused goals. A prose-only goal could instead repeat its
last answer indefinitely. The replacement separates task ownership from attempt
success, shares settlement/recovery across both execution owners, and schedules
retries as cancellable operations.

## Responsibilities

- `turnpolicy.d`: settle only delivered answers and achieved work, retain unfinished
  tasks, apply steering, preserve user-owned boundaries, and route child work.
- `agentloop.d`: choose a changing recovery action and backoff, detect unchanged
  observations, and learn context limits only from provider rejections.
- `conversationactor.d` and the desktop adapter: apply decisions, persist history,
  run effects after durable intent, supervise lost operations, and honor Stop.
- `retrypolicy.d`: persistent default provider waits, slower checking of failures
  that require external repair, provider reset times, and opt-in finite deadlines.
- `requestbuilder.d`: retain original history while excluding rejected output,
  preserving tool/result pairs, and bounding repeated recovery instructions.

A small task takes a direct observe/action/verify/answer path. A medium task may use
an advisory outcome plan. Long tasks retain the objective, decisions, evidence,
remaining outcomes and next action through existing durable task state and context
checkpoints. There is no tool-round cap. Passing checks are reused until a relevant
change invalidates them. Substantive edits reset a no-progress streak; changing
prose or planning alone cannot certify completion.

A retry is not a replay of arbitrary side effects. Completed tool results stay
available. A tool known not to have started may be requested again; a tool with an
unknown outcome is recorded as uncertain so the agent must inspect current state
first. No text-form invocation is converted to an executable call.

## Guidance used

The design follows the recommendation to keep harnesses understandable, connect
agent decisions to real environment feedback, and test tool interfaces in
[Anthropic's Building effective agents](https://www.anthropic.com/engineering/building-effective-agents).
The task-size guidance, preserved work state, incremental delivery and completion
checks draw on
[Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents).
Shared ownership, observable execution and repository-based verification follow
[OpenAI's harness engineering report](https://openai.com/index/harness-engineering/).
These are design inputs, not evidence that any finite implementation guarantees
completion under every provider, disk, operating-system or model failure.

See [recovery behavior and test commands](agent-output-recovery.md) for the actual
implemented guarantees and remaining external dependencies.
