# Aurora v2

Aurora v2 is the self-contained GUI foundation for the Aurora suite. It lives in
one folder and contains four sibling packages. Its primary application path is
an `aurora-host` scene, not a new window executable built around `GuiWindow`.
The one standalone GUI executable is the pre-existing `aurora-designer`
design-time tool.

| Folder | What it is |
|---|---|
| `aurora-d/` | The GUI library: Vulkan and software rendering, the retained compositor, widgets, and the pure-D Unicode/OpenType text engine. It is the foundation used by the host, not the default application entry point. Semantic version `2.0.0`; the folder name carries no version. |
| `aurora-standard/` | The frozen Unicode 17.0.0 text standard used by the host. |
| `aurora-designer/` | The existing visual UI designer and design-time tool, with a hierarchy-aware canvas, Layers tree, inspector hierarchy controls, and a visible frameless titlebar. It depends on `aurora-d`; it is not a template for new applications. |
| `aurora-host/` | The primary GUI application path: retained-scene host, runner, and live scene editor. It stays a separate executable and remains a leaf. |

`libraries/` is the shelf for experimental, general-purpose library packages.
It is deliberately outside the v2 verification gate: `verify.py` neither builds
it nor treats its packages as foundation code, and no application links it by
default. The manifest rules that still apply repository-wide are listed in
[libraries/README.md](libraries/README.md).

Aurora Designer is the first existing application moved into v2. The remaining
applications in the parent `aurora-gui` repository keep their existing sources
and continue to build against their current `vendor/aurora-d-0.4.5` copy until
they are moved. They are migration sources, not templates for new work. The v2
tree establishes the clean foundation they can adopt: one library copy, the
standard next to it, the host outside the library, and the designer as a
separate design tool.

Why this layout:

- one GUI library source, with no version number in its folder name;
- the standard is a package beside the library, not a second copy inside it;
- the host is separate and no framework package depends on it;
- the host is the primary application shell; new GUI products are scenes, not
  another standalone window executable;
- the designer is a design-time tool for the library, not a new application
  template;
- release history stays in the package that owns it (`CHANGELOG.md`, `docs/`).

## Start with aurora-host

New GUI application work starts with a validated scene (`.scene.json`) run by
`aurora-host`. The host owns the window, retained tree, layout, painting, input
routing, DPI, dialogs, and composition. Application domain state and policy stay
outside the host and use the scene plus the versioned control/shared-surface
contract when they need to interact.

Do not create a new executable around `new GuiWindow(...)` to deliver an
application. Direct library window construction is reserved for host internals,
framework tests, and a specialized embedder that the project owner has
explicitly approved. The `GuiWindow` examples in the library documentation
describe library mechanisms; they are not the application template.

The host remains a leaf. Applications do not import or link `aurora-host`; they
run it and communicate through its public scene and control contracts.

## Requirements

- Windows 10/11 x64 with DMD and DUB on `PATH`.
- No third-party DUB dependencies. Vulkan is resolved at runtime; the software
  renderer is the fallback.

## Build and run

Run each block from this `aurora/` folder.

GUI application (the default path):

```bat
cd aurora-host
dub run --config=host --compiler=dmd -- samples/hello.scene.json
```

Live scene building:

```bat
cd aurora-host
python -B tools/live_host.py --scene samples/notepad-icon.scene.json
```

Framework development: GUI library:

```bat
cd aurora-d
dub build --config=library --compiler=dmd
dub run --config=headless-test --compiler=dmd
```

Design-time UI tool (existing tool, not a new product template):

```bat
cd aurora-designer
dub run --config=default --compiler=dmd
dub run --config=headless-smoke --compiler=dmd
```

Host framework development:

```bat
cd aurora-host
dub run --config=host-headless -- --render samples/hello.scene.json --out build/hello.ppm
dub run --config=host -- samples/hello.scene.json
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
builds the designer and runs its headless smoke, builds both host
configurations, renders a sample scene, and runs the full host verification. It
uses Python only; the v2 tree contains no shell scripts.
Individual commands are listed in the package READMEs.

## Licenses

The library, standard, designer, and host source are released under 0BSD; see
each package's `LICENSE`. Documentation and sample content use the terms in the
package they belong to. Third-party notices stay with the package that uses the
material.

## Practices

[Best practices](BEST-PRACTICES.md) is the short, enforceable v2 guide: ownership,
the promotion rule, rendering and interaction rules, and verification discipline.
Detailed framework docs live in `aurora-d/docs/`; the host's normative rules live
in `aurora-host/RESPONSIBILITY.md`.
