#!/usr/bin/env python3
"""Append a .rsrc section embedding an .ico as the PE icon of an exe.

Works with any linker (including the old lld-link 9 DMD ships, which cannot
handle hand-built resource objects). The section is appended to the file and
the PE headers (section table, SizeOfImage, resource data directory) are
updated, so the exe shows the app icon in Explorer/taskbar.

Usage: patch-pe-icon.py icon.ico exe [exe_out]
"""

import struct
import sys
from collections import deque

RT_ICON = 3
RT_GROUP_ICON = 14
LANG = 0x0409

SIZE_DIR_TABLE = 16
SIZE_DIR_ENTRY = 8
SIZE_DATA_ENTRY = 16


class Node:
    def __init__(self, data_index=None):
        self.children = []
        self.data_index = data_index


def read_u16(d, o): return struct.unpack_from('<H', d, o)[0]
def read_u32(d, o): return struct.unpack_from('<I', d, o)[0]
def write_u16(d, o, v): struct.pack_into('<H', d, o, v)
def write_u32(d, o, v): struct.pack_into('<I', d, o, v)


def read_ico(path):
    data = open(path, 'rb').read()
    if len(data) < 6 or data[:4] != b"\x00\x00\x01\x00":
        raise SystemExit(f"{path}: not a valid .ico")
    count = struct.unpack_from('<H', data, 4)[0]
    if count == 0 or len(data) < 6 + 16 * count:
        raise SystemExit(f"{path}: invalid icon directory")
    entries = []
    for i in range(count):
        off = 6 + 16 * i
        width, height, colors, reserved = data[off], data[off+1], data[off+2], data[off+3]
        planes, bitcount = struct.unpack_from('<HH', data, off + 4)
        bytes_in_res, image_off = struct.unpack_from('<II', data, off + 8)
        image = data[image_off:image_off + bytes_in_res]
        if len(image) != bytes_in_res:
            raise SystemExit(f"{path}: truncated icon image {i}")
        entries.append((width, height, colors, reserved, planes, bitcount, image))
    return entries


def build_tree_and_data(entries):
    k = len(entries)
    root = Node()
    type3 = Node()
    type14 = Node()
    root.children.append((RT_ICON, type3))
    root.children.append((RT_GROUP_ICON, type14))
    for i in range(k):
        nd = Node()
        type3.children.append((i + 1, nd))
        nd.children.append((LANG, Node(data_index=i)))
    group_nd = Node()
    type14.children.append((1, group_nd))
    group_nd.children.append((LANG, Node(data_index=k)))

    data = [e[6] for e in entries]
    group = struct.pack('<HHH', 0, 1, k)
    for i, e in enumerate(entries):
        w, h, c, r, planes, bitcount, _ = e
        group += struct.pack('<BBBBHHIH', w, h, c, r, planes, bitcount,
                             len(entries[i][6]), i + 1)
    data.append(group)
    return root, data


def build_rsrc_section(root, data, section_rva):
    """BFS tree identical to llvm-cvtres; data-entry RVAs are absolute."""
    q = deque([root])
    next_level_offset = SIZE_DIR_TABLE + len(root.children) * SIZE_DIR_ENTRY
    data_nodes = []
    out = bytearray()
    current_relative = 0

    while q:
        node = q.popleft()
        out += struct.pack('<IIHHHH', 0, 0, 0, 0, 0, len(node.children))
        current_relative += SIZE_DIR_TABLE
        for child_id, child in node.children:
            if child.data_index is None:
                out += struct.pack('<II', child_id, (1 << 31) | next_level_offset)
                next_level_offset += SIZE_DIR_TABLE + len(child.children) * SIZE_DIR_ENTRY
                q.append(child)
            else:
                out += struct.pack('<II', child_id, next_level_offset)
                next_level_offset += SIZE_DATA_ENTRY
                data_nodes.append(child)
            current_relative += SIZE_DIR_ENTRY

    data_offsets = []
    cur = 0
    for d in data:
        data_offsets.append(cur)
        cur += len(d)
    # data entries come after the directory tree
    data_start = current_relative
    for node in data_nodes:
        idx = node.data_index
        out += struct.pack('<IIII', section_rva + data_start + data_offsets[idx],
                           len(data[idx]), 0, 0)
        current_relative += SIZE_DATA_ENTRY
    # append the raw data blocks
    for d in data:
        out += d
    return bytes(out)


