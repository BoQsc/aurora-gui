#!/usr/bin/env python3
"""Small PPM/PNG helpers for host screenshot checks."""
from __future__ import annotations

import struct
from pathlib import Path
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    tokens: list[bytes] = []
    position = 0
    while len(tokens) < 4:
        while position < len(data) and data[position : position + 1].isspace():
            position += 1
        if data[position : position + 1] == b"#":
            while position < len(data) and data[position : position + 1] not in (
                b"\n",
                b"\r",
            ):
                position += 1
            continue
        start = position
        while position < len(data) and not data[position : position + 1].isspace():
            position += 1
        tokens.append(data[start:position])
    require(tokens[0] == b"P6", f"{path} is not a binary PPM")
    width, height, maximum = (int(token) for token in tokens[1:])
    require(maximum == 255, f"{path} has unsupported channel depth")
    while position < len(data) and data[position : position + 1].isspace():
        position += 1
    pixels = data[position:]
    require(len(pixels) == width * height * 3, f"{path} has a truncated pixel buffer")
    return width, height, pixels


def png_size(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    require(data.startswith(PNG_SIGNATURE), f"{path} is not a PNG")
    length, kind = struct.unpack(">I4s", data[8:16])
    require(kind == b"IHDR" and length == 13, f"{path} has no valid IHDR chunk")
    width, height = struct.unpack(">II", data[16:24])
    require(width > 0 and height > 0, f"{path} has an empty image")
    return width, height


def write_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    require(width > 0 and height > 0, "PNG dimensions must be positive")
    require(len(pixels) == width * height * 3, "PNG pixel buffer has the wrong size")
    stride = width * 3
    raw = b"".join(
        b"\x00" + pixels[y * stride : (y + 1) * stride]
        for y in range(height)
    )

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    data = (
        PNG_SIGNATURE
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )
    path.write_bytes(data)


def nearest_resize(
    pixels: bytes,
    width: int,
    height: int,
    new_width: int,
    new_height: int,
) -> bytes:
    """Resize with the same half-pixel nearest mapping Pillow uses."""
    require(width > 0 and height > 0, "source dimensions must be positive")
    require(new_width > 0 and new_height > 0, "target dimensions must be positive")
    output = bytearray(new_width * new_height * 3)
    for y in range(new_height):
        source_y = min(height - 1, (2 * y + 1) * height // (2 * new_height))
        source_row = source_y * width * 3
        target_row = y * new_width * 3
        for x in range(new_width):
            source_x = min(width - 1, (2 * x + 1) * width // (2 * new_width))
            source = source_row + source_x * 3
            target = target_row + x * 3
            output[target : target + 3] = pixels[source : source + 3]
    return bytes(output)