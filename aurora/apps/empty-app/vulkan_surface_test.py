#!/usr/bin/env python3
"""Render a true Vulkan 3D frame into AURSFACE and show it in aurora-host."""
from __future__ import annotations

from pathlib import Path
import json
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOST_EXE = HOST / "aurora-host.exe"
SHADERS = PROJECT / "shaders3d"
sys.path.insert(0, str(HOST / "tools"))
from host_session import Host  # noqa: E402

WIDTH = 360
HEIGHT = 240
TITLEBAR = 32


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def scene_document(surface: Path) -> dict:
    return {
        "schemaVersion": 2,
        "window": {
            "title": "Vulkan 3D Readback",
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
                    "text": "Vulkan 3D Readback",
                    "height": TITLEBAR,
                    "background": "#0b1220",
                    "border": "#1e293b",
                    "textColor": "#e2e8f0",
                },
                {
                    "id": "view",
                    "type": "surface",
                    "path": str(surface),
                    "width": WIDTH,
                    "height": HEIGHT,
                    "staleMs": 2000,
                    "events": [],
                },
            ],
        },
    }


def wait_surface(host: Host) -> None:
    deadline = time.monotonic() + 10
    last = None
    while time.monotonic() < deadline:
        last = host.request("surface", node="view")
        if last.get("mapped") and last.get("sequence", 0) > 0:
            return
        time.sleep(0.02)
    raise RuntimeError(f"surface not mapped: {last!r}")


def ppm_nonblank(path: Path) -> bool:
    data = path.read_bytes()
    require(data.startswith(b"P6\n"), "host screenshot is not PPM")
    header, pixels = data.split(b"\n255\n", 1)
    require(len(pixels) >= WIDTH * HEIGHT * 3, "host screenshot too short")
    colors = set()
    for i in range(0, len(pixels), 3 * 97):
        colors.add(pixels[i:i + 3])
    return len(colors) > 4


def main() -> int:
    require(HOST_EXE.is_file(), f"missing host: {HOST_EXE}")
    require((SHADERS / "cube.vert.spv").is_file(), "missing vertex shader")
    with tempfile.TemporaryDirectory(prefix="aurora-vulkan-readback-") as name:
        temp = Path(name)
        app = temp / "vulkan3d.exe"
        completed = subprocess.run(
            ["dmd", "-i",
             f"-I={ROOT / 'aurora-d' / 'source'}",
             str(PROJECT / "vulkan3d.d"), f"-of={app}"],
            cwd=str(PROJECT), capture_output=True, text=True, encoding="utf-8")
        require(completed.returncode == 0,
                f"vulkan3d build failed: {completed.stdout}{completed.stderr}")
        surface = temp / "vulkan.surface"
        frame = temp / "vulkan.ppm"
        completed = subprocess.run(
            [str(app), "--shaders", str(SHADERS),
             "--surface", str(surface), "--out", str(frame), "--time", "0.7"],
            cwd=str(PROJECT), capture_output=True, text=True, encoding="utf-8")
        require(completed.returncode == 0,
                f"vulkan3d failed: {completed.stdout}{completed.stderr}")
        require(surface.is_file() and frame.is_file(), "Vulkan output missing")

        scene = temp / "scene.json"
        scene.write_text(json.dumps(scene_document(surface)), encoding="utf-8")
        shot = PROJECT / "build" / "vulkan-surface-host.ppm"
        shot.parent.mkdir(parents=True, exist_ok=True)
        host = Host(scene, exe=HOST_EXE)
        try:
            wait_surface(host)
            time.sleep(0.2)
            host.request("screenshot", path=str(shot))
            require(shot.is_file(), "host screenshot missing")
            require(ppm_nonblank(shot), "host surface is blank")
            print(f"PASS Vulkan 3D readback into host surface "
                  f"hostPid={host.process.pid} shot={shot}")
        finally:
            host.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
