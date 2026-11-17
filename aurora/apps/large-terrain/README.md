# Large Marching Cubes Terrain

A separate 0BSD large-world variant of `marching-cubes-terrain`.

The basic app stays the small, fixed-grid reference. This app owns the larger
terrain field and is free to evolve toward chunked streaming and LOD without
changing the basic app or the generic host.

## Current representation

- 8 x 8 chunked marching-cubes field over 2048 x 2048 x 512 world extents
  (x/z `-1024..1024`, y `-256..256`).
- 32 x 64 x 32 base sampling per chunk; two LODs per chunk.
- Distance-based LOD selection at draw time.
- A worker thread builds the chunk/LOD meshes and hands the completed array
  to the main thread during startup.
- Procedural atmosphere/skybox layer: graded sky bands, horizon haze and sun,
  drawn behind the terrain through the existing HUD pipeline.
- Same `AURSFACE` protocol and generic `aurora-host` window as the basic app.
- 1920x1080 native surface with a flexed host node.

The basic app remains the fixed-grid reference; this app owns chunking, LOD and
the asynchronous mesh handoff.

## Engine runtime

The app is a renderer/host shell over a small 0BSD terrain game runtime:

- `engine/world.d` — `WorldConfig`: extents, chunk layout, sampling, LOD
  distance, far plane and terrain height function.
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

The shaders are embedded with `-J=.`; the executable has no shader sidecars.

## Run

Start the surface producer:

```text
build/large-terrain.exe --animate \
  --shaders shaders3d \
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
