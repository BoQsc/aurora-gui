# Aurora Live App Workflow

This is the standard workflow for building an app against Aurora Host v2.
The host stays open; the app is a live D module that publishes frames through a
shared surface.

## Primary visual standard

These rules are mandatory for app presentation:

- **Highest priority: render through Aurora Canvas and text.** New 2D app UI
  and content use `aurora.Canvas` and `aurora.text`/`FontSystem`. Do not use GDI,
  DirectWrite, FreeType, native text APIs, a private glyph atlas, private text
  layout, or a private shape/icon rasterizer. `aurora-hotswap` compiles with
  `aurora-d` on the import path and enables `-i` so app modules can import the
  framework directly.
- The app's visual area is a host-owned `AURSFACE`. Apps must not put their
  primary visual area in an external child HWND or child swapchain. A child
  swapchain can be DPI-virtualized to 288x192 and offset from a 360x240 host
  body; that is the wrong presentation model for apps.
- GPU apps render offscreen at the surface dimensions and publish the result
  through `AURSFACE`. The host owns placement and scaling.
- Animated apps use double buffering on an in-place mapped surface. Do not
  rewrite or replace the surface file for every frame.
- A host surface node must set `"flex": 1` to consume the remaining layout
  space. Fixed `width`/`height` without `flex` intentionally stays fixed when
  the host window is resized or maximized.
- A captured surface hides the cursor from the host window thread and restores
  it on Escape or focus loss. Producer-side `ShowCursor` does not control the
  host window's cursor state.
- Render the native `AURSFACE` at a resolution appropriate to the host window;
  a small fixed frame that the host flexes will be visibly upscaled and
  pixelated. Use the host-preferred pixel size when adaptive production is
  available.
- Size the render/readback target to the host work area and measure its
  publication rate. An oversized offscreen target plus full readback can drop
  movement to slideshow rates; do not add a blind fixed frame sleep. Keep the
  target at or above the host's native size only when the resulting FPS budget
  is met.
- Verify animation with `apps/verify_animated_surface.py`: sequence must
  advance, `host_read` must advance and must have consumed the previous
  sequence, and the active pixels must change. `host_read` may legitimately
  lag the newest sequence by one at an arbitrary sample; never require
  `host_read >= sequence` at a single instant.

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

Use `apps/pyramid-sample` for geometry and `apps/browser-mockup` for Aurora
Canvas/text UI. `apps/new-app` remains the editable working app.

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

`host_read` is the host's consumed sequence. A sample may observe it one frame
behind the just-published sequence; that is normal handshake latency, not a
stalled surface.

The host passes these arguments to the module:

```text
--surface <app.surface>
--state <app.state.json>
--seconds <duration>
--build <generation>
```

## Create an app

1. Create `apps/<name>/`.
2. For 2D UI, copy `apps/browser-mockup/module.d`; for geometry, copy
   `apps/pyramid-sample/module.d`.
3. Draw with `aurora.Canvas` and shape text through `FontSystem`. Do not add a
   private rasterizer or native text API.
4. Set the app dimensions, colors, state, and `Revision`.
5. Copy `apps/new-app/smoke_test.py`; update `PROJECT`, title, and watch time.
6. Add a README that links back to this standard.
7. Run the smoke test before the first live session.

No app-specific host source change is required for a new app. The generic
hotswap tool already puts `aurora-d`/`aurora-standard` on the import path.

## Start live

From `aurora-host/`:

```text
aurora-hotswap.exe dev --source ../apps/<name>/module.d --host aurora-host.exe --out build/<name> --watch 3600 --events pointer --title "<Name>"
```

Add `--width <logical-width> --height <logical-height>` when the app surface is
not the 320x240 dev default. The supervisor uses those values for the host
window and the surface node, so the app is not scaled down to the demo size.

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

4. **Animated surface contract:**

```text
python -B apps/verify_animated_surface.py --surface <app.surface>
```

This asserts sequence progress, host-ack progress, prior-frame consumption, and
changing pixels using the actual live `AURSFACE`.

5. **Native-resolution / flex contract:**

```text
python -B apps/verify_native_surface.py --surface <app.surface> \
  --title "<host title>" --scene <app.scene.json>
```

This verifies that the surface node is flexed and that the published native
surface is at least the host's resized DPI-native pixel size. A flexed but
undersized surface will look visibly pixelated.

6. **Surface publication rate:**

```text
python -B apps/verify_surface_rate.py --surface <app.surface> --min-fps 30
```

This measures actual sequence publication over a live interval. Use the
smallest native target that meets the rate budget; do not mask a slow renderer
with a fixed sleep.

Use `verify` with the test source as an input when the task requires a tracked
test receipt.

## 3D apps

The standard surface presenter is CPU geometry: rotate points by the frame
tick, apply perspective projection, sort faces far-to-near, and fill triangles.
`new-app/module.d` uses this for a marching-cubes torus: a 16³ scalar-field
grid, the standard 256-case triangle table, and a depth-sorted triangle mesh.

For GPU rendering, use offscreen Vulkan and publish `AURSFACE`; see
`apps/marching-cubes-gpu`. A child-window swapchain is not the app visual
standard. It may be used only for a focused swapchain experiment, and its
window sizing/DPI must be verified independently.

## Stop

Close the host window, or stop the supervised hotswap process. Confirm no stale
`aurora-hotswap.exe`/`aurora-host.exe` pair remains before starting another app.

## Standard checklist

- [ ] App is self-contained under `apps/<name>/`.
- [ ] Module publishes valid `AURSFACE` frames.
- [ ] 2D UI and text render through `aurora.Canvas`/`FontSystem`; no GDI or
      private text rasterizer.
- [ ] Host opens with the app title.
- [ ] Hotswap builds generation 1.
- [ ] An edit rebuilds with the same host PID.
- [ ] Primary visual area is host-owned AURSFACE, not an external child window.
- [ ] Smoke test passes.
- [ ] Animated frames are captured at two times and differ.
- [ ] `verify_animated_surface.py` passes for animated apps.
- [ ] `verify_native_surface.py` passes; surface is flexed and native-sized.
- [ ] `verify_surface_rate.py` meets the agreed FPS minimum.
- [ ] No app-specific logic was added to the generic host.
