#!/usr/bin/env python3
"""Regenerate assets/aurora-opencode-pro.ico from code.

The icon is a rounded purple tile (the app's accent `#8b7cf6`) carrying the
terminal prompt glyph the app already uses in its titlebar (`IconKind.terminal`),
so the executable, the taskbar and the window agree on one mark.

Run: python tools/make-app-icon.py
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw

# App theme tokens (see auroraopencode.core.opencode*).
ACCENT_TOP = (154, 140, 255)      # #9a8cff, accent lightened
ACCENT_BOTTOM = (108, 92, 231)    # #6c5ce7, accent deepened
GLYPH = (245, 244, 255)           # #f5f4ff, near-white on the accent

# Rendered once at a large size and downsampled; small frames stay crisp.
BASE = 1024
# Sizes Explorer, the taskbar and alt-tab ask for.
SIZES = [256, 128, 64, 48, 32, 24, 16]


def rounded_mask(size: int, radius_ratio: float) -> Image.Image:
    """Anti-aliased rounded-square alpha mask drawn at 4x and reduced."""
    scale = 4
    big = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(big)
    draw.rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1),
        radius=int(size * scale * radius_ratio),
        fill=255,
    )
    return big.resize((size, size), Image.LANCZOS)


def gradient(size: int) -> Image.Image:
    top, bottom = ACCENT_TOP, ACCENT_BOTTOM
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    for y in range(size):
        t = y / (size - 1)
        row = tuple(round(top[c] + (bottom[c] - top[c]) * t) for c in range(3))
        for x in range(size):
            pixels[x, y] = (row[0], row[1], row[2], 255)
    return image


def draw_glyph(image: Image.Image, size: float) -> None:
    """A thick `>` chevron and `_` underscore, round-capped for small frames."""
    draw = ImageDraw.Draw(image)
    width = round(size * 0.11)
    half = width / 2

    def dot(center: tuple[float, float]) -> None:
        x, y = center
        draw.ellipse((x - half, y - half, x + half, y + half), fill=GLYPH)

    chevron = [(0.30 * size, 0.31 * size),
               (0.55 * size, 0.50 * size),
               (0.30 * size, 0.69 * size)]
    draw.line(chevron, fill=GLYPH, width=width, joint="curve")
    for point in (chevron[0], chevron[-1]):
        dot(point)

    underscore_start, underscore_end = 0.60 * size, 0.78 * size
    underscore_y = 0.69 * size
    draw.line((underscore_start, underscore_y, underscore_end, underscore_y),
              fill=GLYPH, width=width)
    for x in (underscore_start, underscore_end):
        dot((x, underscore_y))


def main() -> int:
    package_root = Path(__file__).resolve().parent.parent
    target = package_root / "assets" / "aurora-opencode-pro.ico"
    target.parent.mkdir(parents=True, exist_ok=True)

    image = gradient(BASE).convert("RGBA")
    image.putalpha(rounded_mask(BASE, 0.22))
    draw_glyph(image, BASE)

    image.save(target, format="ICO", sizes=[(s, s) for s in SIZES])
    print(f"wrote {target} ({target.stat().st_size} bytes, sizes {SIZES})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
