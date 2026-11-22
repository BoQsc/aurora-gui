#!/usr/bin/env python3
"""Verify the host command menu lists active nodes and triggers an action."""
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
SCENE = APP / "assets" / "lite.scene.json"
TITLE = "Aurora Command Menu Test"
PORT = 18805


def wait_for_port(timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("host control port did not open")


def exchange(sock, buffer, request_id, command, **fields):
    request_id[0] += 1
    payload = {"id": request_id[0], "command": command}
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
            if not text.startswith("RESPONSE "):
                continue
            response = json.loads(text[9:])
            if response.get("id") == request_id[0]:
                return response, buffer
    raise RuntimeError(f"no response to {command}")


def menu_items(response):
    return response.get("menu", {}).get("items", [])


def main() -> int:
    if not HOST.is_file() or not SCENE.is_file():
        raise RuntimeError("build the host-lite executable first")
    temp = Path(tempfile.mkdtemp(prefix="aurora-command-menu-"))
    scene_path = temp / "commands.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    host = subprocess.Popen(
        [str(HOST), "--external-controller", "--no-activate",
         "--instance-group", "command-menu-test", "--listen", str(PORT),
         "--scene", str(scene_path)],
        cwd=str(APP), env=environment, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    try:
        wait_for_port()
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        buffer = b""
        ids = [0]
        try:
            tree, buffer = exchange(sock, buffer, ids, "tree")
            nodes = {node["id"]: node for node in tree["nodes"]}
            if "lite-commands" not in nodes:
                raise RuntimeError("command menu node is missing")
            opened, buffer = exchange(sock, buffer, ids, "menu",
                                      node="lite-commands")
            items = menu_items(opened)
            trigger = next(
                (item for item in items
                 if item.get("label") ==
                 "Trigger preset-opencode  [button lite-provider-opencode]"),
                None)
            if trigger is None:
                raise RuntimeError(
                    f"action trigger not listed: {items}")
            exchange(sock, buffer, ids, "menuClick", index=trigger["index"])
            print("command menu passed: active nodes listed and action triggered")
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
