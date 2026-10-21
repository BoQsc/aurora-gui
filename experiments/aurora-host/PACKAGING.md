# Portable host package

This document defines the supported distribution layout for the isolated
aurora-host experiment. The package is a directory tree or zip archive that can
be extracted anywhere; no runtime path points back into the source repository.

## Supported target

- Windows x64.
- The executable is built with the repository's DMD toolchain and dynamically
  uses the Microsoft Visual C++ 2013 runtime (`MSVCR120.dll`).
- Install the Microsoft Visual C++ 2013 Redistributable on the target machine
  before launching the package. The package does not include `MSVCR120.dll`;
  Microsoft redistribution terms are not assumed.
- System fonts, `user32.dll`, and `gdi32.dll` are supplied by Windows. The
  package does not bundle fonts or Windows system libraries.
- The scene file and any relative image asset are resolved relative to the
  scene file itself, so the package can be moved as a unit.

## Package layout

```text
aurora-host-<version>-win64/
  aurora-host-experiment.exe     windowed host; also supports check/render
  README.md                     package-local launch instructions
  PACKAGING.md                  this contract
  MANIFEST.sha256               content hashes for every other package file
  PACKAGE-METADATA.json         product, version, platform, runtime prerequisite
  samples/                      scenes and the relative image asset
  licenses/
    LICENSE                     host code: 0BSD
    LICENSE-CC0.txt             documentation and sample content: CC0-1.0
    THIRD-PARTY-NOTICES.md      package-relative third-party index
    aurora-d/
      LICENSE                   aurora-d code: 0BSD
      LICENSE-UNICODE.txt       Unicode data: Unicode License V3
      Microsoft-Terminal-MIT.txt
    aurora-standard/
      LICENSE                   aurora-standard code: 0BSD
      LICENSE-UNICODE.txt       Unicode data: Unicode License V3
    DMD-license.txt             DMD/Phobos: Boost Software License 1.0
```

`MANIFEST.sha256` covers the executable, scenes, documentation, and license
files. The manifest and metadata are the only package files that are generated
after staging.

## Build a package

From `experiments/aurora-host`:

```text
python -B tools/package_host.py --out build/package/aurora-host-0.1.0-win64
```

The tool refuses to overwrite an existing directory or zip unless `--clean` is
passed. It builds the `host` configuration in release mode in the fixed sibling
directory `aurora-host-0.1.0-win64-build` (removed after staging), stages the
explicit file set above, writes the manifest and metadata, and produces
`aurora-host-0.1.0-win64.zip` next to the directory. The fixed build path keeps
the build destination stable. The DMD linker may embed a timestamp, so separate
compiler runs need not be byte-identical; reusing the same executable produces
a byte-identical archive. The DMD license text is copied from the compiler
installation selected by `dmd` on `PATH`; packaging fails if that text cannot
be found.

For a build already produced by the release recipe, pass
`--executable build/package-build/aurora-host-experiment.exe` to stage that
binary without rebuilding it.

## Launch model

From the extracted package root:

```text
aurora-host-experiment.exe --version
aurora-host-experiment.exe --check samples/hello.scene.json
aurora-host-experiment.exe --render samples/hello.scene.json --out out/hello.ppm
aurora-host-experiment.exe --render samples/image.scene.json --out out/image.ppm
aurora-host-experiment.exe --run samples/hello.scene.json
aurora-host-experiment.exe --run samples/hello.scene.json --control
```

`--check`, `--render`, and `--run` accept a path relative to the current
directory or an absolute path. `--run --control` writes `READY` when the control
server is available and then uses newline-delimited JSON on stdin/stdout. A
request is `{"id": <number>, "command": "<name>"}`; responses are
`RESPONSE {...}` and asynchronous notifications are `EVENT {...}`.

The windowed executable retains the full CLI, so the package needs only one
binary. `--render` does not require a visible window and writes a P6 PPM.

## Clean-environment verification

From the source checkout, after creating a package:

```text
python -B tools/verify_package.py --package build/package/aurora-host-0.1.0-win64.zip
```

The verifier extracts the zip into a fresh temporary directory, checks every
manifest hash, runs `--version` and `--check`, renders both a text scene and the
image-asset scene, and drives the live control channel through `ping`, `tree`,
and `close`. It does not add the repository to `PATH`, `PYTHONPATH`, or the
child environment. A failure identifies the missing file, dependency, or
runtime behavior.

## Portability contract

- Every runtime path in the package is relative to the extracted package root
  or to the scene file that references it.
- The package contains no absolute source-checkout paths and no build directory.
- The package contains no `MSVCR120.dll`; the redistributable is an explicit
  prerequisite.
- The package does not claim that all third-party material is 0BSD/CC0. The
  licenses and notices above preserve the Unicode, Microsoft Terminal MIT,
  DMD/Phobos, and zlib terms.
- Rebuilding from the same sources and toolchain is expected to produce the
  same staged file set. The manifest is the authority for the exact bytes in a
  built package.
