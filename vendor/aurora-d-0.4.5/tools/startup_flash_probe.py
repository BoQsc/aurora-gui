#!/usr/bin/env python3
"""Detect a forbidden full-client color during Win32 application startup."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import subprocess
import sys
import time


WM_CLOSE = 0x0010
BI_RGB = 0
DIB_RGB_COLORS = 0
COLORONCOLOR = 3
SRCCOPY = 0x00CC0020


class BitmapInfoHeader(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD),
        ("biWidth", wintypes.LONG),
        ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD),
        ("biBitCount", wintypes.WORD),
        ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD),
        ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG),
        ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    ]


class RgbQuad(ctypes.Structure):
    _fields_ = [
        ("rgbBlue", wintypes.BYTE),
        ("rgbGreen", wintypes.BYTE),
        ("rgbRed", wintypes.BYTE),
        ("rgbReserved", wintypes.BYTE),
    ]


class BitmapInfo(ctypes.Structure):
    _fields_ = [("bmiHeader", BitmapInfoHeader), ("bmiColors", RgbQuad * 1)]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sample a Win32 client area from its first visible instant.")
    parser.add_argument("executable", type=Path)
    parser.add_argument("--title", default="Aurora OpenCode")
    parser.add_argument("--renderer", choices=("automatic", "software", "vulkan"),
                        default="vulkan")
    parser.add_argument("--duration", type=float, default=0.75)
    parser.add_argument("--startup-timeout", type=float, default=15.0)
    parser.add_argument("--interval-ms", type=float, default=1.0)
    parser.add_argument("--forbidden-color", default="ffffff",
                        help="RGB hex color that must not fill the client area")
    parser.add_argument("--tolerance", type=int, default=10)
    parser.add_argument("--max-fraction", type=float, default=0.80)
    parser.add_argument("--columns", type=int, default=12)
    parser.add_argument("--rows", type=int, default=8)
    return parser.parse_args()


def parse_rgb(value: str) -> tuple[int, int, int]:
    normalized = value.removeprefix("#")
    if len(normalized) != 6:
        raise ValueError("forbidden color must contain exactly six hexadecimal digits")
    encoded = int(normalized, 16)
    return ((encoded >> 16) & 0xFF, (encoded >> 8) & 0xFF, encoded & 0xFF)


def main() -> int:
    if os.name != "nt":
        raise SystemExit("startup_flash_probe.py requires Windows")
    args = parse_arguments()
    executable = args.executable.resolve()
    if not executable.is_file():
        raise SystemExit(f"Executable not found: {executable}")
    if args.duration <= 0 or args.interval_ms < 0:
        raise SystemExit("duration must be positive and interval-ms cannot be negative")
    if args.columns <= 0 or args.rows <= 0:
        raise SystemExit("columns and rows must be positive")
    if not 0.0 <= args.max_fraction <= 1.0:
        raise SystemExit("max-fraction must be between zero and one")

    try:
        forbidden = parse_rgb(args.forbidden_color)
    except ValueError as error:
        raise SystemExit(str(error)) from error

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
    enum_callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = (enum_callback, wintypes.LPARAM)
    user32.EnumWindows.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = (
        wintypes.HWND, ctypes.POINTER(wintypes.DWORD))
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.GetWindowTextLengthW.argtypes = (wintypes.HWND,)
    user32.GetWindowTextLengthW.restype = ctypes.c_int
    user32.GetWindowTextW.argtypes = (
        wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
    user32.GetWindowTextW.restype = ctypes.c_int
    user32.IsWindowVisible.argtypes = (wintypes.HWND,)
    user32.IsWindowVisible.restype = wintypes.BOOL
    user32.GetClientRect.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.RECT))
    user32.GetClientRect.restype = wintypes.BOOL
    user32.ClientToScreen.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.POINT))
    user32.ClientToScreen.restype = wintypes.BOOL
    user32.GetDC.argtypes = (wintypes.HWND,)
    user32.GetDC.restype = wintypes.HDC
    user32.ReleaseDC.argtypes = (wintypes.HWND, wintypes.HDC)
    user32.ReleaseDC.restype = ctypes.c_int
    user32.SendMessageW.argtypes = (
        wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)
    user32.SendMessageW.restype = ctypes.c_ssize_t
    gdi32.CreateCompatibleDC.argtypes = (wintypes.HDC,)
    gdi32.CreateCompatibleDC.restype = wintypes.HDC
    gdi32.CreateDIBSection.argtypes = (
        wintypes.HDC, ctypes.POINTER(BitmapInfo), wintypes.UINT,
        ctypes.POINTER(ctypes.c_void_p), wintypes.HANDLE, wintypes.DWORD)
    gdi32.CreateDIBSection.restype = wintypes.HANDLE
    gdi32.SelectObject.argtypes = (wintypes.HDC, wintypes.HANDLE)
    gdi32.SelectObject.restype = wintypes.HANDLE
    gdi32.SetStretchBltMode.argtypes = (wintypes.HDC, ctypes.c_int)
    gdi32.SetStretchBltMode.restype = ctypes.c_int
    gdi32.StretchBlt.argtypes = (
        wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
        wintypes.DWORD)
    gdi32.StretchBlt.restype = wintypes.BOOL
    gdi32.DeleteObject.argtypes = (wintypes.HANDLE,)
    gdi32.DeleteObject.restype = wintypes.BOOL
    gdi32.DeleteDC.argtypes = (wintypes.HDC,)
    gdi32.DeleteDC.restype = wintypes.BOOL

    # Match Aurora's per-monitor-v2 coordinate space when the API is available.
    try:
        user32.SetProcessDpiAwarenessContext(
            ctypes.c_void_p(ctypes.c_ssize_t(-4).value))
    except (AttributeError, OSError):
        pass

    process_env = os.environ.copy()
    if args.renderer == "automatic":
        process_env.pop("AURORA_RENDERER", None)
    else:
        process_env["AURORA_RENDERER"] = args.renderer
    process = subprocess.Popen(
        [str(executable)], cwd=str(executable.parent), env=process_env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    hwnd: int | None = None
    sampled_frames = 0
    invalid_samples = 0
    maximum_fraction = 0.0
    first_fraction: float | None = None
    first_visible_ms: float | None = None
    started = time.perf_counter()
    deadline = time.monotonic() + args.startup_timeout
    try:
        while time.monotonic() < deadline and process.poll() is None:
            candidates: list[tuple[int, str]] = []

            @enum_callback
            def collect(window: int, _parameter: int) -> bool:
                owner = wintypes.DWORD()
                user32.GetWindowThreadProcessId(window, ctypes.byref(owner))
                if owner.value != process.pid:
                    return True
                length = user32.GetWindowTextLengthW(window)
                buffer = ctypes.create_unicode_buffer(length + 1)
                user32.GetWindowTextW(window, buffer, len(buffer))
                candidates.append((window, buffer.value))
                return True

            user32.EnumWindows(collect, 0)
            for candidate, title in candidates:
                if ((not args.title or args.title.casefold() in title.casefold()) and
                        user32.IsWindowVisible(candidate)):
                    hwnd = candidate
                    break
            if hwnd is not None:
                first_visible_ms = (time.perf_counter() - started) * 1000.0
                break
            time.sleep(0.0005)

        if hwnd is None:
            raise RuntimeError("no matching visible window appeared before the timeout")

        sample_deadline = time.perf_counter() + args.duration
        screen_dc = user32.GetDC(None)
        if not screen_dc:
            raise ctypes.WinError(ctypes.get_last_error())
        sample_dc = gdi32.CreateCompatibleDC(screen_dc)
        if not sample_dc:
            user32.ReleaseDC(None, screen_dc)
            raise ctypes.WinError(ctypes.get_last_error())
        bitmap_info = BitmapInfo()
        bitmap_info.bmiHeader.biSize = ctypes.sizeof(BitmapInfoHeader)
        bitmap_info.bmiHeader.biWidth = args.columns
        bitmap_info.bmiHeader.biHeight = -args.rows
        bitmap_info.bmiHeader.biPlanes = 1
        bitmap_info.bmiHeader.biBitCount = 32
        bitmap_info.bmiHeader.biCompression = BI_RGB
        sample_bits = ctypes.c_void_p()
        sample_bitmap = gdi32.CreateDIBSection(
            screen_dc, ctypes.byref(bitmap_info), DIB_RGB_COLORS,
            ctypes.byref(sample_bits), None, 0)
        if not sample_bitmap or not sample_bits.value:
            gdi32.DeleteDC(sample_dc)
            user32.ReleaseDC(None, screen_dc)
            raise ctypes.WinError(ctypes.get_last_error())
        previous_bitmap = gdi32.SelectObject(sample_dc, sample_bitmap)
        gdi32.SetStretchBltMode(sample_dc, COLORONCOLOR)
        pixels = (ctypes.c_uint32 * (args.columns * args.rows)).from_address(
            sample_bits.value)
        try:
            while time.perf_counter() < sample_deadline and process.poll() is None:
                rect = wintypes.RECT()
                origin = wintypes.POINT(0, 0)
                if (not user32.GetClientRect(hwnd, ctypes.byref(rect)) or
                        not user32.ClientToScreen(hwnd, ctypes.byref(origin))):
                    invalid_samples += 1
                    continue
                width = rect.right - rect.left
                height = rect.bottom - rect.top
                if width <= 0 or height <= 0:
                    invalid_samples += 1
                    continue

                if not gdi32.StretchBlt(
                        sample_dc, 0, 0, args.columns, args.rows,
                        screen_dc, origin.x, origin.y, width, height, SRCCOPY):
                    invalid_samples += 1
                    continue
                matches = 0
                for color in pixels:
                    blue = color & 0xFF
                    green = (color >> 8) & 0xFF
                    red = (color >> 16) & 0xFF
                    if (abs(red - forbidden[0]) <= args.tolerance and
                            abs(green - forbidden[1]) <= args.tolerance and
                            abs(blue - forbidden[2]) <= args.tolerance):
                        matches += 1
                valid = len(pixels)
                fraction = matches / valid
                if first_fraction is None:
                    first_fraction = fraction
                maximum_fraction = max(maximum_fraction, fraction)
                sampled_frames += 1
                if args.interval_ms > 0:
                    time.sleep(args.interval_ms / 1000.0)
        finally:
            if previous_bitmap:
                gdi32.SelectObject(sample_dc, previous_bitmap)
            gdi32.DeleteObject(sample_bitmap)
            gdi32.DeleteDC(sample_dc)
            user32.ReleaseDC(None, screen_dc)

        if sampled_frames == 0:
            raise RuntimeError("the visible client area produced no valid samples")
        print(f"renderer={args.renderer}")
        print(f"first_visible_ms={first_visible_ms:.3f}")
        print(f"sampled_frames={sampled_frames}")
        print(f"invalid_samples={invalid_samples}")
        print(f"first_forbidden_fraction={first_fraction:.6f}")
        print(f"max_forbidden_fraction={maximum_fraction:.6f}")
        if maximum_fraction > args.max_fraction:
            print("forbidden startup color filled the client area", file=sys.stderr)
            return 1
        return 0
    finally:
        if hwnd is not None:
            user32.SendMessageW(hwnd, WM_CLOSE, 0, 0)
        try:
            process.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5.0)
        output = process.stdout.read() if process.stdout is not None else ""
        if process.returncode not in (0, None) and output:
            print(output, file=sys.stderr, end="")


if __name__ == "__main__":
    raise SystemExit(main())
