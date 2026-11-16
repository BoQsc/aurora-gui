#!/usr/bin/env python3
"""Verify the owner-drawn Notepad close button at the session display scale."""
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

SCENE_WIDTH = 900
SCENE_HEIGHT = 620
TITLE_HEIGHT = 32
CAPTION_WIDTH = 46
GLYPH_SIZE = 10
GLYPH_LOGICAL_LEFT = SCENE_WIDTH - CAPTION_WIDTH + (CAPTION_WIDTH - GLYPH_SIZE) // 2
GLYPH_LOGICAL_TOP = (TITLE_HEIGHT - GLYPH_SIZE) // 2


def physical(value: int, scale: float) -> int:
    """Round a logical coordinate to the physical pixel the host paints."""
    return int(value * scale + 0.5)


def sample(pixels: bytes, width: int, x: int, y: int) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return tuple(pixels[offset : offset + 3])  # type: ignore[return-value]


def near(actual: tuple[int, int, int], expected: tuple[int, int, int],
         tolerance: int) -> bool:
    return all(abs(a - b) <= tolerance for a, b in zip(actual, expected))


def close_box(width: int, height: int, scale: float) -> tuple[int, int]:
    require(width == physical(SCENE_WIDTH, scale) and
            height == physical(SCENE_HEIGHT, scale),
            f"unexpected Notepad screenshot size: {width}x{height}")
    # captionRect(close) is (854, 0, 46, 32) in the 900 px scene. The glyph
    # image is ten logical pixels square, centered in that rectangle.
    return (
        physical(GLYPH_LOGICAL_LEFT, scale),
        physical(GLYPH_LOGICAL_TOP, scale),
    )


def ink_bounds(pixels: bytes, width: int, height: int,
               expected_left: int, expected_top: int, scale: float,
               background: tuple[int, int, int]) -> tuple[int, int, int, int]:
    """Find the painted glyph inside its logical box.

    Fractional scaling can produce one fewer physical row than column, so the
    inspected rectangle comes from the pixels the host actually painted.
    """
    search_left = max(0, expected_left - 3)
    search_top = max(0, expected_top - 3)
    search_right = min(width - 1,
                       physical(GLYPH_LOGICAL_LEFT + GLYPH_SIZE, scale) + 3)
    search_bottom = min(height - 1,
                        physical(GLYPH_LOGICAL_TOP + GLYPH_SIZE, scale) + 3)
    left, top, right, bottom = width, height, -1, -1
    for y in range(search_top, search_bottom + 1):
        for x in range(search_left, search_right + 1):
            if not near(sample(pixels, width, x, y), background, 20):
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
    require(right >= left and bottom >= top,
            "close glyph has no painted pixels")

    painted_width = right - left + 1
    painted_height = bottom - top + 1
    expected_size = physical(GLYPH_SIZE, scale)
    require(abs(painted_width - expected_size) <= 1 and
            abs(painted_height - expected_size) <= 1,
            f"close glyph is {painted_width}x{painted_height}, "
            f"expected about {expected_size}x{expected_size}")
    require(abs(left - expected_left) <= 2 and abs(top - expected_top) <= 2,
            f"close glyph starts at {left},{top}, expected "
            f"{expected_left},{expected_top}")
    return left, top, painted_width, painted_height


