"""Acceptance checks for the zero-tolerance native font comparison."""
import importlib.util
from pathlib import Path
import unittest

from PIL import Image

spec = importlib.util.spec_from_file_location(
    "font_comparison", Path(__file__).resolve().parents[1] / "compare-font-rendering.py")
comparison = importlib.util.module_from_spec(spec)
spec.loader.exec_module(comparison)


class PixelEqualityTests(unittest.TestCase):
    def test_shared_alpha_accepts_every_representable_coverage(self):
        light = Image.new("RGB", (256, 1))
        dark = Image.new("RGB", (256, 1))
        light.putdata([(255 - a,) * 3 for a in range(256)])
        dark.putdata([((240 * a + 24 * (255 - a) + 127) // 255,) * 3 for a in range(256)])
        self.assertTrue(comparison.shared_alpha_feasibility(light, dark)["compatible"])

    def test_shared_alpha_rejects_incompatible_theme_pair(self):
        light = Image.new("RGB", (1, 1), (127,) * 3)
        dark = Image.new("RGB", (1, 1), (200,) * 3)
        result = comparison.shared_alpha_feasibility(light, dark)
        self.assertFalse(result["compatible"])
        self.assertEqual(result["incompatible_pixels"], 1)
        self.assertEqual(result["first_incompatible_pixel"]["predicted_dark_channel"], 132)

    def test_identical_pixels_pass(self):
        image = Image.new("RGB", (3, 2), (71, 113, 199))
        result = comparison.exact_comparison(image, image.copy())
        self.assertTrue(result["exact"])
        self.assertEqual(result["different_pixels"], 0)
        self.assertEqual(result["aurora_rgb_sha256"], result["native_rgb_sha256"])

    def test_single_channel_one_level_difference_fails(self):
        reference = Image.new("RGB", (3, 2), "white")
        actual = reference.copy()
        actual.putpixel((2, 1), (255, 254, 255))
        result = comparison.exact_comparison(actual, reference)
        self.assertFalse(result["exact"])
        self.assertEqual(result["different_pixels"], 1)
        self.assertEqual(result["maximum_channel_error"], 1)
        self.assertEqual((result["first_difference"]["x"], result["first_difference"]["y"]), (2, 1))
        self.assertEqual(comparison.difference_image(actual, reference).getpixel((2, 1)), (255, 0, 0))

    def test_color_difference_survives_equal_luminance(self):
        actual = Image.new("RGB", (1, 1), (1, 0, 0))
        reference = Image.new("RGB", (1, 1), (0, 0, 1))
        self.assertEqual(actual.convert("L").tobytes(), reference.convert("L").tobytes())
        self.assertFalse(comparison.exact_comparison(actual, reference)["exact"])

    def test_different_dimensions_cannot_pass_by_truncating_comparison(self):
        actual = Image.new("RGB", (2, 1), "white")
        reference = Image.new("RGB", (1, 1), "white")
        self.assertFalse(comparison.exact_comparison(actual, reference)["exact"])


if __name__ == "__main__":
    unittest.main()
