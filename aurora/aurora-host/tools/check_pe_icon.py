#!/usr/bin/env python3
"""Verify RT_GROUP_ICON/RT_ICON resources in a Windows executable.

Stdlib-only by design: the package verifier must be able to inspect the PE
resource directory without adding a parser dependency.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import struct
import sys

RT_ICON = 3
RT_GROUP_ICON = 14
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


class PeIconError(Exception):
    pass


def u16(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 2 > len(data):
        raise PeIconError("truncated PE data")
    return struct.unpack_from("<H", data, offset)[0]


def u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise PeIconError("truncated PE data")
    return struct.unpack_from("<I", data, offset)[0]


def section_map(data: bytes) -> tuple[int, int, list[tuple[int, int, int, int]]]:
    if data[:2] != b"MZ":
        raise PeIconError("missing MZ header")
    pe = u32(data, 0x3C)
    if data[pe:pe + 4] != b"PE\0\0":
        raise PeIconError("missing PE signature")
    coff = pe + 4
    sections = u16(data, coff + 2)
    optional_size = u16(data, coff + 16)
    optional = coff + 20
    magic = u16(data, optional)
    if magic == 0x20B:
        directory_base = optional + 112
    elif magic == 0x10B:
        directory_base = optional + 96
    else:
        raise PeIconError(f"unsupported PE optional-header magic 0x{magic:x}")
    count = u32(data, directory_base - 4)
    if count < 3:
        raise PeIconError("PE has no resource data directory")
    resource_rva = u32(data, directory_base + 2 * 8)
    resource_size = u32(data, directory_base + 2 * 8 + 4)
    if resource_rva == 0 or resource_size == 0:
        raise PeIconError("PE resource data directory is empty")

    table = optional + optional_size
    result = []
    for index in range(sections):
        offset = table + index * 40
        virtual_size = u32(data, offset + 8)
        virtual_address = u32(data, offset + 12)
        raw_size = u32(data, offset + 16)
        raw_offset = u32(data, offset + 20)
        result.append((virtual_address, max(virtual_size, raw_size), raw_offset,
                       raw_size))
    return resource_rva, resource_size, result


def rva_offset(rva: int, sections: list[tuple[int, int, int, int]]) -> int:
    for virtual_address, span, raw_offset, raw_size in sections:
        if virtual_address <= rva < virtual_address + span:
            delta = rva - virtual_address
            if delta >= raw_size:
                raise PeIconError(f"RVA 0x{rva:x} points past section data")
            return raw_offset + delta
    raise PeIconError(f"RVA 0x{rva:x} is not in a section")


def directory_entries(data: bytes, offset: int) -> list[tuple[int, int]]:
    named = u16(data, offset + 12)
    ids = u16(data, offset + 14)
    total = named + ids
    if total > 4096:
        raise PeIconError("resource directory is implausibly large")
    entries = []
    for index in range(total):
        entry = offset + 16 + index * 8
        entries.append((u32(data, entry), u32(data, entry + 4)))
    return entries


def find_type(data: bytes, base: int, type_id: int) -> int:
    for name, child in directory_entries(data, base):
        if not name & 0x80000000 and name == type_id:
            return base + (child & 0x7FFFFFFF)
    raise PeIconError(f"resource type {type_id} is missing")


def group_payload(data: bytes, base: int, group_dir: int,
                  sections: list[tuple[int, int, int, int]]) -> tuple[int, bytes]:
    """Return (group id, group data) for the first RT_GROUP_ICON entry."""
    for group_id, child in directory_entries(data, group_dir):
        if group_id & 0x80000000:
            continue
        language_dir = base + (child & 0x7FFFFFFF)
        for _language, leaf in directory_entries(data, language_dir):
            entry = base + (leaf & 0x7FFFFFFF)
            payload_rva = u32(data, entry)
            payload_size = u32(data, entry + 4)
            if payload_size < 6:
                raise PeIconError("group icon payload is truncated")
            offset = rva_offset(payload_rva, sections)
            return group_id, data[offset:offset + payload_size]
    raise PeIconError("RT_GROUP_ICON has no icon group")


def icon_ids(data: bytes, base: int, icon_dir: int,
             sections: list[tuple[int, int, int, int]]) -> set[int]:
    ids = set()
    for name, child in directory_entries(data, icon_dir):
        if name & 0x80000000:
            continue
        ids.add(name)
        language_dir = base + (child & 0x7FFFFFFF)
        for _language, leaf in directory_entries(data, language_dir):
            entry = base + (leaf & 0x7FFFFFFF)
            payload_rva = u32(data, entry)
            payload_size = u32(data, entry + 4)
            offset = rva_offset(payload_rva, sections)
            if payload_size and data[offset:offset + 8] != PNG_SIGNATURE:
                raise PeIconError(f"icon {name} is not a PNG frame")
    return ids


def verify_pe_icon(executable: Path) -> int:
    data = executable.read_bytes()
    resource_rva, _resource_size, sections = section_map(data)
    base = rva_offset(resource_rva, sections)
    group_dir = find_type(data, base, RT_GROUP_ICON)
    group_id, payload = group_payload(data, base, group_dir, sections)
    reserved, icon_type, count = struct.unpack_from("<HHH", payload, 0)
    if reserved != 0 or icon_type != 1:
        raise PeIconError("malformed RT_GROUP_ICON header")
    if count == 0:
        raise PeIconError("RT_GROUP_ICON has no frames")
    if len(payload) < 6 + count * 14:
        raise PeIconError("RT_GROUP_ICON frame table is truncated")
    wanted = {struct.unpack_from("<H", payload, 6 + index * 14 + 12)[0]
              for index in range(count)}
    available = icon_ids(data, base, find_type(data, base, RT_ICON), sections)
    missing = sorted(wanted - available)
    if missing:
        raise PeIconError(f"RT_GROUP_ICON references missing RT_ICON ids {missing}")
    if len(wanted) != count:
        raise PeIconError("RT_GROUP_ICON has duplicate frame ids")
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    try:
        count = verify_pe_icon(args.executable)
    except (OSError, PeIconError) as error:
        print(f"PE icon verification failed: {error}", file=sys.stderr)
        return 1
    print(f"PE icon verified: {count} embedded frames")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
