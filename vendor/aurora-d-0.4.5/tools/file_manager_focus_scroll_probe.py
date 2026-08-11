#!/usr/bin/env python3
"""Verify native focus and wheel routing for the Windows file manager.

The regression sequence mirrors the reported failure:
  1. Aurora must advertise a native vertical scroll surface;
  2. clicking its client must make its HWND foreground;
  3. standard mouse-wheel and precision-touchpad deltas must scroll exactly once.
"""

from __future__ import annotations

import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import subprocess
import sys
import time


WM_CLOSE = 0x0010
WM_MOUSEWHEEL = 0x020A
WM_VSCROLL = 0x0115

INPUT_MOUSE = 0
MOUSEEVENTF_WHEEL = 0x0800
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
GWL_STYLE = -16
WS_VSCROLL = 0x00200000
SB_VERT = 1
SIF_ALL = 0x0017

HWND_TOP = 0
HWND_TOPMOST = -1
HWND_NOTOPMOST = -2
SWP_NOSIZE = 0x0001
SWP_NOMOVE = 0x0002
SWP_NOACTIVATE = 0x0010
GA_ROOT = 2


class MouseInput(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG)),
    ]


class InputUnion(ctypes.Union):
    _fields_ = [("mi", MouseInput)]


class Input(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("union", InputUnion)]


class ScrollInfo(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.UINT),
        ("fMask", wintypes.UINT),
        ("nMin", ctypes.c_int),
        ("nMax", ctypes.c_int),
        ("nPage", wintypes.UINT),
        ("nPos", ctypes.c_int),
        ("nTrackPos", ctypes.c_int),
    ]


