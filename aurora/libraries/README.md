# Experimental libraries

This folder is the shelf for small, general-purpose D libraries that are not
yet part of the Aurora foundation. Each direct subfolder is one DUB **library**
package.

Status:

- Nothing here is built by `aurora/verify.py`, linked by `aurora-host` or
  `aurora-designer`, or included in a release.
- Nothing here is foundation code. The foundation stays `aurora-d` and
  `aurora-standard`; the v2 tree keeps one copy of each (`BEST-PRACTICES.md`,
  rule 2). Do not fork library code into a package here.
- The repository-wide experimental *application* shelf remains
  [../../experiments](../../experiments). This folder is the v2-side *library*
  shelf.

## Package layout

```
libraries/
  aurora-exp-<topic>/
    dub.json
    source/auroraexp/<topic>/
    tests/
```

Use a unique `aurora-exp-<topic>` name with no version number in it, matching
the naming rule for the foundation packages. `targetName` should be short and
also unique.

## Manifest skeleton

```json
{
  "name": "aurora-exp-<topic>",
  "description": "<one line>",
  "authors": ["Aurora libraries"],
  "copyright": "Copyright (C) 2026 aurora-gui contributors",
  "license": "0BSD",
  "version": "0.1.0",
  "targetType": "library",
  "sourcePaths": ["source"],
  "dependencies": {
    "aurora-d": { "path": "../../aurora-d" },
    "aurora-standard": { "path": "../../aurora-standard" }
  },
  "buildTypes": {
    "portable-release": {
      "buildOptions": ["releaseMode", "optimize", "inline"],
      "dflags-windows-dmd": ["-mscrtlib=libcmt"],
      "dflags-windows-ldc": ["-mscrtlib=libcmt"]
    }
  }
}
```

Two repository-wide checks scan every `dub.json` in the tree, including this
folder, so the manifest must carry:

- `"license": "0BSD"` (`scripts/check_licenses.py`).
- The `portable-release` build type with `-mscrtlib=libcmt` for both DMD and LDC
  (`scripts/verify-windows-portability.py`).

A library has no `mainSourceFile`, so the GUI-subsystem check
(`scripts/verify-windows-gui-subsystem.py`) ignores it. Its consumers own their
own `lflags-windows`.

Those first two checks walk the whole repository, so a run can also print
findings for v2 packages that predate the policy. Those findings are not caused
by a manifest in this folder; keep your own package clean.

## Choosing which `aurora-d` to depend on

The package name `aurora-d` can resolve to only one source per build graph.
Pick the copy that matches the consumer, and keep it consistent inside a
library:

| Consumers | Dependency path |
|---|---|
| v2 packages under `aurora/` | `../../aurora-d` (and `../../aurora-standard`) |
| repository apps and `experiments/` | `../../../vendor/aurora-d-0.4.5` (and `../../../vendor/aurora-standard`) |

A library that depends on `aurora-d` therefore cannot serve both groups at
once. A dependency-free library (only the D runtime and Phobos) can, which makes
plain Win32 image/format tooling safer to share than GUI-linked code.

## Scripts

`aurora/verify.py` fails on any `.bat`, `.cmd`, or `.ps1` file under `aurora/`
outside `apps/`. Build and test with `dub` and Python only, from the package
folder:

```bat
dub build --config=library --compiler=dmd
dub build --build=portable-release --compiler=dmd
python -B tests\<test>.py
```

## Promotion

An experiment leaves this folder only after it proves useful:

- general GUI/text behavior moves into `aurora-d` (or `aurora-standard`) with a
  regression test, following the promotion evidence rules in
  `../BEST-PRACTICES.md`;
- a self-contained dependency-style package moves to the repository `vendor/`
  folder if it is frozen for external use;
- dead experiments are deleted rather than left to rot.
