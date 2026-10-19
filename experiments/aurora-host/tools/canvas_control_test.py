#!/usr/bin/env python3
"""Drive a live canvas through the host control channel."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_HOST = Path(os.environ.get(
    "AURORA_HOST_EXE",
    str(ROOT / "aurora-host-experiment.exe"),
))
DEFAULT_SCENE = ROOT / "samples" / "canvas.scene.json"


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=DEFAULT_HOST)
    parser.add_argument("--scene", type=Path, default=DEFAULT_SCENE)
    parser.add_argument("--out", type=Path, default=ROOT / "build" / "canvas-live.ppm")
    parser.add_argument("--png", type=Path, default=ROOT / "build" / "canvas-live.png")
    args = parser.parse_args()

    if not args.host.is_file():
        raise RuntimeError(f"build the host first: {args.host}")

    import control_client
    control_client.EXE = args.host

    session = control_client.HostSession(str(args.scene))
    try:
        session.wait_ready()
        tree = session.send("tree")
        canvas = next(
            (node for node in tree.get("nodes", []) if node.get("id") == "canvas"),
            None,
        )
        if not canvas or canvas.get("type") != "canvas":
            raise RuntimeError("canvas node is missing from the scene tree")

        commands = [
            {
                "op": "rect",
                "x": 20,
                "y": 20,
                "width": 100,
                "height": 60,
                "color": "#00ff00",
            },
            {
                "op": "circle",
                "x": 200,
                "y": 160,
                "radius": 30,
                "color": "#ff00ff",
            },
            {
                "op": "text",
                "x": 20,
                "y": 120,
                "text": "Live",
                "color": "#ffffff",
                "scale": 2,
            },
        ]
        response = session.send("setCanvas", node="canvas", commands=commands)
        if not response.get("ok") or response.get("commands") != len(commands):
            raise RuntimeError(f"setCanvas failed: {json.dumps(response)}")

        session.send("screenshot", path=str(args.out))
    finally:
        exit_code = session.close()

    if exit_code != 0:
        raise RuntimeError(f"host exited with {exit_code}")
    width, height, pixels = read_ppm(args.out)
    if width < 320 or height < 240:
        raise RuntimeError(f"unexpected canvas size: {width}x{height}")
    scale_x = width / 320
    scale_y = height / 240

    def sample(x: float, y: float) -> tuple[int, int, int]:
        return pixel(pixels, width, int(x * scale_x), int(y * scale_y))

    if not close_to(sample(50, 40), (0, 255, 0)):
        raise RuntimeError("setCanvas did not replace the rectangle")
    if not close_to(sample(200, 160), (255, 0, 255)):
        raise RuntimeError("setCanvas did not add the circle")

    try:
        from PIL import Image
    except ImportError:
        print("Pillow is unavailable; leaving the PPM screenshot")
    else:
        args.png.parent.mkdir(parents=True, exist_ok=True)
        Image.open(args.out).save(args.png)
        print(f"png: {args.png}")

    print("canvas control passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"canvas control test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
