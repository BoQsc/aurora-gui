# AGENTS.md

Guidance for AI coding agents working in this repository (Aurora OpenCode).

This project is written in **D** and built with **DUB**. Packages:

- `aurora-opencode-pro` — the desktop application (this repo).
- `aurora-opencode-core` — the core library it depends on.

## Golden rule: the running app is NOT the code you just edited

The executable that is currently running (`aurora-opencode-pro.exe`) is an
**already-built binary**. Editing `.d` source files does **not** change it. A
change is not "working" until a rebuild has happened **and** the rebuilt binary
has been relaunched.

Never report success based only on having edited the sources. This is the single
most common mistake here: the agent edits `source/auroraopencode/appui.d`, the
app keeps running the old build, and the change appears to do nothing (or the
next interaction fails with an error such as `undefined identifier ...` because
the running binary is stale).

## Agent discipline: tool-call budget and rebuilds

Two failures to avoid, with a shared root cause: acting as if actions are free.

**The tool-call budget is counted in rounds, not time.** Every `read`, `grep`,
`dshell`, `edit`, and `rebuild` costs one, and the round cap ends the turn
mid-work.

- One file = one patch. Batch all edits to a file into a single
  `apply_patch`/`write`; many small sequential `edit` calls lose track of what
  is on disk and can leave a file half-written (e.g. a deleted function
  signature).
- Spend reads only on the unknown that gates the next edit; do not re-read for
  confidence or to restate what is already known.
- Reserve the last call for the build/verify step: edit then verify, never end
  on a mutation with unverified state.
- If the work will not fit, ship a coherent, compiling stage and stop with a
  clean tree and a stated next step. Never end a turn with unapplied or broken
  edits.
- Tell: running out of rounds with a broken file means the granularity was
  wrong, not that the cap was too small.

**A rebuild is a deploy, not a save.** `rebuild` persists the conversation,
**closes the running app**, runs `dub build`, and relaunches it with whatever the
source currently is - including half-finished changes.

- Rebuild only when the source is complete and coherent *and* applying it to the
  running app is the goal, and announce it at that moment.
- Never rebuild as a byproduct of answering a question, mid-discussion, on
  half-applied code, or twice for the same change.
- The rebuild *is* required to make a change real (see above); the point is to
  do it deliberately, not to skip it.

**General rule.** State-changing actions - writing files, and especially
rebuilding/relaunching the app - happen only when they are the requested outcome
or when they have been explicitly announced. Investigation and explanation are
read-only and produce no side effects.

## Build

- Run `dub build` from the repository root (release builds use
  `--build=release`).
- Do **not** build in a way that overwrites the live executable while it is
  running. Use the rebuild/restart flow instead.
- Rebuild/restart flow (staged): the app copies *itself* to a throwaway
  `bin/aurora-rebuild-helper-<pid>.exe` and spawns that copy as the agent; there
  is no separate helper executable to build or keep in sync. The agent compiles
  the side-by-side `newbuild` target (`aurora-opencode-pro-new.exe`), records
  `ok` in `rebuildstate.json`, waits for the app to close, swaps the new binary
  in, and supervises the relaunch. A failed compile leaves the previous build
  running with the errors reported in-app. `bin/restart-now.bat` and
  `bin/supervise-now.bat` drive the no-rebuild run/supervise paths; the app
  selects agent mode in `source/app.d` when `main` sees `--aurora-rebuild-helper`.
- Build-side support and in-app build-awareness both live in the single module
  `shared/rebuild.d`: the ledger (`rebuildstate.json` and the build artifacts),
  the app-side launch flow, the resume notice, the Win32 progress window, and
  the agent itself (`runRebuildHelperMode`, dispatched from `source/app.d`).

## How to check whether a rebuild already happened

Do this **before** concluding any change is complete:

1. **Reports/logs** — read `rebuild-report.txt` and `build.log` in the repo root
   if present. They contain the compiler errors and the tail of the build output
   (written by the rebuild agent in `shared/rebuild.d`).
2. **State file** — if `rebuildstate.json` exists, its `status`
   (`pending` / `running` / `ok` / `failed`), timestamps, duration, and log paths
   tell you whether a rebuild is in flight, succeeded, or failed.
3. **Staleness** — if any `.d` file is newer than the built binary, the running
   build is stale.
4. **Exit code / output** — if you ran `dub build` yourself, confirm it exited 0
   and that the binary is newer than the sources.

If the build is stale or failed, say so explicitly and recommend a rebuild
rather than claiming the change works.

## Definition of done for a source change

1. Edit the source.
2. Build (`dub build`), or request the in-app rebuild.
3. Confirm the binary is newer than the edited sources.
4. Confirm the rebuilt app was relaunched.
5. Only then report the outcome, and state what was actually verified.

## Conventions

- Language: D. Match the surrounding style; add comments only where the code is
  not self-explanatory.
- Prefer small, targeted edits over whole-file rewrites.
- Keep the user's existing changes intact; do not revert unrelated edits.
