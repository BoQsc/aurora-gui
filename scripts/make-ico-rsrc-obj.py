#!/usr/bin/env python3
"""Build a COFF object whose .rsrc section embeds an .ico as the PE icon.

Produces a linkable object (no relocations) that DMD/lld-link can consume, so a
single-exe build shows the app icon in Explorer/taskbar without needing a
resource compiler. Usage: make-ico-rsrc-obj.py icon.ico out.obj
"""

import struct
import sys

MACHINE_X64 = 0x8664
IMAGE_SCN_CNT_INITIALIZED_DATA = 0x40
IMAGE_SCN_MEM_READ = 0x40000000
RT_ICON = 3
RT_GROUP_ICON = 14
LANG = 0x0409  # English (US)


def read_ico(path):
    data = open(path, "rb").read()
    if len(data) < 6 or data[:4] != b"\x00\x00\x01\x00":
        raise SystemExit(f"{path}: not a valid .ico")
    count = struct.unpack_from("<H", data, 4)[0]
    if count == 0 or len(data) < 6 + 16 * count:
        raise SystemExit(f"{path}: invalid icon directory")
    entries = []
    for i in range(count):
        off = 6 + 16 * i
        width, height, colors, reserved = data[off], data[off + 1], data[off + 2], data[off + 3]
        planes, bitcount = struct.unpack_from("<HH", data, off + 4)
        bytes_in_res, image_off = struct.unpack_from("<II", data, off + 8)
        image = data[image_off:image_off + bytes_in_res]
        if len(image) != bytes_in_res:
            raise SystemExit(f"{path}: truncated icon image {i}")
        entries.append((width, height, colors, reserved, planes, bitcount, image))
    return entries


def build_resource_dir_entries(entries):
    """Returns (section_bytes, image_blocks, group_block)."""
    k = len(entries)
    root_dir = struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 2)
    root_entries = []
    # offsets (within section) of subdirectories
    type3_dir = 16 + 16  # root header + 2 entries
    type14_dir = type3_dir + 16 + k * 8
    lang_start = type14_dir + 16 + 8

    lang_dirs = [lang_start + i * (24 + 16) for i in range(k)]
    data_entries = [lang_dirs[i] + 24 for i in range(k)]
    group_lang_dir = lang_start + k * 40
    group_data_entry = group_lang_dir + 24

    # data block offsets: after all directory structures
    data_start = group_data_entry + 16
    padded_sizes = [((len(e[6]) + 3) // 4) * 4 for e in entries]
    image_offsets = []
    cursor = data_start
    for i in range(k):
        image_offsets.append(cursor)
        cursor += padded_sizes[i]
    group_offset = cursor
    group_size = 6 + 14 * k

    root_entries.append(struct.pack("<II", RT_ICON, 0x80000000 | type3_dir))
    root_entries.append(struct.pack("<II", RT_GROUP_ICON, 0x80000000 | type14_dir))

    type3_body = struct.pack("<IIHHHH", 0, 0, 0, 0, 0, k)
    for i in range(k):
        type3_body += struct.pack("<II", i + 1, 0x80000000 | lang_dirs[i])
    type14_body = struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 1)
    type14_body += struct.pack("<II", 1, 0x80000000 | group_lang_dir)

    lang_dir_body = struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 1)
    # language dir entry -> data entry (no high bit)
    lang_dir_body += struct.pack("<II", LANG, data_entries[0])  # reused for all

    group_lang_body = struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 1)
    group_lang_body += struct.pack("<II", LANG, group_data_entry)

    section = bytearray()
    section += struct.pack("<IIHHHH", 0, 0, 0, 0, 0, 2) + b"".join(root_entries)
    section += type3_body
    section += type14_body
    for i in range(k):
        de = struct.pack("<II", image_offsets[i], len(entries[i][6]))
        section += lang_dir_body + de
    section += group_lang_body
    de = struct.pack("<II", group_offset, group_size)
    section += de
    for e in entries:
        section += e[6] + b"\x00" * ((4 - len(e[6]) % 4) % 4)
    # group icon data: reserved(0), type(1), count, GRPICONDIRENTRYs (id=i+1)
    group = struct.pack("<HHH", 0, 1, k)
    for i, e in enumerate(entries):
        w, h, c, r, planes, bitcount, _ = e
        group += struct.pack("<BBBBHHIH", w, h, c, r, planes, bitcount,
                             len(entries[i][6]), i + 1)
    section += group + b"\x00" * ((4 - len(group) % 4) % 4)
    return bytes(section)


def build_coff(section_data):
    data_size = len(section_data)
    file_header = struct.pack("<HHIIIHH", MACHINE_X64, 1, 0, 0, 0, 0, 0)
    ptr_raw = 0x40  # headers are 20 + 40 = 60; align to 0x40
    section_header = struct.pack(
        "<8sIIIIIIHHI",
        b".rsrc\0\0\0",
        data_size,
        0,
        data_size,
        ptr_raw,
        0,
        0,
        0,
        0,
        IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ,
    )
    pad = b"\x00" * (ptr_raw - (len(file_header) + len(section_header)))
    return file_header + section_header + pad + section_data


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: make-ico-rsrc-obj.py icon.ico out.obj")
    entries = read_ico(sys.argv[1])
    section = build_resource_dir_entries(entries)
    obj = build_coff(section)
    with open(sys.argv[2], "wb") as f:
        f.write(obj)
    print(f"wrote {sys.argv[2]} ({len(obj)} bytes, {len(entries)} icon image(s), "
          f".rsrc section {len(section)} bytes)")


if __name__ == "__main__":
    main()
