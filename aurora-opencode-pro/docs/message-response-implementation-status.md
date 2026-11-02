> Current work: [Agent continuity](agent-continuity.md) and
> [Long reply rendering](long-reply-rendering.md).
> [Storage and recovery](storage-recovery.md) records the current source work.
> The user's 2026-11-02 request reactivates the entire remaining migration below.

# Message-to-response migration status

Updated 2026-11-02. The full migration in `message-response-architecture-review.md`
is **not complete**. All seven remaining requirements remain in scope.

The subsequent transport/startup latency stage is documented in
`latency-improvements.md`, including its controls, timing evidence and deployment.

## Current path

Composer and steering commands enter `OpenCodeRoot`. Each conversation directly
owns its `ThreadEngine` execution state. Pure branch projection and the prompt
cache prepare requests; `ProviderAdapter` serializes them. Bounded provider workers
use shared asynchronous WinHTTP requests (with a WinINet compatibility option) and
feed a transport-independent `ProviderStreamDecoder`, then a bounded client queue.
A serialized native application service applies events and schedules tools.
Tool results return through the same queue. One repository owner orders journal
writes, partial checkpoints and dirty-thread snapshots. Asynchronous history
results and stable/deferred transcript rows reach markdown layout and paint.

Execution service advances during native resizing without widget ticks.
It still runs on the window thread: it is **not** an autonomous actor.

The source now also contains a standalone `ConversationActor`. It owns its
conversation graph, request preparation, provider drain, tool settlement,
durable admission and ordinary task/goal continuation on a separate thread.
The desktop has not switched to it. Adopting it before optional-feature and
command parity would lose behavior; that adapter remains required below.

## Implemented

