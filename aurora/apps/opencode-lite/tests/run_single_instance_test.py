#!/usr/bin/env python3
"""Verify a second app launch activates the existing single window instead of duplicating it."""
from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from ctypes import wintypes

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-host.exe"
SCENE = APP / "assets" / "lite.scene.json"
TITLE = "Aurora Single Instance Test"

user32 = ctypes.WinDLL("user32", use_last_error=True)


def window_handles(title: str) -> list[int]:
    found: list[int] = []
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND,
                                        wintypes.LPARAM)

    def visit(hwnd, _):
        length = user32.GetWindowTextLengthW(hwnd)
        if length:
            buffer = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buffer, length + 1)
            if buffer.value == title and user32.IsWindowVisible(hwnd):
                found.append(hwnd)
        return True

    user32.EnumWindows(callback_type(visit), 0)
    return found


def wait_for_window(title: str, timeout: float = 15.0) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        windows = window_handles(title)
        if windows:
            return windows[0]
        time.sleep(0.05)
    raise RuntimeError(f"window did not open: {title}")


def main() -> int:
    if not HOST.is_file() or not SCENE.is_file():
        raise RuntimeError("build the host-lite executable first")
    temp = Path(tempfile.mkdtemp(prefix="aurora-single-instance-"))
    scene_path = temp / "single-instance.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    command = [str(HOST), "--no-plugin", "--no-activate",
               "--scene", str(scene_path)]
    first = subprocess.Popen(command, cwd=str(APP), env=environment,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    second = None
    try:
        first_window = wait_for_window(TITLE)
        second = subprocess.Popen(command, cwd=str(APP), env=environment,
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        try:
            second.wait(timeout=8)
        except subprocess.TimeoutExpired:
            raise RuntimeError("second launch opened another instance")
        if first.poll() is not None:
            raise RuntimeError("first host exited during duplicate launch")
        windows = window_handles(TITLE)
        if len(windows) != 1 or windows[0] != first_window:
            raise RuntimeError(
                f"duplicate window opened: window count={len(windows)}")
        print("single-instance policy passed: duplicate launch activated one window")
        return 0
    finally:
        if second is not None and second.poll() is None:
            second.kill()
            second.wait(timeout=5)
        if first.poll() is None:
            first.terminate()
            try:
                first.wait(timeout=5)
            except subprocess.TimeoutExpired:
                first.kill()


if __name__ == "__main__":
    raise SystemExit(main())
