# Aurora Live App Workflow

This is the standard workflow for building an app against Aurora Host v2.
The host stays open; the app is a live D module that publishes frames through a
shared surface.

## Boundary

- `aurora-host` owns the window, scene, input, and presentation.
- The app owns its own process, geometry, state, and pixels.
- `aurora-hotswap` builds the app module, starts the host, watches the source,
  and swaps in a new build without restarting the host.
- App-specific behavior belongs in `apps/<name>/module.d`; it does not belong
  in the generic host.

## App layout

```text
apps/<name>/
  module.d       live app module
  smoke_test.py  project build/frame test
  README.md      app-specific notes
```

Use `apps/pyramid-sample` as the reference sample. `apps/new-app` is the
editable working app that uses the same workflow.

## Surface contract

The module and renderer share an `AURSFACE` memory-mapped file:

- 80-byte header
- 64 pointer events of 24 bytes
- two RGBA frame buffers
- frame bytes = `width * height * 4`

The module writes the inactive frame, flips the active-frame index, increments
the sequence, and waits for the host to acknowledge the sequence. A new app can
reuse the `Surface` struct in `new-app/module.d`; keep the header and frame
layout unchanged.

The host passes these arguments to the module:

```text
--surface <app.surface>
--state <app.state.json>
--seconds <duration>
--build <generation>
```

## Create an app

1. Create `apps/<name>/`.
2. Copy `apps/new-app/module.d` and rename its module.
3. Set the app dimensions, colors, state, and `Revision`.
4. Copy `apps/new-app/smoke_test.py`; update `PROJECT`, title, and watch time.
5. Add a README that links back to this standard.
6. Run the smoke test before the first live session.

No host source change is required for a new app.

## Start live

From `aurora-host/`:

```text
aurora-hotswap.exe dev --source ../apps/<name>/module.d --host aurora-host.exe --out build/<name> --watch 3600 --events pointer --title "<Name>"
```

The host window opens and stays open. Hotswap builds the first generation and
prints:

```text
[1] build=1 buildMs=... hostPid=...
host stays open; edit .../module.d to rebuild
```

### Agent-assisted background launch

When the live app is started by the Aurora OpenCode agent, use the native
background path instead of a Python launcher:

```text
program: aurora-hotswap.exe
args: dev --source ... --host ... --out ... --watch 3600 ...
workdir: aurora-host
background: true
allowSourceBackground: true
```

`allowSourceBackground` is the explicit exception for a long-running,
non-mutating app launcher. Build tools, VCS commands, and source-write targets
still must run in the foreground. Never add a Python process supervisor for
this; hotswap/host are the app runtime.

## Edit live

Edit `module.d` while the session is running. Hotswap detects the change and
prints a new generation:

```text
[2] buildMs=... hostPid=<same host PID>
```

The host PID and window must stay stable. If a build fails, hotswap reports the
compiler error and the previous app remains live; fix the source and save again.

## Verify

A build is not visual proof. Verify both layers:

1. **Runtime:** the host and hotswap PIDs are present; the window title is the
   app title; the latest hotswap generation reports the same host PID.
2. **Project smoke test:**

```text
python -B apps/<name>/smoke_test.py
```

The test copies the module to a temporary directory, runs hotswap, checks
`[1]`, and verifies the first binary PPM frame.

3. **Visual:** capture the host window, then capture again after a delay for an
   animated app. The frames must differ where the app draws. For the New App,
   the two captures show the rotating tetrahedral pyramid.

Use `verify` with the test source as an input when the task requires a tracked
test receipt.

## 3D apps

The standard surface presenter is CPU geometry: rotate points by the frame
tick, apply perspective projection, sort faces far-to-near, and fill triangles.
`new-app/module.d` uses this for its spinning triangular pyramid.

For a true GPU Vulkan path, use the dedicated host child-window swapchain
presenter instead of the shared surface. It requires `VK_KHR_swapchain`; that is
a separate presentation path, not part of this live-surface workflow.

## Stop

Close the host window, or stop the supervised hotswap process. Confirm no stale
`aurora-hotswap.exe`/`aurora-host.exe` pair remains before starting another app.

## Standard checklist

- [ ] App is self-contained under `apps/<name>/`.
- [ ] Module publishes valid `AURSFACE` frames.
- [ ] Host opens with the app title.
- [ ] Hotswap builds generation 1.
- [ ] An edit rebuilds with the same host PID.
- [ ] Smoke test passes.
- [ ] Animated frames are captured at two times and differ.
- [ ] No app-specific logic was added to the generic host.
