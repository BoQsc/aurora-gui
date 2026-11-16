#!/usr/bin/env python3
"""Read PE import tables without external dependencies."""
from __future__ import annotations

import struct
from pathlib import Path


class PeError(ValueError):
    pass


def read_imports(path: Path) -> dict[str, list[str]]:
    """Return imported DLL names mapped to imported symbol names."""
    data = path.read_bytes()
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise PeError(f"{path}: not a PE image")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_offset:pe_offset + 4] != b"PE\0\0":
        raise PeError(f"{path}: missing PE signature")
    coff = pe_offset + 4
    section_count = struct.unpack_from("<H", data, coff + 2)[0]
    optional_size = struct.unpack_from("<H", data, coff + 16)[0]
    optional = coff + 20
    if optional + 2 > len(data):
        raise PeError(f"{path}: truncated optional header")
    magic = struct.unpack_from("<H", data, optional)[0]
    if magic == 0x20B:
        directory_offset = 112
        section_offset = 240
        pointer_size = 8
        pointer_format = "<Q"
        ordinal_flag = 1 << 63
    elif magic == 0x10B:
        directory_offset = 96
        section_offset = 224
        pointer_size = 4
        pointer_format = "<I"
        ordinal_flag = 1 << 31
    else:
        raise PeError(f"{path}: unsupported optional-header magic {magic:#x}")

    sections = []
    section_table = optional + section_offset
    for index in range(section_count):
        offset = section_table + index * 40
        if offset + 40 > len(data):
            raise PeError(f"{path}: truncated section table")
        virtual_size, virtual_address, raw_size, raw_pointer = struct.unpack_from(
            "<IIII", data, offset + 8
        )
        sections.append((virtual_address, virtual_size, raw_pointer, raw_size))

    def rva_to_offset(rva: int) -> int:
        for virtual_address, virtual_size, raw_pointer, raw_size in sections:
            size = max(virtual_size, raw_size)
            if virtual_address <= rva < virtual_address + size:
                return raw_pointer + (rva - virtual_address)
        raise PeError(f"{path}: RVA {rva:#x} is outside all sections")

    def c_string(rva: int) -> str:
        offset = rva_to_offset(rva)
        end = data.find(b"\0", offset)
        if end < 0:
            raise PeError(f"{path}: unterminated import string")
        try:
            return data[offset:end].decode("ascii")
        except UnicodeDecodeError as error:
            raise PeError(f"{path}: non-ASCII import string") from error

    directories = optional + directory_offset
    if directories + 16 > len(data):
        raise PeError(f"{path}: truncated data directories")
    import_rva, import_size = struct.unpack_from("<II", data, directories + 8)
    if import_rva == 0:
        return {}

    descriptor = rva_to_offset(import_rva)
    imports: dict[str, list[str]] = {}
    while True:
        if descriptor + 20 > len(data):
            raise PeError(f"{path}: truncated import descriptor")
        original_first_thunk, _, _, name_rva, first_thunk = struct.unpack_from(
            "<IIIII", data, descriptor
        )
        if name_rva == 0:
            break
        dll = c_string(name_rva).lower()
        thunk_rva = original_first_thunk or first_thunk
        if thunk_rva == 0:
            raise PeError(f"{path}: import descriptor has no thunk table")
        thunk = rva_to_offset(thunk_rva)
        symbols = imports.setdefault(dll, [])
        while True:
            if thunk + pointer_size > len(data):
                raise PeError(f"{path}: truncated import thunk")
            entry = struct.unpack_from(pointer_format, data, thunk)[0]
            if entry == 0:
                break
            if entry & ordinal_flag:
                symbols.append(f"#{entry & 0xFFFF}")
            else:
                symbols.append(c_string((entry & 0x7FFFFFFF) + 2))
            thunk += pointer_size
        descriptor += 20

    return imports
