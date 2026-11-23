#!/usr/bin/env python3
"""Verify the D host CLI can list/get/set/trigger against a live host."""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-host.exe"
CLI = APP / "build" / "aurora-opencode-lite-cli.exe"
SCENE = APP / "assets" / "lite.scene.json"
TITLE = "Aurora CLI Control Test"
PORT = 18812


def wait_for_port(timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("host control port did not open")


def cli(*args: str, expect: int = 0) -> str:
    result = subprocess.run(
        [str(CLI), "--port", str(PORT), *args], cwd=str(APP),
        capture_output=True, text=True, timeout=10)
    if result.returncode != expect:
        raise RuntimeError(
            f"CLI {args} returned {result.returncode}: {result.stderr}")
    return result.stdout


def main() -> int:
    for path in (HOST, CLI, SCENE):
        if not path.is_file():
            raise RuntimeError(f"missing executable/asset: {path}")
    temp = Path(tempfile.mkdtemp(prefix="aurora-cli-control-"))
    scene_path = temp / "cli.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    host = subprocess.Popen(
        [str(HOST), "--external-controller", "--start-minimized",
         "--no-activate", "--instance-group", "cli-control",
         "--listen", str(PORT), "--scene", str(scene_path)],
        cwd=str(APP), env=environment, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    try:
        wait_for_port()
        listing = cli("list")
        if "lite-input" not in listing or "\ttextField" not in listing:
            raise RuntimeError(f"CLI list missing lite-input: {listing}")
        if cli("set", "lite-input", "from-cli").strip() != "ok":
            raise RuntimeError("CLI set did not return ok")
        if cli("get", "lite-input").strip() != "from-cli":
            raise RuntimeError("CLI get did not return the set value")
        if cli("trigger", "lite-provider-openai",
               "preset-openai").strip() != "ok":
            raise RuntimeError("CLI trigger did not return ok")
        if cli("key", "lite-input", "enter").strip() != "ok":
            raise RuntimeError("CLI key did not return ok")
        # Enter submits through the same action as the Send button.
        if cli("get", "lite-input").strip() != "from-cli":
            raise RuntimeError("CLI key inserted text instead of submitting")
        if cli("click", "lite-send").strip() != "ok":
            raise RuntimeError("CLI click did not return ok")
        if host.poll() is not None:
            raise RuntimeError("host exited during CLI control")
        print("cli control passed: list, set, get, trigger, key, click")
        return 0
    finally:
        if host.poll() is None:
            host.terminate()
            try:
                host.wait(timeout=5)
            except subprocess.TimeoutExpired:
                host.kill()


if __name__ == "__main__":
    raise SystemExit(main())