| Boundary | Result |
| --- | --- |
| Execution state | Direct per-chat ownership replaces save/load field copying. A scalar deterministic request reducer tracks phase/correlation. Stop rejects late output; unknown/duplicate tool results are rejected. Delayed operations survive chat insertion/deletion. |
| Standalone owner | `ConversationActor` advances real provider/native-tool turns without any window or UI service. Its mailbox is bounded to 128 commands / 1 MiB, with separate Stop and snapshot signals. Immutable UI values are bounded to 256 changes / 1 MiB; overflow requests a full resync. One indivisible snapshot has its own slot. Physically running actor workers are capped by `AURORA_ACTOR_WORKERS` (default 16); Stop does not release a blocked physical slot. |
| Request and task policy | Context compaction, request assembly, turn decisions, tool-result validation and plan mutations now have separate modules. The root captures settings and applies decisions. A revision-keyed immutable request projection cache reuses full projections for suffixes, retaining complete tool envelopes and private caller arrays. Its 4 MiB logical budget includes omitted-history index entries. |
| Service | Round-robin native application service runs during resize, uses a soft six-millisecond budget and bounded drains, and retains unconsumed events in order. |
| Provider | Wire projection and stream accumulation/usage interpretation have separate modules. Shared asynchronous WinHTTP connections, isolated request cancellation and optional exact token preflight improve startup. Physically running requests have a configurable cap: `AURORA_PROVIDER_WORKERS`, default 16. A stopped worker retains its slot until it returns. Launch rejection is explicit. |
| Retry | HTTP recovery and terminal resend use the same typed policy and outage configuration: `AURORA_PROVIDER_OUTAGE_MS`, default 120 seconds; explicit zero means unlimited. Exhausted provider recovery carries a terminal flag, so the UI cannot restart its budget. Backoff is clipped to remaining time. Explicit quota reset waits and manual Retry remain available. A failed request preserves the persistent goal. |
| Orchestration | Routing values derive from recorded calls and settle into the owning conversation's batch. No process-global assignment/halt channel remains. Invalid participants, malformed partial batches and premature finish are rejected. `ask_user` shares the ordinary missing-information schema and validation. Stop revokes queued rounds/resumes and stops descendants; late child reports require live round membership. Productive handoffs have no eight-hop cap. |
| Delivery | Native notifications service stream queues without widget ticks; remaining bounded-drain work is reposted and paint gets a turn between passes. Soft 8 MiB / 1,024-event producer limits, cancellation wakeups and UTF-8-safe drains retain text and terminal events. An indivisible event or consumer control reserve can exceed the soft bound. |
| Tools | Shared four-worker scheduler, bounded pending queue, workspace read/write barriers and a global desktop lease. Captured computer routing is installed per worker. Leases remain held for physical effects. Queued, running, completed, failed, cancelled and resource-blocked states are explicit; terminal states survive snapshots and journal replay. Missing, duplicate and historically reused call IDs are normalized before ledger admission. |
| Verification | Recognized check identity, actual exit status, workspace and mutation generation. Recipe and direct receipts retain the checked revision; a delayed receipt cannot inherit a later mutation. Completion revalidates current scope even without an intervening service tick. Goal evidence must reference successful recorded results in the active task. Physical mutations invalidate older evidence even when Stop drops their late events. Rebuilding alone cannot satisfy unrelated checks. |
| Storage | One ordered journal owner, separate snapshot/history owner, cached metadata and asynchronous initialization. Startup receives decoded history and projected replay. Dirty snapshots, partial-response and compaction checkpoints preserve work. Copies journal their complete graph. Durability failure gates effects. |
| Native recovery | Before-images and an intent manifest are saved before native file effects. Completion retires temporary blobs. Death leaves an explicitly uncertain operation with preserved before-images; it is never automatically replayed or undone. Changes reports pending operations. |
| Attachments | Immutable content-addressed blobs replace repeated persisted base64. Concurrent writers use unique temporary files and validate the winning content. Missing/corrupt images retain references and appear unavailable; surrounding messages survive. Bounded maintenance conservatively retains every durable reference and process-live pin; corrupt, incomplete or oversized reference scans abort deletion. Legacy records remain readable. |
| History | Selection and internal actions load asynchronously. A bounded ID-based mailbox retains actions through loading and retry. Failed/missing history blocks Send; failed startup preserves original files even on close. Replay patches retain metadata absent from the journal tail. |
| Presentation | Settled rows are retained by identity/presentation inputs. Long pages use deferred descriptors, a height index, overscan and eviction. Tool groups retain cheap result metadata while collapsed and use a nested viewport presenter when expanded. Selection/search targets are pinned; search spans and lazily reveals the active branch. Wrapped code copies logical lines once and retains blank lines. |
| Diagnostics/prompt | Shared lock initialization, bounded asynchronous diagnostics, rotation and measurement sampling. Prompt identity includes module generation and current feature flags; repeated instructions were shortened. |
| Deployment | Apply through the existing self-helper. A per-build local publication switch preserves the normal publisher setting after the new app launches. |

## Proof

All six isolated fixtures passed for source fingerprint
`2cda78a6466cf4900b45465daf9a6cc9b09453305af412c5f5f00cfeca60d350`:

```
python aurora-opencode-pro/tests/run_architecture_checks.py
python aurora-opencode-pro/tests/test_provider_roundtrip.py
python aurora-opencode-pro/tests/test_parallel_tool_batch.py
```

Suite logs/results: `build/architecture-checks-500tpw_4/`.
Result JSON records source fingerprint, Git HEAD, executable hash, exit code and
elapsed time. Tests use private executables/state.

- Four actual HTTP/SSE rounds cover composer, durable plan, two native writes,
  a real Python unittest, paired tool results, final UI response and reload.
  Twelve stalled-stream cancellations release physical slots. Log:
  `build/architecture-checks-hm1x52cd/provider_roundtrip.log`.
- 140 real tool batches settle calls once and preserve mutation barriers.
- Forced process death preserves accepted journal intent and a partial reply.
  A separate native-mutation death preserves its before-image and uncertain intent.
- Native-resize integration advances two chats while widget ticking is suspended.
- Storage failure blocks effects and recovers after snapshot acknowledgement.
  Corrupt history blocks Send; corrupt images retain surrounding text.
