#!/usr/bin/env python3
"""Launch the Vulkan child presenter inside aurora-host and capture it."""
from __future__ import annotations

from pathlib import Path
import ctypes
from ctypes import wintypes
import json
import subprocess
import sys
import time

from PIL import ImageGrab

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOST_EXE = HOST / "aurora-host.exe"
SHADERS = PROJECT / "shaders3d"
sys.path.insert(0, str(HOST / "tools"))
from host_session import Host  # noqa: E402

TITLE = "Aurora InHost 3D"
WIDTH = 360
HEIGHT = 240
TITLEBAR = 32


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def scene_document() -> dict:
    return {
        "schemaVersion": 2,
        "window": {
            "title": TITLE,
            "width": WIDTH,
            "height": HEIGHT + TITLEBAR,
            "decorated": False,
        },
        "root": {
            "id": "root",
            "type": "column",
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
        },
    }


def find_window(title: str) -> int | None:
    user32 = ctypes.windll.user32

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

    found: list[int] = []
    user32.EnumWindows(callback, 0)
    return found[0] if found else None


def capture(hwnd: int, path: Path) -> None:
    user32 = ctypes.windll.user32
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.3)
    image = ImageGrab.grab(bbox=(rect.left, rect.top, rect.right, rect.bottom))
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    colors = image.convert("RGB").getcolors(maxcolors=100000)
    require(colors is not None and len(colors) > 20,
            "host capture is blank or flat")


def main() -> int:
    require(HOST_EXE.is_file(), f"missing host: {HOST_EXE}")
    require((PROJECT / "build" / "vulkan3d.exe").is_file(),
            "missing build/vulkan3d.exe")
    scene = PROJECT / "build" / "vulkan-inhost.scene.json"
    scene.parent.mkdir(parents=True, exist_ok=True)
    scene.write_text(json.dumps(scene_document()), encoding="utf-8")
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
        require(hwnd is not None, "host window was not found")
        app = subprocess.Popen(
            [
                str(PROJECT / "build" / "vulkan3d.exe"),
                "--shaders", str(SHADERS),
                "--host-title", TITLE,
                "--seconds", "3",
            ],
            cwd=str(PROJECT), stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True, encoding="utf-8")
        time.sleep(1.2)
        shot = PROJECT / "build" / "vulkan-inhost.png"
        capture(hwnd, shot)
        output, _ = app.communicate(timeout=15)
        require(app.returncode == 0,
                f"child presenter failed: {output}")
        require("PASS Vulkan 3D child swapchain" in output,
                f"missing pass line: {output}")
        print(f"PASS Vulkan 3D child swapchain in host "
              f"hostPid={host.process.pid} appPid={app.pid} shot={shot}")
    finally:
        if app is not None and app.poll() is None:
            app.kill()
            app.wait(timeout=5)
        host.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
