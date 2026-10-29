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

`dub build --build=release` is worth it for interactive animation preview: on
the 72 MB reference scene it loads, bakes, and audits a frame in about 1.2 s
instead of 2.0 s (debug build, measured with `--glb <scene> --check`).

The editor opens with the watertight v3 human base mesh. `mesh.obj` and
`mesh.glb` are the default Save/Load targets.

Headless tools:

```text
aurora-mesh.exe --check
aurora-mesh.exe --render build/human.ppm --width 1100 --height 800
aurora-mesh.exe --export-obj build/human.obj
aurora-mesh.exe --export-glb build/human.glb
aurora-mesh.exe --export-rig build/rig.glb
aurora-mesh.exe --screenshot build/editor.ppm --width 1400 --height 860
aurora-mesh.exe --obj mesh.obj
aurora-mesh.exe --glb mesh.glb
aurora-mesh.exe --glb character.glb --glb-anim AK47_Run --glb-time 1.0
aurora-mesh.exe --glb character.glb --glb-anim AK47_Run --glb-morph
aurora-mesh.exe --glb character.glb --export-static-glb baked.glb
aurora-mesh.exe --glb character.glb --live build/live.json
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
- `C`: toggle backface culling (turn it off for imported OBJ meshes that are
  wound inconsistently).
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
- `,` / `.`: step one 1/30-second frame and pause.

The sidebar has Human v3, Human v2, Human v1, Reset view, Wireframe, Save OBJ,
Load OBJ, Save GLB, and Load GLB buttons. The sculpt tools are keyboard-driven;
the current tool and mirror state are shown in the sidebar.

## Viewport rendering

The viewport is a software rasterizer, so its behavior is part of the editor
rather than a driver detail:

- Triangles that cross the camera are clipped against the near plane, so a face
  keeps its visible part instead of disappearing when you zoom into the body.
- UVs, depth, and shading use perspective-correct (`1/z`) interpolation, so
  textures do not swim on surfaces that recede from the camera.
- Single-sided faces are backface culled, which both halves the fill work on
  closed meshes and honors the glTF `doubleSided` flag. The winding convention
  is validated by a unit test that compares culled and un-culled renders of a
  closed base mesh.
- Picking and sculpting are occlusion aware. Clicking the chest selects the
  front vertex instead of a hidden vertex on the back, and a brush stroke at the
  surface leaves the far side of the body untouched.

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
`--glb-morph` enables animated morph weights. Large corrective sets such as
the reference body's 228-target set are skipped to preserve the skin; facial
and other small-target sets animate. `--glb-no-morph` disables them.

The reference `Human.AK47.r12.glb` scene imports with 155 nodes, 45 meshes,
33 materials, 30 textures, 24 images, 2 skins, and 22 animations. Its
`AK47_Run` clip at 1.0 s renders with the skeleton and textures applied.

`Save GLB` on a loaded scene writes the original binary unchanged, preserving
features the editor does not author. `--export-static-glb` bakes a frame with
embedded UVs, PNG textures, and materials. `--export-glb` for generated human
meshes writes a static geometry/material GLB. Loaded-scene mutation/export,
Draco, BasisU, full PBR/material extensions, normal/emissive maps, cameras, and
lights are not implemented yet.

## Live authoring

The running editor watches a local JSON command file. `--live <path>` selects
it; the default is `build/live.json`. It writes `build/live-ack.json` after
applying a revision. Edits are rebuilt in the viewport immediately.

```json
{
  "revision": 3,
  "commands": [
    {"type": "animation", "name": "AK47_Run", "time": 1.0},
    {"type": "pose", "node": "RightArm",
     "rotation": [0.0, 0.382683, 0.0, 0.92388]},
    {"type": "object", "shape": "rifle", "node": "RightHand",
     "offset": [0.0, 0.0, 0.0], "rotation": [0, 0, 0.382683, 0.92388],
     "scale": 0.35, "color": [0.45, 0.28, 0.12]},
    {"type": "new-animation", "name": "ArmWave", "duration": 2.0,
     "loop": true, "tracks": [
       {"node": "RightArm", "keys": [
         {"time": 0.0, "rotation": [0, 0, 0, 1]},
         {"time": 1.0, "rotation": [0, 0, 0.966, 0.259]},
         {"time": 2.0, "rotation": [0, 0, 0, 1]}
       ]}
     ]},
    {"type": "save", "path": "build/live-export.glb"},
    {"type": "clear"}
  ]
}
```

- `animation` selects a clip by name/index and sets time.
- `pose` applies a node-local translation, quaternion rotation, and/or scale
  to a named bone. Repeating the node replaces its override; `reset: true`
  clears it.
- `object` creates an owned procedural object. Supported shapes are `box`,
  `sphere`, `rifle`, and `weapon`. With `node`, the object is attached to that
  baked bone and `offset` is bone-local; otherwise `position` is world-space.
  `path` imports an OBJ instead of a built-in shape. `rotation` is a local
  quaternion, `color` is RGB, and `save` writes the current baked mesh to GLB
  after the revision rebuild.
- `new-animation` authors a named, loopable bone clip from local keyframes.
  `Space` plays/pauses it, `N` restarts it, and `[` / `]` scrub it.
  `additive: true` treats the rotations as deltas on the base GLB clip instead
  of replacing the base pose.
  A key may carry `"worldAxis": "x" | "y" | "z"` (or a 3-number vector) plus
  `"angle"` in degrees instead of a quaternion. The editor resolves the axis in
  the bone's base pose and keeps its rest orientation, in both replace and
  additive clips, so a key means "spin this bone about a world axis" exactly.
  `"follow": [{"node": "AK47_Mount", "target": "Spine2"}]` generates the socket
  track from a world-axis target track: the socket rotates with the target and
  orbits its pivot about it, which keeps a socketed prop rigidly in the hands.
  Follow needs replace-mode clips and world-axis keys on the target.
- `check` reruns the collision audit at the current pose.
- `frame` sets a frame number (1/30-second steps) and pauses; `pause` pauses.
- `keyframe` inserts/replaces a keyframe at the current (or supplied) time:
  `{"type":"keyframe","node":"RightHand","time":1.0,"rotation":[0,0,0,1]}`.
  `remove-keyframe` removes one.
- `audit` validates mesh indices/normals, key ordering, duration, and track
  integrity, then writes `build/live-audit.json`.
- `scan-frames` bakes and validates every 1/30-second frame, then writes
  `build/live-frames.json` with per-frame validity, bounds validity, hand-jump
  distance, limb/torso proximity hits, and `awarenessValid`.
- `inspect-bone` writes `build/bone-info.json` with the named bone’s world
  position and world-space X/Y/Z axes. Use this before authoring a rotation.
- `list-bones` writes `build/bones.json` with every node's index, name, parent,
  child count, deform-joint flag, world position, and world X/Y/Z axes at the
  current pose. Dump it once before authoring to see what the rig offers.
- `pose-axis` applies a rotation around a named local axis (`x`, `y`, or `z`)
  instead of a guessed quaternion.
- `capture` writes the current viewport to a PPM without changing window focus:
  `{"type":"capture","path":"build/view.ppm"}`.
- `scan-frames` accepts `"collisions": true` to run full triangle self-intersection
  checks per frame, excluding the baseline collision keys.
- `clear` removes pose overrides and live objects.

Reports (`live-ack.json`, `live-audit.json`, `live-frames.json`,
`bones.json`, `bone-info.json`) are rewritten through a temporary file and
rename and escape every string, so a poller never parses a half-written or
invalid file, even with absolute Windows paths. A tick holds a mutex, so the
window callback and the headless driver thread cannot interleave authoring,
baking, scanning, and reporting.

The acknowledgement separates `baselineCollisions` (same-frame base animation
overlap) from `collisions` (new animation/object overlap), and includes
`collisionSample` and `collisionFaces`. The audit uses a spatial grid and
triangle intersection over the baked mesh; adjacent faces are ignored.
Overlaps can still be intentional, such as layered clothing or eye shells, so
treat the new-pair count as a warning to inspect, not an automatic failure. A
`check` command forces a fresh scan; revisions that change geometry or poses
also scan once.

This is a live authoring and preview path, not a complete scene editor.
Objects are procedural or OBJ, poses are node-local overrides, and edits are
not serialized back into a live skinned scene. GLB scene injection, CSG, undo
transactions, and a live scene graph/network protocol are the next production
steps.

## Animation clips

Authored clips live in `assets/animations/*.json` as declarative data, so they
can be reviewed, diffed, and replayed without the editor UI:

```json
{
  "name": "RightSnapKick", "fps": 30, "duration": 1.2, "loop": true,
  "watch": {"node": "RightFoot", "minTravel": 0.5},
  "tracks": [
    {"node": "RightUpLeg", "keys": [
      {"time": 0.0, "worldAxis": "x", "angle": 0.0},
      {"time": 0.3, "worldAxis": "x", "angle": -70.0}
    ]}
  ]
}
```

Optional blocks: `follow` (socket generation), `grip`
(`pivotNode`/`socketNode` for the hand-drift check), `watch` (a node that must
travel at least `minTravel` metres), `scene` (a rig other than the fixture), and
`checks` (`{"collisions": false}` for assets whose base mesh already
self-intersects).

`tests/replay_clip.py` wraps a clip into a live revision, scans every frame with
collision checks, reads `build/live-frames.json`, renders a frame sheet, and
fails on any invalid frame, collision pair, limb hit, bounds problem, short
motion, or grip drift. `tests/probe_joint_limits.py` sweeps one joint to report
the angle range that stays collision free, which is what a kick or lift should
be designed against.

`RightSnapKick` is a 36-frame right front snap kick: chamber, snap, retract, and
recover. It changes only the kicking leg, the spine lean, and the arms, so the
support foot stays exactly planted and the hips never slide.

## Rig fixture

`--export-rig build/rig.glb` writes a 732-vertex, 1,388-face, 20-joint skinned mannequin
with standard bone names (`Hips`, `Spine`, `Spine2`, `Neck`, `Head`,
`Left/RightShoulder`, `Arm`, `ForeArm`, `Hand`, `UpLeg`, `Leg`, `Foot`). Every
vertex is rigidly bound to one bone, so the fixture has no weights to debug and
the rest pose has no self-intersections.

Its segments are tapered with a pinched cap at each joint, and the cap radius is
smaller than the joint inset. Two caps therefore stay apart at every bend angle,
which is why a knee can fold past 110 degrees without a false collision report.
That makes the fixture a reproducible target for animation tests without the
72 MB reference asset.

## Remaining gaps

- The v3 body is a repaired CC0 reference body, not a from-scratch result and
  not a rigged, game-ready asset. Further anatomy and silhouette refinement is
  still needed for a final character.
- Animated corrective sets larger than 64 targets are skipped to protect the
  reference skin. Large body/vehicle morph animation is therefore incomplete.
- Missing glTF rendering features: metallic/roughness, normal, emissive, and
  occlusion maps; texture transforms; advanced material extensions; animation
  blending/events; cameras; lights; and non-triangle primitive rendering.
- The rasterizer samples textures with nearest-neighbor filtering only: there is
  no mipmap chain, anisotropic filtering, or multisample antialiasing, and
  blended faces are drawn in face order rather than sorted back to front.
- Missing asset forms/compression: arbitrary GLB scene injection, Draco,
  BasisU/KTX2, meshopt, quantization
  extensions, and external URI images/buffers.
- Authored clips are data, not glTF animation: there is no writer that injects a
  live-authored clip back into a GLB animation, so a clip ships as JSON plus the
  rig it was authored for.
- Full scene authoring is absent. Loaded scenes support pass-through save and
  baked static export, but edited hierarchies, skins, animations, and morphs
  cannot be serialized back as a live scene.
- The editor still does not author UVs, skeletons, skin weights, morph targets,
  materials, extrusion, loop cuts, subdivision, or multi-object scenes.

## Files

- `source/auroramesh/mesh.d` — mesh types, v1 humanoid, normals, OBJ I/O.
- `source/auroramesh/sdf.d` — SDF primitives, smooth union, and cuts.
- `source/auroramesh/surface_nets.d` — watertight SDF surface extraction.
- `source/auroramesh/human_v2.d` — v2 anatomy and materials.
- `source/auroramesh/sculpt.d` — smooth/inflate brushes, symmetry lookup, full
  undo snapshots (geometry, materials, UVs, and textures).
- `source/auroramesh/decimate.d` — edge-collapse decimation experiment for v3.
- `source/auroramesh/human_v3.d` — embedded natural low-poly v3 body.
- `assets/human_v3.obj` — v3 body asset.
- `assets/PROVENANCE.md` — CC0 reference provenance and repair steps.
- `source/auroramesh/glb.d` — GLB 2.0 container, accessor, node-transform, and material I/O.
- `source/auroramesh/gltf_scene.d` — full scene import, textures, skinning, morphs, and animation baking.
- `source/auroramesh/rig_fixture.d` — skinned test mannequin generator and its GLB writer.
- `source/auroramesh/live.d` — owned procedural live-authoring objects.
- `source/auroramesh/camera.d` — orbit camera, perspective projection, and the
  near-plane constant.
- `source/auroramesh/renderer.d` — z-buffered shaded rasterizer with near-plane
  clipping, perspective-correct attributes, backface culling, grid, wireframe.
- `source/auroramesh/edit.d` — occlusion-aware vertex picking, surface-limited
  brush selection, ray/mesh queries, and constrained screen drag.
- `source/auroramesh/editor.d` — Aurora viewport and editor chrome.
- `source/auroramesh/main.d` — CLI and GUI entry point.
- `assets/animations/` — authored clips (`right-snap-kick.json`, `rifle-ready-idle.json`).
- `tests/replay_clip.py` — replays a clip through the live protocol and audits every frame.
- `tests/probe_joint_limits.py` — sweeps a joint to report its collision-free range.
- `tests/test_animation_clip.py` — structural checks for the clip assets.

## Verify

```text
dub test
aurora-mesh.exe --check
aurora-mesh.exe --render build/human.ppm
aurora-mesh.exe --screenshot build/editor.ppm
aurora-mesh.exe --export-rig build/rig.glb
python -B tests/test_animation_clip.py
python -u tests/replay_clip.py --clip assets/animations/right-snap-kick.json
python -u tests/replay_clip.py --clip assets/animations/rifle-ready-idle.json
```

`--check` validates indices, bounds, OBJ round-trip, watertightness, and edge
counts. `dub test` covers v1/v2/v3 generation, SDF primitives, sculpting,
GLB/OBJ I/O, projection, picking and brush visibility, near-plane clipping,
perspective-correct texturing, backface culling versus `doubleSided`, and
axis-locked drag math.

The clip replays are the animation gate: they assert zero invalid frames, zero
new collision pairs, zero limb hits, valid awareness, a minimum watched-node
travel, and (for socketed props) under 3 mm of grip drift. The fixture replay
runs anywhere; the reference-rig replay reports itself as skipped when
`build/full-scene-copy.glb` is absent, because that asset is user supplied.

This first editor intentionally does not provide extrusion, loop cuts,
subdivision, authored UVs/skinning/animation, or multi-object scenes. It is a
usable selection-and-transform base mesh editor, not a replacement for Blender.
