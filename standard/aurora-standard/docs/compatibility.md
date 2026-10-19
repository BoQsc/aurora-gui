# Compatibility and change policy

**Standard version:** 1.0.0  
**Unicode data version:** 17.0.0  
**Status:** standard

## What "frozen" means

Within major version 1, the public modules, public symbol names, signatures,
documented semantics, and Unicode 17.0.0 behavior are frozen. Consumers may
rely on them without reading the implementation.

Frozen does not mean "no maintenance ever." It means:

- no silent edits to the public contract;
- no behavior change without a version decision;
- no in-place replacement of the standard with a newer Unicode data set;
- every change is visible in `MANIFEST.sha256` and the version history.

## Version rules

| Change | Version rule |
|---|---|
| Implementation optimization with identical public behavior | Patch release |
| Security fix with identical public behavior | Patch release, with an advisory |
| New public module or symbol | Minor release |
| New Unicode data version | New minor or major release with a new `spec/unicode/<version>` directory |
| Rename, removal, or changed documented semantics | Major release |
| Silent edit under `standard/` without a version change | Rejected by the manifest and API gates |

A future Unicode release is additive. Unicode 18.0.0 would be
`spec/unicode/18.0.0` and a new standard version; it would not mutate the
17.0.0 tables or the 1.0.0 API in place.

## Public API

The complete public surface is [api/surface.json](../api/surface.json). The
verifier compares that file with the compiler's public symbol set and rejects:

- a documented symbol that no longer exists;
- a new public symbol that is not documented;
- a module that is missing from the surface.

Private symbols, private table layout, allocation strategy, and the internal
removed-level marker are not part of the contract.

## Deprecation

- Deprecation is announced in a minor release.
- The deprecated symbol remains available for at least the rest of major
  version 1.
- Removal happens only in a major release with a migration note.

## Security and correctness exceptions

A correctness or security defect may require an implementation change in a
patch release. The public API and documented behavior remain stable. If the
only correct fix changes documented behavior, it requires a version decision
and a migration note rather than a silent patch.

The standard does not promise that conformance proves memory safety or
resistance to adversarial input. The algorithms are pure and use bounded
result arrays, but security review remains a separate gate.

## Consumer expectations

A consumer may rely on:

- Unicode 17.0.0 property values and conformance behavior;
- the documented boundary and index conventions;
- no I/O, global mutable state, or platform dependency;
- the public symbol set in `api/surface.json`.

A consumer may not rely on:

- private symbols or generated table layout;
- performance beyond the documented allocation shape;
- compatibility with a Unicode version other than 17.0.0;
- behavior outside the documented scope, such as word segmentation or shaping.

## Updating the standard

The intended process is:

1. Propose the change with a version classification.
2. Update the implementation or data only in a new version context.
3. Update `api/surface.json`, `docs/api.md`, and the compatibility notes.
4. Regenerate and verify the manifest.
5. Run the consumer and conformance gates.
6. Record the evidence in `docs/conformance.md`.

The manifest and verifier make an accidental in-place change fail. The policy
makes an intentional change require a version.
