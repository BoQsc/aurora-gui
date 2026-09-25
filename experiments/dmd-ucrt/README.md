# Experimental DMD / Windows UCRT build probe

This is a research-only, isolated build path for Aurora's Windows EXE. It is
not part of Aurora's normal build, updater, or release process. It uses DMD's
dynamic UCRT fallback and leaves the live `aurora-opencode-pro` EXE alone.

## Build

1. Download the official `dmd.2.114.0-beta.1.windows.7z` from the
   [DMD release](https://github.com/dlang/dmd/releases/tag/v2.114.0-beta.1)
   and extract it to a local folder. The archive is about 35 MB; the extracted
   tools take more space. This beta is a build probe, not a release toolchain
   endorsement.
2. From the repository root, run:

   ```text
   python experiments/dmd-ucrt/probe-dmd-ucrt.py --compiler C:/path/to/dmd2/windows/bin64/dmd.exe
   ```

The script uses `dub.exe` beside that compiler and builds from the current
source tree. It creates a temporary DUB recipe, omits post-build commands,
and writes the candidate to `build/ucrt-probe/aurora-ucrt-probe.exe`.
The build log is in the same folder. Both files are ignored by Git.

The script also generates a 926-byte COFF import archive for five memory
functions exported by Windows `ucrtbase.dll`. The generator is original 0BSD
code and copies no Microsoft object code or import library. The archive
is a linker input only. DMD's bundled `legacy_stdio_definitions.lib` is
another **build input**; neither library is distributed alongside the EXE.
The EXE itself includes Aurora and its other dependencies, so this workflow
does not make the *whole application* 0BSD-only.

On the machine used for the probe, the EXE imported only `ADVAPI32.dll`,
`GDI32.dll`, `KERNEL32.dll`, `SHELL32.dll`, `USER32.dll`, `WININET.dll`,
`ole32.dll`, and `ucrtbase.dll`; it did not import `vcruntime140.dll`.
It launched, rendered `--screenshot`, and exited successfully. A test on a
clean Windows 10/11 machine is still needed before making this the release
build path. The probe does not publish or replace any EXE.
