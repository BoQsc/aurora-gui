#!/usr/bin/env python3
"""Verify Aurora's static Windows CRT policy and linked PE imports."""

from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from pathlib import Path


REQUIRED_CRT_FLAG = "-mscrtlib=libcmt"
REQUIRED_DFLAG_FIELDS = ("dflags-windows-dmd", "dflags-windows-ldc")
PORTABLE_BUILD_TYPE = "portable-release"
REQUIRED_BUILD_OPTIONS = {"releaseMode", "optimize", "inline"}
FORBIDDEN_CRT_DLL = re.compile(
    r"^(?:"
    r"msvcr(?:t|\d+)d?"
    r"|msvcp\d+d?"
    r"|vcruntime\d+(?:_\d+)?d?"
    r"|ucrtbased?"
    r"|api-ms-win-crt-.+"
    r")\.dll$",
    re.IGNORECASE,
)


class PortableBuildError(RuntimeError):
    pass


def read_u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]


def read_u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def imported_dlls(path: Path) -> list[str]:
    data = path.read_bytes()
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise PortableBuildError(f"{path} is not a Windows PE executable")

    pe_offset = read_u32(data, 0x3C)
    if pe_offset + 24 > len(data) or data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise PortableBuildError(f"{path} has an invalid PE header")

    section_count = read_u16(data, pe_offset + 6)
    optional_size = read_u16(data, pe_offset + 20)
    optional_offset = pe_offset + 24
    magic = read_u16(data, optional_offset)
    if magic == 0x10B:
        directory_offset = optional_offset + 96
        image_base = read_u32(data, optional_offset + 28)
    elif magic == 0x20B:
        directory_offset = optional_offset + 112
        image_base = struct.unpack_from("<Q", data, optional_offset + 24)[0]
    else:
        raise PortableBuildError(f"{path} uses an unsupported PE optional header")

    import_rva = read_u32(data, directory_offset + 8)
    delay_import_rva = read_u32(data, directory_offset + 13 * 8)
    if import_rva == 0 and delay_import_rva == 0:
        return []

    sections: list[tuple[int, int, int]] = []
    section_offset = optional_offset + optional_size
    for index in range(section_count):
        offset = section_offset + index * 40
        if offset + 40 > len(data):
            raise PortableBuildError(f"{path} has a truncated PE section table")
        virtual_size = read_u32(data, offset + 8)
        virtual_address = read_u32(data, offset + 12)
        raw_size = read_u32(data, offset + 16)
        raw_offset = read_u32(data, offset + 20)
        sections.append((virtual_address, max(virtual_size, raw_size), raw_offset))

    def rva_to_offset(rva: int) -> int:
        for virtual_address, mapped_size, raw_offset in sections:
            if virtual_address <= rva < virtual_address + mapped_size:
                result = raw_offset + rva - virtual_address
                if result >= len(data):
                    break
                return result
        raise PortableBuildError(f"{path} contains an invalid import-table RVA")

    def read_name(name_rva: int) -> str:
        name_offset = rva_to_offset(name_rva)
        name_end = data.find(b"\0", name_offset)
        if name_end < 0:
            raise PortableBuildError(f"{path} has an unterminated imported DLL name")
        return data[name_offset:name_end].decode("ascii", errors="replace")

    imports: list[str] = []
    if import_rva:
        descriptor_offset = rva_to_offset(import_rva)
        while descriptor_offset + 20 <= len(data):
            descriptor = struct.unpack_from("<IIIII", data, descriptor_offset)
            if descriptor == (0, 0, 0, 0, 0):
                break
            imports.append(read_name(descriptor[3]))
            descriptor_offset += 20
        else:
            raise PortableBuildError(f"{path} has an unterminated PE import table")

    if delay_import_rva:
        descriptor_offset = rva_to_offset(delay_import_rva)
        while descriptor_offset + 32 <= len(data):
            descriptor = struct.unpack_from("<IIIIIIII", data, descriptor_offset)
            if descriptor == (0, 0, 0, 0, 0, 0, 0, 0):
                break
            attributes, name_pointer = descriptor[:2]
            name_rva = name_pointer if attributes & 1 else name_pointer - image_base
            imports.append(read_name(name_rva))
            descriptor_offset += 32
        else:
            raise PortableBuildError(f"{path} has an unterminated delay-import table")

    return imports


def verify_manifests(repo_root: Path) -> list[str]:
    failures: list[str] = []
    manifests = sorted(
        path
        for path in repo_root.rglob("dub.json")
        if not any(part in {".dub", "build", "dist"} for part in path.parts)
    )
    if not manifests:
        return ["no dub.json manifests were found"]

    for path in manifests:
        relative = path.relative_to(repo_root)
        try:
            recipe = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            failures.append(f"{relative}: cannot read DUB recipe: {error}")
            continue
        build_type = recipe.get("buildTypes", {}).get(PORTABLE_BUILD_TYPE)
        if not isinstance(build_type, dict):
            failures.append(f"{relative}: missing {PORTABLE_BUILD_TYPE} build type")
            continue
        options = set(build_type.get("buildOptions", []))
        missing_options = sorted(REQUIRED_BUILD_OPTIONS - options)
        if missing_options:
            failures.append(
                f"{relative}: {PORTABLE_BUILD_TYPE} is missing build options "
                + ", ".join(missing_options)
            )
        for field in REQUIRED_DFLAG_FIELDS:
            flags = build_type.get(field, [])
            if REQUIRED_CRT_FLAG not in flags:
                failures.append(
                    f"{relative}: {PORTABLE_BUILD_TYPE}.{field} must contain "
                    f"{REQUIRED_CRT_FLAG}"
                )
    return failures


def verify_executables(paths: list[Path]) -> list[str]:
    failures: list[str] = []
    for path in paths:
        if not path.is_file():
            failures.append(f"{path}: executable does not exist")
            continue
        try:
            imports = imported_dlls(path)
        except (OSError, PortableBuildError, struct.error) as error:
            failures.append(str(error))
            continue
        forbidden = sorted(name for name in imports if FORBIDDEN_CRT_DLL.match(name))
        if forbidden:
            failures.append(f"{path}: dynamically imports {', '.join(forbidden)}")
        else:
            print(f"portable CRT check passed: {path}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check Aurora portable-release recipes and optional Windows executables for dynamic CRT dependencies."
    )
    parser.add_argument(
        "executables",
        nargs="*",
        type=Path,
        help="linked Windows executables whose PE imports should be checked",
    )
    parser.add_argument(
        "--skip-manifests",
        action="store_true",
        help="check only the supplied executables",
    )
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parent.parent
    failures = [] if args.skip_manifests else verify_manifests(repo_root)
    failures.extend(verify_executables(args.executables))

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1

    if not args.skip_manifests:
        print("portable-release static CRT policy is present in every Aurora DUB recipe")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