def align_up(v, a): return (v + a - 1) // a * a


def patch_icon(ico_path, exe_path, out_path=None):
    entries = read_ico(ico_path)
    root, data = build_tree_and_data(entries)

    orig = bytearray(open(exe_path, 'rb').read())
    if orig[:2] != b'MZ':
        raise SystemExit(f'{exe_path}: not a PE executable')
    pe = read_u32(orig, 0x3C)
    if orig[pe:pe+4] != b'PE\0\0':
        raise SystemExit(f'{exe_path}: invalid PE signature')
    coff = pe + 4
    n_sections = read_u16(orig, coff + 2)
    opt_size = read_u16(orig, coff + 16)
    opt = coff + 20
    magic = read_u16(orig, opt)
    if magic == 0x20B:
        sec_align = read_u32(orig, opt + 32)
        file_align = read_u32(orig, opt + 36)
        size_of_image_off = opt + 56
        dir_base = opt + 112
    elif magic == 0x10B:
        sec_align = read_u32(orig, opt + 32)
        file_align = read_u32(orig, opt + 36)
        size_of_image_off = opt + 56
        dir_base = opt + 96
    else:
        raise SystemExit(f'{exe_path}: unsupported PE optional header')
    sec_table = opt + opt_size
    sections = []
    for i in range(n_sections):
        o = sec_table + i * 40
        name = orig[o:o+8].rstrip(b'\x00').decode('ascii', 'replace')
        vsz = read_u32(orig, o + 8)
        va = read_u32(orig, o + 12)
        rawsz = read_u32(orig, o + 16)
        praw = read_u32(orig, o + 20)
        sections.append((name, vsz, va, rawsz, praw))
    last = sections[-1]
    last_end = max(last[1], last[3])  # virtual vs raw size
    new_rva = align_up(last[2] + last_end, sec_align)
    rsrc = build_rsrc_section(root, data, new_rva)
    new_praw = align_up(len(orig), file_align)
    new_size = len(rsrc)

    # grow the file
    orig += b'\x00' * (new_praw - len(orig)) + rsrc

    # update section table
    write_u16(orig, coff + 2, n_sections + 1)
    new_sec_off = sec_table + n_sections * 40
    name = b'.rsrc\0\0\0'
    orig[new_sec_off:new_sec_off+8] = name
    write_u32(orig, new_sec_off + 8, new_size)      # VirtualSize
    write_u32(orig, new_sec_off + 12, new_rva)      # VirtualAddress
    write_u32(orig, new_sec_off + 16, new_size)      # SizeOfRawData
    write_u32(orig, new_sec_off + 20, new_praw)      # PointerToRawData
    for off in (24, 28):
        write_u32(orig, new_sec_off + off, 0)
    write_u16(orig, new_sec_off + 32, 0)
    write_u16(orig, new_sec_off + 34, 0)
    write_u32(orig, new_sec_off + 36, 0x40000040)  # INITIALIZED_DATA | READ

    # update SizeOfImage
    write_u32(orig, size_of_image_off, align_up(new_rva + new_size, sec_align))
    # update resource data directory (index 2)
    res_dir = dir_base + 2 * 8
    write_u32(orig, res_dir, new_rva)
    write_u32(orig, res_dir + 4, new_size)

    dest = out_path or exe_path
    with open(dest, 'wb') as f:
        f.write(orig)
    print(f'patched {dest}: .rsrc RVA 0x{new_rva:x} size {new_size} '
          f'({len(entries)} icon image(s))')


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit('usage: patch-pe-icon.py icon.ico exe [exe_out]')
    patch_icon(sys.argv[1], sys.argv[2],
               sys.argv[3] if len(sys.argv) == 4 else None)


if __name__ == '__main__':
    main()
