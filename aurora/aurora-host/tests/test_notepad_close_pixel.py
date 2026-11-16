"""Fast geometry checks for the notepad close pixel gate."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import notepad_close_pixel_test as gate  # noqa: E402


def painted_glyph(screen_width: int, screen_height: int, left: int, top: int,
                  glyph_width: int, glyph_height: int) -> bytes:
    """Paint a solid X with a filled center into a background screenshot."""
    pixels = bytearray(bytes(gate.BACKGROUND) * screen_width * screen_height)
    center_x = (glyph_width - 1) // 2
    center_y = (glyph_height - 1) // 2
    for y in range(glyph_height):
        for x in range(glyph_width):
            rising = abs(x - y) <= 1
            falling = abs(x - (glyph_width - 1 - y)) <= 1
            center = (abs(x - center_x) <= 1 and abs(y - center_y) <= 1)
            if rising or falling or center:
                offset = ((top + y) * screen_width + left + x) * 3
                pixels[offset:offset + 3] = bytes(gate.TEXT)
    return bytes(pixels)


class CloseGlyphGeometryTests(unittest.TestCase):
    def test_physical_rounding(self):
        self.assertEqual(gate.physical(872, 1.0), 872)
        self.assertEqual(gate.physical(872, 1.25), 1090)
        self.assertEqual(gate.physical(11, 1.25), 14)
        self.assertEqual(gate.physical(10, 1.25), 13)

    def test_close_box_at_1x(self):
        self.assertEqual(gate.close_box(900, 620, 1.0), (872, 11))

    def test_close_box_at_125x(self):
        self.assertEqual(gate.close_box(1125, 775, 1.25), (1090, 14))

    def test_close_box_rejects_wrong_screenshot_size(self):
        with self.assertRaises(RuntimeError):
            gate.close_box(900, 620, 1.25)

    def test_ink_bounds_at_1x(self):
        pixels = painted_glyph(900, 620, 872, 11, 10, 10)
        self.assertEqual(
            gate.ink_bounds(pixels, 900, 620, 872, 11, 1.0, gate.BACKGROUND),
            (872, 11, 10, 10),
        )

    def test_ink_bounds_at_125x(self):
        pixels = painted_glyph(1125, 775, 1090, 14, 13, 12)
        self.assertEqual(
            gate.ink_bounds(pixels, 1125, 775, 1090, 14, 1.25, gate.BACKGROUND),
            (1090, 14, 13, 12),
        )

    def test_inspect_exact_1x_branch(self):
        pixels = painted_glyph(10, 10, 0, 0, 10, 10)
        gate.inspect_glyph(pixels, 10, 10, (0, 0, 10, 10),
                           gate.BACKGROUND, gate.TEXT, "test", 70,
                           center_luma_limit=95)

    def test_inspect_fractional_branch(self):
        pixels = painted_glyph(13, 12, 0, 0, 13, 12)
        gate.inspect_glyph(pixels, 13, 12, (0, 0, 13, 12),
                           gate.BACKGROUND, gate.TEXT, "test", 70,
                           center_luma_limit=95)

    def test_inspect_rejects_missing_ink(self):
        pixels = bytes(gate.BACKGROUND) * (10 * 10)
        with self.assertRaises(RuntimeError):
            gate.inspect_glyph(pixels, 10, 10, (0, 0, 10, 10),
                               gate.BACKGROUND, gate.TEXT, "test", 70)

    def test_ink_bounds_rejects_missing_ink(self):
        pixels = bytes(gate.BACKGROUND) * (900 * 620)
        with self.assertRaises(RuntimeError):
            gate.ink_bounds(pixels, 900, 620, 872, 11, 1.0, gate.BACKGROUND)


if __name__ == "__main__":
    unittest.main()