- A 1,502-message transcript reveals an older match with fewer than 100 expensive rows.
- A separate 10,000-row presenter fixture constructs 134 rows across sampled
  scrolling positions. Latest cached software paint: median 47 microseconds,
  p95 55 microseconds. This is a short-row isolated fixture, **not** a production
  FPS or before/after speedup claim.

## Remaining required migration

1. Move full turn/task reduction, request preparation, continuation and effect
   coordination out of `OpenCodeRoot`. Give per-chat actors serialized command
   mailboxes and immutable UI change sets. Owned fields and the scalar reducer
   are foundations, not the completed extraction. The standalone actor now
   proves this ownership for ordinary tool/task/goal turns. Desktop command
   routing, attachment input/hydration, live tool progress, retry/failure
   recovery, title/model-compaction jobs,
   diagnostic/computer context, orchestration and exit/snapshot integration
   still need parity before replacing the existing service. Worker commands now
   cover Regenerate, edited prompts, Continue, branch selection, drafts and goal
   replacement. Implicit branch cancellation keeps the persistent goal; explicit
   Stop pauses it. Accepted edits survive a later Stop, and idle branch
   navigation retains the completed turn status.
2. Replay full recorded provider/tool traces. Shutdown/rebuild/update checkpoint
   barriers, journal admission, startup and internal history reads now avoid
   window-thread I/O waits. Replay
   full recorded provider/tool traces to the same transcript and task; the new
   forced application-death proof covers copied branches and a settled mixed batch.
   Full ordinary provider/tool traces now replay through the standalone actor,
   including captured receipt/workspace facts and plan-history clock values.
   The desktop actor integration and its crash/restart proof remain open.
3. Complete incremental transcript projection and remaining allocation/cold-layout
   reduction. An image-heavy repeated-reference benchmark now covers restore,
   replay, provider budgets, attachment chips, input and search. A bounded
   restore cache shares immutable pixels and avoids repeated serialized copies.
   Stable page reconciliation
   preserves retained children and focus. Tool details now construct lazily,
   including a virtualized expanded group. Long Markdown paint has measured
   visibility indexing and real-chat forced-rebuild/input tests, including a
   10,000-row diff. These measurements do not establish that arbitrary long
   histories are fast.
4. Finish extracting orchestration/title/compaction/computer/continuation effect
   coordination. Request/context/turn/tool/plan policy modules, unified typed
   retry decisions and revision-keyed request projection caching are implemented.
   Orchestration routing values and batch state are now conversation-owned;
   child creation and parent-resume effects still reside in the root.
   Recipe evidence inspection still performs filesystem work and must move with
   effect ownership; extracting a function alone does not remove that I/O.
5. Finish isolation for truly uninterruptible native calls. Explicit queued and
   resource-blocked outcomes are implemented. Bounded pools do not make calls
   interruptible. Evaluate Windows Job Objects and transport replacement from
   measured failures.
6. Tighten consumer-event reserves, remaining memory budgets and mixed-batch
   abrupt-restart proofs at the full application boundary. Conservative blob
   garbage collection is implemented; it retains referenced journal/backups
   and defers new process-live orphans until a later launch.
7. Validate real gateway behavior and interactive performance after deployment.
   A deterministic local provider cannot establish production reliability or
   explain every previously reported hang.

Deployment evidence follows after the helper succeeds and the new image/process
are verified. This report does not mark the full redesign complete.

The orchestration ownership check runs two real tool batches before consuming
their events, verifies distinct child ownership, and exercises parent Stop and
queued dispatch revocation. It also checks invalid participants, incomplete
finish, validated input waiting and a productive handoff beyond 100 hops.
Eight focused fixtures passed in `build/architecture-checks-0fh33cu2/`; the
16-round HTTP conversation passed in `build/architecture-checks-4lcw4p85/` at
source fingerprint
`f028d86f0c535e4f4c51e1251f910a6af5e93bbb7c903935a4e17a62a4cc853d`.
The later orchestrator header-comment edit does not change behavior. These
changes remain source-only pending the complete migration and delivery.

