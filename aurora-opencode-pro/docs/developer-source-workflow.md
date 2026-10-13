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

Turning the setting off skips the remote maintainer check, including when offline.
Unresolved conflicts and unfinished source recovery still block ordinary edits
and rebuilds; conflict repairs remain available.
The separate **Reapply my changes on upstream update** setting controls whether
`sync` applies updates or only reports them. Explicit **Update** always applies
source updates in Developer mode, regardless of this preference.

## Maintainer source channel

`assets/maintainer-source-branch.txt` selects the public source branch for the
app update channel. Source downloads, update notices, sync, the rebuild check,
and contribution PR bases all use this branch. Currently the shipped app's
source is on `codex/portable-crt-experiment`; `main` contains an older app.
Publish source commits to the selected branch before delivering the binary
update. Change the asset when moving the release channel to a different branch.

Update remains visible in Developer mode and installs the maintainer's published
executable. It first synchronizes the selected source with the maintainer branch,
preserving local commits, tracked edits and staged selections through the same
recovery snapshots as Sync source. It also synchronizes source when the executable
is already current. Missing source offers setup; older non-Git snapshots are
preserved and require a checkout before Update can continue.

Finish or stop active turns before Update. Source work and competing source
operations wait while Update prepares the checkout. A failed fetch, untracked
collision, merge conflict or unfinished recovery keeps Aurora open and hides the
installation action. The dialog shows the problem and offers a conflict-resolution
prompt for the existing development chat. Resolve and stage the intended changes,
finish the Git operation and call Sync source, then retry Update. Installation
rechecks source under the checkout lock; disabling the latest-source preference
cannot bypass conflict recovery. Update never rebuilds or resolves conflicting
code automatically. Rebuild separately compiles the selected source to apply
local customizations again.

Ordinary mode Update continues to replace only the executable. Public releases record the exact
source commit, branch and build-input fingerprint. Publishing rejects dirty or
unpublished source, an executable changed since its build record, or source that
changed during compilation. CI follows the selected source branch; update its
branch trigger when moving the channel. Developer Update verifies that the
release's source commit is available on that branch before integrating it.

Rebuild and Update record a handoff for the running process before closing it.
The supervisor consumes that request and leaves relaunching to the replacement
helper, including when shutdown crashes. Ordinary unexpected exits still use
the supervisor's recovery path. Linker failures such as an executable locked by
another process appear in the rebuild report alongside compilation errors.
