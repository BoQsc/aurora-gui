# Aurora ISO

A self-contained ISO image toolkit built with [Aurora-D](../vendor/aurora-d-0.4.5).
It reads, writes, extracts, downloads, and writes ISO images to USB drives
using its own independent ISO 9660 implementation — no external tools, no
native ISO libraries, and a single portable executable.

## Quick start: install Linux to a USB stick

1. Launch `aurora-iso.exe`. It asks for administrator rights (UAC) on start,
   which is required to write to a USB drive. (If you decline, the app still
   runs, and Install will prompt again.)
2. Pick a distribution (Ubuntu or Fedora).
3. Pick the USB drive.
4. Tick **Erase and overwrite the selected USB drive**.
5. Press **Download & Install to USB**.

That one button is the whole flow: it downloads the official ISO (or reuses an
already-downloaded copy from your Downloads folder), then writes the image to
the drive. Because the image carries its own filesystem and boot loader, the
write both formats and installs it in one step. If the ISO for the selected
distribution is already downloaded, it is **not** downloaded again — the list
shows a "downloaded" marker, and the **Delete download** button (X) removes the
cached copy. Everything else — browsing and extracting an ISO, building an ISO,
a custom download URL, format-only, format-plus-copy, and an unprivileged
**Copy Files (no admin)** — is tucked behind the **Advanced** toggle.

## Features

- **Independent ISO 9660 (ECMA-119) engine** written from scratch in
  `source/auroraiso/iso/`:
  - Primary Volume Descriptor parsing.
  - **Joliet** supplementary descriptors (UCS-2 long/Unicode names).
  - **Rock Ridge** (IEEE P1282) `NM` (names), `PX` (POSIX mode), `SL`
    (symlinks), and `CE` (continuation area) parsing.
  - **El Torito** boot-record detection (platform, bootable flag, load LBA).
  - Multi-sector directory walking, case-insensitive lookups, whole-file reads.
  - An ISO writer that produces standards-compliant images (primary + Joliet
    trees, own directory extents and path tables per tree, Rock Ridge `NM`).
- **Browse & extract**: navigate the image tree, extract everything, or extract
  and open a single file with the OS default application.
- **Create**: build a new ISO from any folder, choosing volume id, Joliet, and
  Rock Ridge.
- **Download**: HTTP(S) ISO downloader with progress and resume (WinHTTP).
- **Official distributions**: a built-in catalog of first-party images —
  Ubuntu 26.04.1 / 24.04.5 / 22.04.5 LTS (Desktop and Server, amd64) and
  Fedora 44 Workstation / Server / netinst (x86_64) — taken from Canonical's
  `releases.ubuntu.com` and Fedora's `download.fedoraproject.org`. Pick an
  entry to fill the download fields, or download it immediately.
- **USB / Linux installer** (the primary one-button flow):
  - Enumerate removable USB drives with their backing physical disk, label,
    filesystem, model, and free space.
  - **Download & Install to USB**: downloads the chosen official image when it
    is not cached, then raw/hybrid writes it to the physical disk. This is the
    standard way to make bootable Linux installers (Ubuntu, Fedora, Debian,
    Arch, …) and is the recommended "prepare for Linux" path.
  - Advanced extras: **Write Image (dd)** for a locally opened ISO,
    **Format + Copy** (format the volume, then copy the image contents), and
    **Format Only** for reusing a drive.

Raw disk writing and formatting require **administrator rights**. Launch with
`RUN-AS-ADMIN.bat`, or right-click the exe and choose *Run as administrator*.

## Layout

```
aurora-iso/
  dub.json
  source/app.d                    window + screenshot entry point
  source/auroraiso/theme.d        app theme
  source/auroraiso/appui.d        the whole GUI
  source/auroraiso/job.d          background job helper
  source/auroraiso/osutil.d       shell-open + folders
  source/auroraiso/distro.d       official Ubuntu/Fedora catalog
  source/auroraiso/installflow.d  download-vs-reuse decision (pure, tested)
  source/auroraiso/download.d     WinHTTP download manager
  source/auroraiso/usb.d          USB enumeration, raw write, format
  source/auroraiso/iso/endian.d       both-endian helpers
  source/auroraiso/iso/structures.d   on-disk structures + El Torito
  source/auroraiso/iso/reader.d       ISO reader
  source/auroraiso/iso/writer.d       ISO writer
  source/auroraiso/iso/extract.d      extraction
  source/auroraiso/iso/package.d      public import surface
  tests/iso_unit.d                ISO write/read/extract integration test
  tests/headless_smoke.d          headless GUI smoke + screenshot
  tests/ppm2png.d                 screenshot converter (test utility)
```

