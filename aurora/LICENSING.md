# Aurora licensing

First-party Aurora source code, package metadata, protocol schemas, generated
constants, tools, and the `aurora-d` and `aurora-standard` source are licensed
under **0BSD**. See [LICENSE](LICENSE).

First-party documentation, sample scenes, images, and other content are licensed
under **CC0-1.0**. See [LICENSE-CC0.txt](LICENSE-CC0.txt).

## Third-party notices

These components are not relicensed by the Aurora project and keep their own
terms:

- Unicode character data in `aurora-d` and `aurora-standard`: Unicode License
  V3. See `LICENSE-UNICODE.txt` in each package.
- Microsoft Terminal MIT material in `aurora-d`: see
  `licenses/Microsoft-Terminal-MIT.txt`.
- DMD druntime and Phobos: BSL-1.0. The compiler distribution carries the
  license text; these support libraries are linked into Aurora executables.
- `zlib` code reached through D standard-library compression paths: Zlib
  license.
- Windows operating-system libraries and system fonts: not redistributed by
  this tree. A binary package must not copy associated Microsoft runtime DLLs
  unless the distributor has the applicable Microsoft redistribution rights.

These third-party components mean a distribution containing them is **not**
strictly 0BSD/CC0-only. A package that claims otherwise must replace or remove
those components, not merely change a metadata line.
