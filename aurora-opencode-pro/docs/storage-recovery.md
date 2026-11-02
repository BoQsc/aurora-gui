# Storage and recovery

Source verification, 2026-11-02. These changes are not yet the running release;
delivery remains part of the active agent migration.

## Ownership

Journal initialization and physical reads run on the ordered repository owner.
Sequence, size and error queries read cached metadata without acquiring a lock
held over disk I/O. Provider/tool admission still waits behind accepted intents.

The snapshot owner reads the index, legacy snapshots, required conversations,
attachments and journal range. It decodes conversation metadata/messages and
projects the journal before transferring the result to the window. Index and
legacy restoration share `conversationcodec.d`; there is no inline small-file
parse or timeout fallback to a window-thread journal read.

Selection and internal history-dependent actions load on the snapshot owner,
away from journal admission. A bounded typed mailbox retains the conversation ID
and action while loading. Sidebar insertion/deletion cannot redirect it; deleting
the target cancels it. Failed reads retain pending actions for explicit retry.

## Recovery contracts

- Send stays disabled while startup recovery or selected history is unavailable.
- Physical read failure is distinct from an empty journal. Torn JSON records
  remain locally recoverable.
- A failed startup cannot overwrite the original index or acknowledge a partial
  snapshot, including during shutdown.
- Backup-index recovery reads the full journal; it cannot trust the primary
  index's newer fold marker.
- Journal metadata is applied as a patch. Missing fields preserve saved task,
  goal, steering and verification state; explicit empty values still clear it.
- Conversation copies record the full graph and metadata as one journal event.
  Encoding happens on the owner. A compacted copy includes its extractive
  checkpoint before that event is queued. Later checkpoints have separate records.
- Snapshot writes publish referenced history files before the index and fold
  marker. Goal-history arrays are detached before a background writer sees them.
- Journal ranges stream from disk, and message lookup during replay uses IDs
  instead of repeatedly scanning the growing transcript.
- Window close, rebuild and update freeze new command admission and transfer a
  detached final snapshot through a journal fence and the snapshot owner. The
  window continues painting until acknowledgement. Helper launch follows the
  checkpoint; failure restores the interface and fresh execution clients.
- Final source-conflict checks and update-helper launch run off the window
  thread while retaining the checkout lease. Preference write failures reject
  the checkpoint. Fold markers use atomic replacement.

## Verification

The isolated fixture runner records source/executable hashes, commands on compile
failure, logs, exit codes and elapsed time. It retains linked executables and
removes reproducible compiler intermediates.

`repository_responsiveness_contracts` stalls the owner before initialization,
queries metadata 5,000 times, and verifies that effects wait for the intent.
`startup_responsiveness_contracts` runs 650 ticks with seven software paints
behind stalled storage, then restores the accepted answer before enabling Send.
One measured run took 91 ms for those ticks/paints; this is a fixture result,
not a universal latency guarantee.

`history_mailbox_contracts` covers delayed duplication across sidebar deletion,
failed-read retry, and deletion before a late load returns.
`corrupt_restore_contracts` verifies strict physical-read errors and preservation
of original files during failed recovery and shutdown.

`application_crash_restore_contracts` holds the snapshot owner, creates ordinary
and compacted copies containing two response branches, and runs a real ordered
read/write/read tool batch. After journal acknowledgement, its parent forcibly
terminates the process. A new application instance must recover both copies,
their paused goal and exactly three tool results, then preserve them on reload.
The fixture verifies that no compatibility snapshot was written before death.

`journal_history_restore_contracts` also verifies that a message-only tail retains
the existing goal, task, constraints, steering, thinking setting and verification
scope. `compaction_validation` covers retained history and rejected stale,
truncated, oversized and timed-out model summaries.

