#!/usr/bin/env python3
"""Mock OpenAI-compatible stream for the Lite session test."""
from __future__ import annotations

import http.server
import json
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
EXE = APP / "build" / "aurora-opencode-lite-v2-session-smoke.exe"


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
        settings = Path(directory) / "settings.json"
        try:
            result = subprocess.run(
                [str(EXE), url, str(settings)],
                capture_output=True, text=True, timeout=30)
        finally:
            server.shutdown()
            server.server_close()
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
        if result.returncode != 0:
            print(f"session smoke failed: exit {result.returncode}",
                  file=sys.stderr)
            return 1
        if "assistant=Hello world" not in result.stdout:
            print("session smoke failed: wrong assistant text", file=sys.stderr)
            return 1
        if "done=true failed=false settings=true defaults=true" not in result.stdout:
            print("session smoke failed: completion/settings mismatch",
                  file=sys.stderr)
            return 1
    print("session smoke passed: streamed reply and settings round-trip")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
