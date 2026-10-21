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


def _unfilter(raw: bytes, width: int, height: int, channels: int) -> bytes:
    stride = width * channels
    require(
        len(raw) == height * (stride + 1),
        "PNG image data does not match its dimensions",
    )
    output = bytearray(height * stride)
    previous = bytearray(stride)
    position = 0
    for y in range(height):
        filter_type = raw[position]
        position += 1
        row = bytearray(raw[position : position + stride])
        position += stride
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            above = previous[x]
            upper_left = previous[x - channels] if x >= channels else 0
            if filter_type == 0:
                continue
            if filter_type == 1:
                row[x] = (row[x] + left) & 0xFF
            elif filter_type == 2:
                row[x] = (row[x] + above) & 0xFF
            elif filter_type == 3:
                row[x] = (row[x] + (left + above) // 2) & 0xFF
            elif filter_type == 4:
                estimate = left + above - upper_left
                distance_left = abs(estimate - left)
                distance_above = abs(estimate - above)
                distance_upper_left = abs(estimate - upper_left)
                if distance_left <= distance_above and distance_left <= distance_upper_left:
                    predictor = left
                elif distance_above <= distance_upper_left:
                    predictor = above
                else:
                    predictor = upper_left
                row[x] = (row[x] + predictor) & 0xFF
            else:
                raise RuntimeError(f"unsupported PNG filter {filter_type}")
        start = y * stride
        output[start : start + stride] = row
        previous = row
    return bytes(output)


def read_png(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    require(data.startswith(PNG_SIGNATURE), f"{path} is not a PNG")
    position = 8
    width = height = bit_depth = color_type = interlace = None
    compressed = bytearray()
    while position + 12 <= len(data):
        length = struct.unpack(">I", data[position : position + 4])[0]
        kind = data[position + 4 : position + 8]
        payload = data[position + 8 : position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            require(length == 13, f"{path} has an invalid IHDR")
            width, height, bit_depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break
    require(
        width is not None and height is not None,
        f"{path} has no IHDR chunk",
    )
    require(bit_depth == 8, f"{path} is not an 8-bit PNG")
    require(interlace == 0, f"{path} uses unsupported interlacing")
    channels = {0: 1, 2: 3, 6: 4}.get(color_type)
    require(channels is not None, f"{path} uses an unsupported PNG color type")
    raw = _unfilter(
        zlib.decompress(bytes(compressed)),
        width,
        height,
        channels,
    )
    if channels == 3:
        return width, height, raw
    if channels == 4:
        rgb = bytearray(width * height * 3)
        for index in range(width * height):
            source = index * 4
            rgb[index * 3 : index * 3 + 3] = raw[source : source + 3]
        return width, height, bytes(rgb)
    rgb = bytearray(width * height * 3)
    for index, value in enumerate(raw):
        rgb[index * 3 : index * 3 + 3] = bytes((value, value, value))
    return width, height, bytes(rgb)


def read_image(path: Path) -> tuple[int, int, bytes]:
    suffix = path.suffix.lower()
    if suffix == ".png":
        return read_png(path)
    if suffix in (".ppm", ".pnm"):
        return read_ppm(path)
    raise RuntimeError(f"unsupported image format: {path}")


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