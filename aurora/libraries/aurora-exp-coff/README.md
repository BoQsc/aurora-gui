# aurora-exp-coff

The COFF foundation for Aurora's own linker. Object/archive readers, bigobj,
section/symbol linking, REL32/ADDR64 fixups, COMDAT, imports, TLS/exception
emission, PE emission, and a stripped PDB writer are implemented. Real-D and
aurora-host integration run through `LINKCMD64`.

## Coverage

| Region | Parsed |
|---|---|
| File header (20) | machine, section count, symbol table pointer/count, optional size, characteristics |
| Section table (40 each) | name (inline or `/nnn` string-table name), raw data, relocation table, characteristics |
| Relocations (10 each) | virtual address, symbol index, type, per section |
| Symbols (18 each) | inline or string-table names, value, section number, type, storage class, auxiliary count |
| String table | size validation, section and symbol long names |
| Auxiliary records | counted and skipped when enumerating primary symbols |

Every offset is bounds-checked; malformed input throws `CoffError` with the
offending region named.

## Inspection

```bat
dub build --config=inspect --compiler=dmd
coff-inspect build\coff\probe.obj
```

The instrument prints the machine, section table with relocation counts and
characteristics, symbol counts, and the primary symbols with section/value/
storage.

## Verification

```bat
python -B tests\verify_coff.py
```

The gate builds `coff-inspect`, compiles `tests/probe.d` with
`dmd -c -betterC`, inspects the object, requires `.text`, the mangled `add` and
`counter` symbols, relocation data, and rejects a truncated object.

Last result:

```
COFF verification passed
  machine=0x8664
  sections=8
  symbols=21
  relocations=5
  section .text raw=0 relocations=0 characteristics=0x60500020
  section .text raw=44 relocations=2 characteristics=0x60501020
  symbol _D5probe7counteri section=5 value=0x0 storage=2
  symbol _D5probe3addFiiZi section=6 value=0x0 storage=2
```

## Link stage

```bat
dub build --config=link --compiler=dmd
coff-link out.exe mainCRTStartup object.obj
```

Implemented:

- section merging with characteristic alignment and preserved flags;
- defined-symbol resolution to output RVAs;
- `IMAGE_REL_AMD64_REL32` application relative to the end of the field;
- `ADDR64` and `ADDR32NB` fixups with generated base-relocation entries;
- COMDAT ANY/NODUPLICATES and ASSOCIATIVE selection from section aux records;
- archive (`.lib`) member extraction for undefined symbols;
- `/SUBSYSTEM:WINDOWS`/`CONSOLE` emission (GUI apps get no console window);
- import-library short-object parsing, `.idata` descriptors/ILT/IAT, and
  per-symbol jump thunks;
- TLS directory emission with `_tls_used`/`_tls_index` patching;
- exception directory emission for `.pdata`;
- PE32+ emission with section table, entry point, image size, and raw layout.

Verified by `tests/verify_link.py`: a synthetic COFF object containing
`xor eax, eax; ret` and a defined `mainCRTStartup` symbol becomes a 1,536-byte
PE32+ that exits 0.

Verified by `tests/verify_link_archive.py`: an object calling an undefined
`helper` links against an archive that defines it, the member is extracted, the
REL32 is fixed up, and the EXE exits 0.

Verified by `tests/verify_relocations.py`: a `.data` qword is fixed up to
`imageBase + entry RVA`, `.reloc` carries a DIR64 entry for that slot, and the
optional-header base-relocation directory points at `.reloc`.

Verified by `tests/verify_comdat.py`: two objects define the same COMDAT
`entry`; the first returns 0, the duplicate would return 1, and the linked EXE
exits 0.

Verified by `tests/verify_import.py`: an object calling the undefined
`ExitProcess` links against the real `kernel32.lib`, receives a thunk and IAT
slot, and the EXE exits 0 through the imported function.

Verified by `tests/verify_tls.py`: a synthetic object with `.tls`,
`_tls_index`, `_tls_used`, and `.pdata` produces a TLS directory with matching
start/end/index, a patched `_tls_used`, and an exception directory.

## Archive reader

```bat
dub build --config=archive --compiler=dmd
coff-archive kernel32.lib ExitProcess
```

`auroraexpcoff.archive` parses the global header, 60-byte member headers, `//`
long names, and the `/` linker symbol index. Verified against the real
`kernel32.lib` (1,625 members, `ExitProcess` member) and `phobos64.lib`
(20,537 members, `_d_run_main` member). Short import objects are recognized
through the archive index even though they are not standard COFF objects.

## LINKCMD64 status

`coff-link` accepts MSVC-style `/OUT`, `/ENTRY`, `/SUBSYSTEM`, `/LIBPATH`,
`/DEFAULTLIB`, and `/NODEFAULTLIB` options, so DMD can invoke it through
`LINKCMD64`. It reads `.drectve` default libraries, extracts `phobos64.lib` and
the system import libraries, and links a real D probe.

The probe, `aurora-host` (headless and windowed), and all nine portable apps
link and run through this path. The host passes `--check` and renders P6; every
app imports only OS libraries.

Remaining:

1. `HIGHLOW`/`ADDR32` fixups for unusual 32-bit absolute references.
2. Full type/source PDB streams; the emitted PDB is stripped and carries public
   symbols rather than complete module type information.

## Debug/PDB emission

`/DEBUG` emits a CodeView RSDS debug directory and a stripped MSF 7.0 PDB with
the PDB info, TPI, DBI, symbol-record, section-header, and publics streams.
`tests/verify_pdb.py` links the zero-CRT probe and requires the RSDS GUID/age to
match the PDB info stream, `mainCRTStartup` in the public symbols, `.text` in the
section headers, and the EXE to exit 0.

## Icon embedding

Standalone app/host gates and `scripts/dub-standalone.py` embed an icon with
`scripts/embed-app-icon.py`, which reuses the tested `patch-pe-icon.py`
resource builder. It discovers `<app>/assets/<name>.ico` or
`<app>/<name>.ico`, falls back to the Aurora host icon, and verifies that
Windows `ExtractIconExW` can read the result.

## Default standalone linker

```bat
python scripts\dub-standalone.py build --compiler=dmd
```

This builds `coff-link`, sets `LINKCMD64`, and forwards the build to DUB. The
host and portable-app zero-CRT gates use the same path, so standalone builds no
longer invoke `lld-link`.

## Licensing

Source is 0BSD. Layouts come from the documented COFF specification; no
Microsoft headers or linker source are copied.