## Standalone execution and replay proof

`python aurora-opencode-pro/tests/test_provider_roundtrip.py --actor` runs four
real HTTP/SSE requests, native writes, Python unittest, plan completion and final
settlement with no `GuiWindow`, UI tick, layout or paint. `--actor-recipe` uses
a saved verification recipe instead of the direct checker. Recorded traces
replay after moving the workspace offline and refusing provider access; the
entire final transcript/task state must match, including IDs and timestamps.
Missing external facts and changed behavioral configuration reject replay.
The diagnostic recording is opt-in and capped at 8 MiB; exceeding that budget
invalidates the recording without limiting useful work. Each fact frame is
capped at 256 entries / 4 MiB. Secrets used to connect to a provider are excluded
from the configuration identity.

`actor_mailbox_contracts` holds the journal owner, fills all 128 command slots,
and requests Stop plus a snapshot without waiting for storage. All accepted
guidance survives, and the cancelled admission sends no HTTP request. Four
hundred unconsumed updates force explicit resync within the view budget.
It also checks 8,000 concurrent graph IDs and physical actor-slot retention.

Source changes also consolidate snapshot/journal encoding and unchanged-tool
repeat/mutation policies outside the root. This proof does not establish
desktop adoption or actual gateway quality. Delivery is still pending.

All 46 default fixtures passed in `build/architecture-checks-klag1a91/` at source
fingerprint `ba7ce67353d0e540f1d84a5e33797debcd5a159c032be5369033067227ec742b`.
At that same fingerprint, the actor recipe/offline-replay checks passed in
`build/architecture-checks-5b91tiin/` and the existing 16-round desktop HTTP
conversation passed in `build/architecture-checks-1ggukg9t/`.

The subsequent branch driver makes seven additional real HTTP requests:
original answer, Regenerate, edited prompt, Continue, a held partial stream,
editing that live prompt, and a provider tool request despite disabled tools.
It retains every response version and the cancelled partial reply, rejects the
disabled write without a dangling tool envelope, saves a replacement goal
paused, and replays the complete final state offline. A separate goal mode
uses eight main requests to prove bounded unusable-output recovery while
preserving an active goal.

`requestClose` returns without waiting for a held journal owner; final shutdown
retains already accepted prompts/guidance and holds the physical worker slot
until exit. UI attachment changes and resync snapshots contain blob references,
while execution keeps pixels. Offline replay does not reopen those view blobs.
The recipe/branch/mailbox checks passed in `build/architecture-checks-m25aak5q/`,
and goal/history/recovery/engine checks passed in
`build/architecture-checks-pn0o4hpu/`, source fingerprint
`6fca1cb68a20a8b4736e9875484ea12cc5e74ee9225dac340e83c9f21ac3f89d`.

`ConversationProjection` applies immutable actor changes to a UI-owned session.
It updates text/reasoning by message ID, advances the active leaf on appends,
clears omitted optional fields in complete headers, ignores duplicate delivery,
and requests a fresh snapshot on a revision gap or unavailable parent. Owner
checks prevent one chat's changes from rewriting another chat. The real branch
driver compares the projected graph/task state with the execution owner's final
state, in addition to offline replay.

An accepted-input ledger also retains ordinary requests, steering, queued
follow-ups, goal edits and drafts if journal initialization/admission fails.
The worker closes as failed with a reserved terminal notification; it cannot
advertise that incomplete run as a valid replay trace. The failure fixture holds
storage, accepts several inputs, releases a physically broken journal path and
verifies that all accepted text survives in the final recovery state.
Projection and failure checks passed in `build/architecture-checks-p79wu1ja/`,
source fingerprint
`8bf9e96fa60e1b4ddbcabec03ccc53ba49fd10536d85cd866f0cafb3b14d97fb`.
The preceding full recipe/branch/projection checks passed in
`build/architecture-checks-2bcd5y3z/`. Desktop routing and shutdown/fold-marker
coordination are still pending; the running app has not adopted this owner.
The same updated source fingerprint also passed the full actor recipe, mailbox
and seven-request branch driver in `build/architecture-checks-gpox4qzk/`.

