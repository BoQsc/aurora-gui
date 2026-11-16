"""Physical-input probe for the current Aurora Designer build (temporary)."""
from __future__ import annotations

import ctypes
import os
import struct
import subprocess
import time
import zlib
from ctypes import wintypes
from pathlib import Path

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))

user32.EnumWindows.argtypes = [ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM), wintypes.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.GetDC.argtypes = [wintypes.HWND]
user32.GetDC.restype = wintypes.HDC
user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi32.CreateCompatibleDC.restype = wintypes.HDC
gdi32.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
gdi32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
gdi32.SelectObject.restype = wintypes.HGDIOBJ
gdi32.BitBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.HDC, ctypes.c_int, ctypes.c_int, wintypes.DWORD]
gdi32.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
gdi32.DeleteDC.argtypes = [wintypes.HDC]

HWND_TOPMOST = wintypes.HWND(-1)
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001
SWP_SHOWWINDOW = 0x0040
SRCCOPY = 0x00CC0020
WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN = 0x0201
WM_LBUTTONUP = 0x0202
MK_LBUTTON = 0x0001


def title(hwnd: int) -> str:
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
        if owner.value == pid and "Aurora Designer" in title(hwnd):
            found.append(hwnd)
            return False
        return True

    user32.EnumWindows(callback, 0)
    return found[0] if found else 0


def post(hwnd: int, message: int, x: int, y: int, wparam: int = 0) -> None:
    user32.PostMessageW(hwnd, message, wparam, (y << 16) | (x & 0xFFFF))
    time.sleep(0.03)


def drag(hwnd: int, x1: int, y1: int, x2: int, y2: int) -> None:
    post(hwnd, WM_MOUSEMOVE, x1, y1)
    post(hwnd, WM_LBUTTONDOWN, x1, y1, MK_LBUTTON)
    steps = 10
    for i in range(1, steps + 1):
        post(hwnd, WM_MOUSEMOVE,
             x1 + (x2 - x1) * i // steps,
             y1 + (y2 - y1) * i // steps, MK_LBUTTON)
    post(hwnd, WM_LBUTTONUP, x2, y2)
    time.sleep(0.8)


class BitmapInfoHeader(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD), ("biWidth", wintypes.LONG),
        ("biHeight", wintypes.LONG), ("biPlanes", wintypes.WORD),
        ("biBitCount", wintypes.WORD), ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD), ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG), ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    ]


def capture(hwnd: int) -> tuple[int, int, bytearray]:
    rect = wintypes.RECT()
    user32.GetClientRect(hwnd, ctypes.byref(rect))
    width, height = rect.right - rect.left, rect.bottom - rect.top
    hdc = user32.GetDC(hwnd)
    mem = gdi32.CreateCompatibleDC(hdc)
    bmp = gdi32.CreateCompatibleBitmap(hdc, width, height)
    old = gdi32.SelectObject(mem, bmp)
    gdi32.BitBlt(mem, 0, 0, width, height, hdc, 0, 0, SRCCOPY)
    header = BitmapInfoHeader()
    header.biSize = ctypes.sizeof(header)
    header.biWidth = width
    header.biHeight = -height
    header.biPlanes = 1
    header.biBitCount = 32
    pixels = (ctypes.c_ubyte * (width * height * 4))()
    gdi32.GetDIBits(mem, bmp, 0, height, pixels, ctypes.byref(header), 0)
    rgb = bytearray(width * height * 3)
    for i in range(width * height):
        rgb[i * 3] = pixels[i * 4 + 2]
        rgb[i * 3 + 1] = pixels[i * 4 + 1]
        rgb[i * 3 + 2] = pixels[i * 4]
    gdi32.SelectObject(mem, old)
    gdi32.DeleteObject(bmp)
    gdi32.DeleteDC(mem)
    user32.ReleaseDC(hwnd, hdc)
    return width, height, rgb


def save_png(path: Path, width: int, height: int, rgb: bytearray) -> None:
    raw = b"".join(
        b"\x00" + bytes(rgb[y * width * 3:(y + 1) * width * 3])
        for y in range(height)
    )

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 3))
        + chunk(b"IEND", b"")
    )


def region_stats(width: int, before: bytearray, after: bytearray,
                 x: int, y: int, w: int, h: int) -> tuple[int, int, int]:
    changed = 0
    before_light = 0
    after_light = 0
    for py in range(y, y + h):
        row = py * width * 3
        for px in range(x, x + w):
            i = row + px * 3
            dr = abs(before[i] - after[i])
            dg = abs(before[i + 1] - after[i + 1])
            db = abs(before[i + 2] - after[i + 2])
            if dr + dg + db > 30:
                changed += 1
            if before[i] > 210 and before[i + 1] > 210 and before[i + 2] > 210:
                before_light += 1
            if after[i] > 210 and after[i + 1] > 210 and after[i + 2] > 210:
                after_light += 1
    return changed, before_light, after_light


def main() -> int:
    exe = Path("aurora/aurora-designer/build/probe/aurora-designer.exe").resolve()
    if not exe.is_file():
        print("probe executable missing:", exe)
        return 2
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
            print("no window")
            return 2
        user32.SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW)
        user32.SetForegroundWindow(hwnd)
        time.sleep(0.8)

        width, height, before = capture(hwnd)
        # Drop a palette Button at an empty artboard point (client 800, 420).
        drag(hwnd, 91, 236, 800, 420)
        time.sleep(0.5)
        width2, height2, after = capture(hwnd)
        if (width, height) != (width2, height2):
            print("client size changed during probe")
            return 2

        # The default 96x38 Button is centered at (800, 420).
        left, top = 800 - 48, 420 - 19
        changed, before_light, after_light = region_stats(
            width, before, after, left, top, 96, 38)
        out = Path(os.environ["TEMP"]) / "designer-native"
        out.mkdir(exist_ok=True)
        save_png(out / "before.png", width, height, before)
        save_png(out / "after-palette-drag.png", width, height, after)
        print("client", width, height)
        print("drop region changed pixels:", changed)
        print("drop region light pixels before/after:", before_light, after_light)
        print("screenshots", out)
        if changed < 500 or before_light > 20 or after_light < 50:
            print("PALETTE DRAG VERIFICATION FAILED")
            return 1
        print("PALETTE DRAG VERIFICATION PASSED")
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    raise SystemExit(main())