def main() -> int:
    if os.name != "nt":
        print("Windows only.")
        return 2
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if len(sys.argv) < 3:
        print("usage: file_manager_focus_scroll_probe.py EXE DIRECTORY [OUTPUT_DIR]")
        return 2

    executable = Path(sys.argv[1]).resolve()
    directory = Path(sys.argv[2]).resolve()
    if not executable.exists() or not directory.exists():
        print("executable or test directory does not exist")
        return 2

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    enum_callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = (enum_callback, wintypes.LPARAM)
    user32.EnumWindows.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = (
        wintypes.HWND,
        ctypes.POINTER(wintypes.DWORD),
    )
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.GetWindowTextLengthW.argtypes = (wintypes.HWND,)
    user32.GetWindowTextLengthW.restype = ctypes.c_int
    user32.GetWindowTextW.argtypes = (wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
    user32.GetWindowTextW.restype = ctypes.c_int
    user32.IsWindowVisible.argtypes = (wintypes.HWND,)
    user32.IsWindowVisible.restype = wintypes.BOOL
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.WindowFromPoint.argtypes = (wintypes.POINT,)
    user32.WindowFromPoint.restype = wintypes.HWND
    user32.GetAncestor.argtypes = (wintypes.HWND, wintypes.UINT)
    user32.GetAncestor.restype = wintypes.HWND
    user32.GetClientRect.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.RECT))
    user32.GetClientRect.restype = wintypes.BOOL
    user32.ClientToScreen.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.POINT))
    user32.ClientToScreen.restype = wintypes.BOOL
    user32.SetCursorPos.argtypes = (ctypes.c_int, ctypes.c_int)
    user32.SetCursorPos.restype = wintypes.BOOL
    user32.GetSystemMetrics.argtypes = (ctypes.c_int,)
    user32.GetSystemMetrics.restype = ctypes.c_int
    user32.SetWindowPos.argtypes = (
        wintypes.HWND,
        wintypes.HWND,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_int,
        wintypes.UINT,
    )
    user32.SetWindowPos.restype = wintypes.BOOL
    user32.SetForegroundWindow.argtypes = (wintypes.HWND,)
    user32.SetForegroundWindow.restype = wintypes.BOOL
    user32.GetWindowLongPtrW.argtypes = (wintypes.HWND, ctypes.c_int)
    user32.GetWindowLongPtrW.restype = ctypes.c_ssize_t
    user32.GetScrollInfo.argtypes = (
        wintypes.HWND,
        ctypes.c_int,
        ctypes.POINTER(ScrollInfo),
    )
    user32.GetScrollInfo.restype = wintypes.BOOL
    user32.SendInput.argtypes = (wintypes.UINT, ctypes.POINTER(Input), ctypes.c_int)
    user32.SendInput.restype = wintypes.UINT
    user32.SendMessageW.argtypes = (
        wintypes.HWND,
        wintypes.UINT,
        wintypes.WPARAM,
        wintypes.LPARAM,
    )
    user32.SendMessageW.restype = ctypes.c_ssize_t

    def pid_of(hwnd: int) -> int:
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        return pid.value

    def title_of(hwnd: int) -> str:
        length = user32.GetWindowTextLengthW(hwnd)
        buffer = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buffer, len(buffer))
        return buffer.value

    def find_process_window(pid: int, title_fragment: str = "") -> int | None:
        matches: list[int] = []

        @enum_callback
        def collect(hwnd: int, _: int) -> bool:
            if pid_of(hwnd) == pid and user32.IsWindowVisible(hwnd):
                if not title_fragment or title_fragment.casefold() in title_of(hwnd).casefold():
                    matches.append(hwnd)
            return True

        user32.EnumWindows(collect, 0)
        return matches[0] if matches else None

    def send_mouse(flags: int, data: int = 0) -> None:
        event = Input()
        event.type = INPUT_MOUSE
        event.union.mi = MouseInput(0, 0, data & 0xFFFFFFFF, flags, 0, None)
        if user32.SendInput(1, ctypes.byref(event), ctypes.sizeof(Input)) != 1:
            raise RuntimeError(f"SendInput failed for flags 0x{flags:x}")

    environment = os.environ.copy()
    environment["AURORA_RENDERER"] = "software"

    file_manager = subprocess.Popen(
        [str(executable), str(directory)],
        cwd=str(executable.parent),
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    file_manager_hwnd: int | None = None
    try:
        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline and file_manager.poll() is None:
            file_manager_hwnd = find_process_window(file_manager.pid, "File Manager")
            if file_manager_hwnd is not None:
                break
            time.sleep(0.025)
        if file_manager_hwnd is None:
            raise RuntimeError("file manager window did not appear")
        time.sleep(1.0)

        style = user32.GetWindowLongPtrW(file_manager_hwnd, GWL_STYLE)
        print(f"native_vertical_scrollbar={bool(style & WS_VSCROLL)}")
        if not style & WS_VSCROLL:
            raise RuntimeError("file manager HWND does not advertise WS_VSCROLL")
        scroll_info = ScrollInfo(ctypes.sizeof(ScrollInfo), SIF_ALL)
        if not user32.GetScrollInfo(
            file_manager_hwnd, SB_VERT, ctypes.byref(scroll_info)
        ):
            raise RuntimeError("could not read the native vertical scroll range")
        print(
            "native_scroll="
            f"min:{scroll_info.nMin} max:{scroll_info.nMax} "
            f"page:{scroll_info.nPage} pos:{scroll_info.nPos}"
        )

        client = wintypes.RECT()
        user32.GetClientRect(file_manager_hwnd, ctypes.byref(client))
        point = wintypes.POINT(client.right * 3 // 4, 400)
        user32.ClientToScreen(file_manager_hwnd, ctypes.byref(point))
        user32.SetCursorPos(point.x, point.y)
        time.sleep(0.4)

        under_cursor = user32.WindowFromPoint(point)
        under_cursor_root = user32.GetAncestor(under_cursor, GA_ROOT)
        print(
            f"under_cursor='{title_of(under_cursor_root)}' "
            f"is_filemanager={under_cursor_root == file_manager_hwnd}"
        )
        if under_cursor_root != file_manager_hwnd:
            raise RuntimeError("file manager is not under the probe cursor")

        send_mouse(MOUSEEVENTF_LEFTDOWN)
        send_mouse(MOUSEEVENTF_LEFTUP)
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            if user32.GetForegroundWindow() == file_manager_hwnd:
                break
            time.sleep(0.02)
        foreground_after_hover = user32.GetForegroundWindow()
        print(
            f"after_click_foreground='{title_of(foreground_after_hover)}' "
            f"is_filemanager={foreground_after_hover == file_manager_hwnd}"
        )
        if foreground_after_hover != file_manager_hwnd:
            raise RuntimeError("client click did not activate the file manager")

        user32.SendMessageW(file_manager_hwnd, WM_VSCROLL, 1, 0)
        time.sleep(0.3)
        command_info = ScrollInfo(ctypes.sizeof(ScrollInfo), SIF_ALL)
        user32.GetScrollInfo(file_manager_hwnd, SB_VERT, ctypes.byref(command_info))
        print(f"native_command_position={command_info.nPos}")

        wheel_lparam = ((point.y & 0xFFFF) << 16) | (point.x & 0xFFFF)
        for index in range(4):
            wheel_wparam = ((-120) & 0xFFFF) << 16
            user32.SendMessageW(
                file_manager_hwnd, WM_MOUSEWHEEL, wheel_wparam, wheel_lparam
            )
            time.sleep(0.03)
            step_info = ScrollInfo(ctypes.sizeof(ScrollInfo), SIF_ALL)
            user32.GetScrollInfo(
                file_manager_hwnd, SB_VERT, ctypes.byref(step_info)
            )
            print(f"standard_step_{index + 1}_position={step_info.nPos}")
        time.sleep(1.5)
        standard_info = ScrollInfo(ctypes.sizeof(ScrollInfo), SIF_ALL)
        user32.GetScrollInfo(file_manager_hwnd, SB_VERT, ctypes.byref(standard_info))
        standard_scroll = standard_info.nPos - command_info.nPos
        print(f"standard_wheel_scroll={standard_scroll}")
        print(f"standard_native_position={standard_info.nPos}")
        if standard_scroll != 104:
            raise RuntimeError(
                f"standard wheel expected one delivery (104), got {standard_scroll}"
            )

        # Send exact sub-notch WM_MOUSEWHEEL values. SendInput may normalize or
        # discard these, while touchpad drivers can post them directly.
        wheel_wparam = ((-20) & 0xFFFF) << 16
        for _ in range(12):
            user32.SendMessageW(
                file_manager_hwnd, WM_MOUSEWHEEL, wheel_wparam, wheel_lparam
            )
            time.sleep(0.02)
        time.sleep(1.5)
        precision_info = ScrollInfo(ctypes.sizeof(ScrollInfo), SIF_ALL)
        user32.GetScrollInfo(file_manager_hwnd, SB_VERT, ctypes.byref(precision_info))
        precision_scroll = precision_info.nPos - standard_info.nPos
        print(f"precision_wheel_scroll={precision_scroll}")
        print(f"precision_native_position={precision_info.nPos}")
        if precision_scroll != 52:
            raise RuntimeError(
                f"precision wheel expected exact accumulation (52), got {precision_scroll}"
            )

        print("NATIVE FOCUS + SCROLL VERIFIED")
        return 0
    finally:
        if file_manager_hwnd is not None:
            user32.SendMessageW(file_manager_hwnd, WM_CLOSE, 0, 0)
        try:
            file_manager.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            file_manager.kill()


if __name__ == "__main__":
    raise SystemExit(main())
