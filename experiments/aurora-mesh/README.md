# Aurora Mesh

A small software-projected 3D mesh editor with a procedural low-poly human
base mesh. It runs on Aurora's normal window, font, and input stack; the 3D
viewport is a z-buffered software rasterizer.

## Run

```text
dub build
aurora-mesh.exe
```

The editor opens with the human base mesh. `mesh.obj` in this directory is the
default Save/Load target.

Headless tools:

```text
aurora-mesh.exe --check
aurora-mesh.exe --render build/human.ppm --width 1100 --height 800
aurora-mesh.exe --export-obj build/human.obj
aurora-mesh.exe --screenshot build/editor.ppm --width 1400 --height 860
aurora-mesh.exe --obj mesh.obj
```

## Controls

- Drag empty viewport space: orbit.
- Drag a vertex: move it in the camera plane.
- Right or middle drag: pan.
- Mouse wheel: zoom.
- `X`, `Y`, `Z`: constrain vertex movement to one world axis; press again to release.
- `Esc`: clear the selection and axis lock.
- `W`: toggle wireframe and vertex dots.
- `S`: save the mesh to the current OBJ path.
- `L`: load the current OBJ path.
- `R`: reset the camera to frame the mesh.
- `H`: regenerate the human base mesh.

The sidebar has equivalent Human base, Reset view, Wireframe, Save OBJ, and Load
OBJ buttons.

## Human base mesh

The procedural mesh is a stylized A-pose mannequin: torso, pelvis, neck, head,
nose, ears, arms, hands, thighs, calves, and feet. It is intentionally a
blockout/base mesh rather than an anatomical final character. Current counts:

```text
vertices 1030
faces    1860
height   1.846 m
```

## Files

- `source/auroramesh/mesh.d` — mesh types, procedural humanoid, OBJ I/O.
- `source/auroramesh/camera.d` — orbit camera and perspective projection.
- `source/auroramesh/renderer.d` — z-buffered shaded rasterizer, grid, wireframe.
- `source/auroramesh/edit.d` — vertex picking and constrained screen drag.
- `source/auroramesh/editor.d` — Aurora viewport and editor chrome.
- `source/auroramesh/main.d` — CLI and GUI entry point.

## Verify

```text
dub test
aurora-mesh.exe --check
aurora-mesh.exe --render build/human.ppm
aurora-mesh.exe --screenshot build/editor.ppm
```

`--check` validates indices, bounds, and OBJ round-trip. `dub test` covers the
procedural mesh, projection, rasterizer, OBJ parsing, picking, and axis-locked
drag math.

This first editor intentionally does not provide extrusion, loop cuts,
subdivision, UVs, skinning, undo, or multi-object scenes. It is a usable
selection-and-transform base mesh editor, not a replacement for Blender.
