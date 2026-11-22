#!/usr/bin/env python3
"""Verify TLS-directory and exception-directory emission.

Builds an object with `.tls`, `_tls_index`, `_tls_used`, and `.pdata`, links it,
and requires:

* a TLS directory with start/end around `.tls` and AddressOfIndex at
  `_tls_index`;
* `_tls_used` patched to the same start/end/index;
* an exception directory pointing at `.pdata`;
* the EXE to run with exit code 0.

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


def tls_object() -> bytes:
    code = bytes([0x31, 0xC0, 0xC3])
    text_offset = 180
    tls_offset = text_offset + len(code)
    data_offset = tls_offset + 8
    pdata_offset = data_offset + 48
    symbol_offset = pdata_offset + 12
    header = struct.pack("<HHIIIHH", 0x8664, 4, 0, symbol_offset, 3, 0, 0)

    def section(name: bytes, size: int, raw: int, characteristics: int) -> bytes:
        return struct.pack("<8sIIIIIIHHI", name, size, 0, size, raw, 0, 0, 0, 0,
                           characteristics)

    text = section(b".text\0\0\0", 3, text_offset, 0x60000020)
    tls = section(b".tls\0\0\0\0", 8, tls_offset, 0xC0000040)
    data = section(b".data\0\0\0", 48, data_offset, 0xC0000040)
    pdata = section(b".pdata\0\0", 12, pdata_offset, 0x40000040)

    entry = struct.pack("<8sIhHBB", b"entry\0\0\0", 0, 1, 0x20, 2, 0)
    index = struct.pack("<8sIhHBB", b"\0\0\0\0" + struct.pack("<I", 4),
                        0, 3, 0, 2, 0)
    used = struct.pack("<8sIhHBB", b"\0\0\0\0" + struct.pack("<I", 15),
                       8, 3, 0, 2, 0)
    names = b"_tls_index\0_tls_used\0"
    string_table = struct.pack("<I", 4 + len(names)) + names
    data_bytes = bytes(4) + bytes(4) + bytes(40)
    return (header + text + tls + data + pdata + code + bytes(8) + data_bytes
            + bytes(12) + entry + index + used + string_table)


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

        obj = OUTPUT / "tls.obj"
        obj.write_bytes(tls_object())
        exe = OUTPUT / "tls-linked.exe"
        exe.unlink(missing_ok=True)
        linked = subprocess.run(
            [str(TOOL), str(exe), "entry", str(obj)],
            cwd=REPO, capture_output=True, text=True, timeout=60,
        )
        if linked.returncode != 0:
            raise CheckError("link failed\n" + linked.stdout + linked.stderr)

        data = exe.read_bytes()
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        coff = pe + 4
        optional = coff + 20
        base = struct.unpack_from("<Q", data, optional + 24)[0]
        dirs = optional + 112
        tls_rva, tls_size = struct.unpack_from("<II", data, dirs + 9 * 8)
        exception_rva, exception_size = struct.unpack_from("<II", data, dirs + 3 * 8)
        if tls_rva == 0 or tls_size != 40:
            raise CheckError("missing TLS directory")
        if exception_rva == 0 or exception_size == 0:
            raise CheckError("missing exception directory")

        sections = struct.unpack_from("<H", data, coff + 2)[0]
        optional_size = struct.unpack_from("<H", data, coff + 16)[0]
        table = optional + optional_size
        info = {}
        for index in range(sections):
            offset = table + index * 40
            name = data[offset:offset + 8].rstrip(b"\0").decode()
            virtual_size, virtual_address, raw_size, raw_pointer = (
                struct.unpack_from("<IIII", data, offset + 8))
            info[name] = (virtual_address, raw_pointer)
        def offset_of(rva: int) -> int:
            for name, (va, raw) in info.items():
                pass
            for index in range(sections):
                offset = table + index * 40
                virtual_size, virtual_address, raw_size, raw_pointer = (
                    struct.unpack_from("<IIII", data, offset + 8))
                if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
                    return raw_pointer + rva - virtual_address
            raise CheckError(f"RVA {rva:#x} outside sections")

        start, end, index_address, callbacks, zero_fill, characteristics = (
            struct.unpack_from("<QQQQII", data, offset_of(tls_rva)))
        tls_va = info[".tls"][0]
        data_va = info[".data"][0]
        if start != base + tls_va or end != start + 8:
            raise CheckError(f"TLS start/end wrong: {start:#x}/{end:#x}")
        if index_address != base + data_va:
            raise CheckError("TLS AddressOfIndex does not point at _tls_index")
        used_start, used_end, used_index = struct.unpack_from(
            "<QQQ", data, info[".data"][1] + 8)
        if (used_start, used_end, used_index) != (start, end, index_address):
            raise CheckError("_tls_used was not patched")

        if exception_rva != info[".pdata"][0] or exception_size != 12:
            raise CheckError("exception directory does not match .pdata")

        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             timeout=30)
        if run.returncode != 0:
            raise CheckError(f"linked executable exited {run.returncode}")
    except CheckError as error:
        print(f"COFF TLS verification failed: {error}", file=sys.stderr)
        return 1

    print("COFF TLS verification passed")
    print(f"  TLS directory rva=0x{tls_rva:X} start=0x{start:X} end=0x{end:X}")
    print(f"  AddressOfIndex=0x{index_address:X}")
    print(f"  exception directory rva=0x{exception_rva:X} size={exception_size}")
    print("  executable exit=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
