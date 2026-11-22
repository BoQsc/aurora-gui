# aurora-exp-win32-crt

An Aurora-owned C runtime for Windows. It replaces the Microsoft CRT in the
link: startup, heap, strings, ctype, formatted output, and FILE streams over
kernel32. Programs link with `/NODEFAULTLIB:msvcrt`, `/NODEFAULTLIB:libcmt`, and
`/ENTRY:mainCRTStartup`; the resulting PE imports no `msvcrt`, `msvcr*`, `ucrt`,
or `api-ms-win-crt*` symbol.

## What is implemented

| Layer | Symbols |
|---|---|
| Startup | `mainCRTStartup`, `__getmainargs`, `getenv`, `__p___argc/argv`, `.CRT` constructor walk, `exit`, `abort`, `_errno` |
| Heap | `malloc`, `calloc`, `realloc`, `free` over the process heap |
| Memory/strings | `memcpy`, `memmove`, `memset`, `memcmp`, `memchr`, `strlen`, `strnlen`, `wcslen`, `wcsnlen`, `wcscmp`, `wcstok`, `wcstombs` |
| ctype/convert | `isdigit`, `isspace`, `toupper`, `tolower`, `isalpha`, `isalnum`, `isxdigit`, `islower`, `isupper`, `ispunct`, `isprint`, `iscntrl`, `strtod`, `strerror` |
| Formatted output | `printf`, `fprintf`, `_snprintf`, `snprintf`, `_vsnprintf`, `vsnprintf` for `%s`, `%c`, `%d`, `%i`, `%u`, `%x`, `%X`, `%p`, width/precision markers, `l`/`ll`/`z` lengths |
| FILE | `__iob_func` with the 48-byte VS2013 `_iobuf` stride, `_fdopen`, `_wfopen`, `_wfreopen`, `tmpfile`, `fclose`, `fread`, `fwrite`, `fseek`, `_fseeki64`, `ftell`, `_ftelli64`, `rewind`, `clearerr`, `feof`, `ferror`, `setvbuf`, `_fileno`, `fileno` |
| Narrow/wide put | `_fputc_nolock`, `fputc`, `putc`, `_fgetc_nolock`, `fgetc`, `getc`, `_fputwc_nolock`, `fputwc`, `fgetwc`, `_flsbuf`, `_filbuf` |
| Descriptors | `_open`, `_wopen`, `_read`, `_write`, `_close`, `_lseeki64`, `_get_osfhandle`, `_open_osfhandle`, `_setmode` |
| Compiler support | `_fltused`, `_tls_index`, `_tls_used`, `_initterm`, `_initterm_e`, `_invalid_parameter_noinfo`, `__set_app_type`, `_set_output_format`, `_beginthreadex` |

## The zero-CRT gate

```bat
dub build --config=library --compiler=dmd
python -B tests\verify_zero_crt.py
```

`tests/verify_zero_crt.py` builds four probes with the Aurora CRT and the
Microsoft libraries suppressed:

| Probe | Requirement |
|---|---|
| `probe.d` | exits 0 |
| `exit_probe.d` | `exit(7)` returns 7 |
| `print_probe.d` | Aurora `printf` writes `zero-crt 7` |
| `writeln_probe.d` | Phobos `writeln` writes its line and exits 0 |

Each PE is checked with the laboratory's PE import reader: no Microsoft CRT or
API-set imports are allowed. Only `kernel32.dll` and `shell32.dll`
(`CommandLineToArgvW`) remain.

## Host milestone

```bat
python -B tests\verify_host_zero_crt.py
```

The host gate builds `tests/host_app`, a DUB fixture that links the real
`aurora-host` sources with the Aurora CRT, `/NODEFAULTLIB`, and Aurora's entry
point. It patches the TLS directory, requires no Microsoft CRT import, then runs
the host's headless scene check and a software render.

Last result:

```
host zero-CRT verification passed
  imports: advapi32.dll, avrt.dll, kernel32.dll, shell32.dll,
           user32.dll, winmm.dll, ws2_32.dll
  headless render: P6
```

`aurora-host` now renders its `hello.scene.json` (760×520, dark theme) with no
Microsoft runtime inside the binary.

### Windowed host

```bat
python -B tests\verify_host_gui_zero_crt.py
```

The GUI gate builds `tests/host_gui_app` without the `AuroraHeadless` version,
patches TLS, requires no Microsoft CRT import, then launches
`--run hello.scene.json` and requires the windowed process to still be alive
after two seconds.

Last result:

```
GUI host zero-CRT verification passed
  imports: advapi32.dll, avrt.dll, gdi32.dll, kernel32.dll, ole32.dll,
           shell32.dll, user32.dll, winmm.dll, ws2_32.dll
  windowed launch: alive after 2s
```

## TLS post-link step

D cannot place symbol addresses in static data, so `_tls_used` cannot be built
by the D compiler. The gate links with exported `_tls_used` and `_tls_index`,
then patches the PE's TLS directory and `_tls_used` from the real `.tls` section
and the exported index address. Without that patch the Windows loader writes the
TLS index through a zero `AddressOfIndex` and the image faults before entry.

Any build that uses this CRT must run that patch step until the Aurora linker
emits the TLS directory itself.

## Coverage boundaries

- Floating-point `%f`/`%g` formatting is not implemented; numeric formatting is
  integer/string only.
- `sscanf` reports no conversions.
- FILE streams are unbuffered; `setvbuf` is accepted but has no effect.
- Locale, timezone, wide-character formatting, `atexit`, TLS callbacks, and
  full exception-unwind registration are later phases.
- The `AuroraCrtTrace` version installs an exception logger that writes the
  fault code, RIP, and return addresses to stderr for bring-up work.

Both the headless and windowed host are linked. Next are the remaining portable
applications, then the COFF linker that replaces `lld-link`.

## Portable applications

```bat
python -B tests\verify_apps_zero_crt.py
```

This gate generates a fixture from each application's real `dub.json` (source
paths, string imports, libraries, versions), adds the Aurora CRT and the
`/NODEFAULTLIB` flags, builds it, patches TLS, and requires no Microsoft CRT
import.

Last result — all nine portable applications:

```
aurora-cut, aurora-designer, aurora-font-viewer, aurora-image-viewer,
aurora-notepad, aurora-opencode, aurora-opencode-pro, aurora-remote,
aurora-stream: zero-CRT link ok
```

Every binary imports only Windows libraries (`advapi32`, `avrt`, `bcrypt`,
`crypt32`, `gdi32`, `kernel32`, `ole32`, `shell32`, `user32`, `winhttp`,
`wininet`, `winmm`, `ws2_32`).

Two integration fixes were required outside the CRT:

- `aurora-cut` had six stale `setConsumeAnchorPress(true)` calls. The current
  popup API takes the anchor widget and `showPopup` already sets it, so the
  calls were removed.
- The fixture generator now emits an explicit `sourceFiles` entry and excludes
  sibling files that define `int main`, so alternative entry points such as
  `aurora-stream`'s `app.d` are not compiled alongside the selected one.

## Licensing

Source is 0BSD. No Microsoft CRT source, headers, or import libraries are
copied; the ABI names and layouts come from the documented C and Win32
interfaces.
