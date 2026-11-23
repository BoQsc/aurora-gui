#!/usr/bin/env python3
"""Verify the host replaces a dead isolated controller without restarting itself."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-v2-host.exe"
SCENE = APP / "assets" / "lite.scene.json"
TITLE = "Aurora Supervisor Test"
PORT = 18803


def controller_pid() -> int | None:
    script = (
        "Get-CimInstance Win32_Process -Filter \"Name='"
        "aurora-opencode-lite-v2-controller.exe'\" | "
        "Where-Object { $_.CommandLine -match '18803' } | "
        "Select-Object -ExpandProperty ProcessId")
    result = subprocess.run(["powershell", "-NoProfile", "-Command", script],
                            capture_output=True, text=True)
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.isdigit():
            return int(line)
    return None


def wait_for_controller(timeout: float = 10.0,
                        previous: int | None = None) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pid = controller_pid()
        if pid is not None and pid != previous:
            return pid
        time.sleep(0.1)
    raise RuntimeError("supervised controller did not start")


def controller_console_handle(pid: int) -> int:
    result = subprocess.run(
        ["powershell", "-NoProfile", "-Command",
         f"(Get-Process -Id {pid} -ErrorAction SilentlyContinue).MainWindowHandle"],
        capture_output=True, text=True)
    for line in result.stdout.splitlines():
        if line.strip().isdigit():
            return int(line.strip())
    return 0


def main() -> int:
    if not HOST.is_file() or not SCENE.is_file():
        raise RuntimeError("build the host-lite executable first")
    temp = Path(tempfile.mkdtemp(prefix="aurora-controller-supervisor-"))
    scene_path = temp / "supervisor.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    host = subprocess.Popen(
        [str(HOST), "--no-activate", "--instance-group", "supervisor-test",
         "--controller-port", str(PORT), "--scene", str(scene_path)],
        cwd=str(APP), env=environment, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    try:
        first = wait_for_controller()
        if controller_console_handle(first) != 0:
            raise RuntimeError("controller opened a visible console window")
        subprocess.run(["taskkill", "/PID", str(first), "/F"],
                       capture_output=True)
        replacement = wait_for_controller(previous=first)
        time.sleep(0.3)
        if host.poll() is not None:
            raise RuntimeError("host exited when its controller died")
        print("controller supervisor passed: host stable, controller replaced")
        return 0
    finally:
        pid = controller_pid()
        if pid is not None:
            subprocess.run(["taskkill", "/PID", str(pid), "/F"],
                           capture_output=True)
        if host.poll() is None:
            host.terminate()
            try:
                host.wait(timeout=5)
            except subprocess.TimeoutExpired:
                host.kill()


if __name__ == "__main__":
    raise SystemExit(main())