# Marching Cubes Terrain

A walkable first-person example built on the primary host-surface GPU path.

The terrain is a heightfield isosurface extracted with the standard 256-case
marching-cubes table. The camera follows the same height function, so walking
keeps the player on the surface. The Vulkan renderer draws offscreen at 360x240
and publishes animated `AURSFACE` frames; the host owns the visual area.

## Controls

- `W`, `A`, `S`, `D` — move forward, left, back, right
- Left/Right arrows — turn
- Up/Down arrows — look up/down

Keyboard input is read with `GetAsyncKeyState`; no child window is created.

## Build

From this directory:

```text
dmd -i -I=../../aurora-d/source -I=. vulkan3d.d -of=build/marching-cubes-terrain.exe
```

## Run

The app writes a live shared surface:

```text
marching-cubes-terrain.exe --animate --shaders <absolute>/shaders3d \
  --surface <absolute>/build/terrain-live.surface --time 3600
```

Then open the host surface scene:

```text
aurora-host.exe --run <absolute>/build/terrain.scene.json
```

The scene uses `type: "surface"` at 360x240 and no external child window.

## Verification

The primary animated-surface contract must pass while it is live:

```text
python -B ../../verify_animated_surface.py --surface <absolute>/build/terrain-live.surface
```

Terrain mesh is 23,244 vertices / 23,244 indices at the current 48x20x48
sampling. The implementation links back to [the app standard](../README.md).
