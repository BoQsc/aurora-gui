#!/usr/bin/env python3
"""Prove a failed send cannot terminate the process-isolated host."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import sys
import tempfile
import threading
import time

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-host.exe"
CONTROLLER = APP / "build" / "aurora-opencode-lite-controller.exe"
SCENE = APP / "assets" / "lite.scene.json"
PORT = 18797


def wait_for_port(timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("host control port did not open")


def exchange(client: socket.socket, next_id: list[int], command: str,
             **fields) -> dict:
    next_id[0] += 1
    request_id = next_id[0]
    payload = {"id": request_id, "command": command}
    payload.update(fields)
    client.sendall((json.dumps(payload) + "\n").encode())
    buffer = ""
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        chunk = client.recv(65536).decode(errors="replace")
        if not chunk:
            raise RuntimeError("host closed the control socket")
        buffer += chunk
        while "\n" in buffer:
            line, buffer = buffer.split("\n", 1)
            if not line.startswith("RESPONSE "):
                continue
            response = json.loads(line[9:])
            if response.get("id") == request_id:
                return response
    raise RuntimeError(f"no response to {command}")


def main() -> int:
    for path in (HOST, CONTROLLER, SCENE):
        if not path.is_file():
            raise RuntimeError(f"missing executable/asset: {path}")
    temp = Path(tempfile.mkdtemp(prefix="aurora-send-failure-"))
    settings_dir = temp / "AuroraOpenCodeLite"
    settings_dir.mkdir()
    (settings_dir / "settings.json").write_text(
        json.dumps({
            "baseUrl": "http://127.0.0.1:1/v1",
            "model": "mock",
            "apiKey": "",
        }),
        encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    host = subprocess.Popen(
        [str(HOST), "--external-controller", "--no-activate",
         "--instance-group", "external-failure",
         "--listen", str(PORT),
         "--scene", str(SCENE)],
        cwd=str(APP), env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True)
    controller = None
    lines: queue.Queue[str] = queue.Queue()
    threading.Thread(
        target=lambda: [lines.put(line.rstrip()) for line in host.stdout],
        daemon=True).start()
    try:
        wait_for_port()
        controller = subprocess.Popen(
            [str(CONTROLLER), "--port", str(PORT)], cwd=str(APP),
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)
        time.sleep(0.8)
        client = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        next_id = [0]
        try:
            exchange(client, next_id, "setText", node="lite-input", text="fail")
            bounds = exchange(client, next_id, "getBounds",
                              node="lite-send")["rect"]
            exchange(client, next_id, "uiClick",
                     x=int(bounds["x"]) + int(bounds["width"]) // 2,
                     y=int(bounds["y"]) + int(bounds["height"]) // 2)
            status = ""
            transcript = ""
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                time.sleep(0.3)
                tree = exchange(client, next_id, "tree")
                nodes = {node["id"]: node.get("text", "")
                         for node in tree["nodes"]}
                status = nodes.get("lite-status", "")
                transcript = nodes.get("lite-transcript", "")
                if status == "Error" and "[error]" in transcript:
                    break
            if host.poll() is not None:
                raise RuntimeError("host exited after the failed send")
            if status != "Error" or "[error]" not in transcript:
                raise RuntimeError(
                    f"failed send was not surfaced: status={status!r} "
                    f"transcript={transcript!r}")
            print("failed-send isolation passed: host alive, UI reported error")
            return 0
        finally:
            client.close()
    finally:
        for process in (controller, host):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
        errors = host.stderr.read() if host.stderr is not None else ""
        if errors:
            print(errors, file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
