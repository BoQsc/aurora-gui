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

## Build

- Run `dub build` from the repository root (release builds use
  `--build=release`).
- Do **not** build in a way that overwrites the live executable while it is
  running. Use the rebuild/restart flow instead.
- Rebuild/restart flow: the app records that a rebuild is needed, exits, the
  helper `aurora-rebuilder.exe` runs `dub build`, and the app is relaunched
  (`bin/restart-now.bat` drives the no-rebuild/run path).
- Build-side support lives in `tools/rebuilder.d`; in-app build-awareness lives
  in `source/auroraopencode/rebuildnotice.d` and
  `source/auroraopencode/rebuild.d`.

## How to check whether a rebuild already happened

Do this **before** concluding any change is complete:

1. **Reports/logs** — read `rebuild-report.txt` and `build.log` in the repo root
   if present. They contain the compiler errors and the tail of the build output
   (written by `tools/rebuilder.d`).
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