def inspect_glyph(pixels: bytes, width: int, height: int,
                  glyph: tuple[int, int, int, int],
                  background: tuple[int, int, int],
                  foreground: tuple[int, int, int], label: str,
                  foreground_tolerance: int,
                  center_luma_limit: int | None = None) -> None:
    left, top, glyph_width, glyph_height = glyph
    core = 0
    for y in range(top, top + glyph_height):
        for x in range(left, left + glyph_width):
            color = sample(pixels, width, x, y)
            if near(color, foreground, foreground_tolerance):
                core += 1
    require(core >= 20,
            f"{label} is too thin: only {core} solid pixels")

    # Both diagonals must reach their four corners at every scale.
    last_x = glyph_width - 1
    last_y = glyph_height - 1
    exact = (glyph_width, glyph_height) == (GLYPH_SIZE, GLYPH_SIZE)
    for name, (x, y, dx, dy) in (
        ("top-left", (left, top, 1, 1)),
        ("top-right", (left + last_x, top, -1, 1)),
        ("bottom-left", (left, top + last_y, 1, -1)),
        ("bottom-right", (left + last_x, top + last_y, -1, -1)),
    ):
        if exact:
            solid = near(sample(pixels, width, x, y), foreground,
                         foreground_tolerance)
        else:
            # A fractional-scale tip can land between pixels, so accept a
            # solid pixel anywhere in the two-pixel corner block.
            solid = any(
                near(sample(pixels, width, x + ix, y + iy), foreground,
                     foreground_tolerance)
                for ix in (0, dx)
                for iy in (0, dy)
            )
        require(solid, f"{label} {name} tip is not solid")

    center_x, center_y = left + last_x // 2, top + last_y // 2
    center_core = 0
    center_maximum_luma = 0
    for y in range(center_y - 1, center_y + 2):
        for x in range(center_x - 1, center_x + 2):
            color = sample(pixels, width, x, y)
            center_maximum_luma = max(center_maximum_luma,
                                      sum(color) // 3)
            if near(color, foreground, foreground_tolerance):
                center_core += 1
    if exact:
        require(center_core == 9,
                f"{label} center is not solid: {center_core}/9 pixels")
        if center_luma_limit is not None:
            require(center_maximum_luma <= center_luma_limit,
                    f"{label} center is too soft: luma {center_maximum_luma}")
    else:
        # Fractional scaling narrows the crossing by part of a pixel, so the
        # 1x 3x3 invariant becomes a solid center with connected arms.
        require(center_core >= 4,
                f"{label} center is not solid: {center_core}/9 pixels")
        if center_luma_limit is not None:
            center_luma = sum(sample(pixels, width, center_x, center_y)) // 3
            require(center_luma <= center_luma_limit,
                    f"{label} center is too soft: luma {center_luma}")


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
        require(scale > 0,
                f"invalid display scale: {scale}")
        require(abs(scale - float(window["displayScaleX"])) < 1e-9,
                f"framebuffer and display scale disagree: {scale} vs "
                f"{window['displayScaleX']}")

        normal_path = out / "notepad-close-normal.ppm"
        require(session.send("screenshot", path=str(normal_path)).get("ok") is True,
                "normal screenshot failed")
        width, height, pixels = read_ppm(normal_path)
        expected_left, expected_top = close_box(width, height, scale)
        glyph = ink_bounds(pixels, width, height, expected_left, expected_top,
                           scale, BACKGROUND)
        left, top, _, _ = glyph
        require(near(sample(pixels, width, left, top), TEXT, 20),
                "normal close glyph is not solid at its endpoint")
        chrome = (physical(856, scale), physical(4, scale))
        require(near(sample(pixels, width, chrome[0], chrome[1]), BACKGROUND, 20),
                "normal close button chrome is not neutral")
        inspect_glyph(pixels, width, height, glyph, BACKGROUND, TEXT,
                      "normal close glyph", 70, center_luma_limit=95)

        require(session.send("uiMove", x=GLYPH_LOGICAL_LEFT + 5,
                             y=GLYPH_LOGICAL_TOP + 5).get("ok") is True,
                "close button hover move failed")
        hover_path = out / "notepad-close-hover.ppm"
        require(session.send("screenshot", path=str(hover_path)).get("ok") is True,
                "hover screenshot failed")
        width, height, pixels = read_ppm(hover_path)
        require(near(sample(pixels, width, left, top), WHITE, 20),
                "hover close glyph is not white at its endpoint")
        require(near(sample(pixels, width, chrome[0], chrome[1]), CLOSE_RED, 20),
                "hover close button chrome is not red")
        inspect_glyph(pixels, width, height, glyph, CLOSE_RED, WHITE,
                      "hover close glyph", 75)
    finally:
        session.close()

    print(f"notepad close pixel test passed at {scale:g}x display scale: "
          "normal and hover glyphs are solid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())