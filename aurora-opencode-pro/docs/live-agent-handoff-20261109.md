# Live long-task replay and fixes, 0.66.41

The recent player-model handoff request was replayed against the configured real
provider, using the actual project assets, code and authoring files. There were
no canned responses or tool results. Both full runs used the GUI model
`deepseek/deepseek-v4.1-flash` and its saved **high** reasoning setting. The raw
session boolean was false; it does not override that saved route setting.

The initial snapshot contained 5,661 files / 1,536,480,419 bytes. It excluded
caches, build outputs, prior handoffs and generated reports. After the user's
instruction to leave the original project alone, subsequent work reused only
the existing snapshot. No original project edits or tests were performed in
place, and neither replay's tool arguments referenced the original project.
Project assets, credentials and raw conversations are not part of this commit.

## Observed failures and repairs

1. **Scope expanded to the enclosing repository.** An explicitly named folder
   became the Git root used for commands, searches and context. Preserve the
   configured/named subproject directory; retain checkout identity separately
   for leases and evidence. The first test's location under Aurora also caused
   an Aurora-only foreground guard rejection. The clean replay was placed
   outside Aurora, in its own repository, to avoid that test-layout interference.
2. **Large deliverable could not be tracked by verification.** The first ZIP
   was 106,019,416 bytes. Verification rejected the 64 MiB input total, and the
   agent removed the ZIP from `inputs` to get an accepted receipt. Inputs now
   stream through a 64 KiB buffer, up to 8 GiB total, with cancellation and
   before/after integrity checks. Checked artifacts should remain in inputs.
3. **False phase warning.** The valid active outcome “Assemble handoff folder…”
   had inferred kind `other`. Editing was treated as evidence that this outcome
   was stale. An unknown kind no longer asserts a phase mismatch; periodic
   upkeep and explicit research/edit/verify transitions remain supported.
4. **Completion caused a receipt hunt before identifying remaining work.** A
   prose evidence value caused thirteen history lookups, followed by another
   rejection because verification was still required. Check outstanding
   verification first. Tool guidance now includes a complete custom-check
   recipe, so the agent need not search application source for its format.
   Once checks pass, invalid evidence IDs are still rejected.

## Live evidence

| Run | Duration | Tool results | Outcome |
| --- | ---: | ---: | --- |
| Initial shipping build, 0.66.40 | 917 s | 181 | Delivered valid assets, but accepted recipe omitted the ZIP after the size rejection |
| Candidate full replay | 794 s | 133 | Independent checks passed; actual ZIP and baseline GLB remained tracked verifier inputs; final plan and goal completed |
| Final completion-order repair, resumed pre-completion checkpoint | 47 s | 5 | Real provider, one accepted verification, zero history lookups, completed task and goal |

The resumed run used the real saved history before the first completion attempt
and the actual delivered files. It was a targeted continuation, not a third
cold-start run. Two malformed completion attempts still self-corrected; no
evidence checks were bypassed. The candidate also recovered from a guessed
path, listing-limit mistake and search deadline without human intervention.

Timing and tool counts are observations, not a controlled speed claim: the
model's choices varied and the test location was corrected between full runs.
Long high-reasoning generation remains distinct from a client stall.

Independent checks cover ZIP CRC and unique/safe entries, byte-identical editable
Blender and runtime GLB assets, 59 joints / 71 runtime clips, embedded model
dependencies, unchanged source model/code assets, a completed final checklist,
and inclusion of the actual ZIP in an accepted verifier input set. This does
not claim that hypothetical future returned animations work in the game.

## Reproduction and regression checks

- `benchmarks/replay_player_handoff.py --live --snapshot <existing-copy> ...`
  reuses only manifest-listed unchanged inputs, preserving the original project.
  It refuses output under Aurora's checkout and uses isolated state.
- `benchmarks/check_player_handoff.py <replay-directory>` independently checks
  both deliverables and recorded verification input coverage.
- `tests/live_handoff_completion.d` requires an explicit
  `AURORA_LIVE_HANDOFF_DIRECTORY` and makes real provider requests from the saved
  pre-completion checkpoint. It is excluded from default automated fixtures.
- Targeted fixtures cover large tracked files, changed-input rejection, Stop
  during hashing, subproject scope, plan upkeep, goals and receipt ordering.
  Existing strict evidence/continuity contracts pass with strict mode enabled;
  they assert behavior that default advisory planning deliberately does not use.
- The candidate executable also passed the HTTP/tool round trip and the 32K
  task-ownership/compaction replay. Delivery still requires the production
  rebuild, relaunch and publicly verified update.
