"""SPDX-License-Identifier: 0BSD

Generate standard COFF import descriptors for UCRT memory exports.
No function implementation or Microsoft library object is copied.
"""

import argparse
import ctypes
from pathlib import Path
import struct


parser = argparse.ArgumentParser()
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()

symbols = ("memchr", "memcmp", "memcpy", "memmove", "memset")
ucrt = ctypes.WinDLL("ucrtbase.dll")
for symbol in symbols:
    getattr(ucrt, symbol)  # Fail if this Windows UCRT does not export it.

def member(name, payload):
    header = (
        f"{name:<16}{0:<12}{0:<6}{0:<6}{0:<8}{len(payload):<10}`\n"
    ).encode("ascii")
    assert len(header) == 60
    return header + payload + (b"\n" if len(payload) & 1 else b"")


objects = []
for symbol in symbols:
    # PE/COFF short import header: x64, import-by-name, function code.
    strings = symbol.encode("ascii") + b"\0ucrtbase.dll\0"
    header = struct.pack("<HHHHIIHH", 0, 0xFFFF, 0, 0x8664,
                         0, len(strings), 0, 1 << 2)
    objects.append(member(symbol + ".obj/", header + strings))

indexed = [(name, index) for index, symbol in enumerate(symbols)
           for name in (symbol, "__imp_" + symbol)]
first_size = 4 + 4 * len(indexed) + sum(len(name) + 1 for name, _ in indexed)
second_sorted = sorted(indexed)
second_size = (4 + 4 * len(objects) + 4 + 2 * len(indexed) +
               sum(len(name) + 1 for name, _ in second_sorted))
first_offset = 8
second_offset = first_offset + len(member("/", bytes(first_size)))
object_offset = second_offset + len(member("/", bytes(second_size)))
offsets = []
for obj in objects:
    offsets.append(object_offset)
    object_offset += len(obj)

first = struct.pack(">I", len(indexed))
first += b"".join(struct.pack(">I", offsets[index]) for _, index in indexed)
first += b"".join(name.encode("ascii") + b"\0" for name, _ in indexed)
second = struct.pack("<I", len(objects))
second += b"".join(struct.pack("<I", offset) for offset in offsets)
second += struct.pack("<I", len(indexed))
second += b"".join(struct.pack("<H", index + 1)
                   for _, index in second_sorted)
second += b"".join(name.encode("ascii") + b"\0"
                   for name, _ in second_sorted)
assert len(first) == first_size and len(second) == second_size
archive = b"!<arch>\n" + member("/", first) + member("/", second)
archive += b"".join(objects)
args.out.parent.mkdir(parents=True, exist_ok=True)
args.out.write_bytes(archive)
print(f"Generated {args.out.resolve()} ({args.out.stat().st_size} bytes)")
