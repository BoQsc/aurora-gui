#!/usr/bin/env python3
"""Verify CodeView debug-directory and stripped-PDB emission.

Links the zero-CRT probe through the Aurora linker with `/DEBUG /PDB:`, then:

* requires the PE debug directory to be CodeView and reference the PDB path;
* parses the MSF container and its PDB info, symbol-record, and section-header
  streams;
* requires the RSDS GUID/age to match the PDB info stream;
* requires `mainCRTStartup` in the public symbols and `.text` in the section
  headers;
* runs the EXE with exit code 0.

Run from anywhere; paths resolve from the repository root.
"""
from __future__ import annotations

import os
import shutil
import struct
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
COFF = REPO / "aurora" / "libraries" / "aurora-exp-coff"
CRT = REPO / "aurora" / "libraries" / "aurora-exp-win32-crt"
TOOL = COFF / "coff-link.exe"
OUTPUT = REPO / "build" / "coff" / "pdb"


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


def stream(root: bytes, index: int) -> bytes:
    count = struct.unpack_from("<I", root, 0)[0]
    sizes = list(struct.unpack_from("<" + "I" * count, root, 4))
    position = 4 + 4 * count
    blocks = []
    for size in sizes:
        pages = (size + 4095) // 4096
        blocks.append(list(struct.unpack_from("<" + "I" * pages, root, position)))
        position += 4 * pages
    return sizes, blocks


