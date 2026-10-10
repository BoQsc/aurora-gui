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

- User preference: always rebuild after completing an implementation, verify
  the rebuilt binary and its relaunch, then check delivery performance. A
  source-only result is not completion. Prefer the in-app `rebuild` tool. If an
  external coding session does not expose it and Aurora is already closed,
  invoke the same rebuild flow through a detached copy of the application with
  `--aurora-rebuild-helper`; provide the current package and executable paths.
  Keep local verification rebuilds local with `FORGE_PUBLISH_SKIP=1`. Do not
  replace this flow with a manual build against a running executable. Report
  measured client overhead separately from provider/network latency; do not
  claim an absolute latency minimum from a finite benchmark.

- Apply a source change with the in-app **`rebuild` tool**, not a manual
  `dub build`/`dub run`. The tool closes the app, runs `dub build --build=release`
  in the package root, and relaunches it with the new build.
- Do **not** run `dub build` or `dub run` while the app is running. The live
  executable is locked, so DUB cannot replace it: the command either fails or
  rewrites the file while the old build keeps running, the edit never goes live,
  and the agent ends up recompiling the `.exe` over and over instead of
  triggering a rebuild. The `run` tool refuses `dub build`/`dub run` in Aurora's
  own package for exactly this reason. Use `dub test` (or a target with a
  separate output) when a build-only check is genuinely needed.
- Rebuild/restart flow: the app copies *itself* to a throwaway
  `bin/aurora-rebuild-helper-<pid>.exe`, spawns that copy as the agent, and then
  closes immediately; there is no separate helper executable to build or keep in
  sync. The agent waits for the image to be released, shows a small
  always-on-top progress window, runs `dub build` in place, records the
  lifecycle in `rebuildstate.json`, and relaunches the app supervised. A failed
  compile relaunches the previous build and the relaunched app reports the
  errors. `bin/restart-now.bat` and `bin/supervise-now.bat` drive the no-rebuild
  run/supervise paths; the app selects agent mode in `source/app.d` when `main`
  sees `--aurora-rebuild-helper`.
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
4. **Tool refusal** — a `run` call that reported it refused `dub build`/`dub run`
   means nothing was compiled: use the `rebuild` tool instead.

If the build is stale or failed, say so explicitly and recommend a rebuild
rather than claiming the change works.

## Definition of done for a source change

1. Edit the source.
2. Request the in-app rebuild (`rebuild` tool). Do not run `dub build` yourself -
   it cannot replace the running executable and only recompiles the file.
3. Confirm the binary is newer than the edited sources.
4. Confirm the rebuilt app was relaunched.
5. Only then report the outcome, and state what was actually verified.

## Conventions

- Preserve chat history unless the user explicitly deletes it. Regenerate,
  retry, editing, stopping, compaction and branch navigation must retain prior
  messages and continuations. Regenerated responses need numbered previous/next
  navigation during streaming as well as after completion and reload.

- Language: D. Match the surrounding style; add comments only where the code is
  not self-explanatory.
- Prefer small, targeted edits over whole-file rewrites.
- Keep the user's existing changes intact; do not revert unrelated edits.
