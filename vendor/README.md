# Bundled dependency root

This directory keeps both dependency roles in one place, alongside the
application folders at the repository root:

- `aurora-d-0.4.5/` — the mutable Aurora-D framework and vendor snapshot
- `aurora-standard/` — the frozen, first-party standard package

The `vendor/` folder answers **where a dependency is bundled**, not whether it
is mutable. `aurora-standard/` carries its own `VERSION`, `MANIFEST.sha256`,
API contract, and verification gate; it is not an upstream snapshot and must not
be edited in place.

## Current standard

- [aurora-standard](aurora-standard/) — version 1.0.0
- Unicode 17.0.0 properties, grapheme boundaries, bidi, and line breaks
- Public API: [docs/api.md](aurora-standard/docs/api.md)
- Machine-readable surface: [api/surface.json](aurora-standard/api/surface.json)
- Migration from vendor imports: [docs/migration.md](aurora-standard/docs/migration.md)

## Verification

```text
python vendor/aurora-standard/tools/verify_standard.py
```

The saved recipe is [`.aurora/verify-aurora-standard.json`](../.aurora/verify-aurora-standard.json).
It verifies the manifest, version agreement, deterministic regeneration, the
exact API surface, the documented-API consumer, and all four official Unicode
17.0.0 conformance corpora.

## What does not belong in the standard

- Window, widget, platform, renderer, or application policy code
- Font loading, shaping, rasterization, or compositor behavior
- Anything requiring an OS, GPU, font, or app-specific dependency
- Historical logs, release notes, screenshots, or build artifacts

The standard is frozen within major version 1. A change requires a version
decision and the verification gate; new Unicode data is a new versioned data
set, not an in-place edit.
