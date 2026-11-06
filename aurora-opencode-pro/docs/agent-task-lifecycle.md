# Agent task ownership

Each chat retains its messages, selected branch, task archive and persistent goal.
Only the current task owns its checklist, acceptance and continuation. Earlier
unfinished work is recoverable context, not an instruction to keep running it.
The first message of a new chat becomes its persistent goal by default. A
question or analysis creates an answer goal that settles after the reply instead
of resuming unrelated implementation work.

| Input | Transition |
| --- | --- |
| Independent action without an active goal | Archive the current task exactly; start a task anchored to this request |
| Amendment to ongoing work, live steering, or answer to required input | Keep the task and its acceptance |
| New requirements during an active persistent goal | Keep the goal and unaffected requirements |
| Explanation or status question | Answer without resuming implementation |
| Why-question (diagnosis) | Keep the current task and continue investigating and resolving the cause |
| Continue unfinished current work | Resume that task |
| Continue after current work completed | Do not choose an arbitrary archived task |
| Explicitly resume a paused goal | Restore the task associated with that goal |
| Explicit new task while a goal is active | Archive the old task and pause that goal |

The request classifier recognizes explicit amendment references, not semantic
similarity. The full request remains visible to the model. Paused goal ownership
cannot turn a corrective action into a continuation of its obsolete checklist.

The bounded working context includes a small background-task index. `read_plan`
with `task_id` retrieves exact archived acceptance without activating it.
`read_history` continues to recover original messages. Compaction and branching
do not erase these records.

Earlier-turn control messages are omitted from provider requests when a new
human request arrives. They stay in saved history. Live tool rounds preserve
their existing prefix for provider caching; constrained windows retain the
existing bounded control-history retirement mechanism.

Verification must establish the requested behavior in its relevant execution
path. Headless/helper checks alone cannot establish live GUI behavior. Routine
execution and verification remain authorized; a repeated status summary is not
progress. Simple work needs no mandatory planning ceremony. Complex work uses
short outcome plans, and active goals retain their acceptance across changes.

## Regression evidence

`tests/request_scope_contracts.d` reduces the reported trading-to-fullscreen
chat to its conflicting ownership, acceptance and pause state. It also checks
background recovery, explicit goal resume, explanation, continuation, restart,
and active-goal amendments.

`python tests/test_request_scope.py` runs the shipping executable with isolated
state and a deterministic local provider. It exercises real plan, write, read,
input and persistence paths. On the previous 0.66.38 image it reproduced 14
requests, stale trading ownership and two stall errors. The expected corrected
flow uses 10 requests and completes the independent deliverable while leaving
the trading goal paused. This is a client lifecycle test, not an evaluation of
a hosted model's intelligence or the real game's fullscreen behavior.

The existing conversation HTTP test covers steering, failed-check recovery,
Stop/resend and queued follow-ups. The 32K long-horizon benchmark independently
checks package behavior, changing requirements, required input, compaction and
exact JSON recall. Neither replaces observing real user chats after delivery.
