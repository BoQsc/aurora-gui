"""Physical mouse-input check for the current Aurora Designer window."""
from __future__ import annotations

import ctypes
import os
import subprocess
import time
from ctypes import wintypes
from pathlib import Path

user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
user32.EnumWindows.argtypes = [ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM), wintypes.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.mouse_event.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ctypes.c_void_p]
user32.WindowFromPoint.argtypes = [wintypes.POINT]
user32.WindowFromPoint.restype = wintypes.HWND

HWND_TOPMOST = wintypes.HWND(-1)
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001
SWP_SHOWWINDOW = 0x0040
LEFTDOWN = 0x0002
LEFTUP = 0x0004


def window_title(hwnd: int) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    buffer = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buffer, length + 1)
    return buffer.value


def find_window(pid: int) -> int:
    found = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def callback(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid:
            found.append(hwnd)
            return False
        return True

    user32.EnumWindows(callback, 0)
    return found[0] if found else 0


def wait_title(hwnd: int, needle: str) -> str:
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        title = window_title(hwnd)
        if needle in title:
            return title
        time.sleep(0.05)
    actual = window_title(hwnd)
    raise AssertionError(f"window title never contained {needle!r}; got {actual!r}")


def click(origin: wintypes.POINT, hwnd: int, x: int, y: int) -> None:
    point = wintypes.POINT(origin.x + x, origin.y + y)
    if user32.WindowFromPoint(point) != hwnd:
        raise AssertionError(f"window is not under client point ({x}, {y})")
    user32.SetCursorPos(point.x, point.y)
    time.sleep(0.08)
    user32.mouse_event(LEFTDOWN, 0, 0, 0, None)
    time.sleep(0.08)
    user32.mouse_event(LEFTUP, 0, 0, 0, None)
    time.sleep(0.35)


def main() -> int:
    exe = Path("aurora/aurora-designer/aurora-designer.exe").resolve()
    if not exe.is_file():
        raise AssertionError(f"current designer executable missing: {exe}")
    env = os.environ.copy()
    env["AURORA_RENDERER"] = "software"
    process = subprocess.Popen([str(exe)], env=env)
    try:
        hwnd = 0
        for _ in range(100):
            hwnd = find_window(process.pid)
            if hwnd:
                break
            time.sleep(0.1)
        if not hwnd:
            raise AssertionError("designer window was not created")
        user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW)
        user32.SetForegroundWindow(hwnd)
        time.sleep(0.7)
        origin = wintypes.POINT(0, 0)
        user32.ClientToScreen(hwnd, ctypes.byref(origin))
        print("initial:", wait_title(hwnd, "window1"))

        # Palette Panel at client (91, 166) -> child of window1.
        click(origin, hwnd, 91, 166)
        print("after palette Panel:", wait_title(hwnd, "Panel"))

        # Palette Button at client (91, 287) -> child of panel2.
        click(origin, hwnd, 91, 287)
        print("after palette Button:", wait_title(hwnd, "Button"))

        # Layers row for panel2 at client (60, 514) -> select parent panel.
        click(origin, hwnd, 60, 514)
        print("after Layers row:", wait_title(hwnd, "panel2"))

        # Palette Label at client (91, 327) -> child of selected panel2.
        click(origin, hwnd, 91, 327)
        print("after palette Label:", wait_title(hwnd, "Label"))
        print("PHYSICAL DESIGNER INPUT CHECK PASSED")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    raise SystemExit(main())
