#!/usr/bin/env python3
"""Verify a controller can be restarted without restarting the host window."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import socket
import subprocess
import tempfile
import threading
import time

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-host.exe"
CONTROLLER = APP / "build" / "aurora-opencode-lite-controller.exe"
SCENE = APP / "assets" / "lite.scene.json"
PORT = 18799


def wait_for_port(timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("host control port did not open")


def tree(stdin, lines: queue.Queue, request_id: int) -> dict:
    stdin.write(json.dumps({"id": request_id, "command": "tree"}) + "\n")
    stdin.flush()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            line = lines.get(timeout=0.2)
        except queue.Empty:
            continue
        if line.startswith("RESPONSE "):
            response = json.loads(line[9:])
            if response.get("id") == request_id and "nodes" in response:
                return response
    raise RuntimeError("host did not answer tree request")


def tcp_tree(port: int, request_id: int) -> dict:
    with socket.create_connection(("127.0.0.1", port), timeout=5) as client:
        client.sendall(
            (json.dumps({"id": request_id, "command": "tree"}) + "\n").encode())
        buffer = b""
        while True:
            chunk = client.recv(65536)
            if not chunk:
                raise RuntimeError("host closed the control socket")
            buffer += chunk
            for line in buffer.decode(errors="replace").splitlines():
                if line.startswith("RESPONSE "):
                    response = json.loads(line[9:])
                    if response.get("id") == request_id and "nodes" in response:
                        return response


def main() -> int:
    for path in (HOST, CONTROLLER):
        if not path.is_file():
            raise RuntimeError(f"missing executable: {path}")
    temp = Path(tempfile.mkdtemp(prefix="aurora-external-controller-"))
    environment = os.environ.copy()
    environment["LOCALAPPDATA"] = str(temp)
    environment["APPDATA"] = str(temp)
    host = subprocess.Popen(
        [str(HOST), "--external-controller", "--listen", str(PORT),
         "--scene", str(SCENE)],
        cwd=str(APP), env=environment, stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    controller = None
    second = None
    stalled = None
    lines: queue.Queue[str] = queue.Queue()
    threading.Thread(
        target=lambda: [lines.put(line.rstrip()) for line in host.stdout],
        daemon=True).start()
    try:
        wait_for_port()
        host_pid = host.pid
        controller = subprocess.Popen(
            [str(CONTROLLER), "--port", str(PORT)], cwd=str(APP),
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)
        time.sleep(0.8)
        first = {node["id"]: node.get("text", "")
                 for node in tree(host.stdin, lines, 9001)["nodes"]}
        if first.get("lite-status") != "Ready":
            raise RuntimeError("controller did not attach to the scene")
        # A connected client that never sends anything must not block another
        # control client.
        stalled = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        concurrent = tcp_tree(PORT, 9100)
        if not concurrent.get("nodes"):
            raise RuntimeError("host blocked a second control client")
        stalled.close()
        stalled = None
        controller.terminate()
        controller.wait(timeout=10)
        controller = None
        time.sleep(0.3)
        if host.poll() is not None:
            raise RuntimeError("host exited when the controller stopped")
        second = subprocess.Popen(
            [str(CONTROLLER), "--port", str(PORT)], cwd=str(APP),
            env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True)
        time.sleep(0.8)
        after = {node["id"]: node.get("text", "")
                 for node in tree(host.stdin, lines, 9002)["nodes"]}
        if after.get("lite-status") != "Ready":
            raise RuntimeError("restarted controller did not attach")
        if host.pid != host_pid:
            raise RuntimeError("host PID changed across controller restart")
        print("external controller restart passed: host PID stable")
        return 0
    finally:
        if stalled is not None:
            stalled.close()
        for process in (second, controller, host):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()


if __name__ == "__main__":
    raise SystemExit(main())
