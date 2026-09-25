# Experimental DMD-to-UCRT compatibility shim

This Windows x64 experiment supplies runtime entry points that Aurora's
current DMD build cannot find without a Visual Studio CRT library. The
`windows-ucrt` code forwards C runtime operations to the UCRT installed with
Windows 10 or later. It also supplies its own Windows PE startup and TLS
descriptors. The authored source is licensed under 0BSD. The library archive
contains two objects compiled from that source; it packages no Microsoft CRT
library, DLL, compiler binary, or third-party source.

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

This is a link feasibility experiment, not a production runtime. The library
linked one cached Aurora DUB object with zero unresolved symbols. That proves
symbol coverage for that object, not startup correctness or C runtime behavior.
A fresh portable-release build and runtime validation remain. The custom
startup path may omit setup normally performed by an official CRT startup
library. The UCRT's `__stdio_common_*` functions are exported but documented
by Microsoft as implementation details that may change. A legal review should
also confirm the intended distribution terms for compiler-produced objects;
the 0BSD license on our source does not license the Windows UCRT.

The Windows-specific source names leave room for another backend later. This
repository currently contains one compatibility shim, not a general platform
runtime abstraction.
