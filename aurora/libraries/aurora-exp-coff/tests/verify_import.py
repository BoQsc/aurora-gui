#!/usr/bin/env python3
"""Verify import-library linking.

Builds an object whose entry calls the undefined `ExitProcess`, links it with
the real `kernel32.lib`, and requires:

* an import directory in the PE optional header;
* an `.idata` section;
* the EXE to run and exit 0 through the generated thunk and IAT.

Run from anywhere; paths resolve from the repository root.
"""
from __future__ import annotations

import shutil
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
PACKAGE = REPO / "aurora" / "libraries" / "aurora-exp-coff"
TOOL = PACKAGE / "coff-link.exe"
OUTPUT = REPO / "build" / "coff"


class CheckError(Exception):
    pass


def tool(name: str, fallback: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    path = Path(fallback)
    if path.is_file():
        return str(path)
    raise CheckError(f"{name} was not found on PATH")


def library(name: str) -> Path:
    dmd = Path(tool("dmd", r"C:\D\dmd2\windows\bin64\dmd.exe")).resolve()
    root = dmd.parents[1]
    for candidate in (root / "lib64" / "mingw" / name,
                      root / "lib64" / name):
        if candidate.is_file():
            return candidate
    raise CheckError(f"library not found: {name}")


def import_object() -> bytes:
    # xor ecx, ecx; call ExitProcess
    code = bytes([0x31, 0xC9, 0xE8, 0, 0, 0, 0])
    raw_offset = 60
    relocation_offset = raw_offset + len(code)
    symbol_offset = relocation_offset + 10
    header = struct.pack("<HHIIIHH", 0x8664, 1, 0, symbol_offset, 2, 0, 0)
    section = struct.pack("<8sIIIIIIHHI", b".text\0\0\0", 0, 0, len(code),
                          raw_offset, relocation_offset, 0, 1, 0, 0x60000020)
    relocation = struct.pack("<IIH", 3, 1, 4)  # REL32 operand of call
    entry = struct.pack("<8sIhHBB", b"entry\0\0\0", 0, 1, 0x20, 2, 0)
    imported = struct.pack("<8sIhHBB", b"\0\0\0\0" + struct.pack("<I", 4),
                           0, 0, 0x20, 2, 0)
    name = b"ExitProcess\0"
    string_table = struct.pack("<I", 4 + len(name)) + name
    return (header + section + code + relocation + entry + imported
            + string_table)


def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    try:
        built = subprocess.run(
            [tool("dub", r"C:\D\dmd2\windows\bin64\dub.exe"),
             "build", "--config=link", "--compiler=dmd"],
            cwd=PACKAGE, capture_output=True, text=True, timeout=300,
        )
        if built.returncode != 0:
            raise CheckError("tool build failed\n" + built.stdout + built.stderr)
        if not TOOL.is_file():
            raise CheckError("coff-link was not produced")

        obj = OUTPUT / "import.obj"
        obj.write_bytes(import_object())
        exe = OUTPUT / "import-linked.exe"
        exe.unlink(missing_ok=True)
        linked = subprocess.run(
            [str(TOOL), str(exe), "entry", str(obj), str(library("kernel32.lib"))],
            cwd=REPO, capture_output=True, text=True, timeout=60,
        )
        if linked.returncode != 0:
            raise CheckError("link failed\n" + linked.stdout + linked.stderr)

        data = exe.read_bytes()
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        coff = pe + 4
        optional = coff + 20
        import_rva, import_size = struct.unpack_from("<II", data, optional + 112 + 8)
        if import_rva == 0 or import_size == 0:
            raise CheckError("optional header has no import directory")
        sections = struct.unpack_from("<H", data, coff + 2)[0]
        optional_size = struct.unpack_from("<H", data, coff + 16)[0]
        table = optional + optional_size
        names = []
        for index in range(sections):
            offset = table + index * 40
            names.append(data[offset:offset + 8].rstrip(b"\0").decode())
        if ".idata" not in names:
            raise CheckError("output has no .idata section")

        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             timeout=30)
        if run.returncode != 0:
            raise CheckError(f"imported ExitProcess exited {run.returncode}")
    except CheckError as error:
        print(f"COFF import verification failed: {error}", file=sys.stderr)
        return 1

    print("COFF import verification passed")
    print(f"  import directory rva=0x{import_rva:X} size={import_size}")
    print("  .idata section present")
    print("  ExitProcess thunk executed, exit=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
