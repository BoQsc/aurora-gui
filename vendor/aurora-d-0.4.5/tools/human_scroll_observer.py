#!/usr/bin/env python3
"""Observe real human wheel input and foreground routing without injection."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
from pathlib import Path
import time


WH_MOUSE_LL = 14
WM_MOUSEWHEEL = 0x020A
WM_MOUSEHWHEEL = 0x020E
PM_REMOVE = 0x0001
GA_ROOT = 2
SB_VERT = 1
SIF_ALL = 0x0017


ULONG_PTR = wintypes.WPARAM
LRESULT = wintypes.LPARAM


class MouseHookStruct(ctypes.Structure):
    _fields_ = [
        ("point", wintypes.POINT),
        ("mouseData", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("extraInfo", ULONG_PTR),
    ]


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


def signed_high_word(value: int) -> int:
    return ctypes.c_short((value >> 16) & 0xFFFF).value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--target-pid", type=int, required=True)
    parser.add_argument("--activate", action="store_true")
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        import sys

        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    callback_type = ctypes.WINFUNCTYPE(
        LRESULT, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM
    )
    user32.SetWindowsHookExW.argtypes = (
        ctypes.c_int,
        callback_type,
        wintypes.HINSTANCE,
        wintypes.DWORD,
    )
    user32.SetWindowsHookExW.restype = wintypes.HHOOK
    user32.UnhookWindowsHookEx.argtypes = (wintypes.HHOOK,)
    user32.UnhookWindowsHookEx.restype = wintypes.BOOL
    user32.CallNextHookEx.argtypes = (
        wintypes.HHOOK,
        ctypes.c_int,
        wintypes.WPARAM,
        wintypes.LPARAM,
    )
    user32.CallNextHookEx.restype = LRESULT
    user32.PeekMessageW.argtypes = (
        ctypes.POINTER(wintypes.MSG),
        wintypes.HWND,
        wintypes.UINT,
        wintypes.UINT,
        wintypes.UINT,
    )
    user32.PeekMessageW.restype = wintypes.BOOL
    user32.TranslateMessage.argtypes = (ctypes.POINTER(wintypes.MSG),)
    user32.DispatchMessageW.argtypes = (ctypes.POINTER(wintypes.MSG),)
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.GetCursorPos.argtypes = (ctypes.POINTER(wintypes.POINT),)
    user32.GetCursorPos.restype = wintypes.BOOL
    user32.WindowFromPoint.argtypes = (wintypes.POINT,)
    user32.WindowFromPoint.restype = wintypes.HWND
    user32.GetAncestor.argtypes = (wintypes.HWND, wintypes.UINT)
    user32.GetAncestor.restype = wintypes.HWND
    user32.GetWindowThreadProcessId.argtypes = (
        wintypes.HWND,
        ctypes.POINTER(wintypes.DWORD),
    )
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.GetWindowTextLengthW.argtypes = (wintypes.HWND,)
    user32.GetWindowTextLengthW.restype = ctypes.c_int
    user32.GetWindowTextW.argtypes = (wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
    user32.GetWindowTextW.restype = ctypes.c_int
    enum_callback_type = ctypes.WINFUNCTYPE(
        wintypes.BOOL, wintypes.HWND, wintypes.LPARAM
    )
    user32.EnumWindows.argtypes = (enum_callback_type, wintypes.LPARAM)
    user32.EnumWindows.restype = wintypes.BOOL
    user32.GetScrollInfo.argtypes = (
        wintypes.HWND,
        ctypes.c_int,
        ctypes.POINTER(ScrollInfo),
    )
    user32.GetScrollInfo.restype = wintypes.BOOL

    def pid_of(hwnd: int) -> int:
        pid = wintypes.DWORD()
        if hwnd:
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        return pid.value

    def title_of(hwnd: int) -> str:
        if not hwnd:
            return ""
        length = user32.GetWindowTextLengthW(hwnd)
        buffer = ctypes.create_unicode_buffer(length + 1)
        user32.GetWindowTextW(hwnd, buffer, len(buffer))
        return buffer.value

    activated_hwnd = 0
    if args.activate:
        matches: list[int] = []

        @enum_callback_type
        def collect_target(hwnd: int, _: int) -> bool:
            if pid_of(hwnd) == args.target_pid and user32.IsWindowVisible(hwnd):
                matches.append(hwnd)
            return True

        user32.EnumWindows(collect_target, 0)
        if matches:
            activated_hwnd = matches[0]
            user32.ShowWindow(activated_hwnd, 9)
            user32.BringWindowToTop(activated_hwnd)
            user32.SetForegroundWindow(activated_hwnd)

    started = time.monotonic()
    lines: list[str] = []
    wheel_events = 0
    target_foreground_samples = 0
    target_hover_samples = 0
    scroll_changes = 0
    target_hwnd = activated_hwnd
    last_scroll_position: int | None = None
    last_state: tuple[int, int] | None = None

    def record(kind: str, text: str) -> None:
        elapsed = time.monotonic() - started
        line = f"{elapsed:7.3f} {kind} {text}"
        lines.append(line)
        print(line, flush=True)

    hook_handle = wintypes.HHOOK()

    @callback_type
    def hook_callback(code: int, message: int, data: int) -> int:
        nonlocal wheel_events
        if code >= 0 and message in (WM_MOUSEWHEEL, WM_MOUSEHWHEEL):
            wheel_events += 1
            info = ctypes.cast(data, ctypes.POINTER(MouseHookStruct)).contents
            under = user32.GetAncestor(user32.WindowFromPoint(info.point), GA_ROOT)
            foreground = user32.GetForegroundWindow()
            record(
                "WHEEL",
                f"delta={signed_high_word(info.mouseData)} "
                f"cursor=({info.point.x},{info.point.y}) "
                f"under_pid={pid_of(under)} under='{title_of(under)}' "
                f"foreground_pid={pid_of(foreground)} "
                f"foreground='{title_of(foreground)}'",
            )
        return user32.CallNextHookEx(hook_handle, code, message, data)

    hook_handle = user32.SetWindowsHookExW(WH_MOUSE_LL, hook_callback, None, 0)
    if not hook_handle:
        record("HOOK", f"installation failed winerror={ctypes.get_last_error()}")
    else:
        record("HOOK", "installed")

    record("START", f"target_pid={args.target_pid} duration={args.duration:.1f}s")
    deadline = started + args.duration
    message = wintypes.MSG()
    try:
        while time.monotonic() < deadline:
            while user32.PeekMessageW(
                ctypes.byref(message), None, 0, 0, PM_REMOVE
            ):
                user32.TranslateMessage(ctypes.byref(message))
                user32.DispatchMessageW(ctypes.byref(message))

            foreground = user32.GetForegroundWindow()
            cursor = wintypes.POINT()
            user32.GetCursorPos(ctypes.byref(cursor))
            under = user32.GetAncestor(user32.WindowFromPoint(cursor), GA_ROOT)
            foreground_pid = pid_of(foreground)
            under_pid = pid_of(under)
            if foreground_pid == args.target_pid:
                target_foreground_samples += 1
                target_hwnd = foreground
            if under_pid == args.target_pid:
                target_hover_samples += 1
                target_hwnd = under
            state = (foreground, under)
            if state != last_state:
                record(
                    "STATE",
                    f"cursor=({cursor.x},{cursor.y}) "
                    f"under_pid={under_pid} under='{title_of(under)}' "
                    f"foreground_pid={foreground_pid} "
                    f"foreground='{title_of(foreground)}'",
                )
                last_state = state
            if target_hwnd:
                scroll_info = ScrollInfo(ctypes.sizeof(ScrollInfo), SIF_ALL)
                if user32.GetScrollInfo(
                    target_hwnd, SB_VERT, ctypes.byref(scroll_info)
                ):
                    if last_scroll_position is None:
                        last_scroll_position = scroll_info.nPos
                        record(
                            "SCROLLINFO",
                            f"position={scroll_info.nPos} max={scroll_info.nMax} "
                            f"page={scroll_info.nPage}",
                        )
                    elif scroll_info.nPos != last_scroll_position:
                        scroll_changes += 1
                        record(
                            "SCROLL",
                            f"position={scroll_info.nPos} "
                            f"delta={scroll_info.nPos - last_scroll_position}",
                        )
                        last_scroll_position = scroll_info.nPos
            time.sleep(0.01)
    finally:
        if hook_handle:
            user32.UnhookWindowsHookEx(hook_handle)

    scroll_lines: list[str] = []
    if args.trace is not None and args.trace.exists():
        scroll_lines = args.trace.read_text(
            encoding="utf-8", errors="replace"
        ).splitlines()
    record(
        "SUMMARY",
        f"wheel_hook_events={wheel_events} "
        f"target_hover_samples={target_hover_samples} "
        f"target_foreground_samples={target_foreground_samples} "
        f"native_scroll_changes={scroll_changes} "
        f"native_scroll_position={last_scroll_position} "
        f"aurora_scroll_trace_lines={len(scroll_lines)}",
    )
    if scroll_lines:
        record("SCROLL", f"first='{scroll_lines[0]}' last='{scroll_lines[-1]}'")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
