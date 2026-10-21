"""Prove the logical/native DPI surface contract without a display server.

The scene asks for a 320x240 logical surface.  The producer publishes a
640x480 native checkerboard.  A host that treats header width/height as native
pixels scales the checker into the logical bounds; a host that requires them to
equal the logical size rejects the mapping and renders no checker colors.
"""
from __future__ import annotations

import argparse
import json
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = 80
EVENT = 24
CAPACITY = 64
BUFFERS = 2
MAGIC = b"AURSFACE"
VERSION = 2
WIDTH = 320
HEIGHT = 240
NATIVE_WIDTH = WIDTH * 2
NATIVE_HEIGHT = HEIGHT * 2
COLORS = (
    (16, 24, 32, 255),
    (0, 200, 120, 255),
    (230, 57, 70, 255),
    (241, 250, 238, 255),
)


def checker() -> bytes:
    pixels = bytearray(NATIVE_WIDTH * NATIVE_HEIGHT * 4)
    for y in range(NATIVE_HEIGHT):
        for x in range(NATIVE_WIDTH):
            color = COLORS[
                (1 if x >= NATIVE_WIDTH // 2 else 0)
                + (2 if y >= NATIVE_HEIGHT // 2 else 0)
            ]
            offset = (y * NATIVE_WIDTH + x) * 4
            pixels[offset : offset + 4] = bytes(color)
    return bytes(pixels)


def write_surface(path: Path) -> None:
    frame_bytes = NATIVE_WIDTH * NATIVE_HEIGHT * 4
    size = HEADER + CAPACITY * EVENT + BUFFERS * frame_bytes
    data = bytearray(size)
    struct.pack_into(
        "<8sIIIIII",
        data,
        0,
        MAGIC,
        VERSION,
        HEADER,
        NATIVE_WIDTH,
        NATIVE_HEIGHT,
        0,
        CAPACITY,
    )
    struct.pack_into("<Q", data, 32, 1)
    struct.pack_into("<Q", data, 40, 0)
    struct.pack_into("<IIIII", data, 48, 0, 0, EVENT, BUFFERS, frame_bytes)
    frame_start = HEADER + CAPACITY * EVENT
    data[frame_start : frame_start + frame_bytes] = checker()
    path.write_bytes(data)


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    header, pixels = data.split(b"\n255\n", 1)
    parts = header.split()
    width, height = int(parts[-2]), int(parts[-1])
    if len(pixels) != width * height * 3:
        raise RuntimeError(
            f"bad PPM payload: {len(pixels)} != {width * height * 3}"
        )
    return width, height, pixels


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=ROOT / "aurora-host-experiment.exe")
    args = parser.parse_args()
    if not args.host.is_file():
        raise SystemExit(f"missing host executable: {args.host}")
    with tempfile.TemporaryDirectory(prefix="aurora-surface-dpi-") as name:
        temp = Path(name)
        surface = temp / "native.surface"
        scene = temp / "scene.json"
        output = temp / "render.ppm"
        write_surface(surface)
        scene.write_text(
            json.dumps(
                {
                    "schemaVersion": 2,
                    "window": {"title": "DPI contract", "width": WIDTH, "height": HEIGHT},
                    "root": {
                        "id": "native",
                        "type": "surface",
                        "path": str(surface),
                        "width": WIDTH,
                        "height": HEIGHT,
                    },
                }
            ),
            encoding="utf-8",
        )
        completed = subprocess.run(
            [str(args.host), "--render", str(scene), "--out", str(output)],
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        if completed.returncode != 0:
            raise RuntimeError(
                "headless render failed\n" + completed.stdout + completed.stderr
            )
        width, height, pixels = read_ppm(output)
        scale = width / WIDTH
        if scale < 1.0 or height != int(HEIGHT * scale + 0.5):
            raise RuntimeError(f"unexpected render size: {width}x{height}")
        counts = {color[:3]: 0 for color in COLORS}
        for offset in range(0, len(pixels), 3):
            color = tuple(pixels[offset : offset + 3])
            if color in counts:
                counts[color] += 1
        missing = {str(color): count for color, count in counts.items() if count == 0}
        if missing:
            raise RuntimeError(f"native surface was not visible: {missing!r}")
        quadrants = {
            (width // 4, height // 4): COLORS[0][:3],
            (width * 3 // 4, height // 4): COLORS[1][:3],
            (width // 4, height * 3 // 4): COLORS[2][:3],
            (width * 3 // 4, height * 3 // 4): COLORS[3][:3],
        }
        for (x, y), expected in quadrants.items():
            offset = (y * width + x) * 3
            actual = tuple(pixels[offset : offset + 3])
            if actual != expected:
                raise RuntimeError(
                    f"native quadrant at {x},{y} is {actual}, expected {expected}"
                )
        print(
            json.dumps(
                {
                    "logical": [WIDTH, HEIGHT],
                    "displayScale": scale,
                    "native": [NATIVE_WIDTH, NATIVE_HEIGHT],
                    "colors": {str(color): count for color, count in counts.items()},
                }
            )
        )
        print("surface dpi test passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
