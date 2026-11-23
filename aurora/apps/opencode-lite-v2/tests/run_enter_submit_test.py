#!/usr/bin/env python3
"""Verify Enter in a textField dispatches its submitAction and does not add a newline."""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-v2-host.exe"
SCENE = APP / "assets" / "lite.scene.json"
TITLE = "Aurora Enter Submit Test"
PORT = 18808


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
    events = []
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("host closed the control socket")
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            text = line.decode(errors="replace")
            if text.startswith("EVENT "):
                events.append(json.loads(text[6:]))
            elif text.startswith("RESPONSE "):
                response = json.loads(text[9:])
                if response.get("id") == ids[0]:
                    return response, events, buffer
    raise RuntimeError(f"no response to {command}")


def main() -> int:
    if not HOST.is_file() or not SCENE.is_file():
        raise RuntimeError("build the host-lite executable first")
    temp = Path(tempfile.mkdtemp(prefix="aurora-enter-submit-"))
    scene_path = temp / "enter.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    host = subprocess.Popen(
        [str(HOST), "--external-controller", "--no-activate",
         "--instance-group", "enter-submit", "--listen", str(PORT),
         "--scene", str(scene_path)],
        cwd=str(APP), env=environment, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    try:
        wait_for_port()
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        buffer = b""
        ids = [0]
        try:
            set_result, _, buffer = exchange(
                sock, buffer, ids, "setText", node="lite-input", text="hello")
            if not set_result.get("ok"):
                raise RuntimeError(f"setText failed: {set_result}")
            key_result, events, buffer = exchange(
                sock, buffer, ids, "key", node="lite-input", key="enter",
                kind="down")
            if not key_result.get("ok"):
                raise RuntimeError(f"Enter key failed: {key_result}")
            if not any(event.get("event") == "action" and
                       event.get("node") == "lite-input" and
                       event.get("action") == "send" for event in events):
                raise RuntimeError(f"send action not emitted: {events}")
            value, _, buffer = exchange(sock, buffer, ids, "getText",
                                        node="lite-input")
            if value.get("text") != "hello":
                raise RuntimeError(
                    f"Enter added text instead of submitting: {value}")
            print("enter submit passed: send action emitted, no newline inserted")
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
