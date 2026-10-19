"""Open the real desktop window with the software renderer, capture it, close it.

The running app's state is left untouched: the probe gets its own temporary
APPDATA, so this can run while the normal app is open.
"""

import ctypes
import ctypes.wintypes as wt
import os
import shutil
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageStat


def window_for(pid):
    user32 = ctypes.windll.user32
    found = []

    @ctypes.WINFUNCTYPE(wt.BOOL, wt.HWND, wt.LPARAM)
    def callback(hwnd, _):
        owner = wt.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        if owner.value == pid and user32.IsWindowVisible(hwnd) and user32.GetWindowTextLengthW(hwnd) > 0:
            found.append(hwnd)
        return True

    user32.EnumWindows(callback, 0)
    return found[0] if found else None


def capture(hwnd, width, height):
    user32 = ctypes.windll.user32
    gdi32 = ctypes.windll.gdi32

    class BITMAPINFOHEADER(ctypes.Structure):
        _fields_ = [("biSize", wt.DWORD), ("biWidth", wt.LONG), ("biHeight", wt.LONG),
                    ("biPlanes", wt.WORD), ("biBitCount", wt.WORD), ("biCompression", wt.DWORD),
                    ("biSizeImage", wt.DWORD), ("biXPelsPerMeter", wt.LONG),
                    ("biYPelsPerMeter", wt.LONG), ("biClrUsed", wt.DWORD), ("biClrImportant", wt.DWORD)]

    screen = user32.GetWindowDC(hwnd)
    memory = gdi32.CreateCompatibleDC(screen)
    bitmap = gdi32.CreateCompatibleBitmap(screen, width, height)
    gdi32.SelectObject(memory, bitmap)
    user32.PrintWindow(hwnd, memory, 2)
    info = BITMAPINFOHEADER()
    info.biSize = ctypes.sizeof(BITMAPINFOHEADER)
    info.biWidth, info.biHeight = width, -height
    info.biPlanes, info.biBitCount = 1, 32
    buffer = ctypes.create_string_buffer(width * height * 4)
    gdi32.GetDIBits(memory, bitmap, 0, height, buffer, ctypes.byref(info), 0)
    gdi32.DeleteObject(bitmap)
    gdi32.DeleteDC(memory)
    user32.ReleaseDC(hwnd, screen)
    return Image.frombuffer("RGB", (width, height), buffer, "raw", "BGRX", 0, 1)


def main():
    exe = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else
                          r"aurora-opencode-pro\aurora-opencode-pro.exe")
    state = tempfile.mkdtemp(prefix="aurora-software-gui-")
    env = os.environ.copy()
    env["APPDATA"] = state
    process = subprocess.Popen([exe, "--renderer=software"], env=env,
                               cwd=os.path.dirname(exe))
    try:
        hwnd = None
        for _ in range(120):
            hwnd = window_for(process.pid)
            if hwnd or process.poll() is not None:
                break
            time.sleep(0.5)
        if not hwnd:
            raise SystemExit(f"software window did not open (exit {process.poll()})")

        rect = wt.RECT()
        ctypes.windll.user32.GetWindowRect(hwnd, ctypes.byref(rect))
        width, height = rect.right - rect.left, rect.bottom - rect.top
        image = capture(hwnd, width, height)
        mean = ImageStat.Stat(image.convert("L")).mean[0]
        colors = len(image.getcolors(maxcolors=100000) or [])
        print(f"software window {width}x{height} mean={mean:.1f} colors={colors}")
        if mean < 10 or colors < 100:
            raise SystemExit("software window is effectively black")

        log = os.path.join(state, "Aurora OpenCode", "logs", "errors.log")
        if os.path.exists(log):
            with open(log, encoding="utf-8", errors="replace") as lines:
                for line in lines:
                    if "renderer:" in line:
                        print(line.strip())
                        break

        ctypes.windll.user32.PostMessageW(hwnd, 0x0010, 0, 0)
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.terminate()
        if process.poll() != 0:
            raise SystemExit(f"software window exited with {process.poll()}")
    finally:
        if process.poll() is None:
            process.terminate()
        shutil.rmtree(state, ignore_errors=True)


if __name__ == "__main__":
    main()