## Build & run

Requires DMD (with DUB) and the sibling `../vendor/aurora-d-0.4.5` checkout.

```
RUN-WINDOWS.bat              build + run (debug)
RUN-WINDOWS-SOFTWARE.bat     run with the software renderer
BUILD-WINDOWS.bat            release build
BUILD-RELEASE.bat            self-contained single-file release build
RUN-AS-ADMIN.bat             launch elevated (USB writing)
```

The produced `aurora-iso.exe` is self-contained: it links Phobos statically and
depends only on Windows system DLLs (`kernel32`, `user32`, `gdi32`, `shell32`,
`winhttp`, `ole32`).

## Tests

ISO core (independent of the GUI):

```
dmd -Isource -i -ofbuild/iso_unit.exe tests/iso_unit.d
build/iso_unit.exe
```

Module unit tests plus the integration suite:

```
dmd -unittest -Isource -i -ofbuild/unit_all.exe tests/iso_unit.d source/auroraiso/download.d source/auroraiso/usb.d source/auroraiso/distro.d source/auroraiso/installflow.d winhttp.lib
build/unit_all.exe
```

Headless GUI smoke (builds a small ISO, loads it, asserts the browser, and
writes `build/headless_smoke.png`):

```
dmd -version=AuroraHeadless -Isource -I../vendor/aurora-d-0.4.5/source -i ^
    -ofbuild/headless_smoke.exe tests/headless_smoke.d shell32.lib winhttp.lib
build/headless_smoke.exe
```

## Diagnostics & self-test

The app writes a log next to the executable (`aurora-iso.log`); every run records
elevation state, detected USB devices, the install steps, the volume-lock
results, the queried sector size, and any `WriteFile` error. Point it elsewhere
with `--log <path>`.

```
aurora-iso.exe --selftest            # create ISO -> read -> extract -> aligned write, logs PASS/FAIL
aurora-iso.exe --selftest --log build/selftest.log
```

The self-test exercises the same aligned write streamer used for USB, against a
plain file, so the write path can be verified without hardware.

`REBUILD.bat` closes a running instance (raising UAC if needed) and rebuilds the
release executable.

## Notes & limits

- Raw/"dd" writing to a physical disk fundamentally requires administrator
  rights on Windows, so the app auto-elevates at launch (one UAC prompt; the
  `--elevated` marker prevents any loop) and, if you declined, asks again when
  you press Install. The write itself opens the disk unbuffered with a
  sector-aligned buffer and holds the volume locks — a buffered, unaligned
  handle returns Windows error 1 (ERROR_INVALID_FUNCTION). If the app is
  running, close it before rebuilding; a running (often elevated) copy locks
  `aurora-iso.exe`. The unprivileged alternative is
  **Advanced → USB → Copy Files (no admin)**, which copies the image's files
  onto the drive's existing filesystem but does not install a boot loader.
- Official images are pinned to concrete file names so downloads are
  unambiguous. When a vendor publishes a new point release, refresh the version
  and file name in `source/auroraiso/distro.d` (see the index listings at
  `releases.ubuntu.com/<release>/` and
  `download.fedoraproject.org/pub/fedora/linux/releases/<n>/`).
- The writer targets ISO 9660 level 2 with optional Joliet/Rock Ridge. Files ≥
  4 GiB and multi-extent files beyond the first extent are not yet written.
- The reader follows the first extent of multi-extent files; the common case
  (single extent) is fully supported.
- Raw writing needs the whole physical disk, so on a hybrid image it produces a
  bootable installer exactly like `dd`; the filesystem on the stick will appear
  as the image's own layout (often ISO9660 or an El Torito ESP), which is the
  expected behaviour for Linux installers.
- ISO creation does not yet embed El Torito boot catalogs; it targets data
  images. Use the *Write Image* path for bootable installers.
