#!/usr/bin/env python3
"""Verify an unexpected host exit leaves a diagnostic run state."""
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
TITLE = "Aurora Run Journal Test"
GROUP = "journal-test"
user32 = ctypes.WinDLL("user32", use_last_error=True)


def window_open(title: str) -> bool:
    found = False
    callback_type = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND,
                                        wintypes.LPARAM)

    def visit(hwnd, _):
        nonlocal found
        length = user32.GetWindowTextLengthW(hwnd)
        if length:
            buffer = ctypes.create_unicode_buffer(length + 1)
            user32.GetWindowTextW(hwnd, buffer, length + 1)
            if buffer.value == title and user32.IsWindowVisible(hwnd):
                found = True
        return True

    user32.EnumWindows(callback_type(visit), 0)
    return found


def wait_for_window(title: str, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if window_open(title):
            return
        time.sleep(0.05)
    raise RuntimeError(f"window did not open: {title}")


def run_state(temp: Path) -> dict:
    path = temp / f"AuroraOpenCodeLite-{GROUP}" / "run-state.json"
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def start(environment: dict[str, str], scene: Path):
    return subprocess.Popen(
        [str(HOST), "--no-plugin", "--no-activate",
         "--instance-group", GROUP, "--scene", str(scene)],
        cwd=str(APP), env=environment, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)


def main() -> int:
    if not HOST.is_file() or not SCENE.is_file():
        raise RuntimeError("build the host-lite executable first")
    temp = Path(tempfile.mkdtemp(prefix="aurora-run-journal-"))
    scene_path = temp / "journal.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    first = start(environment, scene_path)
    second = None
    try:
        wait_for_window(TITLE)
        first.terminate()
        first.wait(timeout=5)
        after_crash = run_state(temp)
        if after_crash.get("status") != "running":
            raise RuntimeError(f"unexpected run state after crash: {after_crash}")
        second = start(environment, scene_path)
        wait_for_window(TITLE)
        after_relaunch = run_state(temp)
        if not after_relaunch.get("previousUnclean"):
            raise RuntimeError(
                f"relaunch did not report unclean previous run: {after_relaunch}")
        print("run-journal policy passed: unexpected exit detected on relaunch")
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
