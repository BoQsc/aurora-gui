# Aurora v2

Aurora v2 is the self-contained GUI foundation for the Aurora suite. It lives in
one folder and contains three sibling packages:

| Folder | What it is |
|---|---|
| `aurora-d/` | The GUI library: Vulkan and software rendering, the retained compositor, widgets, and the pure-D Unicode/OpenType text engine. Semantic version `2.0.0`; the folder name carries no version. |
| `aurora-standard/` | The frozen Unicode 17.0.0 text standard used by the host. |
| `aurora-host/` | The retained-scene host and live scene editor. It is the design-time companion to the library and stays a separate executable. |

This is a reorganization, not a port of every program. The applications in the
parent `aurora-gui` repository keep their existing sources and continue to build
against their current `vendor/aurora-d-0.4.5` copy until they are moved. The v2
tree establishes the clean foundation they can adopt: one library copy, the
standard next to it, and the host outside the library.

Why this layout:

- one GUI library source, with no version number in its folder name;
- the standard is a package beside the library, not a second copy inside it;
- the host is separate and no framework package depends on it;
- demo programs are not duplicated here; the host is the retained-scene shell;
- release history stays in the package that owns it (`CHANGELOG.md`, `docs/`).

## Requirements

- Windows 10/11 x64 with DMD and DUB on `PATH`.
- No third-party DUB dependencies. Vulkan is resolved at runtime; the software
  renderer is the fallback.

## Build and run

GUI library:

```bat
cd aurora-d
dub build --config=library --compiler=dmd
dub run --config=headless-test --compiler=dmd
```

Retained-scene host:

```bat
cd ..\aurora-host
dub run --config=host-headless -- --render samples/hello.scene.json --out build/hello.ppm
dub run --config=host -- samples/hello.scene.json
```

Live design session:

```bat
python -B tools/live_host.py --scene samples/notepad-icon.scene.json
```

The host's editor, scene schema, control channel, and live workflow are described
in [aurora-host/README.md](aurora-host/README.md) and
[aurora-host/LIVE-BUILDING.md](aurora-host/LIVE-BUILDING.md).

## Verify

From this folder:

```text
python -B verify.py
```

That builds the library, runs its headless, public-API, and text-system checks,
builds both host configurations, renders a sample scene, and runs the full host
verification. It uses Python only; the v2 tree contains no shell scripts.
Individual commands are listed in the package READMEs.

## Licenses

The library, standard, and host source are released under 0BSD; see each
package's `LICENSE`. Documentation and sample scene content use the terms in the
package they belong to. Third-party notices stay with the package that uses the
material.

## Practices

[Best practices](BEST-PRACTICES.md) is the short, enforceable v2 guide: ownership,
the promotion rule, rendering and interaction rules, and verification discipline.
Detailed framework docs live in `aurora-d/docs/`; the host's normative rules live
in `aurora-host/RESPONSIBILITY.md`.