def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    try:
        built = subprocess.run(
            [tool("dub", r"C:\D\dmd2\windows\bin64\dub.exe"),
             "build", "--config=link", "--compiler=dmd"],
            cwd=COFF, capture_output=True, text=True, timeout=300,
        )
        if built.returncode != 0:
            raise CheckError("tool build failed\n" + built.stdout + built.stderr)

        exe = OUTPUT / "pdb-hello.exe"
        pdb = OUTPUT / "pdb-hello.pdb"
        exe.unlink(missing_ok=True)
        pdb.unlink(missing_ok=True)
        objects = OUTPUT / "obj"
        objects.mkdir(exist_ok=True)
        environment = os.environ.copy()
        environment["LINKCMD64"] = str(TOOL)
        sources = sorted(str(path) for path in (CRT / "source").rglob("*.d"))
        sources.append(str(CRT / "tests" / "probe.d"))
        compiled = subprocess.run(
            [
                tool("dmd", r"C:\D\dmd2\windows\bin64\dmd.exe"),
                "-mscrtlib=msvcrt",
                f"-I{CRT / 'source'}",
                f"-od={objects}",
                f"-of={exe}",
                *sources,
                "-L/NODEFAULTLIB:msvcrt",
                "-L/NODEFAULTLIB:libcmt",
                "-L/NODEFAULTLIB:oldnames",
                "-L/ENTRY:mainCRTStartup",
                "-Lkernel32.lib",
                "-L/DEBUG",
                f"-L/PDB:{pdb}",
            ],
            cwd=REPO, capture_output=True, text=True, timeout=300,
            env=environment,
        )
        if compiled.returncode != 0:
            raise CheckError("DMD/PDB link failed\n"
                             + compiled.stdout + compiled.stderr)
        if not exe.is_file() or not pdb.is_file():
            raise CheckError("linker did not emit both EXE and PDB")

        data = exe.read_bytes()
        pe = struct.unpack_from("<I", data, 0x3C)[0]
        coff = pe + 4
        optional = coff + 20
        debug_rva, debug_size = struct.unpack_from("<II", data, optional + 112 + 6 * 8)
        if debug_rva == 0 or debug_size < 28:
            raise CheckError("optional header has no debug directory")
        sections = struct.unpack_from("<H", data, coff + 2)[0]
        optional_size = struct.unpack_from("<H", data, coff + 16)[0]
        table = optional + optional_size
        section_info = []
        for index in range(sections):
            offset = table + index * 40
            name = data[offset:offset + 8].rstrip(b"\0").decode()
            virtual_size, virtual_address, raw_size, raw_pointer = (
                struct.unpack_from("<IIII", data, offset + 8))
            section_info.append((name, virtual_address, virtual_size,
                                 raw_pointer, raw_size))

        def offset_of(rva: int) -> int:
            for name, va, vsize, raw, rawsize in section_info:
                if va <= rva < va + max(vsize, rawsize):
                    return raw + rva - va
            raise CheckError(f"RVA {rva:#x} outside sections")

        entry = offset_of(debug_rva)
        debug_type, debug_data_size, raw_data = struct.unpack_from("<III", data, entry + 12)
        if debug_type != 2:
            raise CheckError(f"debug entry type is {debug_type}, not CodeView")
        if raw_data != debug_rva + 28:
            raise CheckError("debug entry does not point at the RSDS record")
        rsds = offset_of(raw_data)
        if data[rsds:rsds + 4] != b"RSDS":
            raise CheckError("missing RSDS signature")
        guid = data[rsds + 4:rsds + 20]
        age = struct.unpack_from("<I", data, rsds + 20)[0]
        path_start = rsds + 24
        path_end = data.index(b"\0", path_start)
        rsds_path = data[path_start:path_end].decode("utf-8", "replace")
        if Path(rsds_path).name != pdb.name:
            raise CheckError(f"RSDS path is {rsds_path!r}, expected {pdb.name}")

        image = pdb.read_bytes()
        if not image.startswith(b"Microsoft C/C++ MSF 7.00\r\n\x1aDS"):
            raise CheckError("PDB has no MSF 7.00 superblock")
        page_size, fpm, num_pages, root_size, reserved, root_map = (
            struct.unpack_from("<IIIIII", image, 0x20))
        if page_size != 4096:
            raise CheckError(f"unexpected PDB page size {page_size}")
        root_pages = list(struct.unpack_from("<I", image, root_map * page_size)[:1])
        root_blocks = []
        directory_pages = (root_size + 4095) // 4096
        for index in range(directory_pages):
            root_blocks.append(struct.unpack_from("<I", image, root_map * page_size + index * 4)[0])
        root = b"".join(
            image[block * page_size:block * page_size + page_size]
            for block in root_blocks
        )[:root_size]

        sizes, blocks = stream(root, 0)
        if sizes[0] != 0 or len(sizes) != 7:
            raise CheckError(f"unexpected PDB stream count {len(sizes)}")

        def stream_bytes(index: int) -> bytes:
            return b"".join(
                image[block * page_size:block * page_size + page_size]
                for block in blocks[index]
            )[:sizes[index]]

        info = stream_bytes(1)
        info_guid = info[12:28]
        info_age = struct.unpack_from("<I", info, 8)[0]
        if info_guid != guid or info_age != age:
            raise CheckError("PDB GUID/age does not match the RSDS record")

        symbols = stream_bytes(4)
        names = []
        position = 0
        while position + 2 <= len(symbols):
            length = struct.unpack_from("<H", symbols, position)[0]
            if length == 0 or position + 2 + length > len(symbols):
                break
            kind = struct.unpack_from("<H", symbols, position + 2)[0]
            if kind == 0x110E:
                name_start = position + 2 + 2 + 4 + 4 + 2
                name = symbols[name_start:position + 2 + length]
                names.append(name.rstrip(b"\0").decode("utf-8", "replace"))
            position += 2 + length
        if "mainCRTStartup" not in names:
            raise CheckError(
                "public symbol stream has no mainCRTStartup; "
                f"stream size={sizes[4]} names={names[:20]}")

        headers = stream_bytes(5)
        if b".text" not in headers:
            raise CheckError("section-header stream has no .text")

        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             timeout=30)
        if run.returncode != 0:
            raise CheckError(f"linked executable exited {run.returncode}")
    except CheckError as error:
        print(f"COFF PDB verification failed: {error}", file=sys.stderr)
        return 1

    print("COFF PDB verification passed")
    print(f"  debug directory rva=0x{debug_rva:X}")
    print(f"  RSDS GUID={guid.hex()} age={age}")
    print(f"  PDB streams={len(sizes)} symbols={len(names)}")
    print(f"  PDB path={rsds_path}")
    print("  executable exit=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
