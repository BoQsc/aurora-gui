# aurora-exp-win32-image

The binary-format laboratory. It reads, verifies, mutates, and generates
Windows PE images without a linker, a CRT, or a Windows SDK header.

Two properties define it:

1. **Nothing is left out of the format model.** Every header field has a
   declared on-disk size; every non-empty data directory has a typed model or
   an explicit byte view.
2. **Parse and emit validate each other.** Rebuilding an unmodified image must
   reproduce it byte for byte; a wrong offset shows up as a mismatch, not as a
   silent skip.

## Coverage

| Region | Model |
|---|---|
| DOS header (64) | all fields, `MZ`, `e_lfanew` |
| DOS stub, header padding, payload, overlay | preserved verbatim |
| PE signature, COFF header (20) | all fields |
| Optional header PE32 (224) / PE32+ (240) | all fields, all 16 data directories |
| Section table | all 40 bytes per entry, names, raw ranges validated |
| Imports (dir 1) | DLLs, symbol names, ordinals |
| Exports (dir 0) | ordinals, names, RVAs, forwarder strings |
| Resources (dir 2) | full tree: named/ID types, names, languages, data, code pages |
| Exceptions (dir 3) | `RUNTIME_FUNCTION` count (12-byte x64, 8-byte ARM64) |
| Certificates (dir 4) | `WIN_CERTIFICATE` records from a file-offset directory |
| Relocations (dir 5) | blocks, page RVAs, per-block entry counts |
| Debug (dir 6) | entries, timestamps, CodeView `RSDS` GUID/age/PDB path |
| Architecture, global pointer, CLR, reserved | explicit raw byte views |
| TLS (dir 9) | 32/64-bit directories plus decoded callback addresses |
| Load config (dir 10) | explicit raw byte view (its layout is version-specific) |
| Bound imports (dir 11) | DLL names and timestamps |
| IAT (dir 12) | covered by the import model |
| Delay imports (dir 13) | DLLs and symbols, RVA and VA attribute forms |

The load config, architecture, global-pointer, CLR, and reserved directories
are exposed as exact byte slices rather than guessed structures. Their bytes are
fully reachable; no field is invented.

## Generation

`--emit` writes a complete, runnable PE32+ executable from fields alone: DOS
header, COFF header, optional header, a `.text` section with a 3-byte entry stub
(`xor eax, eax; ret`), and a `.reloc` section with a valid padding block. It is
1,536 bytes, has no imports, no CRT, and no linker input, and can be mapped away
from its preferred base. The instrument parses its own output and requires a
byte-identical rebuild before writing it.

```bat
pe-roundtrip --emit hello.exe
hello.exe            :: exits with code 0
```

## Loading

`pe-load` maps an image itself instead of calling `CreateProcess`:

1. `VirtualAlloc` for `SizeOfImage`, at the preferred base when free.
2. Copy headers, then each section's raw bytes to its RVA.
3. Apply `IMAGE_REL_BASED_HIGHLOW` and `DIR64` relocations for the base delta.
4. Resolve imports with `LoadLibraryA`/`GetProcAddress` and fill the IAT.
5. Set each section's protection from its characteristics, then flush the
   instruction cache.
6. `CreateThread` at the entry point, wait, and report the thread exit code.

```bat
pe-load hello.exe               :: maps, runs, prints threadExit=0
pe-load hello.exe --map-only    :: maps and reports, runs nothing
```

The loader executable itself is based at `0x140000000`, so the emitted image
lands elsewhere; its `.reloc` directory makes that legal and zero fixups are
required because the entry code contains no absolute address. Mapping output
shows the preferred base, the actual base, the delta, section placements with
protections, and the exit code.

The loader is deliberately smaller than the system loader. It does not process
TLS callbacks, register exception unwind data, activate manifests/SxS, or follow
forwarded exports, and it refuses images whose bitness differs from its own.

## Mutation

```bat
:: replace the COFF link timestamp (4 bytes change, nowhere else)
pe-roundtrip app.exe stamped.exe --stamp 1790000000

:: replace a resource leaf in place; the slot size is updated and zero-filled
pe-roundtrip app.exe changed.exe --replace-resource 3/1/1033 icon.bin

:: inspect a resource leaf
pe-roundtrip app.exe --dump-resource 3/1/1033 icon.bin
```

Resource replacement fits the existing slot. Growing a resource or adding a
section requires relayout, which is the next writer milestone.

## Verification

From this package folder:

```bat
dub build --config=library --compiler=dmd
dub build --config=roundtrip --compiler=dmd
dub build --config=load --compiler=dmd
dub build --config=emit-load-test --compiler=dmd
pe-roundtrip ..\..\..\aurora\aurora-host\aurora-host.exe --self-test
pe-emit-load-test.exe
```

`tests/emit_load.d` is the end-to-end test: it emits the image from fields,
checks the 1,536-byte size, both section names, the entry RVA, zero imports,
byte-exact rebuild, and the three entry-code bytes; then it maps the image with
the loader, requires `.text` to be `PAGE_EXECUTE_READ` and `.reloc` to be
`PAGE_READONLY`, runs the entry point, and requires exit code 0.

The committed `tests/verify_corpus.py` also emits a fresh image, maps it with
`pe-load`, runs its entry, and requires exit code 0, alongside the corpus,
stamping, resource, icon, and self-test checks. It runs `pe-emit-load-test.exe`
as part of the gate.

`--self-test` exercises three malformed images (truncated file, broken PE
signature, impossible section count), a timestamp stamp that must change exactly
four bytes, and an in-place resource replacement that must survive a reload.

The repository corpus gate runs the instrument over every readable `.exe` and
`.dll` in the tree and requires `rebuilt=identical` plus byte equality for each.
The last run covered 34 images, including a 10.8 MB PE32+ application and images
with exports, certificates, delay imports, TLS, and resources. Separate runs
covered a 32-bit PE32 image and a signed system library with 1,636 exports, a
certificate table, and delay imports.

The printed `dll <name> <count>` lines match
`experiments/aurora-host/tools/pe_imports.py`, and the icon resource tree is
validated by `experiments/aurora-host/tools/check_pe_icon.py`.

## Boundaries of this package

These are separate laboratory milestones, not hidden gaps:

1. Section/resource relayout, so resources can grow and sections can be added.
2. COFF object parsing and a link path that does not depend on `lld-link`.
3. CodeView/PDB symbol generation, so an address resolves to a name.
4. A CRT package, so laboratory tools and Aurora executables need no Microsoft
   runtime DLL.

## Dependencies and licensing

D runtime and Phobos only; no `aurora-d` dependency. Source is 0BSD. Structures
are written from the documented PE/COFF format; no Windows SDK header or
Microsoft CRT source is copied or translated.

## GUI inspector

[`../aurora-exp-win32-inspector`](../aurora-exp-win32-inspector) is the friendly
front end: it opens an image, shows this coverage, verifies the rebuild, emits
the minimal executable, and runs it with the loader. It is a separate package so
this library stays free of GUI dependencies.
