"""Verify the quick chat-name rewrite runs while another conversation is busy.

Serves a deterministic provider that answers the main turn with DONE and the
no-thinking title rewrite with Fixture, then builds and runs the
``quick_title_contracts`` fixture against it.
"""
import http.server
import json
import os
import subprocess
import sys
import threading
from pathlib import Path

package = Path(__file__).resolve().parents[1]


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def respond(self, body, kind):
        body = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_GET(self):
        self.respond(json.dumps({"data": [{"id": "fixture", "owned_by": "fixture"}]}),
                     "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        is_title = any(message.get("role") == "system" and
                       "short title" in (message.get("content") or "")
                       for message in request.get("messages", []))
        content = "Fixture" if is_title else "DONE"
        rounds = [{"choices": [{"delta": {"content": content}, "finish_reason": "stop"}]},
                  {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 2,
                                            "total_tokens": 12}}]
        self.respond("".join("data: " + json.dumps(row) + "\n\n" for row in rounds) +
                     "data: [DONE]\n\n", "text/event-stream")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ,
               AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "quick_title_contracts"], cwd=package.parent, env=env, timeout=180)
    assert result.returncode == 0, "quick title contract failed"
    print("PASS quick title generated while another conversation stayed busy", flush=True)
finally:
    server.shutdown()
    server.server_close()
