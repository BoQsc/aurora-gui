# Marching Cubes Terrain

A walkable first-person example built on the primary host-surface GPU path.

The terrain is a heightfield isosurface extracted with the standard 256-case
marching-cubes table. The camera follows the same height function, so walking
keeps the player on the surface. The Vulkan renderer draws offscreen at
1920x1080 and publishes animated `AURSFACE` frames; the host owns the visual
area and scales the native frame into the flexed logical surface.

## Controls

- `W`, `A`, `S`, `D` — move forward, left, back, right
- Hold `Shift` — sprint
- Hover the render area — cursor stays visible
- Click the render area to capture — mouse look, cursor hidden
- `Windows` or `Escape` — release the mouse for titlebar/maximize use
- `F1` — toggle the information panel in the upper-right corner
- Left/Right arrows — turn
- Up/Down arrows — look up/down

Keyboard input is read with `GetAsyncKeyState`; no child window is created.
Mouse look captures only when you click the render area; hovering does not hide
or recenter the cursor. After releasing with `Windows` or `Escape`, click the
render area to capture again. While captured, the host hides the regular
cursor; releasing shows it again.
Camera movement uses frame-delta timing with acceleration and damping, and the
camera height follows the terrain smoothly.

The upper-right information panel shows the frame rate, camera position, and
control hints. Press `F1` to hide or show it.

## Build

From this directory:

```text
dmd -J=. -i -I=../../aurora-d/source -I=. vulkan3d.d -of=build/marching-cubes-terrain.exe
```

`-J=.` embeds `shaders3d/*.spv` into the executable, so the built `.exe` has no
shader sidecars and runs from any directory.

## Run

The app writes a live shared surface:

```text
marching-cubes-terrain.exe --animate \
  --surface <absolute>/build/terrain-live.surface --time 3600
```

The shaders are embedded; `--shaders <directory>` remains available as an
override when you want to load external SPIR-V files.

Then open the host surface scene:

```text
aurora-host.exe --run <absolute>/terrain.scene.json
```

With no arguments the executable opens its own 1280x720 window, renders the
terrain live, and stays open until you close it. Point and click the view to
capture the mouse; the window title is `Marching Cubes Terrain`.

To render one 1920x1080 frame to `vulkan3d.ppm` and exit instead, pass
`--render`. The host-presented shared-surface mode is still selected by
`--animate --surface <path>` plus an `aurora-host` window.

The scene uses `type: "surface"` with `"flex": 1`; this lets the host fill the
available window area instead of keeping the logical node fixed. Without
`flex`, a surface node keeps its preferred height when the host is maximized.
The host scales the 1920x1080 native frame into the resulting node bounds.

## Verification

The primary animated-surface contract must pass while it is live:

```text
python -B ../../verify_animated_surface.py --surface <absolute>/build/terrain-live.surface
```

The native/flex contract must also pass:

```text
python -B ../../verify_native_surface.py \
  --surface <absolute>/build/terrain-live.surface \
  --title "Marching Cubes Terrain" --scene terrain.scene.json
```

The movement-rate contract must pass while the app is running:

```text
python -B ../../verify_surface_rate.py \
  --surface <absolute>/build/terrain-live.surface --min-fps 30
```

Terrain mesh is 23,244 vertices / 23,244 indices at the current 48x20x48
sampling. The implementation links back to [the app standard](../README.md).
