# Working standard: program mode vs model mode

This project is worked in exactly one of two modes at a time. Mixing them is what
makes sessions confusing: program work needs the binary rebuilt and relaunched, model
work needs the window left open. State the mode at the start of a session, and switch
only deliberately.

## Mode 1 — program work (aurora-mesh / aurora-mesh editor)

Applies to any change under `source/`, `tests/`, or the vendored platform.

* Relaunching is expected: the running executable is locked, so a new build means a
  new process. Reuse one folder rather than inventing a new one per launch:
  `%TEMP%\aurora-mesh-live\`.
* Before relaunching: `dub build --dest=build/verify`, `dub test`, and the checkout
  checker `python -u -B -m unittest discover -s tests -p verify_*.py -v`
  (or `.aurora/verify-mesh.json`).
* Every new mechanism gets a test that can fail. Keep tests in `tests/` or module
  `unittest` blocks, never inline in the feature path.
* Prefer a general mechanism over a per-body-part one: regions, SDF fields, carve,
  deform, camera — not a `feet.d`.

## Mode 2 — model work (the mesh and its data)

Applies to `assets/*.json` and anything expressed as live commands.

* **One live window, kept open.** Launch it once per program build:
  `aurora-mesh.exe --glb build/verify-human.glb --live live.json`
  from `%TEMP%\aurora-mesh-live\`.
* Drive every change by editing `live.json` and bumping `revision`. Do not restart
  the window, and do not run extra headless renders for iteration.
* Look through the window itself: send `camera` + `capture`, then read the image it
  wrote. A headless render is a different pipeline and can disagree.
* Read the window's answer from `%TEMP%\aurora-mesh-live\build\live-ack.json`:
  `replaceOk`, `replaceReason`, `shellFaces`, `maskVerts`, `meshFaces`, `meshWarning`,
  `camDistance`.

### Live command reference

| type | fields | meaning |
|---|---|---|
| `region` | `name`, `kind` (box/sphere/capsule), `a`, `b`, `falloff` | select a volume; later edits use it |
| `deform` | `region`, `op` (inflate/pull/flatten/pinch/smooth), `amount`, `direction` | move existing vertices, mask-weighted |
| `replace` | `kind`: `carve` \| `sdf` \| `subdivide` \| `decimate`, `region` | change topology, gated by mesh health |
| `camera` | `target`, `yaw`, `pitch`, `distance`, `fov` | frame a detail from the live window |
| `capture` | `path` | write the window's current frame as PPM |

`sdf` takes `cell`, `blend`, `shapes` (sphere/ellipsoid/taper/plane) and `cuts`
(any shape, subtracted). A `plane` cut flattens (e.g. a sole); a sphere cut leaves a
flap.

Deforms and replacements are **state**: they are replayed after every rebake, deforms
first, then replacements.

## Switching

* Program → Model: build, relaunch once, then stay in model mode.
* Model → Program: say so explicitly, because the window will be closed and rebuilt.
  Never close the window "just to check something" — that is the confusion this
  standard exists to prevent.

## Reporting

Program changes report tests and the checks that ran. Model changes report the capture
the window wrote and what is still wrong in it. Neither claims the other's result.
