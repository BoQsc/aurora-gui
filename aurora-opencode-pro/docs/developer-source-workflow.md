# Updating Aurora source before rebuilding

Developer settings enable **Require latest maintainer source before editing or rebuild**
by default. Source writes, source commands, the Developer and toolbar Rebuild
buttons, and the agent's `rebuild` tool check Git state and the remote branch
without changing source files. Missing updates, unresolved Git operations,
non-Git snapshots, and failed checks stop ordinary source writes and rebuilds.
Native edits of conflicted files and Git commands that finish conflict resolution
remain available. Unrelated projects are not blocked by an Aurora source update.

Sync, edits, source reads, publication and rebuild preparation share the physical
checkout lock. Repository roots, package subfolders, Windows short paths and
junctions resolve to one checkout. The lock remains held until the actual operation
finishes, including after Stop. Source commands must run in the foreground.

Sync merges maintainer history on every branch, preserving merge-only amendments
and published commits. It refuses incoming paths that collide with untracked or
ignored local files before changing the checkout. Before applying an update it
records durable recovery refs under `refs/aurora/recovery/`. Tracked edits are
saved separately and reapplied with their staged/unstaged selections. If merge or
restoration conflicts remain, resolve and stage them, finish the Git operation,
then call sync again before continuing. Recovery snapshots remain available.
If restoration was interrupted or the staged selection could not be restored,
inspect the saved snapshot and integrate the intended result, then call
`sync` with `recoveryResolved=true` to acknowledge that recovery. This acknowledgement
never deletes the durable snapshots.
Background check failures appear in Developer source status and reach the next
development request, including tool continuations.

The dialog offers a prompt to copy into the existing Aurora development chat.
The agent uses the Aurora-specific `sync` tool to fetch maintainer source and
reapply local changes. It resolves conflicts, finishes the Git operation, then
rebuilds, verifies the relaunched application, and tests the changes. Publishing
a pull request follows testing. The dialog never starts an agent or resolves
conflicts automatically.

Turning the setting off skips the maintainer check, including when offline.
The separate **Reapply my changes on upstream update** setting controls whether
`sync` applies updates or only reports them.

## Maintainer source channel

`assets/maintainer-source-branch.txt` selects the public source branch for the
app update channel. Source downloads, update notices, sync, the rebuild check,
and contribution PR bases all use this branch. Currently the shipped app's
source is on `codex/portable-crt-experiment`; `main` contains an older app.
Publish source commits to the selected branch before delivering the binary
update. Change the asset when moving the release channel to a different branch.

Update remains visible in Developer mode and installs the maintainer's published
executable. Rebuild separately compiles the selected local source. A binary update
leaves local source files intact; use Sync source to integrate maintainer source
updates and Rebuild to apply local customizations again. Public releases record the exact
source commit, branch and build-input fingerprint. Publishing rejects dirty or
unpublished source, an executable changed since its build record, or source that
changed during compilation. CI follows the selected source branch; update its
branch trigger when moving the channel.
