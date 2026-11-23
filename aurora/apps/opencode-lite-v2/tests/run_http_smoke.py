#!/usr/bin/env python3
"""Run the Lite SSE client against a local two-event mock stream.

The client cancels after the first event. The test requires HTTP 200, exactly
one delivered event, and a clean canceled result.
"""
from __future__ import annotations

import http.server
import subprocess
import sys
import threading
import time
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
EXE = APP / "build" / "aurora-opencode-lite-v2-http-smoke.exe"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(b"data: one\n\n")
            self.wfile.flush()
            time.sleep(0.5)
            self.wfile.write(b"data: two\n\n")
            self.wfile.flush()
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
    try:
        result = subprocess.run(
            [str(EXE), url], capture_output=True, text=True, timeout=20)
    finally:
        server.shutdown()
        server.server_close()
    print(result.stdout, end="")
    if result.stderr:
        print(result.stderr, end="", file=sys.stderr)
    if result.returncode != 0:
        print(f"http smoke failed: exit {result.returncode}", file=sys.stderr)
        return 1
    if "events=1" not in result.stdout or "canceled=true" not in result.stdout:
        print("http smoke failed: expected one event and cancellation",
              file=sys.stderr)
        return 1
    print("http smoke passed: streamed one event, canceled cleanly")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
