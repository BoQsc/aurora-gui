#!/usr/bin/env python3
"""Normalize a live host screenshot to the UI-depth golden viewport."""
from __future__ import annotations

import argparse
from pathlib import Path

from image_io import nearest_resize, png_size, read_ppm, require, write_png


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--screenshot", type=Path, default=Path("build/ui-depth.ppm"))
    parser.add_argument(
        "--reference",
        type=Path,
        default=Path("samples/ui-depth-ref1x.png"),
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("build/ui-depth-1x.png"),
    )
    args = parser.parse_args()

    width, height, pixels = read_ppm(args.screenshot)
    reference_width, reference_height = png_size(args.reference)
    require(
        width * reference_height == height * reference_width,
        f"{args.screenshot} has aspect {width}x{height}, not "
        f"{reference_width}x{reference_height}",
    )
    normalized = nearest_resize(
        pixels,
        width,
        height,
        reference_width,
        reference_height,
    )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    write_png(args.out, reference_width, reference_height, normalized)
    print(
        f"normalized {width}x{height} screenshot to "
        f"{reference_width}x{reference_height}: {args.out}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())