Evidence for the crash, metadata and compaction checks is in
`build/architecture-checks-fckukrv5/`, source fingerprint
`4d68203372fa4d05ec2a72efa6d1a1b65025190da318be78e2a938477a2ef264`.
The full default suite is recorded in `build/architecture-checks-np2fs86d/`.
After the exit checkpoint and output recovery changes, all 33 default fixtures
passed in `build/architecture-checks-g0xma90d/`, source fingerprint
`752e1e91f34e051b77a813af667408108061cb74a8a4b7cb9d08e1b19a8abffd`.

`exit_checkpoint_contracts` holds each storage owner separately and verifies
100 native ticks with ten paints remain responsive (79 ms and 9 ms in one run).
It verifies that a failed snapshot cannot launch the helper, a failed helper
leaves the application usable, and a later successful checkpoint preserves the
draft before closing. Evidence: `build/architecture-checks-wkvag72k/`.

## Attachment maintenance and concurrent writers

Source changes, not yet deployed: attachment writes use a unique temporary file
per writer and validate a competing writer's result. Reads and writes pin their
digest for the process lifetime, including reused blobs whose new reference has
not reached the journal yet. At 65,536 pins, collection is disabled for that
directory rather than allowing pin memory to grow without a bound.

The snapshot owner attempts collection at most once per hour after a successful
store write. It marks all conversation files, backups, legacy snapshots and the
entire retained journal. Incomplete or invalid reference sources abort deletion.
Defaults cap a pass at 128 MiB of reference input, 8 MiB per JSON snapshot,
2 MiB per journal line, 65,536 references, 16,384 files and 128 deletions, with a
500 ms scan/deletion budget and a 24-hour age grace period. Time is checked
between filesystem operations; it cannot interrupt an individual blocked read.
Journal-referenced blobs remain retained even if no longer in the active branch.
Newly orphaned live pins become eligible on a later launch.

`attachment_collection_contracts` covers retained branches/backups/journal and
archived original pixels,
in-flight and loaded references, corrupt/torn/over-budget scan aborts, age grace,
checksum rejection, and eight concurrent writers during collection. It passed
with the architecture, forced-application-death and exit-checkpoint fixtures in
`build/architecture-checks-kflpthk6/`, source fingerprint
`ef6ba8835f9fe31ea32403c2ee71c060ce3342c664dd551d859a707617783381`.

The full suite exposed a Windows path-length regression in temporary names;
temporary files now have shorter names than the final digest path, and a
near-MAX_PATH fixture covers writes. The corrected original-reference and path
checks passed in `build/architecture-checks-kcrtvy2n/`.

Restore operations share immutable hydrated payloads through a local cache capped
at 16 MiB and 256 entries. Replay retains compact on-disk references in
`payloadJson` and the hydrated value in `parsedPayload`, avoiding an additional
serialized pixel copy per event. This does not cap the total size of a loaded
conversation containing many distinct images.

`image_history_performance_contracts` uses 512 references to eight real PNGs,
representing 134,479,872 logical image bytes. In one debug run, snapshot restore
took 64,515 microseconds and allocated 4,268,144 bytes; journal restore/projection
took 74,613 microseconds and allocated 6,316,288 bytes. The request retained two
images within its byte budget. The current UI renders attachment chips, and its
input/forced-rebuild/paint test measured median 17,006 and p95 24,973 microseconds.
Search revealed an old attachment row with fewer than 100 materialized rows.
This tests repeated references, not a bound for arbitrary unique-image histories.
Evidence: `build/architecture-checks-e056kl3s/`, source fingerprint
`70d02224e5281c47177777ffaea8484486d4625d669910a94d226dc8cf68c599`.

All 43 default architecture fixtures subsequently passed at that same source
fingerprint in `build/architecture-checks-hbxvbc4w/`. The independent 16-round
HTTP conversation check also passed before the final hydration-cache change
in `build/architecture-checks-279zcqo1/`; deployment remains pending.

Full autonomous execution remains in the parent migration. These tests establish
process-crash recovery, not power-loss behavior or real-provider quality.
