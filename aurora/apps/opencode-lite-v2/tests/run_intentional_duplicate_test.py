#!/usr/bin/env python3
"""Verify intentional instance groups may run in parallel."""
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
HOST = APP / "build" / "aurora-opencode-lite-v2-host.exe"
SCENE = APP / "assets" / "lite.scene.json"
TITLE = "Aurora Intentional Duplicate Test"
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


def wait_for_windows(title: str, count: int, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if len(window_handles(title)) == count:
            return
        time.sleep(0.05)
    raise RuntimeError(
        f"expected {count} windows named {title!r}, got {len(window_handles(title))}")


def main() -> int:
    if not HOST.is_file() or not SCENE.is_file():
        raise RuntimeError("build the host-lite executable first")
    temp = Path(tempfile.mkdtemp(prefix="aurora-intentional-duplicate-"))
    scene_path = temp / "duplicate.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    base = [str(HOST), "--no-plugin", "--no-activate", "--scene", str(scene_path)]
    first = subprocess.Popen(base + ["--instance-group", "duplicate-a"],
                             cwd=str(APP), env=environment,
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    second = None
    try:
        wait_for_windows(TITLE, 1)
        second = subprocess.Popen(base + ["--instance-group", "duplicate-b"],
                                  cwd=str(APP), env=environment,
                                  stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL)
        wait_for_windows(TITLE, 2)
        if first.poll() is not None or second.poll() is not None:
            raise RuntimeError("an intentional duplicate exited unexpectedly")
        print("intentional duplicate policy passed: two grouped instances")
        return 0
    finally:
        for process in (second, first):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()


if __name__ == "__main__":
    raise SystemExit(main())
