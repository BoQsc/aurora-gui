#!/usr/bin/env python3
"""Verify ADDR64 fixups and generated .reloc entries.

Builds an object with a `.data` qword relocated to the entry code symbol,
links it, and requires:

* `.data` to contain imageBase + entry RVA;
* a `.reloc` section with a DIR64 entry for the `.data` slot;
* the optional-header base-relocation directory to point at `.reloc`;
* the linked EXE to run with exit code 0.

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


def object_with_absolute_relocation() -> bytes:
    code = bytes([0x31, 0xC0, 0xC3])  # xor eax, eax; ret
    text_offset = 100
    data_offset = 104
    relocation_offset = 112
    symbol_offset = 122

    header = struct.pack("<HHIIIHH", 0x8664, 2, 0, symbol_offset, 1, 0, 0)
    text = struct.pack("<8sIIIIIIHHI", b".text\0\0\0", 0, 0, len(code),
                       text_offset, 0, 0, 0, 0, 0x60000020)
    data = struct.pack("<8sIIIIIIHHI", b".data\0\0\0", 8, 0, 8,
                       data_offset, relocation_offset, 0, 1, 0, 0xC0000040)
    relocation = struct.pack("<IIH", 0, 0, 1)  # ADDR64 to symbol 0
    symbol = struct.pack("<8sIhHBB", b"entry\0\0\0", 0, 1, 0x20, 2, 0)
    string_table = struct.pack("<I", 4)
    return (header + text + data + code + b"\0" + bytes(8) + relocation + symbol
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

        obj = OUTPUT / "absolute.obj"
        obj.write_bytes(object_with_absolute_relocation())
        exe = OUTPUT / "absolute-linked.exe"
        exe.unlink(missing_ok=True)
        linked = subprocess.run(
            [str(TOOL), str(exe), "entry", str(obj)],
            cwd=REPO, capture_output=True, text=True, timeout=60,
        )
        if linked.returncode != 0:
            raise CheckError("link failed\n" + linked.stdout + linked.stderr)
        data = exe.read_bytes()
        if data[:2] != b"MZ":
            raise CheckError("output has no MZ header")
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        coff = pe + 4
        optional = coff + 20
        o = optional + 112
        reloc_rva, reloc_size = struct.unpack_from("<II", data, o + 5 * 8)
        if reloc_rva == 0 or reloc_size == 0:
            raise CheckError("optional header has no base-relocation directory")

        sections = struct.unpack_from("<H", data, coff + 2)[0]
        optional_size = struct.unpack_from("<H", data, coff + 16)[0]
        table = optional + optional_size
        reloc_offset = None
        data_offset = None
        for index in range(sections):
            offset = table + index * 40
            name = data[offset:offset + 8].rstrip(b"\0").decode()
            virtual_size, virtual_address, raw_size, raw_pointer = (
                struct.unpack_from("<IIII", data, offset + 8))
            if name == ".reloc":
                reloc_offset = raw_pointer
            if name == ".data":
                data_offset = raw_pointer
        if reloc_offset is None or data_offset is None:
            raise CheckError("output is missing .reloc or .data")

        page, block_size = struct.unpack_from("<II", data, reloc_offset)
        entry = struct.unpack_from("<H", data, reloc_offset + 8)[0]
        if page != 0x2000 or block_size < 10:
            raise CheckError(f"bad relocation block: page={page:#x} size={block_size}")
        if (entry >> 12) != 10 or (entry & 0xFFF) != 0:
            raise CheckError(f"bad relocation entry: {entry:#x}")

        pointer = struct.unpack_from("<Q", data, data_offset)[0]
        if pointer != 0x140001000:
            raise CheckError(f".data pointer is {pointer:#x}, expected 0x140001000")

        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             timeout=30)
        if run.returncode != 0:
            raise CheckError(f"linked executable exited {run.returncode}")
    except CheckError as error:
        print(f"COFF relocation verification failed: {error}", file=sys.stderr)
        return 1

    print("COFF relocation verification passed")
    print(f"  base-relocation directory rva=0x{reloc_rva:X} size={reloc_size}")
    print(f"  .data pointer=0x{pointer:X}")
    print("  relocation type=DIR64 offset=0")
    print("  executable exit=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
