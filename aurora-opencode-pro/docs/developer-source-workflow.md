# Updating Aurora source before rebuilding

Developer settings enable **Require latest maintainer source before rebuild**
by default. It applies to the Developer and toolbar Rebuild buttons and the
agent's `rebuild` tool. The check reads Git state and the remote branch without
changing source files. Missing updates, unresolved Git operations, non-Git
snapshots, and failed checks stop the rebuild while Aurora stays open.

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
