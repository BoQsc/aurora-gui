#!/usr/bin/env python3
"""Send a real forward key to the live terrain host and verify camera movement."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from pathlib import Path
import re
import sys
import time

PATTERN = re.compile(
    r"terrain camera x=([-0-9.]+) y=([-0-9.]+) z=([-0-9.]+) yaw=([-0-9.]+)")


def last_camera(path: Path) -> tuple[float, float, float]:
    text = path.read_text(errors="replace")
    matches = PATTERN.findall(text)
    if not matches:
        raise RuntimeError("no terrain camera log in app output")
    x, y, z, _ = matches[-1]
    return float(x), float(y), float(z)


def find_window(title: str) -> int:
    user32 = ctypes.windll.user32
    found: list[int] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def callback(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        size = user32.GetWindowTextLengthW(hwnd)
        text = ctypes.create_unicode_buffer(size + 1)
        user32.GetWindowTextW(hwnd, text, size + 1)
        if text.value == title:
            found.append(int(hwnd))
            return False
        return True

    user32.EnumWindows(callback, 0)
    if not found:
        raise RuntimeError(f"window not found: {title}")
    return found[0]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--title", default="Marching Cubes Terrain")
    args = parser.parse_args()

    user32 = ctypes.windll.user32
    hwnd = find_window(args.title)
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.3)
    before = last_camera(args.output)
    user32.keybd_event(0x57, 0, 0, 0)
    time.sleep(1.8)
    user32.keybd_event(0x57, 0, 2, 0)
    time.sleep(0.6)
    after = last_camera(args.output)
    print(f"camera before x={before[0]} y={before[1]} z={before[2]}")
    print(f"camera after  x={after[0]} y={after[1]} z={after[2]}")
    if after[2] >= before[2] - 0.1:
        raise RuntimeError("forward key did not move the camera forward")
    print("PASS terrain forward movement")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL terrain forward movement: {error}", file=sys.stderr)
        raise SystemExit(1)
