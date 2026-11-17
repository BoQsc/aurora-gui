#!/usr/bin/env python3
"""Test D DLL hot reload without restarting the D runtime or aurora-host."""
from __future__ import annotations

from pathlib import Path
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
sys.path.insert(0, str(HOST / "tools"))
from host_session import Host  # noqa: E402

WIDTH = 320
HEIGHT = 240
TITLEBAR = 34


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def build_logic(source: Path, target: Path) -> None:
    completed = subprocess.run(
        [
            "dmd",
            "-betterC",
            "-shared",
            "-L/NOENTRY",
            "-L/EXPORT:aurora_logic_frame",
            f"-of={target.name}",
            source.name,
        ],
        cwd=str(source.parent),
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    require(completed.returncode == 0,
            f"logic build failed: {completed.stdout}{completed.stderr}")


def scene_document(surface: Path) -> dict:
    return {
        "schemaVersion": 2,
        "window": {
            "title": "DLL Live",
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
                    "text": "DLL Live",
                    "height": TITLEBAR,
                    "background": "#0f172a",
                    "border": "#1e293b",
                    "textColor": "#e2e8f0",
                },
                {
                    "id": "module",
                    "type": "surface",
                    "path": str(surface),
                    "width": WIDTH,
                    "height": HEIGHT,
                    "staleMs": 1000,
                    "events": ["pointer"],
                },
            ],
        },
    }


def wait_surface(host: Host) -> None:
    deadline = time.monotonic() + 10
    last = None
    while time.monotonic() < deadline:
        last = host.request("surface", node="module")
        if last.get("mapped") and last.get("sequence", 0) > 0:
            return
        time.sleep(0.02)
    raise RuntimeError(f"surface not mapped: {last!r}")


def wait_build(path: Path, build: int, pointer_x: int | None = None) -> dict:
    deadline = time.monotonic() + 10
    last = None
    while time.monotonic() < deadline:
        if path.is_file():
            try:
                last = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                last = None
            if (last and last.get("build") == build and
                    (pointer_x is None or last.get("pointerX") == pointer_x)):
                return last
        time.sleep(0.02)
    raise RuntimeError(f"runtime did not publish build {build}: {last!r}")


def main() -> int:
    require((HOST / "aurora-host.exe").is_file(), "missing aurora-host.exe")
    with tempfile.TemporaryDirectory(prefix="aurora-dll-live-") as name:
        temp = Path(name)
        shutil.copyfile(PROJECT / "runtime.d", temp / "runtime.d")
        shutil.copyfile(PROJECT / "logic.d", temp / "logic.d")
        runtime = temp / "runtime.exe"
        completed = subprocess.run(
            ["dmd", "runtime.d", "-of=runtime.exe"],
            cwd=str(temp), capture_output=True, text=True, encoding="utf-8")
        require(completed.returncode == 0,
                f"runtime build failed: {completed.stdout}{completed.stderr}")
        logic1 = temp / "logic-1.dll"
        build_logic(temp / "logic.d", logic1)

        surface = temp / "app.surface"
        state = temp / "app.state.json"
        signal = temp / "reload.signal"
        scene = temp / "app.scene.json"
        scene.write_text(json.dumps(scene_document(surface)), encoding="utf-8")
        shot1 = temp / "before.ppm"
        shot2 = temp / "after.ppm"

        host = Host(scene, exe=HOST / "aurora-host.exe")
        live = subprocess.Popen(
            [
                str(runtime), "--surface", str(surface),
                "--state", str(state), "--logic", str(logic1),
                "--signal", str(signal), "--seconds", "30",
            ],
            cwd=str(temp), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
        )
        try:
            wait_surface(host)
            wait_build(state, 1)
            host.request("pointer", node="module", kind="move", x=240, y=120)
            wait_build(state, 1, 240)
            host.request("screenshot", path=str(shot1))
            host_pid = host.process.pid
            runtime_pid = live.pid

            text = (temp / "logic.d").read_text(encoding="utf-8")
            match = re.search(r"enum Revision = (\d+);", text)
            require(match is not None, "Revision declaration missing")
            revision = int(match.group(1))
            next_revision = 1 if revision != 1 else 2
            (temp / "logic.d").write_text(
                text.replace(f"enum Revision = {revision};",
                             f"enum Revision = {next_revision};"),
                encoding="utf-8",
            )
            logic2 = temp / "logic-2.dll"
            build_logic(temp / "logic.d", logic2)

            signal_doc = {"path": str(logic2), "build": 2}
            temporary = signal.with_suffix(".tmp")
            temporary.write_text(json.dumps(signal_doc), encoding="utf-8")
            os.replace(temporary, signal)

            wait_build(state, 2, 240)
            time.sleep(0.2)
            host.request("screenshot", path=str(shot2))
            require(host.process.pid == host_pid,
                    "aurora-host restarted")
            require(live.pid == runtime_pid,
                    "D runtime restarted")
            latest = json.loads(state.read_text(encoding="utf-8"))
            require(latest.get("pointerX") == 240,
                    "pointer state did not survive the DLL swap")
            require(shot1.read_bytes() != shot2.read_bytes(),
                    "DLL swap did not change the frame")
            print("PASS D DLL live reload")
            print(f"hostPid={host_pid} runtimePid={runtime_pid} build=2")
            return 0
        finally:
            live.terminate()
            try:
                live.wait(timeout=5)
            except subprocess.TimeoutExpired:
                live.kill()
                live.wait(timeout=5)
            host.close()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL D DLL live reload: {error}", file=sys.stderr)
        raise SystemExit(1)
