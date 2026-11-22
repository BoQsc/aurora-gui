#!/usr/bin/env python3
"""Verify archive extraction and cross-object REL32 linking.

Builds two synthetic COFF objects — `entry` calls an undefined `helper`, and an
archive member defines `helper` — links them with `coff-link`, and requires the
resulting PE32+ to run with exit code 0.

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


def object_with(code: bytes, symbols, relocations=()) -> bytes:
    raw_offset = 20 + 40
    relocation_offset = raw_offset + len(code)
    symbol_offset = relocation_offset + 10 * len(relocations)
    section = struct.pack(
        "<8sIIIIIIHHI",
        b".text\0\0\0",
        0,
        0,
        len(code),
        raw_offset,
        relocation_offset if relocations else 0,
        0,
        len(relocations),
        0,
        0x60000020,
    )
    header = struct.pack("<HHIIIHH", 0x8664, 1, 0, symbol_offset,
                         len(symbols), 0, 0)
    body = bytearray(code)
    for address, symbol_index in relocations:
        body += struct.pack("<IIH", address, symbol_index, 4)
    for name, section_number in symbols:
        inline = name.encode("ascii")[:8].ljust(8, b"\0")
        body += struct.pack("<8sIhHBB", inline, 0, section_number, 0x20, 2, 0)
    body += struct.pack("<I", 4)
    return header + section + bytes(body)


def archive(members) -> bytes:
    data = bytearray(b"!<arch>\n")
    for name, payload in members:
        header = (
            name.encode("ascii").ljust(16)
            + b"0".ljust(12)
            + b"0".ljust(6)
            + b"0".ljust(6)
            + b"644".ljust(8)
            + str(len(payload)).encode("ascii").ljust(10)
            + b"`\n"
        )
        data += header + payload
        if len(payload) & 1:
            data += b"\n"
    return bytes(data)


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

        # call helper (REL32 at offset 1), then ret.
        entry = object_with(
            bytes([0xE8, 0, 0, 0, 0, 0xC3]),
            [("entry", 1), ("helper", 0)],
            [(1, 1)],
        )
        helper = object_with(bytes([0x31, 0xC0, 0xC3]), [("helper", 1)])
        entry_path = OUTPUT / "entry.obj"
        library_path = OUTPUT / "helpers.lib"
        entry_path.write_bytes(entry)
        library_path.write_bytes(archive([("helper.obj/", helper)]))

        exe = OUTPUT / "archive-linked.exe"
        exe.unlink(missing_ok=True)
        linked = subprocess.run(
            [str(TOOL), str(exe), "entry", str(entry_path), str(library_path)],
            cwd=REPO, capture_output=True, text=True, timeout=60,
        )
        if linked.returncode != 0:
            raise CheckError("link failed\n" + linked.stdout + linked.stderr)
        if not exe.is_file():
            raise CheckError("no executable was written")
        data = exe.read_bytes()
        if data[:2] != b"MZ":
            raise CheckError("output has no MZ header")
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe:pe + 4] != b"PE\0\0":
            raise CheckError("output has no PE signature")

        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             timeout=30)
        if run.returncode != 0:
            raise CheckError(f"linked executable exited {run.returncode}")
    except CheckError as error:
        print(f"COFF archive link verification failed: {error}",
              file=sys.stderr)
        return 1

    print("COFF archive link verification passed")
    print(f"  linked bytes={len(data)}")
    print("  extracted: helper.obj for undefined helper")
    print("  executable exit=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
