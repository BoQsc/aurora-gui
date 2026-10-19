# Aurora standard library boundary

This directory contains code that has earned a frozen, documented contract. It
is separate from `vendor/`, which remains the mutable Aurora-D framework.

## Current standard

- [aurora-standard](aurora-standard/) — version 1.0.0
- Unicode 17.0.0 property tables, grapheme boundaries, bidi resolution, and
  line-break opportunities
- Public API: [docs/api.md](aurora-standard/docs/api.md)
- Machine-readable surface: [api/surface.json](aurora-standard/api/surface.json)
- Migration from vendor imports: [docs/migration.md](aurora-standard/docs/migration.md)

## The rule

Anything under `standard/aurora-standard/` is frozen within its major version.
Consumers should use the API documentation, not read the implementation. A
change requires a version decision and the package verification gate:

```text
python standard/aurora-standard/tools/verify_standard.py
```

The gate verifies the manifest, version agreement, deterministic table
regeneration, the exact public API surface, a documented-API consumer, and the
official Unicode conformance corpora.

## What does not belong here

- Window, widget, platform, renderer, or application policy code
- Font loading, shaping, rasterization, or compositor behavior
- Anything that requires an OS, GPU, font, or app-specific dependency
- Historical logs, release notes, screenshots, or build artifacts

The vendor tree remains the mutable framework. Code moves here only after it has
an external oracle or a framework-wide invariant, deterministic behavior,
complete API documentation, a consumer test, and verified provenance.

## Adding a new standard layer

1. Prove the layer against the promotion checklist.
2. Give it its own version, manifest, API surface, and conformance gate.
3. Add a migration note for consumers.
4. Do not edit a released standard in place; publish a new version.