`test_actor_recovery.py` now exercises the autonomous owner against eight real
HTTP scenarios: provisioning recovery, Stop during backoff, a three-attempt
503 limit, a 250 ms outage budget, an explicit quota reset, three bounded
protocol repairs, an unavailable tool during a tool-free completion handoff,
and a failed summary request. All retain prior responses and replay the full
final state offline. Exhausted transport recovery cannot restart an outer
retry loop; explicit Stop cancels the pending timer. A provider's reset time
is honored separately from the ordinary outage budget. Unusable output leaves
the persistent goal active, and summary fallback cannot execute a tool.
Proof: `build/architecture-checks-mrzwc_7y/`, source fingerprint
`b9c162afd5bdaae509cbeed12a5f68fe4db6da7204f057e25d44c44c3bbcf62f`.
These are standalone-owner checks; desktop adoption and delivery remain open.

The owner now archives inline image bytes before pruning and lazily hydrates
only the bounded request window. Full UI snapshots keep references. A live
three-request image driver sends two images, sends none after the answer
retires them, then reloads two when regenerating the earlier branch. Of 49
historical references, each request checks at most three sizes and opens at
most two blobs. An unavailable reference keeps its diagnostic and cannot
discard the surrounding conversation. The same trace replays after renaming
the attachment directory offline. Size arithmetic rejects overflowing payloads.
Proof: `build/architecture-checks-5o__2e5u/`, source fingerprint
`120a1d26f77b8161139e3115399d3a670a056f2fd101302fd604c7007adbb969`.
Recovery and recipe/mailbox/branch checks passed at that same fingerprint in
`build/architecture-checks-g5jmwry_/` and `build/architecture-checks-6rlbbouu/`.
User attachment commands and desktop lifecycle integration still need adoption.

The immutable projection also carries bounded live tool rows and execution
state. Tool progress is keyed by call ID, distinguishes queued/running/terminal
states and retains the worker-start boundary. An authoritative resync snapshot
includes those rows. Ordinary progress does not publish a new durable thread
header. At most 64 rows retain 2 KiB of arguments and 2 KiB of output each;
additional calls remain in the durable model and have an explicit omitted count.
The live recipe driver checks running/completed progress and equality of the
projected transcript/task state. Unknown call progress requests resync.
Tool jobs now receive the conversation's computer-use context and diagnostic
read-only mode. Proof: `build/architecture-checks-31sa3csh/` and
`build/architecture-checks-v5gd5ljc/`, source fingerprint
`1532c0fa1955f09d4be68e7a89bd39fcc7972e714e603dc281b2c50fbe6f7cdb`.

Image-bearing user commands now use immutable image JSON plus hidden file
context. Busy steering/follow-ups archive pixels before durable queue admission;
their saved contexts align with the existing text queues. Journal projection,
snapshot copying and offline replay retain those references. A failed journal
also retains accepted inline pixels and file context in the recovery state.
The five-request image/attachment driver passes in
`build/architecture-checks-imjoed5_/`; the recipe/branch/mailbox driver passes in
`build/architecture-checks-gpe2xqpt/`.

All 47 default fixtures pass in `build/architecture-checks-kbvcyzx3/`, and all
eight HTTP recovery cases pass in `build/architecture-checks-egs2p77u/`, at
source fingerprint
`9868fd1cb8ab48de147899e68662db029682491b84e68a60e1874c1f2d83a254`.
The local-provider image test also checks that new chats leave the default
client routing key and branch navigation retains it. Gateway-specific headers
remain confined to the gateway. Real gateway validation is still pending.
The desktop continues to use its legacy coordinator; these source-only checks
do not establish adoption, rebuild, relaunch or delivery.

