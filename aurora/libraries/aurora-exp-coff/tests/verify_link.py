#!/usr/bin/env python3
"""Verify the first COFF link stage end to end.

Writes a synthetic COFF object with one `.text` section (`xor eax, eax; ret`)
and one defined `mainCRTStartup` symbol, links it with `coff-link`, and requires
the produced PE32+ to run with exit code 0.

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


def synthetic_object() -> bytes:
    code = bytes([0x31, 0xC0, 0xC3])  # xor eax, eax; ret
    raw_offset = 20 + 40
    symbol_offset = raw_offset + len(code)
    string_table = b"mainCRTStartup\0"
    string_offset = 4

    header = struct.pack("<HHIIIHH", 0x8664, 1, 0, symbol_offset, 1, 0, 0)
    section = struct.pack(
        "<8sIIIIIIHHI",
        b".text\0\0\0",
        0,
        0,
        len(code),
        raw_offset,
        0,
        0,
        0,
        0,
        0x60000020,
    )
    symbol = struct.pack("<8sIhHBB", b"\0\0\0\0" + struct.pack("<I", string_offset),
                         0, 1, 0x20, 2, 0)
    table = struct.pack("<I", 4 + len(string_table)) + string_table
    return header + section + code + symbol + table


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

        obj = OUTPUT / "synthetic.obj"
        obj.write_bytes(synthetic_object())
        exe = OUTPUT / "linked.exe"
        exe.unlink(missing_ok=True)
        linked = subprocess.run(
            [str(TOOL), str(exe), "mainCRTStartup", str(obj)],
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
        print(f"COFF link verification failed: {error}", file=sys.stderr)
        return 1

    print("COFF link verification passed")
    print(f"  linked bytes={len(data)}")
    print("  entry=mainCRTStartup")
    print("  executable exit=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())