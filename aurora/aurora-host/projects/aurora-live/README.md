# Aurora Live

A live-coded Aurora v2 module. The source in `module.d` is the program: the
native supervisor compiles it, starts the new generation as a separate process,
and swaps it into the running `aurora-host` while the window and state stay up.

## Run the demo edit

From `aurora-host/`:

```text
aurora-hotswap.exe live --source projects/aurora-live/module.d --host aurora-host.exe --out build/live-code-demo --demo-edit
```

The supervisor:

1. builds `module.d` with `dmd`;
2. starts generation 1 and maps its surface into `aurora-host`;
3. toggles `enum Revision` in the source (1 → 2);
4. rebuilds the changed source;
5. starts generation 2 and reloads the host scene;
6. verifies the host PID stayed the same, the module PIDs differ, state carried
   over, and the screenshots changed.

Typical output:

```text
PASS live code swap
host: pid=... stable
build v1: 471 ms; build v2: 453 ms
v1: pid=... value=11
v2: pid=... value=12
reload + remap: 24 ms
screenshots: build/live-code-demo/live-v1.ppm -> .../live-v2.ppm
```

The two screenshots are the same host window before and after the source edit:
green/red → blue/orange.

## Edit it yourself

Change `enum Revision`, the colors, or the frame logic in `module.d`, then run:

```text
aurora-hotswap.exe live --source projects/aurora-live/module.d --host aurora-host.exe --out build/live-code-demo --watch 30
```

`--watch` waits for the source file to change, rebuilds it, and swaps the new
generation. `--demo-edit` is the automated version used by verification.

## Boundary

This is compile-and-swap, not in-process code patching. The host remains the
stable window/scene owner; D code changes become a new module process. That is
the safe live-coding model for Aurora v2.
