#!/usr/bin/env python3
"""Verify the registered Notepad component and its custom-painted chrome."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from host_session import Host, read_ppm  # noqa: E402


def pixel(pixels: bytes, width: int, x: int, y: int) -> tuple[int, int, int]:
    offset = (y * width + x) * 3
    return tuple(pixels[offset : offset + 3])


def near(actual: tuple[int, int, int], expected: tuple[int, int, int],
         tolerance: int = 4) -> bool:
    return all(abs(a - b) <= tolerance for a, b in zip(actual, expected))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=Path)
    parser.add_argument("--scene", required=True, type=Path)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="aurora-notepad-") as temp_name:
        shot = Path(temp_name) / "notepad.ppm"
        host = Host(args.scene, args.host)
        try:
            tree = host.request("tree")
            nodes = {node["id"]: node for node in tree.get("nodes", [])}
            component = nodes.get("notepad")
            if component is None or component.get("type") != "component":
                raise RuntimeError("Notepad component was not registered in the scene")
            host.request("screenshot", path=str(shot))
        finally:
            host.close()

        width, height, pixels = read_ppm(shot)
        if width < 800 or height < 600:
            raise RuntimeError(f"unexpected Notepad surface {width}x{height}")
        if not near(pixel(pixels, width, width // 2, 8), (243, 243, 243)):
            raise RuntimeError("titlebar is not using the component's chrome color")
        if not near(pixel(pixels, width, width // 2, height // 2),
                    (255, 255, 255)):
            raise RuntimeError("editor is not painting a white document surface")
        if not near(pixel(pixels, width, width // 2, height - 6),
                    (240, 240, 240)):
            raise RuntimeError("status bar is missing from the component")

    print("notepad component test passed: registry, chrome, editor, and status bar")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"notepad component test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
