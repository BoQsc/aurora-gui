# New App

A live D app for Aurora Host v2. It samples a torus scalar field and renders the
extracted isosurface as a spinning marching-cubes mesh.

## Pieces

- `module.d` — the app. It samples the torus field on a 16³ grid, triangulates
  the isosurface with the standard 256-case marching-cubes triangle table,
  depth-sorts the triangles, and renders them with perspective projection.
- `smoke_test.py` — builds the module through `aurora-hotswap`, opens the host,
  and verifies the first frame.

See [the standard live-app workflow](../README.md) for the full build/run/edit/
verify contract.

## Run

From `aurora-host/`:

```text
aurora-hotswap.exe dev --source ../apps/new-app/module.d --host aurora-host.exe --out build/new-app --watch 3600 --events pointer --title "New App"
```

Edit `module.d` while it runs; hotswap rebuilds in the same host. For an
agent-assisted launch, use `background: true` with
`allowSourceBackground: true` on the `run` tool.

## Verify

```text
python -B apps/new-app/smoke_test.py
```

The visual verification also captures two host frames after a short delay; the
frames must differ where the marching-cubes surface is rotating.
