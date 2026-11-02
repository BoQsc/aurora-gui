# Stabilization review: 0.66.30

The 2026-11-02 review checkpoint stops feature expansion. The release collects
the existing desktop fixes and freezes the standalone actor groundwork for
human assessment. The full migration is unfinished and must not resume
automatically before feedback on this build.

## Changes used by the desktop

Compared with the previously shipped 0.66.29 source, commit
`88a879f0f9a5dbdd6bd5cd92d2afb4bc3ddcb1e4`:

| Change | Evidence and practical limit |
| --- | --- |
| Asynchronous startup/history recovery and exit checkpointing; partial responses and dirty snapshots survive recovery. | Startup, history mailbox, application crash, corrupt restore and exit checkpoint fixtures pass. These isolated cases do not establish reliability for every real workspace. |
| Bounded invalid/no-action output recovery, normalized tool call IDs, scoped verification receipts and explicit resource failures. | Output recovery, goal, retry, tool protocol, resource and verification fixtures pass. Actual model answer quality still needs human assessment. |
| Conversation-scoped child ownership; parent Stop revokes descendants. | Legacy orchestration ownership and headless fixtures pass. The separate actor orchestration implementation is not the desktop path. |
| Wrapped code selection retains logical lines; expanded tool groups materialize visible content lazily. | Selection, lazy tool group, viewport and performance fixtures pass. Cold transcript construction remains a cost. |
| Shared snapshot/journal message decoding retains image retirement, original/normalized image metadata and authors; atomic replacement protects a valid recovered backup until the first successful primary installation. | Journal, image, corrupt restore and forced failed-rename checks pass. Attachment references and pending outbox roots are retained conservatively by collection. |
| Concurrent attachment publication/read sharing and smaller ordinary metadata encoding. | A retained isolated race proof fails on earlier source and passes three times after the fix; ordinary metadata avoids constructing thousands of omitted history steps. This is not an overall application speedup measurement. |

## Groundwork that is not active in the desktop

`OpenCodeRoot` still coordinates execution on the window thread.
`ConversationActor`, `ConversationRegistry` and `ComposerStore` have not been
connected to the desktop composer and presentation path. Their independent
workers, durable submission outbox, optional title/model-summary jobs,
diagnostic policy and actor orchestration are tested infrastructure. They do
not yet establish a better everyday desktop experience. In particular, the
new actor compaction scheduling is not a delivered desktop behavior change.

No additional migration or feature work belongs in this checkpoint. A failing
release gate may receive a targeted correction; broader work needs the human
review below first.

## Frozen source verification

At D source fingerprint
`c32eaf9be43e1b1a456252f60ffad9bf9b8aa15b2e0386dc246cd1dc0a976e33`:

- All 53 default architecture fixtures passed.
- The desktop conversation test passed 16 HTTP/SSE rounds, including steering,
  Stop/resend, background chat, correction, failure repair and reload.
- Five standalone actor orchestration cases passed, with 26 actor generations
  replaying exactly offline. This is groundwork evidence, not desktop adoption.
- Focused composer-to-actor HTTP/tool/journal checks passed before the final
  regression run; newer unsent text and complete image metadata survived reload.

Commands: `python tests/run_architecture_checks.py`,
`python tests/test_conversation_flow.py`,
`python tests/test_actor_orchestration.py`, and
`python tests/test_composer_actor.py` from the application package.
The retention concurrency unit also passed. Review evidence is retained under
`build/stabilization-review-06630/`; generated evidence is not source code.

In the debug performance fixture, long-reply input rebuild/paint measured
9.7 ms median / 13.4 ms p95, while cold projection/paint for 250 messages took
307 ms. These are isolated client measurements, without a matched baseline or
provider/network time. They do not prove a general latency improvement.

The release must also pass its existing production-executable round-trip smoke
after rebuilding, and source/binary publication must match exactly. Delivery
results are recorded separately under the review evidence directory.

## Human review before further work

Use a real task that was annoying in the previous build. Assess these three
interactions in 0.66.30:

1. Give a correction while work is streaming, then Stop and resume. Check that
   the assistant follows the correction, stops unwanted work and makes the next
   state understandable.
2. Edit or regenerate an earlier message, navigate its alternatives, and close
   and reopen the app. Check the retained history, partial response and images.
3. Open a large tool result and copy wrapped code during a long reply. Check
   responsiveness, selection correctness and whether progress feels useful.

Record what improved, what regressed and one concrete remaining annoyance.
If the interaction does not feel better, that evidence takes priority over
passing synthetic fixtures. Perfect clarity, stability or assistant quality
has not been demonstrated by these checks.