`ConversationRegistry` now owns construction, physical admission, idle
retirement and final recovery state off the UI thread. At capacity it retains
accepted commands with an explicit waiting state. Stop has a separate reserved
position, and a deferred actor can settle accepted input on shutdown without
starting a physical worker or an effect. New owner generations begin with an
authoritative snapshot. Final states transfer once, after closure; no live
mutable graph is shared with presentation. Construction failure retains input,
goals and attachments without blocking other chats. Lifecycle inputs waiting
for actor processing are distinct from a durable journal acknowledgement.

The lifecycle HTTP driver completes four real SSE/native-tool/verification
requests without draining a single presentation update, then resynchronizes the
entire final state. The goal variant settles bounded unusable output after
eight requests and preserves the active goal. Proofs:
`build/architecture-checks-oocql2pv/` and `build/architecture-checks-mudazy6y/`.
At source fingerprint
`acdf2098c8c778575f5e10fbb2e5e8103497a434ab96769c8650ad979b6e10ad`,
lifecycle/performance checks pass in `build/architecture-checks-_7qftumu/`,
recipe/branch/replay checks in `build/architecture-checks-q60qcex6/`, image
commands in `build/architecture-checks-j0m4zf9p/` and recovery in
`build/architecture-checks-97xafq6j/`.

Production admission now detaches mutable containers instead of serializing
the whole transcript. The 10,000-message debug fixture (24 MB logical body)
measured 3.2 ms / 3.8 MB for detachment and 44 microseconds / 9.4 KB for
transferring an already detached model. These are isolated measurements, not
desktop release latency guarantees. Desktop routing, hot configuration,
optional title/compaction/orchestration jobs, exit/fold coordination and final
deployment still remain open. The default runner now includes 49 fixtures;
the preceding full suite proof covers its former 47-fixture set.

Hot configuration is now an ordered command. It captures policy data separately
from connection credentials, preserves the workspace/model of an already
requested tool batch, and applies new schemas/credentials to the next request.
Manual titles and selected/unread state use the same command boundary. An
in-flight two-request HTTP test verifies the old workspace receives its write,
the next request uses the new model, key and read-only schema, caller arrays
cannot mutate admitted policy, malformed configuration is rejected, and full
replay works offline without recording either fixture key. Proof:
`build/architecture-checks-a3kefaxk/`, source fingerprint
`32fc7b92cfbd3693588cfe21d8002549c5334ba15d07962cfb306412bfc49c64`.

That test also exposed a real no-action continuation loop: short, varied
completion claims could repeatedly bypass the earlier prose-replay guard while
verification remained required. The new shared task audit bounds consecutive
continuations without a useful tool attempt; it does not cap productive task
length. A native HTTP case now fails explicitly after seven requests with the
task and required verification preserved. A hundred useful continuation/tool
intervals remain allowed. Per-request tool-name admission also rejects unoffered
calls while preserving paired results for mixed accepted/rejected batches.
All eleven HTTP recovery cases pass in `build/architecture-checks-lrtf611x/`.
The 16-round GUI conversation passes in `build/architecture-checks-jbff9ci3/`,
and lifecycle goal/recipe/branch checks pass in
`build/architecture-checks-v5g5kypv/`, source fingerprint
`e014a17d9b9485cf24fecf5d4d571e0f7bef62d8ab84c57d1e55f573baa397b7`.
Terminal completion now publishes its final busy/unread state together; a retry
wait remains a running turn instead of publishing a premature turn failure.

The subsequent full-suite run found an intermittent Windows attachment sharing
failure. Blob publication now installs without replacing an existing winner;
reads explicitly share rename/delete handles and still verify the content hash.
The concurrency fixture includes a held DELETE-access handle and eight writers.
The prior implementation fails that reproduction, while the current executable
passed three repeated runs. Evidence:
`build/blob-sharing-proof-1793645357385855900/` and focused checks in
`build/architecture-checks-d1c4awmb/`, source fingerprint
`cf72b9be5d3bb0aa6037e7707ddc05305ab5039f98581a87861444d3ad96164b`.
All 49 default fixtures now pass in `build/architecture-checks-7k8om0xa/` at
that same source fingerprint. These changes remain source-only; the desktop
still uses its legacy execution coordinator.

