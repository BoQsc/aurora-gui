# Large Marching Cubes Terrain

A separate 0BSD large-world variant of `marching-cubes-terrain`.

The basic app stays the small, fixed-grid reference. This app owns the larger
terrain field and is free to evolve toward chunked streaming and LOD without
changing the basic app or the generic host.

## Current representation

- 16 x 16 chunked marching-cubes field over 2048 x 2048 x 512 world extents
  (x/z `-1024..1024`, y `-256..256`).
- 48 x 128 x 48 base sampling per chunk; two LODs per chunk.
- Chunk LOD selection at draw time: rings 0 through 4 around the camera chunk
  render at full resolution; every chunk past 4 chunks renders at half
  resolution in all axes (24 x 64 x 24 sampling).
- Startup builds only the LOD each chunk needs at the camera, spread across the
  available CPU cores. A background worker then builds the complementary LODs
  and the main thread uploads them when ready; drawing falls back to a ready
  LOD until then.
- Procedural atmosphere/skybox layer: graded sky bands, horizon haze and sun,
  drawn behind the terrain through the existing HUD pipeline.
- Same `AURSFACE` protocol and generic `aurora-host` window as the basic app.
- 2048x1152 native surface with a flexed host node.

The basic app remains the fixed-grid reference; this app owns chunking, LOD and
the asynchronous mesh handoff.

## Controls

- `F` at the aimed terrain point digs a shallow radius and lowers the surface.
- `G` at the aimed terrain point constructs a raised radius.
- `1`-`4` selects grass, dirt, rock or sand for the next edit.
- Edited chunks rebuild only the affected LOD buffers and are re-uploaded.

## Engine runtime

The app is a renderer/host shell over a small 0BSD terrain game runtime:

- `engine/world.d` — `WorldConfig`: extents, chunk layout, sampling, LOD ring
  radius, far plane and terrain height function.
- `engine/lod.d` — chunk LOD policy: the full-resolution ring radius and the
  per-LOD horizontal and vertical sampling counts.
- `engine/frame_clock.d` — `FrameClock`: the single frame-deadline policy.
- `engine/atmosphere.d` — `SkyPalette`: sky, horizon, ground and sun colors.
- `engine/runtime.d` — `TerrainRuntime`: composed world, atmosphere and clock.

Chunk generation, camera height, render LOD, far-plane and sky colors all read
from `TerrainRuntime`; the app does not own those values independently.

## Build

From this directory:

```text
dmd -release -O -J=. -i -I=../../aurora-d/source -I=. vulkan3d.d -of=build/large-terrain.exe
```

The shaders are embedded with `-J=.`. At runtime the executable also loads its
textures and SPIR-V from the `shaders3d` directory beside the executable or its
parent `build` directory, so the working directory does not matter.

## Run

Open the standalone window by launching the executable with no arguments
(double-clicking it works):

```text
build/large-terrain.exe
```

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

```text
python -B ../verify_animated_surface.py \
  --surface <absolute>/build/large-terrain-live.surface

python -B ../verify_native_surface.py \
  --surface <absolute>/build/large-terrain-live.surface \
  --title "Large Marching Cubes Terrain" --scene terrain.scene.json

python -B ../verify_surface_rate.py \
  --surface <absolute>/build/large-terrain-live.surface --min-fps 60
```

## License

BSD Zero Clause License; see [LICENSE](LICENSE). The basic app and the generic
host are not modified by this app.
