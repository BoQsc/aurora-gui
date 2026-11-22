# Host responsibility

This document is normative. The structural rules are enforced by
`tools/check_boundary.py`, which runs as part of `tools/verify_host.py`.

## Single responsibility

> The aurora-host owns the retained Aurora UI shell and its platform boundary.

The host turns a validated scene plus platform and application events into one
correctly composited Aurora frame. It does not own what the application's
content means.

## Primary GUI path

The host runtime is the primary application presentation path for Aurora. New
GUI work is a validated host scene, not a new executable that constructs its own
`GuiWindow`. Application policy stays outside the host and uses the public scene
and control/shared-surface contracts. Applications may depend on
`aurora-host-core` for the standard GUI; they must not depend on this CLI
package. Direct window construction is limited to host internals, framework
tests, and an explicitly owner-approved specialized embedder.

## Host-core MUST own

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
- The versioned control/shared-surface contract in [MODULES.md](MODULES.md);
  external modules run out of process and the host never loads them.

## Host-core MUST NOT own

- Browser, JavaScript, 3D-engine, simulation, or application-domain policy.
- Application rendering or asset pipelines. Applications render offscreen and
  publish pixels through the versioned shared surface.
- Per-frame application draw-command production. A client may replace a
  retained canvas, but the client decides what and when to draw.
- Application modules, demo modules, or repository packages other than the
  approved vendor dependencies.
- Module supervision, restart policy, sandboxing, GPU/compositor handoff, audio
  services, a module-facing focus/IME protocol, or packaged browser runtimes.

## Enforcement rules

1. The host CLI dependency set is `aurora-host-core`, `aurora-d`, and
   `aurora-standard`. Host-core depends only on `aurora-d` and
   `aurora-standard`.
2. Host source imports are limited to `aurora.*`, `aurorahost.*`,
   `std.*`, and `core.*`.
3. No package may depend on the `aurora-host` CLI. Applications may depend on
   `aurora-host-core` and import the `aurorahost` namespace only through that
   dependency. Host-core is host code; app domain policy must not be added to
   it. Standalone evidence captures and ignored build output are not packages.
4. The generated protocol/API reference must remain current through
   `tools/generate_reference.py --check`.
5. The semantic rule remains subject to review: a feature that requires knowing
   what application content means does not belong in the host, even if it could
   be implemented without violating the structural checks.

`protocol/aurora-host.boundary.json` is the machine-readable source for the
dependency and import whitelists used by the checker.