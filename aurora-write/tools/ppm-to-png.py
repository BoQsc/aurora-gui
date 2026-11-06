#!/usr/bin/env python3
"""Convert an Aurora screenshot (binary PPM, P6) to PNG using only stdlib.

Aurora's GuiWindow.saveScreenshot writes Netpbm P6 because the software
renderer already has straight RGB pixels. Reviewers and image tools want PNG,
so this keeps the capture path untouched and converts for inspection.

Usage: python tools/ppm-to-png.py <input.ppm> <output.png>
"""
import struct
import sys
import zlib


def read_ppm(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if not data.startswith(b"P6"):
        raise SystemExit(f"{path}: not a binary PPM (P6) file")
    fields, offset = [], 2
    while len(fields) < 3:
        while offset < len(data) and data[offset : offset + 1].isspace():
            offset += 1
        if data[offset : offset + 1] == b"#":
            while offset < len(data) and data[offset : offset + 1] != b"\n":
                offset += 1
            continue
        start = offset
        while offset < len(data) and not data[offset : offset + 1].isspace():
            offset += 1
        fields.append(int(data[start:offset]))
    offset += 1
    width, height, max_value = fields
    if max_value != 255:
        raise SystemExit(f"{path}: only 8-bit PPM is supported")
    pixels = data[offset : offset + width * height * 3]
    if len(pixels) != width * height * 3:
        raise SystemExit(f"{path}: truncated pixel data")
    return width, height, pixels


def write_png(path, width, height, pixels):
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)  # filter: none
        raw += pixels[y * stride : (y + 1) * stride]

    def chunk(kind, body):
        return (
            struct.pack(">I", len(body))
            + kind
            + body
            + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    width, height, pixels = read_ppm(sys.argv[1])
    write_png(sys.argv[2], width, height, pixels)
    print(f"{sys.argv[2]}: {width}x{height}")


if __name__ == "__main__":
    main()
