# Third-party notices

The `aurora-host` package is licensed as follows:

- Source code, protocol schema, generated constants, and tools: **0BSD**
  ([LICENSE](LICENSE)).
- Documentation, sample scenes, images, and sample assets: **CC0-1.0**
  ([LICENSE-CC0.txt](LICENSE-CC0.txt)).

These licenses apply only to material owned by the aurora-host contributors.
They do not relicense the vendored packages or third-party material below.

## Build dependencies linked into the executable

- **aurora-d 0.4.5**: BSL-1.0. Its license and notices are in
  `../../vendor/aurora-d-0.4.5/LICENSE`, `LICENSE-UNICODE.txt`, and
  `licenses/Microsoft-Terminal-MIT.txt` relative to this package.
- **aurora-standard 1.0.0**: BSL-1.0. Its license and Unicode notice are in
  `../../vendor/aurora-standard/LICENSE` and `LICENSE-UNICODE.txt`.
- **DMD 2.113.0 druntime and Phobos**: BSL-1.0. The compiler package license
  text is in the DMD installation's `license.txt`.

The Unicode data is covered by the **Unicode License V3**. The adapted
foreground-aware font alpha model includes code under the **Microsoft
Terminal MIT** license. Both notices must accompany a binary distribution.

## Runtime platform

- The host uses Windows system libraries (`user32`, `gdi32`, `shell32`,
  `ole32`, `advapi32`, and `kernel32`) and system fonts. No fonts are bundled.
- The current DMD build also imports `MSVCR120.dll`. Redistribution of that
  Microsoft runtime binary requires rights under Microsoft's Visual C++
  license terms. A packaged distribution must either use a licensed static CRT
  build or document the Microsoft Visual C++ 2013 Redistributable prerequisite.
