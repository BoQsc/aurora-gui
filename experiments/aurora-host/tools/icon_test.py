#!/usr/bin/env python3
"""Verify that the host publishes the embedded application icon to its window."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from caption_behavior_test import window_for_pid  # noqa: E402
from host_session import Host  # noqa: E402

WM_GETICON = 0x007F
ICON_SMALL = 0
ICON_BIG = 1
GCLP_HICON = -14
GCLP_HICONSM = -34


class IconInfo(ctypes.Structure):
    _fields_ = [
        ("fIcon", wintypes.BOOL),
        ("xHotspot", wintypes.DWORD),
        ("yHotspot", wintypes.DWORD),
        ("hbmMask", wintypes.HBITMAP),
        ("hbmColor", wintypes.HBITMAP),
    ]


class Bitmap(ctypes.Structure):
    _fields_ = [
        ("bmType", wintypes.LONG),
        ("bmWidth", wintypes.LONG),
        ("bmHeight", wintypes.LONG),
        ("bmWidthBytes", wintypes.LONG),
        ("bmPlanes", wintypes.WORD),
        ("bmBitsPixel", wintypes.WORD),
        ("bmBits", ctypes.c_void_p),
    ]


def window_icon(hwnd: int, which: int, class_index: int) -> tuple[int, int, int]:
    user32 = ctypes.windll.user32
    gdi32 = ctypes.windll.gdi32
    user32.SendMessageW.argtypes = [
        wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
    user32.SendMessageW.restype = ctypes.c_void_p
    handle = user32.SendMessageW(hwnd, WM_GETICON, which, 0)
    if not handle:
        user32.GetClassLongPtrW.argtypes = [wintypes.HWND, ctypes.c_int]
        user32.GetClassLongPtrW.restype = ctypes.c_void_p
        handle = user32.GetClassLongPtrW(hwnd, class_index)
    if not handle:
        raise RuntimeError(f"window has no icon for slot {which}")

    user32.GetIconInfo.argtypes = [wintypes.HICON, ctypes.POINTER(IconInfo)]
    user32.GetIconInfo.restype = wintypes.BOOL
    info = IconInfo()
    if not user32.GetIconInfo(handle, ctypes.byref(info)):
        raise RuntimeError(f"GetIconInfo failed for icon slot {which}")
    try:
        gdi32.GetObjectW.argtypes = [
            wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p]
        gdi32.GetObjectW.restype = ctypes.c_int
        bitmap = Bitmap()
        if not info.hbmColor or not gdi32.GetObjectW(
            info.hbmColor, ctypes.sizeof(bitmap), ctypes.byref(bitmap)
        ):
            raise RuntimeError(f"icon slot {which} has no colour bitmap")
        return bitmap.bmWidth, bitmap.bmHeight, bitmap.bmBitsPixel
    finally:
        gdi32.DeleteObject.argtypes = [wintypes.HANDLE]
        gdi32.DeleteObject.restype = wintypes.BOOL
        if info.hbmColor:
            gdi32.DeleteObject(info.hbmColor)
        if info.hbmMask:
            gdi32.DeleteObject(info.hbmMask)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=Path)
    parser.add_argument("--scene", default=ROOT / "samples" / "hello.scene.json",
                        type=Path)
    args = parser.parse_args()

    host = Host(args.scene, args.host)
    try:
        hwnd = window_for_pid(host.process.pid)
        large = window_icon(hwnd, ICON_BIG, GCLP_HICON)
        small = window_icon(hwnd, ICON_SMALL, GCLP_HICONSM)
        if large[0] < 16 or large[1] < 16 or small[0] < 8 or small[1] < 8:
            raise RuntimeError(f"unexpected icon sizes: large={large} small={small}")
    finally:
        time.sleep(0.2)
        if host.errors:
            print("host stderr:", *host.errors, sep="\n", file=sys.stderr)
        host.close()

    print(f"icon test passed: large={large[0]}x{large[1]}, "
          f"small={small[0]}x{small[1]}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"icon test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
