# Aurora Mesh

A small software-projected 3D mesh editor with a procedural human base mesh.
It runs on Aurora's normal window, font, and input stack; the 3D viewport is a
z-buffered software rasterizer.

## Run

```text
dub build
aurora-mesh.exe
```

The editor opens with the watertight v2 human base mesh. `mesh.obj` in this
directory is the default Save/Load target. v3 is selectable but still
experimental.

Headless tools:

```text
aurora-mesh.exe --check
aurora-mesh.exe --render build/human.ppm --width 1100 --height 800
aurora-mesh.exe --export-obj build/human.obj
aurora-mesh.exe --screenshot build/editor.ppm --width 1400 --height 860
aurora-mesh.exe --obj mesh.obj
aurora-mesh.exe --v1
aurora-mesh.exe --v2
aurora-mesh.exe --v3
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
- `H`: regenerate the v3 base mesh.
- `V`: load the organic v2 mesh.
- `1` / `2` / `3`: load v1 / v2 / v3.
- `B`: cycle Grab, Smooth, and Inflate sculpt tools.
- `M`: toggle X symmetry for sculpting and vertex drags.
- `U`: undo the last edit.

The sidebar has Human v3, Human v2, Human v1, Reset view, Wireframe, Save OBJ,
and Load OBJ buttons. The sculpt tools are keyboard-driven; the current tool
and mirror state are shown in the sidebar.

## Human base mesh

The default v2 mesh is one blended SDF surface, extracted with surface nets and
smoothed. Torso, pelvis, shoulders, arms, legs, head, jaw, chin, nose, ears,
eye sockets, hands, and feet all share one continuous skin instead of
intersecting primitive parts. It is still a stylized base/blockout, not an
anatomical final character.

```text
vertices 19920
faces    39836
height   1.827 m
watertight yes
```

The original primitive v1 mannequin is retained and can be loaded with the
Human v1 button, `1`, or `--v1`. Its counts are 1,030 vertices and 1,860 faces.

## v3 status

v3 is a decimation experiment: currently 6,122 vertices and 12,200 faces.
It is intentionally not the default. Its silhouette is still a blockout, and
its boundary edges are not yet clean enough to call watertight. The modeling
tools above are the route to fixing that by hand rather than trusting more
automatic voxel detail.

## Files

- `source/auroramesh/mesh.d` — mesh types, v1 humanoid, normals, OBJ I/O.
- `source/auroramesh/sdf.d` — SDF primitives, smooth union, and cuts.
- `source/auroramesh/surface_nets.d` — watertight SDF surface extraction.
- `source/auroramesh/human_v2.d` — v2 anatomy and materials.
- `source/auroramesh/sculpt.d` — smooth/inflate brushes, symmetry lookup, undo snapshots.
- `source/auroramesh/decimate.d` — edge-collapse decimation experiment for v3.
- `source/auroramesh/human_v3.d` — experimental low-poly v3.
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

`--check` validates indices, bounds, OBJ round-trip, watertightness, and edge
counts. `dub test` covers the procedural mesh, SDF primitives, projection,
rasterizer, OBJ parsing, picking, and axis-locked drag math.

This first editor intentionally does not provide extrusion, loop cuts,
subdivision, UVs, skinning, undo, or multi-object scenes. It is a usable
selection-and-transform base mesh editor, not a replacement for Blender.
