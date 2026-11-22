#!/usr/bin/env python3
"""Prove the Aurora CRT can replace the Microsoft C runtime.

Builds three D probes with the Aurora CRT, suppressing `msvcrt`, `libcmt`, and
`oldnames`, selecting Aurora's `mainCRTStartup`, and linking kernel32 directly.
D cannot emit the address relocations the PE TLS directory needs, so the gate
patches the linked image's TLS directory and `_tls_used` from the real `.tls`
section and exported `_tls_index` before running it.

Every resulting PE must import no Microsoft CRT DLL or API-set and must run with
the expected exit code and output.
"""
from __future__ import annotations

import shutil
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
PACKAGE = REPO / "aurora" / "libraries" / "aurora-exp-win32-crt"
SOURCE = PACKAGE / "source"
TESTS = PACKAGE / "tests"
OUTPUT = REPO / "build" / "zero-crt"

sys.path.insert(0, str(REPO / "experiments" / "aurora-host" / "tools"))
from pe_imports import read_imports  # noqa: E402

FORBIDDEN_PREFIXES = (
    "msvcrt", "msvcr", "ucrt", "vcruntime", "api-ms-win-crt",
)


class CheckError(Exception):
    pass


def u16(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes | bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def dmd_path() -> str:
    found = shutil.which("dmd")
    if found:
        return found
    fallback = Path(r"C:\D\dmd2\windows\bin64\dmd.exe")
    if fallback.is_file():
        return str(fallback)
    raise CheckError("dmd was not found on PATH")


def sections(data: bytes | bytearray):
    pe = u32(data, 0x3C)
    coff = pe + 4
    count = u16(data, coff + 2)
    optional_size = u16(data, coff + 16)
    optional = coff + 20
    table = optional + optional_size
    result = []
    for index in range(count):
        offset = table + index * 40
        name = data[offset:offset + 8].rstrip(b"\0").decode("ascii", "replace")
        virtual_size = u32(data, offset + 8)
        virtual_address = u32(data, offset + 12)
        raw_size = u32(data, offset + 16)
        raw_pointer = u32(data, offset + 20)
        result.append((name, virtual_address, virtual_size, raw_pointer, raw_size))
    return pe, optional, result


def rva_to_offset(rva: int, table) -> int:
    for _name, virtual_address, virtual_size, raw_pointer, raw_size in table:
        if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
            delta = rva - virtual_address
            if delta >= raw_size:
                raise CheckError(f"RVA {rva:#x} is not backed by file data")
            return raw_pointer + delta
    raise CheckError(f"RVA {rva:#x} is outside all sections")


def export_rva(data: bytes | bytearray, table, optional: int, magic: int,
               wanted: str) -> int:
    directories = optional + (112 if magic == 0x20B else 96)
    export_rva_value, _size = struct.unpack_from("<II", data, directories)
    if export_rva_value == 0:
        raise CheckError("image has no export directory")
    offset = rva_to_offset(export_rva_value, table)
    (_characteristics, _timestamp, _major, _minor, _name, _base,
     _functions, names, functions_rva, names_rva,
     ordinals_rva) = struct.unpack_from("<IIHHIIIIIII", data, offset)
    names_offset = rva_to_offset(names_rva, table)
    functions_offset = rva_to_offset(functions_rva, table)
    ordinals_offset = rva_to_offset(ordinals_rva, table)
    for index in range(names):
        name_offset = rva_to_offset(u32(data, names_offset + index * 4), table)
        end = data.index(b"\0", name_offset)
        if data[name_offset:end] == wanted.encode("ascii"):
            ordinal_index = u16(data, ordinals_offset + index * 2)
            return u32(data, functions_offset + ordinal_index * 4)
    raise CheckError(f"export {wanted} was not found")


def patch_tls(executable: Path) -> None:
    data = bytearray(executable.read_bytes())
    _pe, optional, table = sections(data)
    magic = u16(data, optional)
    if magic != 0x20B:
        raise CheckError("TLS patch expects a PE32+ image")
    image_base = struct.unpack_from("<Q", data, optional + 24)[0]
    directories = optional + 112
    tls_rva, tls_size = struct.unpack_from("<II", data, directories + 9 * 8)
    if tls_rva == 0 or tls_size < 40:
        raise CheckError("image has no TLS directory")

    tls_section = next((entry for entry in table if entry[0] == ".tls"), None)
    if tls_section is None:
        raise CheckError("image has no .tls section")
    _name, tls_address, tls_virtual_size, _raw, _raw_size = tls_section

    index_rva = export_rva(data, table, optional, magic, "_tls_index")
    used_rva = export_rva(data, table, optional, magic, "_tls_used")
    start = image_base + tls_address
    end = start + tls_virtual_size
    payload = struct.pack("<QQQQII", start, end,
                          image_base + index_rva, 0, 0, 0)
    for rva in {tls_rva, used_rva}:
        offset = rva_to_offset(rva, table)
        if offset + 40 > len(data):
            raise CheckError("TLS directory is truncated")
        data[offset:offset + 40] = payload
    executable.write_bytes(data)


def build(probe: str, name: str, extra: list[str] | None = None) -> Path:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    objects = OUTPUT / (name + "-obj")
    objects.mkdir(exist_ok=True)
    executable = OUTPUT / (name + ".exe")
    sources = sorted(str(path) for path in SOURCE.rglob("*.d"))
    sources.append(str(TESTS / probe))
    dmd = dmd_path()
    command = [
        dmd,
        "-mscrtlib=msvcrt",
        f"-I{SOURCE}",
        f"-od={objects}",
        f"-of={executable}",
        *sources,
        "-L/NODEFAULTLIB:msvcrt",
        "-L/NODEFAULTLIB:libcmt",
        "-L/NODEFAULTLIB:oldnames",
        "-L/ENTRY:mainCRTStartup",
        "-Lkernel32.lib",
        "-L/EXPORT:_tls_used",
        "-L/EXPORT:_tls_index",

    ]
    if extra:
        command.extend(extra)
    result = subprocess.run(command, capture_output=True, text=True,
                            timeout=180, cwd=OUTPUT)
    if result.returncode != 0:
        raise CheckError(
            "link failed for " + probe + "\n"
            + result.stdout + result.stderr
        )
    if not executable.is_file():
        raise CheckError("no executable was produced for " + probe)
    patch_tls(executable)
    return executable


def check(probe: str, name: str, expected_exit: int,
          expected_stdout: str | None = None) -> list[str]:
    executable = build(probe, name)
    imports = read_imports(executable)
    forbidden = sorted(
        dll for dll in imports if dll.startswith(FORBIDDEN_PREFIXES)
    )
    if forbidden:
        raise CheckError(
            f"{name}: imports Microsoft CRT libraries: {', '.join(forbidden)}"
        )
    result = subprocess.run(
        [str(executable)], capture_output=True, text=True, timeout=30
    )
    if result.returncode != expected_exit:
        raise CheckError(
            f"{name}: exit {result.returncode}, expected {expected_exit}\n"
            + result.stdout + result.stderr
        )
    if expected_stdout is not None and expected_stdout not in result.stdout:
        raise CheckError(
            f"{name}: stdout did not contain {expected_stdout!r}: "
            + repr(result.stdout)
        )
    return sorted(imports)


def main() -> int:
    try:
        hello_imports = check("probe.d", "hello", 0)
        exit_imports = check("exit_probe.d", "exit", 7)
        print_imports = check("print_probe.d", "print", 0, "zero-crt 7")
        writeln_imports = check("writeln_probe.d", "writeln", 0,
                                "writeln from the Aurora CRT")
    except CheckError as error:
        print(f"zero-CRT verification failed: {error}", file=sys.stderr)
        return 1

    print("zero-CRT verification passed")
    print("  hello imports:", ", ".join(hello_imports) or "(none)")
    print("  exit imports: ", ", ".join(exit_imports) or "(none)")
    print("  print imports:", ", ".join(print_imports) or "(none)")
    print("  writeln imports:", ", ".join(writeln_imports) or "(none)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
