#!/usr/bin/env python3
"""Real-Windows, no-activation runtime check for FFmpeg gfxcapture.

The inventory check proves that the filter was compiled. This check proves its
WinRT worker can initialize and capture a real HWND. The generated test window
is placed at the bottom of the Z order with SWP_NOACTIVATE and is never focused.
"""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time


CREATE_NO_WINDOW = 0x08000000
CS_HREDRAW = 0x0002
CS_VREDRAW = 0x0001
HWND_BOTTOM = 1
SW_SHOWNOACTIVATE = 4
SWP_NOACTIVATE = 0x0010
SWP_SHOWWINDOW = 0x0040
WM_CLOSE = 0x0010
WM_DESTROY = 0x0002
WM_ERASEBKGND = 0x0014
WM_PAINT = 0x000F
WS_OVERLAPPEDWINDOW = 0x00CF0000


LRESULT = ctypes.c_ssize_t
WNDPROC = ctypes.WINFUNCTYPE(
    LRESULT, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM
)


class WNDCLASSW(ctypes.Structure):
    _fields_ = [
        ("style", wintypes.UINT),
        ("lpfnWndProc", WNDPROC),
        ("cbClsExtra", ctypes.c_int),
        ("cbWndExtra", ctypes.c_int),
        ("hInstance", wintypes.HINSTANCE),
        ("hIcon", wintypes.HICON),
        ("hCursor", wintypes.HANDLE),
        ("hbrBackground", wintypes.HBRUSH),
        ("lpszMenuName", wintypes.LPCWSTR),
        ("lpszClassName", wintypes.LPCWSTR),
    ]


class PAINTSTRUCT(ctypes.Structure):
    _fields_ = [
        ("hdc", wintypes.HDC),
        ("fErase", wintypes.BOOL),
        ("rcPaint", wintypes.RECT),
        ("fRestore", wintypes.BOOL),
        ("fIncUpdate", wintypes.BOOL),
        ("rgbReserved", ctypes.c_byte * 32),
    ]


class TestWindow:
    def __init__(self) -> None:
        self.hwnd = 0
        self.error: BaseException | None = None
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self._wndproc = WNDPROC(self._window_proc)

    def start(self) -> int:
        self.thread.start()
        if not self.ready.wait(10):
            raise RuntimeError("timed out creating the background WGC test window")
        if self.error is not None:
            raise RuntimeError(f"could not create the WGC test window: {self.error}")
        if not self.hwnd:
            raise RuntimeError("the WGC test window has no HWND")
        return self.hwnd

    def close(self) -> None:
        if self.hwnd:
            ctypes.windll.user32.PostMessageW(self.hwnd, WM_CLOSE, 0, 0)
        self.thread.join(timeout=5)
        if self.thread.is_alive():
            raise RuntimeError("the background WGC test window did not close")

    def _window_proc(self, hwnd: int, message: int, wparam: int, lparam: int) -> int:
        user32 = ctypes.windll.user32
        gdi32 = ctypes.windll.gdi32
        if message == WM_ERASEBKGND:
            return 1
        if message == WM_PAINT:
            paint = PAINTSTRUCT()
            dc = user32.BeginPaint(hwnd, ctypes.byref(paint))
            bounds = wintypes.RECT()
            user32.GetClientRect(hwnd, ctypes.byref(bounds))
            width = bounds.right - bounds.left
            colors = (0x2020E8, 0x20E820, 0xE82020)  # red, green, blue COLORREF
            for index, color in enumerate(colors):
                region = wintypes.RECT(
                    width * index // 3,
                    0,
                    width * (index + 1) // 3,
                    bounds.bottom,
                )
                brush = gdi32.CreateSolidBrush(color)
                user32.FillRect(dc, ctypes.byref(region), brush)
                gdi32.DeleteObject(brush)
            user32.EndPaint(hwnd, ctypes.byref(paint))
            return 0
        if message == WM_CLOSE:
            user32.DestroyWindow(hwnd)
            return 0
        if message == WM_DESTROY:
            user32.PostQuitMessage(0)
            return 0
        return user32.DefWindowProcW(hwnd, message, wparam, lparam)

    def _run(self) -> None:
        user32 = ctypes.windll.user32
        kernel32 = ctypes.windll.kernel32
        class_name = f"AuroraWgcRuntimeTest-{ctypes.windll.kernel32.GetCurrentProcessId()}"
        instance = kernel32.GetModuleHandleW(None)

        user32.RegisterClassW.argtypes = [ctypes.POINTER(WNDCLASSW)]
        user32.RegisterClassW.restype = wintypes.ATOM
        user32.DefWindowProcW.argtypes = [
            wintypes.HWND,
            wintypes.UINT,
            wintypes.WPARAM,
            wintypes.LPARAM,
        ]
        user32.DefWindowProcW.restype = LRESULT
        user32.CreateWindowExW.argtypes = [
            wintypes.DWORD,
            wintypes.LPCWSTR,
            wintypes.LPCWSTR,
            wintypes.DWORD,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            wintypes.HWND,
            wintypes.HMENU,
            wintypes.HINSTANCE,
            wintypes.LPVOID,
        ]
        user32.CreateWindowExW.restype = wintypes.HWND

        registered = False
        try:
            window_class = WNDCLASSW()
            window_class.style = CS_HREDRAW | CS_VREDRAW
            window_class.lpfnWndProc = self._wndproc
            window_class.hInstance = instance
            window_class.lpszClassName = class_name
            if not user32.RegisterClassW(ctypes.byref(window_class)):
                raise ctypes.WinError()
            registered = True
            hwnd = user32.CreateWindowExW(
                0,
                class_name,
                "Aurora WGC runtime test",
                WS_OVERLAPPEDWINDOW,
                20,
                20,
                640,
                360,
                None,
                None,
                instance,
                None,
            )
            if not hwnd:
                raise ctypes.WinError()
            self.hwnd = int(hwnd)
            user32.ShowWindow(hwnd, SW_SHOWNOACTIVATE)
            user32.SetWindowPos(
                hwnd,
                HWND_BOTTOM,
                20,
                20,
                640,
                360,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            )
            user32.UpdateWindow(hwnd)
            self.ready.set()
            message = wintypes.MSG()
            while user32.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
                user32.TranslateMessage(ctypes.byref(message))
                user32.DispatchMessageW(ctypes.byref(message))
        except BaseException as error:
            self.error = error
            self.ready.set()
        finally:
            self.hwnd = 0
            if registered:
                user32.UnregisterClassW(class_name, instance)


