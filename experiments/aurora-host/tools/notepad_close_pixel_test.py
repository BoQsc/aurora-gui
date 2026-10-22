#!/usr/bin/env python3
"""Verify the owner-drawn Notepad close button at 100% display scale."""
from __future__ import annotations

import argparse
from pathlib import Path

import control_client
from control_client import HostSession
from image_io import read_ppm, require

ROOT = Path(__file__).resolve().parents[1]

BACKGROUND = (0xF3, 0xF3, 0xF3)
TEXT = (0x1A, 0x1A, 0x1A)
CLOSE_RED = (0xE8, 0x11, 0x23)
WHITE = (255, 255, 255)


def sample(pixels: bytes, width: int, x: int, y: int) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return tuple(pixels[offset : offset + 3])  # type: ignore[return-value]


def near(actual: tuple[int, int, int], expected: tuple[int, int, int],
         tolerance: int) -> bool:
    return all(abs(a - b) <= tolerance for a, b in zip(actual, expected))


def close_box(pixels: bytes, width: int, height: int) -> tuple[int, int]:
    require(width == 900 and height == 620,
            f"unexpected Notepad screenshot size: {width}x{height}")
    # captionRect(close) is (854, 0, 46, 32) in the 900 px scene. The glyph
    # image is inset five logical pixels on each side.
    return 872, 11


def inspect_glyph(pixels: bytes, width: int, height: int,
                  glyph: tuple[int, int], background: tuple[int, int, int],
                  foreground: tuple[int, int, int], label: str) -> None:
    left, top = glyph
    core = 0
    unclassified = 0
    for y in range(top, top + 10):
        for x in range(left, left + 10):
            color = sample(pixels, width, x, y)
            if near(color, background, 20):
                continue
            if near(color, foreground, 20):
                core += 1
                continue
            unclassified += 1
    require(unclassified == 0,
            f"{label} has {unclassified} low-contrast halo pixels")
    require(core >= 12,
            f"{label} has only {core} solid glyph pixels")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out-dir", default="build")
    parser.add_argument("--host", type=Path)
    args = parser.parse_args()
    if args.host is not None:
        control_client.EXE = args.host.resolve()

    out = ROOT / args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    session = HostSession("samples/notepad.scene.json")
    try:
        session.wait_ready()
        status = session.send("status")
        require(status.get("ok") is True, f"status failed: {status}")
        window = status["window"]
        scale = float(window["framebufferWidth"]) / float(window["width"])
        require(abs(scale - 1.0) < 1e-9,
                f"close pixel test requires 100% display scale, got {scale}")

        normal_path = out / "notepad-close-normal.ppm"
        require(session.send("screenshot", path=str(normal_path)).get("ok") is True,
                "normal screenshot failed")
        width, height, pixels = read_ppm(normal_path)
        glyph = close_box(pixels, width, height)
        left, top = glyph
        require(near(sample(pixels, width, left, top), TEXT, 20),
                "normal close glyph is not solid at its endpoint")
        require(near(sample(pixels, width, left + 1, top), BACKGROUND, 20),
                "normal close glyph has a halo beside its endpoint")
        inspect_glyph(pixels, width, height, glyph, BACKGROUND, TEXT, "normal close glyph")

        require(session.send("uiMove", x=left + 5, y=top + 5).get("ok") is True,
                "close button hover move failed")
        hover_path = out / "notepad-close-hover.ppm"
        require(session.send("screenshot", path=str(hover_path)).get("ok") is True,
                "hover screenshot failed")
        width, height, pixels = read_ppm(hover_path)
        require(near(sample(pixels, width, left, top), WHITE, 20),
                "hover close glyph is not white at its endpoint")
        require(near(sample(pixels, width, left + 1, top), CLOSE_RED, 20),
                "hover close glyph has a pale halo beside its endpoint")
        inspect_glyph(pixels, width, height, glyph, CLOSE_RED, WHITE, "hover close glyph")
    finally:
        session.close()

    print("notepad close pixel test passed: normal and hover glyphs are crisp")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())