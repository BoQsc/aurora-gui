# Host responsibility

This document is normative. The structural rules are enforced by
`tools/check_boundary.py`, which runs as part of `tools/verify_experiment.py`.

## Single responsibility

> The aurora-host owns the retained Aurora UI shell and its platform boundary.

The host turns a validated scene plus platform and application events into one
correctly composited Aurora frame. It does not own what the application's
content means.

## The host MUST own

- Scene parsing, validation, and construction of the retained widget tree.
- The primary Aurora window, its lifecycle, layout, painting, and invalidation,
  plus host-owned dialogs at the same platform boundary.
- Pointer, keyboard, wheel, and tick routing to scene nodes.
- The frame clock and composition of application-supplied surface frames,
  including logical/native DPI scaling and staleness policy.
- Platform adapters at the boundary: file dialogs, clipboard integration, and
  the stdin/stdout control channel.
- Diagnostics for host-owned state, including input-ring saturation and
  discrete-event reserve, surface mapping failures, retry timing, and frame
  freshness.

## The host MUST NOT own

- Browser, JavaScript, 3D-engine, simulation, or application-domain policy.
- Application rendering or asset pipelines. Applications render offscreen and
  publish pixels through the versioned shared surface.
- Per-frame application draw-command production. A client may replace a
  retained canvas, but the client decides what and when to draw.
- Application modules, demo modules, or repository packages other than the
  approved vendor dependencies.

## Enforcement rules

1. The host dependency set is exactly `aurora-d` and `aurora-standard`, at the
   approved vendor paths.
2. Host source imports are limited to `aurora.*`, `experiment.aurorahost.*`,
   `std.*`, and `core.*`.
3. No repository package may depend on the host package, and no source belonging
   to a package may import the `experiment.aurorahost` namespace. The host
   remains a leaf. Standalone evidence captures and ignored build output are not
   packages and cannot create a build dependency.
4. The generated protocol/API reference must remain current through
   `tools/generate_reference.py --check`.
5. The semantic rule remains subject to review: a feature that requires knowing
   what application content means does not belong in the host, even if it could
   be implemented without violating the structural checks.

`protocol/aurora-host.boundary.json` is the machine-readable source for the
dependency and import whitelists used by the checker.