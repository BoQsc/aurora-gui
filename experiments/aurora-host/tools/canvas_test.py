#!/usr/bin/env python3
"""Verify the retained canvas node through the headless software renderer."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HOST = Path(os.environ.get(
    "AURORA_HOST_HEADLESS",
    str(ROOT / "aurora-host-experiment-headless.exe"),
))


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    match = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not match:
        raise RuntimeError(f"not a P6 PPM: {path}")
    width, height, maximum = (int(value) for value in match.groups())
    if maximum != 255:
        raise RuntimeError("canvas screenshot is not 8-bit RGB")
    pixels = data[match.end():]
    if len(pixels) != width * height * 3:
        raise RuntimeError("canvas screenshot has the wrong payload size")
    return width, height, pixels


def pixel(pixels: bytes, width: int, x: int, y: int) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return tuple(pixels[offset:offset + 3])


def close_to(actual: tuple[int, int, int], expected: tuple[int, int, int],
             tolerance: int = 3) -> bool:
    return all(abs(a - b) <= tolerance for a, b in zip(actual, expected))


def color_argb(value: str) -> tuple[int, int, int]:
    return (int(value[1:3], 16), int(value[3:5], 16), int(value[5:7], 16))


def count_near(pixels: bytes, width: int, bounds: tuple[int, int, int, int],
               expected: tuple[int, int, int], tolerance: int = 12) -> int:
    x0, y0, x1, y1 = bounds
    count = 0
    for y in range(y0, y1):
        for x in range(x0, x1):
            if close_to(pixel(pixels, width, x, y), expected, tolerance):
                count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=DEFAULT_HOST)
    parser.add_argument("--scene", type=Path,
                        default=ROOT / "samples" / "canvas.scene.json")
    parser.add_argument("--out", type=Path, default=ROOT / "build" / "canvas.ppm")
    parser.add_argument("--png", type=Path, default=ROOT / "build" / "canvas.png")
    args = parser.parse_args()

    if not args.host.is_file():
        raise RuntimeError(f"build the headless host first: {args.host}")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        [str(args.host), "--render", str(args.scene), "--out", str(args.out)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(completed.stdout + completed.stderr)

    width, height, pixels = read_ppm(args.out)
    if width != 320 or height != 240:
        raise RuntimeError(f"unexpected canvas size: {width}x{height}")

    background = color_argb("#101820")
    checks = {
        (10, 10): ("background", background),
        (50, 40): ("rectangle", color_argb("#e63946")),
        (190, 50): ("rounded rectangle", color_argb("#457b9d")),
        (150, 100): ("line", color_argb("#f1faee")),
        (70, 160): ("circle", color_argb("#f4a261")),
    }
    for point, (label, expected) in checks.items():
        actual = pixel(pixels, width, *point)
        if not close_to(actual, expected):
            raise RuntimeError(
                f"{label} pixel {point} was {actual}, expected {expected}"
            )

    ring_pixels = count_near(
        pixels, width, (110, 130, 171, 191), color_argb("#2a9d8f"))
    if ring_pixels < 40:
        raise RuntimeError(f"ring did not render enough pixels: {ring_pixels}")

    text_pixels = count_near(
        pixels, width, (195, 140, 311, 180), color_argb("#f1faee"))
    if text_pixels < 20:
        raise RuntimeError(f"canvas text did not render enough pixels: {text_pixels}")

    try:
        from PIL import Image
    except ImportError:
        print("Pillow is unavailable; leaving the PPM screenshot")
    else:
        args.png.parent.mkdir(parents=True, exist_ok=True)
        Image.open(args.out).save(args.png)
        print(f"png: {args.png}")

    print("canvas pixel test passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"canvas pixel test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
