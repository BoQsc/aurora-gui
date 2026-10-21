# Aurora Host World

An isolated 3D demo for `aurora-host`: a procedurally generated terrain world
with water, trees, rocks, a first-person camera, and a player controller. The
demo owns the renderer and simulation; `aurora-host` only displays the frames
and forwards input through a shared memory-mapped surface.

## Architecture

```
aurora-host-world.exe                         aurora-host-experiment.exe
  World / Player / Renderer                     scene: world.scene.json
  writes RGBA frames  ──► build/world.surface ◄── reads active frame
  reads input ring    ◄── build/world.surface ◄── host input bridge
```

- `source/world/world.d` — height field, terrain/water/prop meshes, spawn
  selection, player physics, input state.
- `source/world/render.d` — software rasterizer (sky, terrain, water, props,
  fog), first-person camera, HUD.
- `source/world/surface.d` — `AURSFACE` v2 shared surface: 80-byte header, two
  RGBA buffers, 24-byte input events, head/tail ring.
- `source/app.d` — live mode, `--self-test`, `--render`, `--publish`,
  `--no-host`; host spawn/close and input plumbing.

The host scene (`world.scene.json`) contains one `surface` node that maps
`build/world.surface` at 960×540 and subscribes to `pointer` and `key` events.
The surface ABI is an experiment-local contract (protocol/schema versions are
asserted by the host), not a stable plugin API.

## Build

Build the host once (only when its executable is missing or stale):

```
cd experiments/aurora-host
dub build --config=host
```

Then build and run the demo:

```
cd experiments/aurora-host-world
dub build --build=release
.\aurora-host-world.exe
```

The demo looks for `../aurora-host/aurora-host-experiment.exe` and
`world.scene.json`. Use `--host <path>` and `--scene <path>` to override them.
`--host` is intentionally not a dependency of this package: the renderer runs
without any Aurora libraries, and the host can be omitted entirely.

## Controls

| Input | Action |
| --- | --- |
| `W` `A` `S` `D` | Move |
| Mouse drag / arrow keys | Look |
| `Space` | Jump |
| `Shift` | Sprint |
| Mouse wheel | Zoom |
| `R` | Reseed the world |
| `Esc` | Exit |

When run under the host, the demo spawns the host itself and injects input via
the surface ring. When run with `--no-host`, the same loop runs without a host
so the surface can be inspected by another process.

## Modes

```
aurora-host-world.exe --self-test [--seed N]
aurora-host-world.exe --render [frame.ppm] [--seed N]
aurora-host-world.exe --publish [--seed N]
aurora-host-world.exe --no-host [--seconds N]
```

- `--self-test` validates terrain/water/probe counts, key/pointer decoding,
  jump/landing, W movement, settle height, and camera-dependent frame hashes.
  It writes `build/selftest-before.ppm` and `build/selftest-after.ppm`.
- `--render` writes one 960×540 PPM frame.
- `--publish` writes one frame into `build/world.surface` and exits.
- `--no-host` runs the live loop without spawning a host; `--seconds N` makes
  it exit after N seconds of wall-clock time.
- Default mode spawns the host, maps the surface, and runs until the host
  closes (or Esc is pressed).

## Verification

```
.\aurora-host-world.exe --self-test
python -u tools\verify_live.py
```

`verify_live.py` starts the client and host, maps the surface, injects a W press
through the host control socket, asserts the input ring advances from 0 to 1
while held and to 2 after release, and compares host screenshots captured
before, during, and after the hold. The full sequence (release build, self-test,
live check) is also declared in `verify.json`.

For a manual live check:

```
.\aurora-host-world.exe --no-host --seconds 30
# in another terminal:
.\experiments\aurora-host\aurora-host-experiment.exe --run `
    experiments\aurora-host-world\world.scene.json --control
```

Expected evidence from the manual check:

- `surface` reports `mapped: true`, 960×540, and increasing `sequence`.
- Injecting `key down w`, waiting, then `key up w` advances `inputHead` to 1
  while down and to 2 after release.
- Host captures before/after the hold; the HUD moves from the spawn toward the
  world center and the terrain perspective changes.

## Notes and limits

- Rendering is CPU-only and single-threaded; the HUD FPS is the frame rate of
  the software renderer (~30 fps at 960×540 on a typical desktop).
- The surface is double-buffered; consumers must respect the active index and
  copy a frame before the next publish.
- The world, renderer, surface client, and HUD are owned entirely by this
  experiment. No code under `vendor/` or `experiments/aurora-host/` imports
  this package.
