#!/usr/bin/env python3
"""Exercise standard caption double-click maximize/restore on a host window."""
from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from host_session import Host  # noqa: E402

WM_LBUTTONDBLCLK = 0x0203
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
WM_MOUSEMOVE = 0x0200
MK_LBUTTON = 0x0001
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def window_for_pid(pid: int, timeout: float = 8.0) -> int:
    user32 = ctypes.windll.user32
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND,
                                        wintypes.LPARAM)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found: list[int] = []

        def visit(hwnd: int, _lparam: int) -> bool:
            process_id = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(process_id))
            if process_id.value == pid and user32.IsWindowVisible(hwnd):
                found.append(hwnd)
                return False
            return True

        user32.EnumWindows(callback_type(visit), 0)
        if found:
            return found[0]
        time.sleep(0.1)
    raise RuntimeError(f"no visible window for host pid {pid}")


def window_rect(hwnd: int) -> tuple[int, int, int, int]:
    rect = wintypes.RECT()
    if not ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        raise RuntimeError("GetWindowRect failed")
    return rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top


def client_size(hwnd: int) -> tuple[int, int]:
    rect = wintypes.RECT()
    if not ctypes.windll.user32.GetClientRect(hwnd, ctypes.byref(rect)):
        raise RuntimeError("GetClientRect failed")
    return rect.right, rect.bottom


def double_click_caption(hwnd: int) -> None:
    width, _ = client_size(hwnd)
    dpi = ctypes.windll.user32.GetDpiForWindow(hwnd)
    y = max(4, round(16 * dpi / 96))
    x = width // 2
    packed = (y << 16) | (x & 0xFFFF)
    user32 = ctypes.windll.user32
    user32.PostMessageW(hwnd, WM_LBUTTONDBLCLK, MK_LBUTTON, packed)
    user32.PostMessageW(hwnd, WM_LBUTTONUP, 0, packed)
    time.sleep(0.6)


def drag_caption_down(hwnd: int, distance: int = 200) -> None:
    width, _ = client_size(hwnd)
    dpi = ctypes.windll.user32.GetDpiForWindow(hwnd)
    y = max(4, round(16 * dpi / 96))
    x = width // 2
    pressed = (y << 16) | (x & 0xFFFF)
    dragged = ((y + distance) << 16) | (x & 0xFFFF)
    user32 = ctypes.windll.user32
    user32.PostMessageW(hwnd, WM_LBUTTONDOWN, MK_LBUTTON, pressed)
    time.sleep(0.1)
    user32.PostMessageW(hwnd, WM_MOUSEMOVE, MK_LBUTTON, dragged)
    time.sleep(0.2)
    user32.PostMessageW(hwnd, WM_LBUTTONUP, 0, dragged)
    time.sleep(0.6)


def exercise_caption(hwnd: int) -> None:
    before = window_rect(hwnd)
    double_click_caption(hwnd)
    maximized = window_rect(hwnd)
    if maximized[2] <= before[2] + 100 or maximized[3] <= before[3] + 100:
        raise RuntimeError(
            f"double-click did not maximize: {before} -> {maximized}")
    double_click_caption(hwnd)
    restored = window_rect(hwnd)
    if abs(restored[2] - before[2]) > 24 or abs(restored[3] - before[3]) > 24:
        raise RuntimeError(
            f"second double-click did not restore: {before} -> {restored}")
    double_click_caption(hwnd)
    drag_caption_down(hwnd)
    dragged = window_rect(hwnd)
    if dragged[2] > before[2] + 100 or dragged[3] > before[3] + 100:
        raise RuntimeError(
            f"drag from maximized did not restore: {before} -> {dragged}")
    if dragged[:2] == before[:2]:
        raise RuntimeError(
            f"drag from maximized did not move the window: {before} -> {dragged}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=Path)
    parser.add_argument("--scene", required=True, type=Path)
    args = parser.parse_args()

    host = Host(args.scene, args.host)
    try:
        hwnd = window_for_pid(host.process.pid)
        exercise_caption(hwnd)
    finally:
        time.sleep(0.2)
        if host.errors:
            print("host stderr:", *host.errors, sep="\n", file=sys.stderr)
        host.close()

    print("caption behavior test passed: double-click maximizes and restores; "
          "maximized drag restores and moves")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"caption behavior test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