The owner now journals compaction anchors/summaries, unread state, instructions,
per-chat tools mode and roster metadata. Plan history is cached and emitted only
when its append/prune identity changes; ordinary task-state encoding no longer
builds history merely to remove it. The 8,000-step metadata fixture allocates
18.6 KB for ordinary state encoding, preserves journal-only recovery after 50
draft updates and a history prune, and verifies idempotent replacement/clearing
and owner isolation. Source fingerprint
`b4a137e9c1f2f5752084acd8dc68fc80b31ed8b7bf747e7351ed108ee26c62d0`:
`build/architecture-checks-ir5lbogg/` (metadata and killed-process recovery) and
`build/architecture-checks-vvm5eh2l/` (recipe/mailbox/branch/offline replay).
Snapshot and journal metadata now share one decoder; arrays replace existing
values rather than appending duplicates during a second application.

UI metadata now uses explicit replacement patches too. Fifty draft changes send
2,540 bytes while retaining the same 8,000-step history array. Removed optional
fields clear explicitly, and only one resync request is outstanding at a time.
Source fingerprint
`67ac4c02a52031fa922fc4cb3f0d4371af319afd3c95c324f65416fb0e8f57b6`:
`build/architecture-checks-lvjy4z0t/` (projection and metadata),
`build/architecture-checks-v4btg3uh/` (image and attachment commands), and
`build/architecture-checks-h1007430/` (hot configuration). All eleven HTTP
recovery cases also pass at the preceding patch fingerprint in
`build/architecture-checks-90xq7a9s/`. These are standalone owner checks; desktop
adoption and deployment remain required.

Optional title and model-summary jobs now run inside the conversation owner.
The main response uses its extractive checkpoint immediately; it never waits
for the optional model summary. A later summary requires the same checkpoint,
task identity and captured leaf on the active branch. Titles use UTF-8-safe
limits, two persisted attempts and a durable manual-rename guard. Both jobs
have bounded output/deadlines, independent correlated clients and cancellation
that also revokes queued journal admissions. Neither job can execute tools.
Source fingerprint
`d612eed34c50de89678deedab26b73c6b1c87942d9a13e28c029b516ba06f8d2`:
`build/architecture-checks-1t2e4bp3/` covers eight actual HTTP cases, journal-only
recovery and exact offline replay. Every foreground response finishes while
its optional job is held. Renames, goal changes, branch changes, Stop, invalid
tool output and title-attempt exhaustion are covered. The ordinary desktop
still uses the legacy coordinator; this closes optional-job parity in the
standalone owner, not the desktop migration. The default runner now has 51
fixtures. Artifact retention follows the runner's configured newest-run limit.

## Earlier hardening deployment

The self-helper completed the release rebuild with exit code 0 and no compiler errors.
Duration: 118399 ms. New process: 29840.
The new binary is newer than every compiled source, and the process started after this deployment began.
Image SHA-256: `5f56b3721ce343cce93226520aa76c80a13467382024b39a009a0847631b730f`.
The local publisher was skipped for this build; the new app clears that per-build flag.
Evidence: `build/architecture-deploy.json`.
The full actor/effect/presenter migration remains open.

The subsequent latency stage was deployed and verified through the production
executable. Its current transport path, controls and proof are recorded in
`latency-improvements.md`; the image hash is
`c1655d9002f904fc126cd398c593bc02372fbe163fc5a4864e423a6b0e853d0d`.

The deployed binary also passed its own `--headless` real-widget entry point against the local provider.
Four HTTP/SSE rounds performed native writes and a Python check, reached READY and persisted the final response.
State/workspace were isolated under `build/production-roundtrip-_jiya9y2/`.
The proof binary hash matches the deployed image: `5f56b3721ce343cce93226520aa76c80a13467382024b39a009a0847631b730f`.
