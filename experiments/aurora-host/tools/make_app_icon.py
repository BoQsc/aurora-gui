#!/usr/bin/env python3
"""Generate the Aurora Host multi-resolution Windows application icon.

This is intentionally stdlib-only so the icon remains reproducible without an
image library. Frames are PNG-compressed ICO entries, which Windows 10/11
supports for window, taskbar, Alt-Tab, and Explorer icons.
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path
import struct
import zlib

SIZES = (16, 24, 32, 48, 64, 128, 256)


def mix(a: tuple[float, float, float], b: tuple[float, float, float],
        t: float) -> tuple[float, float, float]:
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def rounded_rect_distance(x: float, y: float, half: float,
                          radius: float) -> float:
    qx = abs(x - 0.5) - (half - radius)
    qy = abs(y - 0.5) - (half - radius)
    outside = math.hypot(max(qx, 0.0), max(qy, 0.0))
    inside = min(max(qx, qy), 0.0)
    return outside + inside - radius


def segment_distance(x: float, y: float, ax: float, ay: float,
                     bx: float, by: float) -> float:
    dx = bx - ax
    dy = by - ay
    length2 = dx * dx + dy * dy
    t = ((x - ax) * dx + (y - ay) * dy) / length2
    t = max(0.0, min(1.0, t))
    return math.hypot(x - (ax + t * dx), y - (ay + t * dy))


def sample(x: float, y: float) -> tuple[float, float, float, float]:
    base = rounded_rect_distance(x, y, 0.44, 0.13)
    if base > 0.0:
        return 0.0, 0.0, 0.0, 0.0

    color = mix((11.0, 18.0, 32.0), (30.0, 41.0, 59.0), y)
    if abs(base) < 0.022:
        color = mix(color, (34.0, 211.0, 238.0), 0.95)

    left = segment_distance(x, y, 0.29, 0.79, 0.50, 0.23)
    right = segment_distance(x, y, 0.71, 0.79, 0.50, 0.23)
    crossbar = segment_distance(x, y, 0.385, 0.585, 0.615, 0.585)
    letter = min(left, right) - 0.105
    bar = crossbar - 0.075
    glyph = min(letter, bar)

    if glyph <= 0.0:
        color = mix((45.0, 212.0, 191.0), (167.0, 243.0, 208.0),
                    (y - 0.23) / 0.56)
    elif glyph < 0.035:
        glow = 1.0 - glyph / 0.035
        color = mix(color, (34.0, 211.0, 238.0), 0.28 * glow)

    return color[0], color[1], color[2], 255.0


def render(size: int, samples: int) -> bytes:
    pixels = bytearray()
    step = 1.0 / (size * samples)
    for py in range(size):
        pixels.append(0)
        for px in range(size):
            red = green = blue = alpha = 0.0
            for sy in range(samples):
                y = (py + (sy + 0.5) / samples) / size
                for sx in range(samples):
                    x = (px + (sx + 0.5) / samples) / size
                    r, g, b, a = sample(x, y)
                    red += r * a
                    green += g * a
                    blue += b * a
                    alpha += a
            count = samples * samples
            if alpha > 0.0:
                pixels += bytes((
                    round(red / alpha),
                    round(green / alpha),
                    round(blue / alpha),
                    round(alpha / count),
                ))
            else:
                pixels += b"\x00\x00\x00\x00"
    return bytes(pixels)


def chunk(kind: bytes, data: bytes) -> bytes:
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(
        ">I", zlib.crc32(body) & 0xFFFFFFFF)


def png(size: int, samples: int) -> bytes:
    raw = render(size, samples)
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw, 9)) +
            chunk(b"IEND", b""))


def build_ico() -> bytes:
    frames = []
    for size in SIZES:
        samples = 8 if size <= 48 else 4
        frames.append((size, png(size, samples)))
    header = struct.pack("<HHH", 0, 1, len(frames))
    offset = 6 + 16 * len(frames)
    directory = bytearray()
    payload = bytearray()
    for size, data in frames:
        directory += struct.pack(
            "<BBBBHHII",
            0 if size == 256 else size,
            0 if size == 256 else size,
            0,
            0,
            1,
            32,
            len(data),
            offset,
        )
        payload += data
        offset += len(data)
    return header + directory + payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_bytes(build_ico())
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes, "
          f"{len(SIZES)} sizes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
