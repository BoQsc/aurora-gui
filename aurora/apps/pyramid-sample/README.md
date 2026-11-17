# Pyramid Sample

Reference sample for the Aurora Host v2 live-app workflow. It draws a spinning
3D triangular pyramid (tetrahedron) on a dark grid.

## Pieces

- `module.d` — the sample app. `drawPyramid` rotates four vertices, projects
  them, depth-sorts the four triangular faces, and fills them.
- `smoke_test.py` — builds the module through `aurora-hotswap`, opens the host,
  and verifies the first frame.

The full workflow is in [the live-app standard](../README.md).

## Run

From `aurora-host/`:

```text
aurora-hotswap.exe dev --source ../apps/pyramid-sample/module.d --host aurora-host.exe --out build/pyramid-sample --watch 3600 --events pointer --title "Pyramid Sample"
```

Edit `module.d` while it runs; hotswap rebuilds in the same host. For an
agent-assisted launch, use `background: true` with
`allowSourceBackground: true` on the `run` tool.

## Verify

```text
python -B apps/pyramid-sample/smoke_test.py
```

The sample's visual check captures two host frames after a short delay; the
frames must differ where the pyramid is spinning.
