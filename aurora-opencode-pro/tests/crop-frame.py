"""Crop a fixed region out of a captured PPM/PNG frame.

Used by verification recipes to compare one rendered row (for example the live
Thinking header) without depending on clocks, sidebars or other frame chrome.
"""
import sys
from PIL import Image


def main(argv):
    if len(argv) != 7:
        raise SystemExit("usage: crop-frame.py SRC DST X Y WIDTH HEIGHT")
    src, dst, x, y, width, height = argv[1], argv[2], *map(int, argv[3:])
    image = Image.open(src).convert("RGB")
    if x < 0 or y < 0 or width <= 0 or height <= 0 or \
            x + width > image.width or y + height > image.height:
        raise SystemExit(f"crop outside {image.width}x{image.height}: "
                         f"{x},{y} {width}x{height}")
    image.crop((x, y, x + width, y + height)).save(dst)


if __name__ == "__main__":
    main(sys.argv)
