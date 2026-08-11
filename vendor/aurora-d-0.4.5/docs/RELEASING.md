# Release process

Aurora-D source releases are produced by `tools/release.py`, which uses only the Python standard library. The shell and PowerShell entry points are thin wrappers:

```sh
./scripts/package-release.sh --output dist
```

```powershell
./scripts/package-release.ps1 --output dist
```

The package version comes from `dub.json`. `tools/verify_assets.py` requires the same version in `source/aurora/versioning.d`, the changelog, and the README before packaging can start.

## Prerequisites

A release host needs:

- Python 3.9 or newer;
- DUB;
- a D compiler, with LDC recommended for the cross-target release checks;
- the native link libraries required by the host GUI backend;
- a Vulkan loader, display, and usable ICD only when the required-Vulkan smoke is requested.

Set `DC`, `DUB`, or `PYTHON` when the commands are not on `PATH`:

```sh
DC=/opt/ldc/bin/ldc2 DUB=/opt/ldc/bin/dub \
  ./scripts/package-release.sh --output dist
```

## Verification phases

A normal package run performs these phases in order:

1. Validate package-version agreement, JSON, script syntax, UTF-8/LF source hygiene, local Markdown links, required Unicode 17 inputs, release-input symlinks, and the SDK-independent default Windows DUB recipe.
2. Regenerate the compact Unicode property table and the embedded SPIR-V modules in a temporary directory, then require byte-for-byte equality with the checked-in files.
3. Stage an explicit allowlist of source, demos, tests, documentation, screenshots, scripts, shaders, optional Windows manifest deployment resources, and licensed Unicode inputs; reject any unexpected file type.
4. Reject symlinks, build directories, DUB caches, duplicate Unicode-data directories, executables, objects, static libraries, framebuffer dumps, Python bytecode, and other generated artifacts.
5. Add `PACKAGE-METADATA.json` and a complete `MANIFEST.sha256` to the payload.
6. Normalize payload permissions, timestamps, and tar ownership.
7. Create deterministic ZIP and tar.gz archives twice and require identical hashes between the two independent creation passes.
8. Validate each archive's exact member set, types, sizes, timestamps, permissions, and normalized tar ownership.
9. Safely extract both formats, compare every file and POSIX mode, compare the two extracted payloads, and validate both embedded manifests.
10. Run `scripts/verify-release.sh` from the extracted ZIP payload.
11. Write external archive checksums, a JSON report, and the captured verification log in a private staging directory.
12. Remove any stale report, atomically replace and hash-check each final artifact, then publish the JSON report last as the release-set commit marker.

`verify-release.sh` includes the ordinary unit, headless, text, high-DPI, Unicode-conformance, public-API, and 13-configuration build matrix. It also compiles the library, all demos, the Vulkan smoke, and every headless test graph with warnings treated as errors. With LDC, it emits complete library, demo, and Vulkan-smoke object graphs for Windows x86-64, macOS x86-64, and macOS arm64. `AURORA_CROSS_TARGETS` may select a whitespace-separated subset for isolated reruns; release packaging leaves it unset and therefore checks all three.

## Vulkan runtime gate

Vulkan execution is deliberately opt-in because it requires a native display and usable ICD:

```sh
./scripts/package-release.sh --output dist --verify-vulkan
```

This sets `AURORA_VERIFY_VULKAN=1` for the extracted-archive release verification and requires `scripts/test-vulkan.sh` to pass. A software Vulkan ICD validates Aurora's Vulkan API path but is not evidence of physical-GPU performance.

The optional GUI startup gate launches all five demos and requires them to remain in their event loops for the configured smoke interval without writing to stderr:

```sh
./scripts/package-release.sh --output dist --verify-gui
```

When `--verify-gui` and `--verify-vulkan` are supplied together, every demo is exercised once with software presentation and once with required Vulkan presentation. On Linux this command must run inside a real X session or under Xvfb.

## Development-only options

`--skip-verify` still validates assets, creates both deterministic archives, compares their extracted payloads, and checks both manifests, but it does not compile or execute the extracted source. Archives produced with this option are marked `"verification": "skipped"` in the release report and should not be published.

`--keep-work` preserves the temporary staging and extraction directories for investigation.

`--source-date-epoch` overrides the normalized timestamp. The default is the portable ZIP epoch, `315532800` (`1980-01-01T00:00:00Z`). Given identical source, version, Python implementation, and source-date epoch, a package run must reproduce identical archive bytes.

## Output files

For version `x.y.z`, the output directory contains:

```text
aurora-d-x.y.z.zip
aurora-d-x.y.z.tar.gz
aurora-d-x.y.z.sha256
aurora-d-x.y.z.release.json
aurora-d-x.y.z-verification.log
```

Both archives use `aurora-d-x.y.z/` as their root directory. The internal `MANIFEST.sha256` covers every other payload file. The external `.sha256` file covers the two archives. The JSON report is published last and records archive hashes, payload statistics, the manifest and verification-log hashes, requested runtime gates, packaging host details, and the result of every package-integrity phase.

All candidate outputs are built and verified outside the destination directory. Existing final names are replaced only after every requested release gate succeeds. Each replacement uses an atomic rename, but the multi-file set is committed by convention rather than by a filesystem transaction: any old report is removed before replacement, and the new report is published last. Therefore, a report is present only after every preceding artifact has been replaced and hash-verified.

## Independent package inspection

After extraction, validate the embedded manifest from the archive root:

```sh
sha256sum --check MANIFEST.sha256
```

Then run the release matrix:

```sh
./scripts/verify-release.sh
```

On a suitable Vulkan host:

```sh
AURORA_VERIFY_VULKAN=1 ./scripts/verify-release.sh
```

## Native-test boundary

Cross-target object generation is not native runtime validation. Before declaring the Windows and macOS backends production-hardened, run the extracted package natively on those systems. Windows acceptance must cover an ordinary standalone-DMD development link, a `portable-release` link against the MSVC x64/x86 tools and Universal CRT SDK individual components, verification that the portable executable has no dynamic CRT imports, 100%, 125%, 150%, 175%, and 200%, repeated mixed-monitor DPI transitions, maximize/restore, optional manifest inspection, software/Vulkan comparison, and hosts that establish DPI policy before Aurora loads. Both systems also need repeated renderer and font changes, input-method behavior, and long-running window/swapchain lifecycle tests. The recorded scope and remaining gates belong in `docs/VALIDATION.md` for each release.
