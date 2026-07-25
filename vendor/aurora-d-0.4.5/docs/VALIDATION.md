# Aurora-D 0.4.5 validation report

## Scope

Aurora-D 0.4.5 replaces the taskbar's mutate-on-motion reorder path with a pointer-locked retained drag proxy. The visible task now follows the exact original grab point, including vertical and fractional motion; the taskbar shows an insertion gap without changing the stable model order; and mouse-up commits at most one move and one persistence notification.

The implementation remains entirely Aurora-rendered. `TaskDragProxy` is a root-level retained compositor layer containing the task icon, title, running indicator, and active state. Ordinary pointer samples update only the proxy transform. `GuiWindow` can late-sample the pointer before submission and update the proxy and synchronized Aurora cursor in the same scene.

The external `aurora-d-0.4.5.release.json` file is the authoritative machine-readable record for archive hashes, package statistics, and whether extracted-release compilation was run. `MANIFEST.sha256` inside each archive covers every other packaged file.

## Validation completed in the packaging environment

The current environment did not contain DMD, LDC, GDC, or DUB and could not resolve the D compiler download host. Therefore this package was created with extracted-release D compilation explicitly skipped. It is not represented as a native Windows-certified build.

The following source and release gates were executed:

| Gate | Result |
|---|---:|
| Version agreement | `dub.json`, public version constants, README, tests, and changelog agree on 0.4.5 |
| Taskbar source contract | Retained proxy, grab-offset preservation, late-latch hook, gap projection, one-shot commit, and legacy-path rejection passed |
| Deterministic reorder model | 68,856 target resolutions passed |
| One-shot order commits | 68,856 permutations passed |
| Pointer-anchor samples | 1,805,760 circular/fractional samples passed |
| Python syntax | Passed for all packaged tools |
| POSIX shell syntax | Passed for all packaged shell scripts |
| JSON and authored text hygiene | Passed |
| Local documentation links | Passed |
| Unicode 17 generated table | Regenerated and byte-compared |
| Embedded SPIR-V assets | Regenerated and byte-compared |
| Windows manifest/default-DMD recipe checks | Passed |
| Source/file-type allowlist | Passed |
| ZIP and tar.gz deterministic second build | Passed |
| Archive metadata and safe extraction | Passed |
| ZIP/tar extracted payload comparison | Byte-identical |
| Embedded SHA-256 manifests | Passed |
| Extracted-release D verification | Skipped; no D toolchain was available |
| Native Windows 10 interaction test | Not run in this environment |

## Runtime regressions included in the package

`tests/desktop_shell.d` contains the authoritative D integration regression. It sends input through `UiTestDriver` and the real `GuiWindow` dispatch path rather than invoking reorder internals directly. The new test:

1. presses a task at a deliberately off-centre grab point;
2. crosses the five-logical-pixel threshold;
3. verifies the drag proxy preserves that original grab offset;
4. moves horizontally and vertically while asserting the stable task order is unchanged;
5. applies a fractional late-latched pointer sample and verifies exact pointer anchoring;
6. releases over a target slot and checks one final stable-ID move;
7. starts a second drag, removes host focus, and verifies cancellation leaves the order unchanged.

The existing 320-drag stress regression remains and continues to check stable identities, one callback per completed drag, persistence snapshots, invalid-snapshot rejection, and context-menu targeting after repeated reorders.

`tests/shell_visual.d` additionally renders `aurora-task-drag.ppm` with the proxy displaced vertically from the taskbar. This makes regressions where the task remains stuck in a slot visible in a deterministic headless frame.

## Performance contract

While a task remains inside the same insertion slot, the intended frame work is:

```text
stable task-model mutations       0
task-content rebuilds             0
drag-proxy content rebuilds       0
drag-proxy transform updates      1
synchronized cursor updates       1
```

Crossing a neighbouring midpoint updates the insertion target and repaints the taskbar's gap preview. It still does not mutate the task order. Release performs the single model commit.

## Windows acceptance command

On Windows 10, extract the archive into a clean directory and run an optimized Vulkan build:

```bat
cd C:\Users\Windows10_new\Downloads\aurora-d-0.4.5

dub clean
set AURORA_RENDERER=vulkan
set AURORA_LOW_LATENCY=1
set AURORA_SYNC_DRAG_POINTER=1

dub run --build=release --config=desktop --force
```

The host title should report Vulkan. The decisive acceptance check is to grab a task away from its centre, move it in circles above and below the taskbar, and confirm that the same point in the visible task remains attached to the Aurora cursor while the stable order changes only when the button is released.

Run the complete package matrix on a machine with a D toolchain using:

```bat
scripts\verify-release.ps1
```

## Native acceptance still required

The following remain outside the evidence collected here:

- native Windows 10/11 execution of the new taskbar proxy through a physical Vulkan driver and DWM;
- input-to-photon measurements on the user's mouse, monitor, refresh mode, and GPU;
- native macOS linking/execution and Linux physical-GPU execution;
- native inter-process shell drag formats and file operations outside Aurora's host surface.
