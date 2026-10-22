# Portable host package

This document defines the supported distribution layout for the isolated
aurora-host experiment. The package is a directory tree or zip archive that can
be extracted anywhere; no runtime path points back into the source repository.

## Supported target

- Windows x64.
- The executable is built with the repository's DMD toolchain and uses the
  Windows system C runtime (`msvcrt.dll`). A small first-party compatibility
  layer supplies the few entry points that `msvcrt.dll` does not export.
- No Microsoft Visual C++ Redistributable is required. The package does not
  bundle `MSVCR120.dll` or another redistributable CRT.
- Windows 10 and Windows 11 are the supported systems. `msvcrt.dll` is a legacy
  system component; Microsoft does not recommend it as the CRT for new
  applications. Do not treat older Windows versions, Wine/Proton, or minimal
  Windows editions as supported without separate verification.
- System fonts, `user32.dll`, `gdi32.dll`, and `msvcrt.dll` are supplied by
  Windows. The package does not bundle fonts or Windows system libraries.
- The scene file and any relative image asset are resolved relative to the
  scene file itself, so the package can be moved as a unit.

## Package layout

```text
aurora-host-<version>-win64/
  aurora-host-experiment.exe     windowed host with an embedded application
                                 icon; also supports check/render
  README.md                     package-local launch instructions
  PACKAGING.md                  this contract
  MANIFEST.sha256               content hashes for every other package file
  PACKAGE-METADATA.json         product, version, platform, runtime contract
  samples/                      scenes and the relative image asset
  licenses/
    LICENSE                     host code: 0BSD
    LICENSE-CC0.txt             documentation, sample content, and icon
                                 artwork: CC0-1.0
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

The application icon is not shipped as a sidecar `.ico`. The executable embeds
the icon bytes for the live window/taskbar/Alt-Tab icon, and packaging appends
the same ICO frames as `RT_GROUP_ICON`/`RT_ICON` PE resources for Explorer.
This keeps the executable self-contained when it is copied out of the package.

A scene may instead embed a base64 ICO in `window.icon`. The host writes the
decoded bytes to a content-addressed temp file and reloads the window icon
live. `samples/notepad-icon.scene.json` demonstrates this and remains a single
portable scene file with no icon sidecar.

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

Staging copies the executable into the package and then runs
`scripts/patch-pe-icon.py` against that copy. The patcher appends a `.rsrc`
section using only the Python standard library, because the bundled DMD linker
does not link resource objects. The source icon lives at
`assets/aurora-host.ico`; it is a packaging input, not a package file.
The icon itself is authored by the first-party D tool; no Python or image
library participates in icon generation. Regenerate the asset with:

```text
dmd -I../../vendor/aurora-d-0.4.5/source -Isource -i -mscrtlib=msvcrt -run tools/icon_author.d --kind host --out assets/aurora-host.ico
```

The notepad asset and its scene embedding use the same tool:

```text
dmd -I../../vendor/aurora-d-0.4.5/source -Isource -i -mscrtlib=msvcrt -run tools/icon_author.d --kind notepad --out assets/aurora-notepad.ico
dmd -I../../vendor/aurora-d-0.4.5/source -Isource -i -mscrtlib=msvcrt -run tools/icon_author.d --scene samples/notepad.scene.json --icon assets/aurora-notepad.ico --scene-out samples/notepad-icon.scene.json
```

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

The windowed executable retains the full CLI and its icon, so the package needs
only one binary. `--render` does not require a visible window and writes a P6
PPM.

## Clean-environment verification

From the source checkout, after creating a package:

```text
python -B tools/verify_package.py --package build/package/aurora-host-0.1.0-win64.zip
```

The verifier extracts the zip into a fresh temporary directory, checks every
manifest hash, runs `--version` and `--check`, renders both a text scene and the
image-asset scene, validates the executable's embedded `RT_GROUP_ICON` frames,
and drives the live control channel through `ping`, `tree`, and `close`. It does
not add the repository to `PATH`, `PYTHONPATH`, or the child environment. A
failure identifies the missing file, dependency, or runtime behavior.

## Portability contract

- Every runtime path in the package is relative to the extracted package root
  or to the scene file that references it.
- The package contains no absolute source-checkout paths and no build directory.
- The executable contains both its runtime icon bytes and its Explorer icon
  resources. No `.ico` sidecar is required at runtime.
- The package contains no `MSVCR120.dll` or other redistributable CRT. The
  executable must pass `tools/check_crt_imports.py`, which requires the system
  `msvcrt.dll` and rejects versioned `msvcr*`, `msvcp*`, `vcruntime*`, UCRT, and
  API-set CRT imports.
- The package does not claim that all third-party material is 0BSD/CC0. The
  licenses and notices above preserve the Unicode, Microsoft Terminal MIT,
  DMD/Phobos, and zlib terms.
- Rebuilding from the same sources and toolchain is expected to produce the
  same staged file set. The manifest is the authority for the exact bytes in a
  built package.
