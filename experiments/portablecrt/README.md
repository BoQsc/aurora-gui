# Portable platform runtime abstraction

This experimental library supplies the small set of runtime entry points that
Aurora's current DMD build cannot find without a Visual Studio CRT library.
The first backend is `windows-ucrt`: it forwards C runtime operations to the
UCRT installed with Windows 10 or later, and supplies Windows PE startup and
TLS descriptors. Its source and distributed `portablecrt.lib` are 0BSD-only.
No Microsoft CRT library, DLL, compiler binary, or third-party source is
packaged with this artifact.

`portablecrt.lib` is an ordinary static archive of two Aurora-owned object
files. It contains compatibility code, not a complete C runtime. The linker
uses DMD's existing `ucrtbase.lib`, `kernel32.lib`, and `shell32.lib` import
libraries to refer to Windows-provided DLLs. Those import libraries are build
inputs and are not part of the distributed artifact. Windows provides the
implementation when the EXE runs.

The C sources are built on GitHub's Windows runner with `cl /Zl /GS-`. The
downloadable artifact contains `portablecrt.lib`, this README, and `LICENSE`.
Place `portablecrt.lib` in a DMD linker search directory or pass its absolute
path to the link command. Keep `LICENSE` alongside any redistributed library.
With Git Credential Manager signed in to GitHub, run
`python experiments/portablecrt/fetch.py` to download the latest successful
artifact into this folder. For a link-only check:

```text
python experiments/portablecrt/probe_link.py <dub-build-log> experiments/portablecrt/portablecrt.lib ucrtbase.lib kernel32.lib
```

This is still a feasibility experiment. The library has to pass a full Aurora
link and runtime checks before it can replace the current build dependency.
The startup/TLS path and the UCRT formatted I/O glue are especially sensitive
to ABI changes. The UCRT's `__stdio_common_*` functions are exported but
documented by Microsoft as implementation details; this backend therefore
targets the Windows 10 and later UCRT ABI currently used by DMD.

The platform boundary is the archive's exported runtime symbols. New backend
implementations can supply the same names where the target ABI permits; the
startup and TLS implementation will necessarily be platform-specific.
