#!/usr/bin/env python3
"""Exercise Lite's host scene while an SSE response is in flight."""
from __future__ import annotations

import http.server
import json
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
EXE = APP / "build" / "aurora-opencode-lite-live-smoke.exe"
SCENE = APP / "assets" / "lite.scene.json"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

        def event(data):
            self.wfile.write(b"data: " + json.dumps(data).encode() + b"\n\n")
            self.wfile.flush()

        try:
            event({"choices": [{"delta": {"content": "Hello"}}]})
            time.sleep(0.5)
            event({"choices": [{"delta": {"content": " world"}}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, format, *args):
        pass


def main() -> int:
    if not EXE.is_file():
        print(f"missing test executable: {EXE}", file=sys.stderr)
        return 2
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}/v1/chat/completions"
    with tempfile.TemporaryDirectory() as directory:
        scene_a = Path(directory) / "a.scene.json"
        scene_b = Path(directory) / "b.scene.json"
        text = SCENE.read_text(encoding="utf-8")
        scene_a.write_text(text, encoding="utf-8")
        scene_b.write_text(text.replace(
            "Aurora OpenCode Lite", "Aurora OpenCode Lite Reloaded", 1),
            encoding="utf-8")
        try:
            result = subprocess.run(
                [str(EXE), url, str(scene_a), str(scene_b)],
                capture_output=True, text=True, timeout=40)
        finally:
            server.shutdown()
            server.server_close()
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        if result.returncode != 0:
            print(f"live smoke failed: exit {result.returncode}",
                  file=sys.stderr)
            return 1
        if "transcript=" not in result.stdout or "Hello world" not in result.stdout:
            print("live smoke failed: reply did not survive reload",
                  file=sys.stderr)
            return 1
        if "status=Complete" not in result.stdout:
            print("live smoke failed: stream did not complete", file=sys.stderr)
            return 1
    print("live smoke passed: scene reload preserved the in-flight stream")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