def ppm_pixels(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    position = 0

    def token() -> bytes:
        nonlocal position
        while position < len(data):
            if data[position : position + 1] == b"#":
                position = data.find(b"\n", position) + 1
            elif data[position : position + 1].isspace():
                position += 1
            else:
                break
        start = position
        while position < len(data) and not data[position : position + 1].isspace():
            position += 1
        return data[start:position]

    if token() != b"P6":
        raise RuntimeError("gfxcapture output is not a binary PPM frame")
    width = int(token())
    height = int(token())
    if int(token()) != 255:
        raise RuntimeError("gfxcapture PPM uses an unexpected component depth")
    if position >= len(data) or not data[position : position + 1].isspace():
        raise RuntimeError("gfxcapture PPM header is truncated")
    position += 1
    pixels = data[position:]
    if len(pixels) != width * height * 3:
        raise RuntimeError(
            f"gfxcapture PPM has {len(pixels)} bytes; expected {width * height * 3}"
        )
    return width, height, pixels


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ffmpeg", required=True, type=Path)
    parser.add_argument("--work-dir", type=Path)
    args = parser.parse_args()
    if not args.ffmpeg.is_file():
        raise RuntimeError(f"FFmpeg executable is missing: {args.ffmpeg}")

    temporary: tempfile.TemporaryDirectory[str] | None = None
    if args.work_dir is None:
        temporary = tempfile.TemporaryDirectory(prefix="aurora-wgc-runtime-")
        work_dir = Path(temporary.name)
    else:
        work_dir = args.work_dir.resolve()
        work_dir.mkdir(parents=True, exist_ok=True)
    output = work_dir / "gfxcapture-runtime.ppm"

    test_window = TestWindow()
    foreground_before = int(ctypes.windll.user32.GetForegroundWindow())
    hwnd = test_window.start()
    try:
        time.sleep(0.5)
        source = (
            f"gfxcapture=hwnd={hwnd}:capture_cursor=0:capture_border=0:"
            "display_border=0:max_framerate=5:output_fmt=bgra"
        )
        result = subprocess.run(
            [
                str(args.ffmpeg.resolve()),
                "-y",
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-f",
                "lavfi",
                "-i",
                source,
                "-vf",
                "hwdownload,format=bgra",
                "-frames:v",
                "1",
                "-c:v",
                "ppm",
                str(output),
            ],
            creationflags=CREATE_NO_WINDOW,
            capture_output=True,
            text=True,
            timeout=20,
        )
        if result.returncode != 0 or not output.is_file():
            raise RuntimeError(
                f"gfxcapture runtime failed with exit {result.returncode}: "
                + result.stderr.strip()
            )
        width, height, pixels = ppm_pixels(output)
        counts = {"red": 0, "green": 0, "blue": 0, "visible": 0}
        for offset in range(0, len(pixels), 3):
            red, green, blue = pixels[offset : offset + 3]
            if max(red, green, blue) > 64:
                counts["visible"] += 1
            if red > 160 and red > green * 2 and red > blue * 2:
                counts["red"] += 1
            if green > 160 and green > red * 2 and green > blue * 2:
                counts["green"] += 1
            if blue > 160 and blue > red * 2 and blue > green * 2:
                counts["blue"] += 1
        total = width * height
        if counts["visible"] < total * 0.80 or any(
            counts[color] < total * 0.20 for color in ("red", "green", "blue")
        ):
            raise RuntimeError(
                f"gfxcapture returned incomplete/incorrect pixels: {counts}, total={total}"
            )
        foreground_after = int(ctypes.windll.user32.GetForegroundWindow())
        if foreground_before == hwnd or foreground_after == hwnd:
            raise RuntimeError("the no-activation WGC test window became foreground")
        print(
            json.dumps(
                {
                    "status": "passed",
                    "hwnd": hwnd,
                    "width": width,
                    "height": height,
                    "pixels": counts,
                    "foreground_before": foreground_before,
                    "foreground_after": foreground_after,
                    "test_window_activated": False,
                },
                indent=2,
            )
        )
        return 0
    finally:
        test_window.close()
        if temporary is not None:
            temporary.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
