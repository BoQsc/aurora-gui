#!/usr/bin/env python3
"""Measure how long native Win32 resize messages block the caller/UI thread."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import math
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time


WM_CLOSE = 0x0010
WM_NULL = 0x0000
WM_ENTERSIZEMOVE = 0x0231
WM_EXITSIZEMOVE = 0x0232
SWP_NOMOVE = 0x0002
SWP_NOZORDER = 0x0004
SWP_NOACTIVATE = 0x0010


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("--title", default="")
    parser.add_argument("--iterations", type=int, default=120)
    parser.add_argument("--renderer", choices=("automatic", "vulkan", "software"),
                        default="vulkan")
    parser.add_argument("--startup-timeout", type=float, default=10.0)
    parser.add_argument("--step-delay", type=float, default=0.002,
                        help="Seconds between native size changes")
    parser.add_argument("--settle-iterations", type=int, default=60,
                        help="Responsiveness samples after resize ends")
    parser.add_argument("--profile-frame", action="store_true")
    return parser.parse_args()


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1))
    return ordered[index]


def main() -> int:
    if sys.platform != "win32":
        raise SystemExit("This probe uses the Win32 window-sizing API.")
    args = parse_args()
    executable = args.executable.resolve()
    if not executable.is_file():
        raise SystemExit(f"Executable not found: {executable}")

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    enum_callback = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows.argtypes = (enum_callback, wintypes.LPARAM)
    user32.EnumWindows.restype = wintypes.BOOL
    user32.GetWindowThreadProcessId.argtypes = (wintypes.HWND,
                                                 ctypes.POINTER(wintypes.DWORD))
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.GetWindowTextLengthW.argtypes = (wintypes.HWND,)
    user32.GetWindowTextLengthW.restype = ctypes.c_int
    user32.GetWindowTextW.argtypes = (wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
    user32.GetWindowTextW.restype = ctypes.c_int
    user32.IsWindowVisible.argtypes = (wintypes.HWND,)
    user32.IsWindowVisible.restype = wintypes.BOOL
    user32.SetWindowPos.argtypes = (wintypes.HWND, wintypes.HWND, ctypes.c_int,
                                    ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                    wintypes.UINT)
    user32.SetWindowPos.restype = wintypes.BOOL
    user32.SendMessageW.argtypes = (wintypes.HWND, wintypes.UINT,
                                    wintypes.WPARAM, wintypes.LPARAM)
    user32.SendMessageW.restype = ctypes.c_ssize_t

    process_env = os.environ.copy()
    if args.renderer == "automatic":
        process_env.pop("AURORA_RENDERER", None)
    else:
        process_env["AURORA_RENDERER"] = args.renderer
    if args.profile_frame:
        process_env["AURORA_RESIZE_PROFILE"] = "1"
    process = subprocess.Popen([str(executable)], cwd=str(executable.parent),
                               env=process_env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    hwnd: int | None = None
    deadline = time.monotonic() + args.startup_timeout
    try:
        while time.monotonic() < deadline and process.poll() is None:
            candidates: list[tuple[int, str]] = []

            @enum_callback
            def collect(window: int, _: int) -> bool:
                pid = wintypes.DWORD()
                user32.GetWindowThreadProcessId(window, ctypes.byref(pid))
                if pid.value != process.pid or not user32.IsWindowVisible(window):
                    return True
                length = user32.GetWindowTextLengthW(window)
                buffer = ctypes.create_unicode_buffer(length + 1)
                user32.GetWindowTextW(window, buffer, len(buffer))
                candidates.append((window, buffer.value))
                return True

            user32.EnumWindows(collect, 0)
            for candidate, title in candidates:
                if not args.title or args.title.casefold() in title.casefold():
                    hwnd = candidate
                    break
            if hwnd is not None:
                break
            time.sleep(0.025)
        if hwnd is None:
            raise RuntimeError("The application did not create a matching visible window")

        time.sleep(0.5)
        user32.SendMessageW(hwnd, WM_ENTERSIZEMOVE, 0, 0)
        measurements: list[float] = []
        flags = SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE
        for index in range(max(1, args.iterations)):
            width = 760 + (index % 24) * 13
            height = 480 + (index % 17) * 9
            started = time.perf_counter()
            if not user32.SetWindowPos(hwnd, None, 0, 0, width, height, flags):
                raise ctypes.WinError(ctypes.get_last_error())
            measurements.append((time.perf_counter() - started) * 1000.0)
            time.sleep(max(0.0, args.step_delay))
        user32.SendMessageW(hwnd, WM_EXITSIZEMOVE, 0, 0)
        settle_measurements: list[float] = []
        for _ in range(max(0, args.settle_iterations)):
            started = time.perf_counter()
            user32.SendMessageW(hwnd, WM_NULL, 0, 0)
            settle_measurements.append((time.perf_counter() - started) * 1000.0)
            time.sleep(0.005)
        if args.profile_frame:
            profile_deadline = time.monotonic() + 5.0
            while time.monotonic() < profile_deadline:
                length = user32.GetWindowTextLengthW(hwnd)
                buffer = ctypes.create_unicode_buffer(length + 1)
                user32.GetWindowTextW(hwnd, buffer, len(buffer))
                if "[resize-profile" in buffer.value:
                    print(buffer.value[buffer.value.index("[resize-profile"):])
                    break
                time.sleep(0.01)
        print(f"renderer={args.renderer} iterations={len(measurements)}")
        print(f"median_ms={statistics.median(measurements):.3f}")
        print(f"p95_ms={percentile(measurements, 0.95):.3f}")
        print(f"max_ms={max(measurements):.3f}")
        print(f"over_16ms={sum(value > 16.0 for value in measurements)}")
        print(f"over_50ms={sum(value > 50.0 for value in measurements)}")
        if settle_measurements:
            print(f"settle_p95_ms={percentile(settle_measurements, 0.95):.3f}")
            print(f"settle_max_ms={max(settle_measurements):.3f}")
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
