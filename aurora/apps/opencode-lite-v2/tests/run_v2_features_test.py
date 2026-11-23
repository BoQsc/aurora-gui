#!/usr/bin/env python3
"""Exercise v2 persisted session, clear, and retry controls."""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-v2-host.exe"
CONTROLLER = APP / "build" / "aurora-opencode-lite-v2-controller.exe"
SCENE = APP / "assets" / "lite.scene.json"
TITLE = "Aurora V2 Features Test"
PORT = 18814
HTTP_PORT = 18816


class FailHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        self.send_response(500)
        self.end_headers()

    def log_message(self, *args):
        pass


def wait_for_port(timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", PORT), timeout=0.2):
                return
        except OSError:
            time.sleep(0.02)
    raise RuntimeError("host control port did not open")


def wait_for_status(sock, buffer, ids, wanted: str, timeout: float = 10.0):
    deadline = time.monotonic() + timeout
    last = ""
    while time.monotonic() < deadline:
        response, buffer = exchange(sock, buffer, ids, "tree")
        last = next(
            (node.get("text", "") for node in response.get("nodes", [])
             if node.get("id") == "lite-status"), "")
        if last == wanted:
            return buffer
        time.sleep(0.1)
    raise RuntimeError(f"status did not reach {wanted}; last={last!r}")


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


def start_controller(environment):
    return subprocess.Popen(
        [str(CONTROLLER), "--port", str(PORT)], cwd=str(APP),
        env=environment, stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE, text=True)


def main() -> int:
    for path in (HOST, CONTROLLER, SCENE):
        if not path.is_file():
            raise RuntimeError(f"missing executable/asset: {path}")
    temp = Path(tempfile.mkdtemp(prefix="aurora-v2-features-"))
    settings = temp / "AuroraOpenCodeLiteV2"
    settings.mkdir()
    (settings / "settings.json").write_text(json.dumps({
        "baseUrl": "http://127.0.0.1:1/v1",
        "model": "mock",
        "apiKey": "",
    }), encoding="utf-8")
    scene_path = temp / "v2.scene.json"
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    scene["window"]["title"] = TITLE
    scene_path.write_text(json.dumps(scene), encoding="utf-8")
    environment = os.environ.copy()
    environment["APPDATA"] = str(temp)
    environment["LOCALAPPDATA"] = str(temp)
    httpd = HTTPServer(("127.0.0.1", HTTP_PORT), FailHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    host = subprocess.Popen(
        [str(HOST), "--external-controller", "--start-minimized",
         "--no-activate", "--instance-group", "v2-features",
         "--listen", str(PORT), "--scene", str(scene_path)],
        cwd=str(APP), env=environment, stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL)
    controller = None
    try:
        wait_for_port()
        controller = start_controller(environment)
        time.sleep(0.8)
        if controller.poll() is not None:
            raise RuntimeError(
                "controller exited: " + (controller.stderr.read() or ""))
        sock = socket.create_connection(("127.0.0.1", PORT), timeout=5)
        buffer = b""
        ids = [0]
        try:
            tree, buffer = exchange(sock, buffer, ids, "tree")
            nodes = {node["id"]: node for node in tree["nodes"]}
            for required in ("lite-session", "lite-clear", "lite-retry"):
                if required not in nodes:
                    raise RuntimeError(f"missing v2 control {required}")
            exchange(sock, buffer, ids, "setText",
                     node="lite-base",
                     text=f"http://127.0.0.1:{HTTP_PORT}/v1")
            exchange(sock, buffer, ids, "setText",
                     node="lite-model", text="mock")
            exchange(sock, buffer, ids, "setText",
                     node="lite-input", text="persist me")
            exchange(sock, buffer, ids, "trigger",
                     node="lite-send", action="send")
            buffer = wait_for_status(sock, buffer, ids, "Error")
            transcript, buffer = exchange(sock, buffer, ids, "getText",
                                          node="lite-transcript")
            if "persist me" not in transcript.get("text", ""):
                raise RuntimeError("transcript did not record the prompt")
            tree, buffer = exchange(sock, buffer, ids, "tree")
            session = next(
                (node.get("text", "") for node in tree.get("nodes", [])
                 if node.get("id") == "lite-session"), "")
            if "1 message" not in session:
                raise RuntimeError(f"session count wrong: {session}")
            history_file = settings / "conversation.json"
            if not history_file.is_file() or \
                    "persist me" not in history_file.read_text(encoding="utf-8"):
                raise RuntimeError("history was not persisted")
            time.sleep(0.5)
            exchange(sock, buffer, ids, "trigger",
                     node="lite-clear", action="clear")
            time.sleep(0.5)
            transcript, buffer = exchange(sock, buffer, ids, "getText",
                                          node="lite-transcript")
            if "New session" not in transcript.get("text", ""):
                raise RuntimeError("clear did not reset the transcript")
            controller.terminate()
            controller.wait(timeout=5)
            controller = start_controller(environment)
            time.sleep(0.8)
            persisted, buffer = exchange(sock, buffer, ids, "getText",
                                         node="lite-transcript")
            if "New session" not in persisted.get("text", ""):
                raise RuntimeError("cleared session did not persist")
            print("v2 features passed: history, clear, session count")
            return 0
        finally:
            sock.close()
    finally:
        httpd.shutdown()
        for process in (controller, host):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()


if __name__ == "__main__":
    raise SystemExit(main())
