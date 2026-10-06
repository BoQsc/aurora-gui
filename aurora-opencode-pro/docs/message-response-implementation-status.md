# Message-to-response migration status

Updated 2026-10-06. The full migration in `message-response-architecture-review.md`
is **not complete**. This is a verified hardening stage.

## Current path

Composer and steering commands enter `OpenCodeRoot`. Each conversation directly
owns its `ThreadEngine` execution state. Pure branch projection and the prompt
cache prepare requests; `ProviderAdapter` serializes them. Bounded WinINet workers
feed a transport-independent `ProviderStreamDecoder`, then a bounded client queue.
A serialized native application service applies events and schedules tools.
Tool results return through the same queue. One repository owner orders journal
writes, partial checkpoints and dirty-thread snapshots. Asynchronous history
results and stable/deferred transcript rows reach markdown layout and paint.

Execution service advances during native resizing without widget ticks.
It still runs on the window thread: it is **not** an autonomous actor.

## Implemented

| Boundary | Result |
| --- | --- |
| Execution state | Direct per-chat ownership replaces save/load field copying. A scalar deterministic request reducer tracks phase/correlation. Stop rejects late output; unknown/duplicate tool results are rejected. Delayed operations survive chat insertion/deletion. |
| Service | Round-robin native application service runs during resize, uses a soft six-millisecond budget and bounded drains, and retains unconsumed events in order. |
| Provider | Wire projection and stream accumulation/usage interpretation have separate modules. Physically running requests have a configurable cap: `AURORA_PROVIDER_WORKERS`, default 16. A stopped worker retains its slot until it returns. Launch rejection is explicit. |
| Retry | Typed HTTP recovery has an outage budget: `AURORA_PROVIDER_OUTAGE_MS`, default 120 seconds; explicit zero means unlimited. Hard quota errors are distinguished. Root resend remains separate. |
| Delivery | Soft 8 MiB / 1,024-event producer limits, cancellation wakeups and UTF-8-safe bounded drains. Text and terminal events are retained. An indivisible event or consumer control reserve can exceed the soft bound. |
| Tools | Shared four-worker scheduler, bounded pending queue, workspace read/write barriers and a global desktop lease. Captured computer routing is installed per worker. Leases remain held for physical effects. |
| Verification | Recognized check identity, actual exit status, workspace and mutation generation. Command words alone cannot pass. Physical mutations invalidate older evidence even when Stop drops their late events. Rebuilding alone cannot satisfy unrelated checks. |
| Storage | One ordered repository owner, dirty-thread snapshots and periodic partial-response checkpoints. Snapshot high-water marks are read on the owner without a UI-thread barrier. Durability failure gates new requests/tools and appears in status. |
| Native recovery | Before-images and an intent manifest are saved before native file effects. Completion retires temporary blobs. Death leaves an explicitly uncertain operation with preserved before-images; it is never automatically replayed or undone. Changes reports pending operations. |
| Attachments | Immutable content-addressed blobs replace repeated persisted base64. Missing/corrupt images retain references and appear unavailable; surrounding messages survive. Corrupt existing blobs are rejected. Legacy records remain readable. |
| History | Selection loads asynchronously. Failed/missing history blocks Send and can be retried; it cannot silently become empty context. |
| Presentation | Settled rows are retained by identity/presentation inputs. Long pages use deferred descriptors, a height index, overscan and eviction. Selection/search targets are pinned; search spans and lazily reveals the active branch. |
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
   are foundations, not the completed extraction.
2. Remove remaining synchronous intent acknowledgements/internal history reads
   from window-thread paths while preserving durable acceptance. Replay full
   recorded provider/tool traces to the same transcript and task.
3. Complete incremental transcript/group projection. Structural pages are still
   cleared/reattached and complex tool groups remain eager. Benchmark forced
   rebuilds, long markdown/diffs/images, allocations and input latency.
4. Extract orchestration/title/compaction/computer/continuation policy effects,
   consolidate root resend with typed retry, and cache immutable request
   projections by graph and capability revisions.
5. Add explicit queued/resource-blocked outcomes and isolation for truly
   uninterruptible native calls. Bounded pools do not make those calls
   interruptible. Evaluate Windows Job Objects and transport replacement from
   measured failures.
6. Tighten consumer-event reserves, blob garbage collection, memory budgets and
   mixed-batch abrupt-restart proofs at the full application boundary.
7. Validate real gateway behavior and interactive performance after deployment.
   A deterministic local provider cannot establish production reliability or
   explain every previously reported hang.

Deployment evidence follows after the helper succeeds and the new image/process
are verified. This report does not mark the full redesign complete.

## Deployed stage

The self-helper completed the release rebuild with exit code 0 and no compiler errors.
Duration: 118399 ms. New process: 29840.
The new binary is newer than every compiled source, and the process started after this deployment began.
Image SHA-256: `5f56b3721ce343cce93226520aa76c80a13467382024b39a009a0847631b730f`.
The local publisher was skipped for this build; the new app clears that per-build flag.
Evidence: `build/architecture-deploy.json`.
The full actor/effect/presenter migration remains open.

The deployed binary also passed its own `--headless` real-widget entry point against the local provider.
Four HTTP/SSE rounds performed native writes and a Python check, reached READY and persisted the final response.
State/workspace were isolated under `build/production-roundtrip-_jiya9y2/`.
The proof binary hash matches the deployed image: `5f56b3721ce343cce93226520aa76c80a13467382024b39a009a0847631b730f`.
