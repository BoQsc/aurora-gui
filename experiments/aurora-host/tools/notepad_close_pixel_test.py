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
                  foreground: tuple[int, int, int], label: str,
                  foreground_tolerance: int,
                  center_luma_limit: int | None = None) -> None:
    left, top = glyph
    core = 0
    for y in range(top, top + 10):
        for x in range(left, left + 10):
            color = sample(pixels, width, x, y)
            if near(color, foreground, foreground_tolerance):
                core += 1
    require(core >= 20,
            f"{label} is too thin: only {core} solid pixels")

    center_x, center_y = left + 4, top + 4
    center_core = 0
    center_maximum_luma = 0
    for y in range(center_y - 1, center_y + 2):
        for x in range(center_x - 1, center_x + 2):
            color = sample(pixels, width, x, y)
            center_maximum_luma = max(center_maximum_luma,
                                      sum(color) // 3)
            if near(color, foreground, foreground_tolerance):
                center_core += 1
    require(center_core == 9,
            f"{label} center is not solid: {center_core}/9 pixels")
    if center_luma_limit is not None:
        require(center_maximum_luma <= center_luma_limit,
                f"{label} center is too soft: luma {center_maximum_luma}")


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
        require(near(sample(pixels, width, 856, 4), BACKGROUND, 20),
                "normal close button chrome is not neutral")
        inspect_glyph(pixels, width, height, glyph, BACKGROUND, TEXT,
                      "normal close glyph", 70, center_luma_limit=95)

        require(session.send("uiMove", x=left + 5, y=top + 5).get("ok") is True,
                "close button hover move failed")
        hover_path = out / "notepad-close-hover.ppm"
        require(session.send("screenshot", path=str(hover_path)).get("ok") is True,
                "hover screenshot failed")
        width, height, pixels = read_ppm(hover_path)
        require(near(sample(pixels, width, left, top), WHITE, 20),
                "hover close glyph is not white at its endpoint")
        require(near(sample(pixels, width, 856, 4), CLOSE_RED, 20),
                "hover close button chrome is not red")
        inspect_glyph(pixels, width, height, glyph, CLOSE_RED, WHITE,
                      "hover close glyph", 75)
    finally:
        session.close()

    print("notepad close pixel test passed: normal and hover glyphs are solid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())