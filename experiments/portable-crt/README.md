# Portable CRT feasibility probe

This is an isolated, source-only experiment. It does not replace Aurora's
runtime or enter release builds. The library is built locally with DMD and
links only to documented Windows system APIs. It contains no Microsoft CRT
objects or binaries.

The goal is to build a small, independently redistributable static CRT subset
for Aurora. An isolated link with an empty replacement library and
`kernel32.lib` found 65 unresolved CRT symbols. The D-only portion now leaves
9 linker symbols, including startup/TLS and the C formatting/parsing bridge.
The full library with C objects has not yet been compiled or linked.

The `.lib` produced by the local D-only build cannot yet link Aurora and is
not a portable release dependency. Runtime behavior has not been validated.
Known gaps include binary-only descriptor I/O, ASCII-only wide stream I/O,
limited `sscanf` formats, and immediate `exit` without C `atexit` handlers.
The `time` function reports an error outside the 32-bit `time_t` range used
by this DMD toolchain. A successful link would not close these behavior gaps.

Build the D-only portion locally with DMD on Windows:

```text
python experiments/portable-crt/build.py
```

On GitHub's Windows runner, `python experiments/portable-crt/build.py --with-c`
compiles the C ABI sources with the runner's Visual C++ compiler and packages
them with the D objects. This produces a library artifact, not an Aurora EXE.
The C sources use `stb_sprintf` and `ffc.h`; see `third_party/README.md` for
their source commits and licenses.

To repeat a link-only probe, pass a DUB failure log containing its printed
`lld-link` command to `probe_link.py`. The probe writes an EXE only into the
system temporary directory and never launches it.

The manual GitHub Actions workflow builds the same source and retains the
library as a downloadable artifact. It includes no Microsoft CRT libraries.
