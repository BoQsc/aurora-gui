# Large Marching Cubes Terrain V2

A separate 0BSD large-world variant of `marching-cubes-terrain`. Version 2
grows the field, adds a third mesh tier, streams tier upgrades as the camera
moves, and drives a full day/night sky with aerial fog.

The basic app stays the small, fixed-grid reference. This app owns the larger
terrain field and is free to evolve toward chunked streaming and LOD without
changing the basic app or the generic host.

## Version 2 representation

- 32 x 32 chunked marching-cubes field over 4096 x 4096 x 512 world extents
  (x/z `-2048..2048`, y `-256..256`).
- 48 x 128 x 48 base sampling per chunk; three LODs per chunk.
- Chunk LOD selection at draw time: rings 0 through 3 around the camera chunk
  render at full resolution (48 x 128 x 48), rings 4 through 7 at half
  resolution (24 x 64 x 24), and rings 8 and beyond at quarter resolution
  (12 x 32 x 12).
- Startup builds the one LOD each chunk needs at the camera, spread across the
  available CPU cores. Only that tier is resident per chunk, which keeps v2's
  1024-chunk field near the v1 memory footprint.
- When the camera moves, a background LOD refresh plans the missing tiers
  nearest-first, builds up to 16 at a time, and uploads them as they complete.
  The previous tier keeps drawing until the replacement is ready.
- Procedural day/night cycle (eight real minutes per 24-hour day): moving sun,
  moon at night, a 240-star field, warm dawn/dusk bands, global scene tint and
  sky-matched distance fog. The HUD shows the in-world clock and phase.
- Same `AURSFACE` protocol and generic `aurora-host` window as the basic app.
- 2048x1152 native surface with a flexed host node.

The basic app remains the fixed-grid reference; this app owns chunking, LOD,
streaming and the living atmosphere.

## Controls

- `WASD` move, `Shift` sprint, `Space` jump, mouse look.
- `T` (hold) accelerates the day/night clock 45x.
- `F` at the aimed terrain point digs a shallow radius and lowers the surface.
- `G` at the aimed terrain point constructs a raised radius.
- `1`-`4` selects grass, dirt, rock or sand for the next edit.
- Left mouse fires; right mouse digs; `B` builds.
- `Esc` releases the mouse; `F1` hides the HUD.
- Edited chunks rebuild only their resident tier and are re-uploaded.

## Engine runtime

The app is a renderer/host shell over a small 0BSD terrain game runtime:

- `engine/world.d` — `WorldConfig`: extents, chunk layout, sampling, LOD ring
  radii, far plane and terrain height function.
- `engine/lod.d` — chunk LOD policy: full/mid/far ring radii and the per-LOD
  horizontal and vertical sampling counts.
- `engine/atmosphere.d` — `SkyPalette`, `paletteForTime`, `sunDirectionAt`,
  clock text and phase names for the day/night cycle.
- `engine/frame_clock.d` — `FrameClock`: the single frame-deadline policy.
- `engine/runtime.d` — `TerrainRuntime`: composed world, atmosphere, lighting,
  clock and time advance.
- `engine/player.d`, `engine/collision.d`, `engine/game.d` — the unchanged
  movement, terrain collision and first-person game runtime.

Chunk generation, camera height, render LOD, far plane, sky colors, fog and sun
direction all read from `TerrainRuntime`; the app does not own those values
independently.

## Build

From this directory:

```text
dmd -release -O -J=. -i -I=../../aurora-d/source -I=. vulkan3d.d -of=build/large-terrain.exe
```

The shaders are embedded with `-J=`. At runtime the executable also loads its
textures and SPIR-V from the `shaders3d` directory beside the executable or its
parent `build` directory, so the working directory does not matter.

If a shader is edited, rebuild its SPIR-V first:

```text
tools/glslang/bin/glslang.exe -V -S vert shaders3d/terrain.vert -o shaders3d/terrain.vert.spv
tools/glslang/bin/glslang.exe -V -S frag shaders3d/terrain.frag -o shaders3d/terrain.frag.spv
tools/glslang/bin/glslang.exe -V -S vert shaders3d/cube.vert -o shaders3d/cube.vert.spv
tools/glslang/bin/glslang.exe -V -S frag shaders3d/cube.frag -o shaders3d/cube.frag.spv
```

## Run

Open the standalone window by launching the executable with no arguments
(double-clicking it works):

```text
build/large-terrain.exe
```

Start at a specific in-world time, or against a surface:

```text
build/large-terrain.exe --render --out build/v2.ppm --time-of-day 18
build/large-terrain.exe --animate --surface <absolute>/build/large-terrain-live.surface --time 30
build/large-terrain.exe --topmost
```

`--topmost` pins the standalone window above other applications for demos.
`--window-shot <file.ppm>` captures the standalone swapchain frame after 20
frames, including the HUD, for deterministic visual checks.

Start the surface producer:

```text
build/large-terrain.exe --animate \
  --surface <absolute>/build/large-terrain-live.surface \
  --out <absolute>/build/large-terrain.ppm --time 3600
```

Start the generic host:

```text
../aurora-host/aurora-host.exe --run <absolute>/terrain.scene.json
```

## Verification

Build and run the runtime tests:

```text
dmd -release -O -i -I=. test_lod.d mcmesh.d -of=build/test_lod.exe
dmd -release -O -i -I=. test_atmosphere.d -of=build/test_atmosphere.exe
dmd -release -O -i -I=. test_game.d mcmesh.d -of=build/test_game.exe
dmd -release -O -i -I=. test_player_physics.d -of=build/test_player_physics.exe
dmd -release -O -i -I=. test_terrain_edits.d mcmesh.d -of=build/test_terrain_edits.exe

build/test_lod.exe
build/test_atmosphere.exe
build/test_game.exe
build/test_player_physics.exe
build/test_terrain_edits.exe
```

Check the live surface when a host is consuming it:

```text
python -B ../verify_animated_surface.py \
  --surface <absolute>/build/large-terrain-live.surface

python -B ../verify_native_surface.py \
  --surface <absolute>/build/large-terrain-live.surface \
  --title "Large Marching Cubes Terrain V2" --scene terrain.scene.json

python -B ../verify_surface_rate.py \
  --surface <absolute>/build/large-terrain-live.surface --min-fps 60
```

## License

BSD Zero Clause License; see [LICENSE](LICENSE). The basic app and the generic
host are not modified by this app.
