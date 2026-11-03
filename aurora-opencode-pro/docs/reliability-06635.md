# Focused reliability repair: 0.66.35

The reported repeated replies were separate automatic turns, not merely duplicate
rendering. Recent saved chats showed repeated hidden `Continuation request:`
messages after a paused goal and a settled reply. A second computer-use rescue
controller called `prepareContinue` and opened a fresh user turn, outside the
normal durable-task controller and its audit interval. Each cycle could produce
four more near-identical status replies. The current installed image identified
itself as 0.66.34, but included newer composer/provider changes from commit
44d448e and uncommitted lifecycle fixes; its SHA-256 was
`7fd18afcec8cd2be7cd91d6e101b2d906c9be2579ce8617ab3546ce62b08957d`.

This repair removes that second automatic controller. Durable task/goal
continuation, explicit Continue, Stop, user steering and queued follow-ups remain
with their existing owners. The existing uncommitted settlement fix is retained:
settled turns clear their flight and clock state before the missing-operation
watchdog runs. A desktop regression enables computer use with a paused legacy
goal, settles an unfinished conversational reply, then pumps beyond the watchdog
deadline and checks that no extra reply/request or error appears.

Short corrections such as `so fix it`, `just fix it`, and `i said to move to the
new tab page each` now classify as action requests. A legacy task originally
classified as conversation can advance to implementation. Previously the latest
correction could leave the task classified as conversation, settle without useful
action, then be reissued by the second continuation controller.

For a JSON-only request, delivery extracts one complete valid JSON object/array
from a prose or Markdown wrapper. It does not infer data, fix invalid syntax or
select between multiple candidate objects. The original provider output remains
in the message's persisted `providerContent` field; the delivered content and
future model context contain the requested JSON. Mixed prose/JSON requests retain
their requested format. This applies to the actual desktop completion path and
survives save/reload. It fixes the prior observed preface-before-correct-JSON case
without an extra model request.

At 32K, the old preflight reserved 40% of the window for output. Native tool
definitions consumed 35,696 bytes before the system prompt and history. The
small-context projection now retains schema fields, types, required properties,
enums and constraints while removing nested descriptive prose and bounding tool
descriptions. It measures 22,295 bytes, freeing 13,401 bytes for working context.
Larger windows retain their full tool descriptions. Small windows reserve 20%
for output while retaining the conservative three-byte input-token estimate.
Checkpoint refinement also receives its actual reserved size instead of only a
1,200-word instruction that could produce an unusably large summary. Identical
goal/request/outcome text is not repeated in the bounded task projection.
Within a small window, superseded internal task-state checkpoints are retired
from requests during the tool turn, rather than accumulating until the next
human message. Only synthetic control state is retired; the human instructions,
current tool batch, current state and full saved graph remain intact. This trades
some prefix-cache continuity for usable working memory in a constrained window.

The live benchmark had a configuration flaw: after the selected GUI model
changed, a 32K override could be assigned to that GUI model while the console
used another route. The harness now configures the saved model and both console
aliases, and reports the actual persisted model/thinking state. The initial
misconfigured run is excluded. With the override actually applied, the installed
baseline repeatedly read the same inputs and timed out in stage one after 300
seconds. Intermediate candidates are retained, including insufficient schema
reductions and headroom changes without internal-state retirement; passing
fixtures alone were not accepted as task completion. One full 57-fixture run
passed before the final internal-state-retirement change. Final-source checks
and rebuilt-image results are recorded separately.

Final rebuilt-image task results, recorded request budgets, independent artifact
and API checks, regression logs, rejected iterations and delivery provenance are
kept under `build/reliability-06635/`. The live task is the same billing scenario
with changing requirements, customer-owned facts, Decimal/UTC/refund boundaries,
CSV delivery, compaction and exact JSON recall. User chats and their history were
not edited or deleted.

The observed production latency sample separated about 23 ms of request
admission from about 1.8 seconds until the first provider token, with about 1 ms
from first token to application. That sample does not establish sustained decode
speed or a general latency improvement. Large histories, provider load and
reasoning can affect throughput; this repair makes no provider-speed claim.
