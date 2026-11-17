#!/usr/bin/env python3
"""Validate host surface layout and native producer resolution."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
import struct
from pathlib import Path
import sys


def surface_extent(path: Path) -> tuple[int, int]:
    data = path.read_bytes()[:80]
    if len(data) < 80 or data[:8] != b"AURSFACE":
        raise RuntimeError(f"not an AURSFACE: {path}")
    return struct.unpack_from("<II", data, 16)


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


def find_surface_flex(value: object) -> int | None:
    if isinstance(value, dict):
        if value.get("type") == "surface":
            return int(value.get("flex", 0))
        for child in value.values():
            result = find_surface_flex(child)
            if result is not None:
                return result
    elif isinstance(value, list):
        for child in value:
            result = find_surface_flex(child)
            if result is not None:
                return result
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--surface", required=True, type=Path)
    parser.add_argument("--title", required=True)
    parser.add_argument("--scene", type=Path)
    args = parser.parse_args()

    width, height = surface_extent(args.surface)
    hwnd = find_window(args.title)
    user32 = ctypes.windll.user32
    client = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(client))
    dpi = user32.GetDpiForWindow(hwnd)
    scale = dpi / 96.0
    required_width = int(client.right * scale)
    required_height = int(client.bottom * scale)
    print(f"surface {width}x{height}")
    print(f"host client {client.right}x{client.bottom} dpi={dpi} "
        f"native_required={required_width}x{required_height}")
    if width < required_width or height < required_height:
        raise RuntimeError("surface is below the host's native pixel size")

    if args.scene is not None:
        scene = json.loads(args.scene.read_text())
        flex = find_surface_flex(scene.get("root"))
        print(f"surface flex={flex}")
        if not flex or flex <= 0:
            raise RuntimeError("surface node is not flexed in the host scene")

    print("PASS flexed native host surface")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL flexed native host surface: {error}", file=sys.stderr)
        raise SystemExit(1)
