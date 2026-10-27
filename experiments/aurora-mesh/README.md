# Aurora Mesh

A small software-projected 3D mesh editor with a natural low-poly human base
mesh and an owned sculpting pipeline.
It runs on Aurora's normal window, font, and input stack; the 3D viewport is a
z-buffered software rasterizer.

## Run

```text
dub build
aurora-mesh.exe
```

The editor opens with the watertight v3 human base mesh. `mesh.obj` and
`mesh.glb` are the default Save/Load targets.

Headless tools:

```text
aurora-mesh.exe --check
aurora-mesh.exe --render build/human.ppm --width 1100 --height 800
aurora-mesh.exe --export-obj build/human.obj
aurora-mesh.exe --export-glb build/human.glb
aurora-mesh.exe --screenshot build/editor.ppm --width 1400 --height 860
aurora-mesh.exe --obj mesh.obj
aurora-mesh.exe --glb mesh.glb
aurora-mesh.exe --glb character.glb --glb-anim AK47_Run --glb-time 1.0
aurora-mesh.exe --glb character.glb --glb-anim AK47_Run --glb-morph
aurora-mesh.exe --glb character.glb --export-static-glb baked.glb
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
- `G` / `F`: save / load the GLB file.
- `Space`: play/pause a loaded GLB animation.
- `N`: next GLB animation clip.
- `[` / `]`: step animation time.

The sidebar has Human v3, Human v2, Human v1, Reset view, Wireframe, Save OBJ,
Load OBJ, Save GLB, and Load GLB buttons. The sculpt tools are keyboard-driven;
the current tool and mirror state are shown in the sidebar.

## Human base mesh

The default v3 mesh is a natural T-pose body with an anatomically shaped skull,
face, hands, fingers, feet, and separate eyes. It is a single welded body
surface at a game-like triangle budget:

```text
vertices 4953
faces    9966
height   1.804 m
watertight yes (0 boundary, 0 non-manifold)
```

The organic v2 mesh is still available. It is one blended SDF surface extracted
with surface nets and smoothed. Torso, pelvis, shoulders, arms, legs, head,
jaw, chin, nose, ears, eye sockets, hands, and feet all share one continuous
skin instead of
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

v3 is the default. Its body geometry comes from the user-provided CC0
`Human.AK47.r12.glb` reference (`Reference_High_Mesh.001.ThirdPerson`), with
the gear and clothing excluded. Our own pipeline separated, welded, repaired,
and validated the body, then added the separate eye shells. It is a natural
base body, not a from-scratch SDF rebuild and not a game-ready rigged asset.
See `assets/PROVENANCE.md`.

## GLB

`--glb` imports a full glTF 2.0 binary scene: node hierarchy and matrix/TRS
transforms, meshes, indexed triangles, materials, base-color textures, UVs,
PNG/JPEG/WebP images, sparse accessors, morph targets, skins/weights, and
animation clips. `--glb-anim` and `--glb-time` select a clip and time; the
editor uses `Space`, `N`, `[` and `]` for playback. Alpha mask/blend, sampler
wrap modes, cubic-spline animation, and morph-target parsing are implemented.
`--glb-morph` enables animated morph weights; skeleton animation is the safe
default because the reference body's 228 targets still deform the skin.

The reference `Human.AK47.r12.glb` scene imports with 155 nodes, 45 meshes,
33 materials, 30 textures, 24 images, 2 skins, and 22 animations. Its
`AK47_Run` clip at 1.0 s renders with the skeleton and textures applied.

`Save GLB` on a loaded scene writes the original binary unchanged, preserving
features the editor does not author. `--export-static-glb` bakes a frame with
embedded UVs, PNG textures, and materials. `--export-glb` for generated human
meshes writes a static geometry/material GLB. Full scene mutation/export,
Draco, BasisU, full PBR/material extensions, normal/emissive maps, alpha
blending, cameras, and lights are not implemented yet.

## Files

- `source/auroramesh/mesh.d` — mesh types, v1 humanoid, normals, OBJ I/O.
- `source/auroramesh/sdf.d` — SDF primitives, smooth union, and cuts.
- `source/auroramesh/surface_nets.d` — watertight SDF surface extraction.
- `source/auroramesh/human_v2.d` — v2 anatomy and materials.
- `source/auroramesh/sculpt.d` — smooth/inflate brushes, symmetry lookup, undo snapshots.
- `source/auroramesh/decimate.d` — edge-collapse decimation experiment for v3.
- `source/auroramesh/human_v3.d` — embedded natural low-poly v3 body.
- `assets/human_v3.obj` — v3 body asset.
- `assets/PROVENANCE.md` — CC0 reference provenance and repair steps.
- `source/auroramesh/glb.d` — GLB 2.0 container, accessor, node-transform, and material I/O.
- `source/auroramesh/gltf_scene.d` — full scene import, textures, skinning, morphs, and animation baking.
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
counts. `dub test` covers v1/v2/v3 generation, SDF primitives, sculpting,
GLB/OBJ I/O, projection, rasterizer, picking, and axis-locked drag math.

This first editor intentionally does not provide extrusion, loop cuts,
subdivision, UVs, skinning, undo, or multi-object scenes. It is a usable
selection-and-transform base mesh editor, not a replacement for Blender.
