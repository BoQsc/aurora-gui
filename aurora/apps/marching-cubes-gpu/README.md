# Marching Cubes GPU

Vulkan marching-cubes renderer that publishes frames to `aurora-host` through a
shared `AURSFACE`. It follows [the app standard](../README.md).

## Build

From this directory:

```text
dmd -J=. -i -I=../../aurora-d/source -I=. vulkan3d.d -of=build/marching-cubes-gpu.exe
```

`-J=.` embeds `shaders3d/*.spv` into the executable. The built `.exe` has no
shader sidecars.

## Run

With no arguments the executable opens its own 360x240 window and stays open
until you close it. Pass `--render` to render one 360x240 frame to
`vulkan3d.ppm` and exit. For an animated surface, pass `--animate --surface
<path>`. To present inside a host window, start the host scene first and pass
`--host-title "<host window title>"`. The embedded shaders can be overridden
with `--shaders <directory>`.