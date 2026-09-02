# Legacy Artifacts

This directory isolates legacy/demo influences so new projects (aurora-cut, aurora-stream, etc.) stay clean.

## Structure

- `launchers/` — `RUN-AURORA-D-*.cmd` demo launchers (formerly at repo root). Call `scripts/run-aurora-d-demo.cmd` with `legacy_demos` configs. Path fixed to `..\..\scripts\run-aurora-d-demo.cmd` after move.
- `probes/` — build probe objects `*.obj` (`capturesource_probe*.obj`, `d3d11test_app.obj`, `ytdlp.obj`, etc.) — previously at repo root, now archived here. Gitignored (`*.obj`).
- `vendor-exes/` — built vendor demo executables `*.exe`/`*.pdb` from `vendor/aurora-d-0.4.5/` (`aurora-desktop.exe`, `aurora-notepad.exe`, etc.) — gitignored, moved here to keep vendor clean.

## Vendor demos renamed

`vendor/aurora-d-0.4.5/demos/` → `vendor/aurora-d-0.4.5/legacy_demos/` (D module `demos.*` → `legacy_demos.*`).

- `vendor/aurora-d-0.4.5/dub.json` updated `mainSourceFile`/`sourceFiles` to `legacy_demos/...`
- `vendor/aurora-d-0.4.5/MANIFEST.sha256` hashes recomputed for 8 renamed files
- `vendor/aurora-d-0.4.5/tests/*_probe.d` imports updated to `legacy_demos.*`
- `vendor/aurora-d-0.4.5/scripts/verify-release.*` and `tools/verify_assets.py` path updated

New code should not import `legacy_demos.*`; use `vendor/aurora-d-0.4.5/source/aurora/*` directly. This folder exists solely for isolation.
