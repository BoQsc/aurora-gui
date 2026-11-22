#!/usr/bin/env python3
"""Verify COMDAT ANY selection.

Builds two objects that both define a COMDAT `.text` section with the external
symbol `entry`. The first returns 0, the duplicate would return 1. Linking both
must keep the first and run with exit code 0.

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


def comdat_object(code: bytes) -> bytes:
    raw_offset = 60
    symbol_offset = raw_offset + len(code)
    header = struct.pack("<HHIIIHH", 0x8664, 1, 0, symbol_offset, 3, 0, 0)
    section = struct.pack("<8sIIIIIIHHI", b".text\0\0\0", 0, 0, len(code),
                          raw_offset, 0, 0, 0, 0, 0x60501020)
    section_symbol = struct.pack("<8sIhHBB", b".text\0\0\0", 0, 1, 0, 3, 1)
    aux = struct.pack("<IHHIHB3x", len(code), 0, 0, 0, 0, 2)
    entry_symbol = struct.pack("<8sIhHBB", b"entry\0\0\0", 0, 1, 0x20, 2, 0)
    string_table = struct.pack("<I", 4)
    return (header + section + code + section_symbol + aux + entry_symbol
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

        first = OUTPUT / "comdat-first.obj"
        second = OUTPUT / "comdat-second.obj"
        first.write_bytes(comdat_object(bytes([0x31, 0xC0, 0xC3])))
        second.write_bytes(comdat_object(
            bytes([0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3])))  # mov eax,1; ret

        exe = OUTPUT / "comdat-linked.exe"
        exe.unlink(missing_ok=True)
        linked = subprocess.run(
            [str(TOOL), str(exe), "entry", str(first), str(second)],
            cwd=REPO, capture_output=True, text=True, timeout=60,
        )
        if linked.returncode != 0:
            raise CheckError("link failed\n" + linked.stdout + linked.stderr)

        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             timeout=30)
        if run.returncode != 0:
            raise CheckError(
                f"COMDAT selection kept the duplicate (exit {run.returncode})")
    except CheckError as error:
        print(f"COMDAT verification failed: {error}", file=sys.stderr)
        return 1

    print("COMDAT verification passed")
    print("  duplicate ANY section discarded")
    print("  executable exit=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
