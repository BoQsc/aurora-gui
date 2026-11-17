#!/usr/bin/env python3
"""Run the Vulkan marching-cubes presenter inside an aurora-host window."""
from __future__ import annotations

import ctypes
from ctypes import wintypes
from pathlib import Path
import subprocess
import sys
import time

from PIL import ImageGrab

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOST_EXE = HOST / "aurora-host.exe"
APP_EXE = PROJECT / "build" / "marching-cubes-gpu.exe"
SHADERS = PROJECT / "shaders3d"
TITLE = "Marching Cubes GPU"
TITLEBAR = 32

sys.path.insert(0, str(HOST / "tools"))


def scene_document() -> dict:
    return {
        "schemaVersion": 2,
        "window": {
            "title": TITLE,
            "width": 360,
            "height": 272,
            "decorated": False,
        },
        "root": {
            "type": "column",
            "width": 360,
            "height": 272,
            "background": "#0b1220",
            "spacing": 0,
            "padding": 0,
            "children": [
                {
                    "id": "titlebar",
                    "type": "titleBar",
                    "text": TITLE,
                    "height": TITLEBAR,
                    "background": "#0b1220",
                    "border": "#1e293b",
                    "textColor": "#e2e8f0",
                },
            ],
        }
    }


def find_window(title: str) -> int | None:
    user32 = ctypes.windll.user32
    found: list[int] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def callback(hwnd, _):
        if not user32.IsWindowVisible(hwnd):
            return True
        size = user32.GetWindowTextLengthW(hwnd)
        text = ctypes.create_unicode_buffer(size + 1)
        user32.GetWindowTextW(hwnd, text, size + 1)
        if text.value == title:
            found.append(int(hwnd))
            return False
        return True

    user32.EnumWindows(callback, 0)
    return found[0] if found else None


def main() -> int:
    if not HOST_EXE.is_file():
        raise SystemExit(f"missing host: {HOST_EXE}")
    if not APP_EXE.is_file():
        raise SystemExit(f"missing GPU app: {APP_EXE}")
    if not SHADERS.is_dir():
        raise SystemExit(f"missing shaders: {SHADERS}")
    import json

    scene = PROJECT / "build" / "gpu.scene.json"
    scene.parent.mkdir(parents=True, exist_ok=True)
    scene.write_text(json.dumps(scene_document()), encoding="utf-8")

    from host_session import Host

    host = Host(scene, exe=HOST_EXE)
    app = None
    try:
        deadline = time.monotonic() + 5
        hwnd = None
        while time.monotonic() < deadline:
            hwnd = find_window(TITLE)
            if hwnd is not None:
                break
            time.sleep(0.05)
        if hwnd is None:
            raise RuntimeError("host window was not found")
        app = subprocess.Popen(
            [
                str(APP_EXE),
                "--shaders", str(SHADERS),
                "--host-title", TITLE,
                "--time", "3",
            ],
            cwd=str(PROJECT),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
        )
        time.sleep(1.4)
        user32 = ctypes.windll.user32
        user32.SetForegroundWindow(hwnd)
        time.sleep(0.2)
        rect = wintypes.RECT()
        user32.GetWindowRect(hwnd, ctypes.byref(rect))
        shot = PROJECT / "build" / "gpu-marching-cubes.png"
        image = ImageGrab.grab(
            bbox=(rect.left, rect.top, rect.right, rect.bottom))
        image.save(shot)
        colors = image.convert("RGB").getcolors(maxcolors=100000)
        if colors is None or len(colors) < 20:
            raise RuntimeError("GPU host capture is blank or flat")
        output, _ = app.communicate(timeout=20)
        print(output, end="")
        if app.returncode != 0:
            raise RuntimeError(f"GPU app failed: {output}")
        print(f"PASS Vulkan marching cubes in host shot={shot}")
        return 0
    finally:
        if app is not None and app.poll() is None:
            app.kill()
            app.wait(timeout=5)
        host.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL Vulkan marching cubes: {error}", file=sys.stderr)
        raise SystemExit(1)
