#!/usr/bin/env python3
"""Verify host actions work while the window is minimized and never foregrounded."""
from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
from ctypes import wintypes

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-host.exe"
SCENE = APP / "assets" / "lite.scene.json"
TITLE = "Aurora Minimized Control Test"
PORT = 18806
user32 = ctypes.WinDLL("user32", use_last_error=True)


def wait_for_port(timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("host control port did not open")


def exchange(sock, buffer, ids, command, **fields):
    ids[0] += 1
    payload = {"id": ids[0], "command": command}
    payload.update(fields)
    sock.sendall((json.dumps(payload) + "\n").encode())
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("host closed the control socket")
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            text = line.decode(errors="replace")
            if text.startswith("RESPONSE "):
                response = json.loads(text[9:])
                if response.get("id") == ids[0]:
                    return response, buffer
    raise RuntimeError(f"no response to {command}")


def main() -> int:
    if not HOST.is_file() or not SCENE.is_file():
        raise RuntimeError("build the host-lite executable first")
    temp = Path(tempfile.mkdtemp(prefix="aurora-minimized-control-"))
    scene_path = temp / "minimized.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    host = subprocess.Popen(
        [str(HOST), "--external-controller", "--start-minimized",
         "--no-activate", "--instance-group", "minimized-control",
         "--listen", str(PORT), "--scene", str(scene_path)],
        cwd=str(APP), env=environment, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    try:
        wait_for_port()
        time.sleep(0.4)
        window = user32.FindWindowW(None, TITLE)
        if not window:
            raise RuntimeError("minimized host window was not found")
        if not user32.IsIconic(window):
            raise RuntimeError("host window did not start minimized")
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        buffer = b""
        ids = [0]
        try:
            tree, buffer = exchange(sock, buffer, ids, "tree")
            nodes = {node["id"]: node for node in tree["nodes"]}
            if "lite-commands" not in nodes:
                raise RuntimeError("command menu missing while minimized")
            set_result, buffer = exchange(
                sock, buffer, ids, "setText", node="lite-input",
                text="minimized action")
            if not set_result.get("ok"):
                raise RuntimeError(f"setText failed while minimized: {set_result}")
            text, buffer = exchange(sock, buffer, ids, "getText",
                                    node="lite-input")
            if text.get("text") != "minimized action":
                raise RuntimeError(f"getText mismatch while minimized: {text}")
            trigger, buffer = exchange(
                sock, buffer, ids, "trigger",
                node="lite-provider-openai", action="preset-openai")
            if not trigger.get("ok"):
                raise RuntimeError(f"trigger failed while minimized: {trigger}")
            if host.poll() is not None:
                raise RuntimeError("host exited during minimized actions")
            if not user32.IsIconic(window):
                raise RuntimeError("host window was unexpectedly restored")
            print("minimized control passed: tree, text, and action succeeded")
            return 0
        finally:
            sock.close()
    finally:
        if host.poll() is None:
            host.terminate()
            try:
                host.wait(timeout=5)
            except subprocess.TimeoutExpired:
                host.kill()


if __name__ == "__main__":
    raise SystemExit(main())
