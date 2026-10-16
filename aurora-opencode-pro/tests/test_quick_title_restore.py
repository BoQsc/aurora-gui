"""Restart-recovery regression for quick chat-name generation.

Serves a deterministic provider whose title rewrite answers Fixture, then builds
and runs the ``quick_title_restore_contracts`` fixture. That fixture restores a
conversation left with its raw first message as a title (the state a rebuild
leaves behind) and asserts the rewrite is re-queued on launch - while an
already-generated name is never overwritten.
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

    def do_GET(self):
        body = json.dumps({"data": [{"id": "fixture", "owned_by": "fixture"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("messages", [])
        is_title = any(m.get("role") == "system" and
                       "short title" in (m.get("content") or "") for m in messages)
        text = "Fixture" if is_title else "Done"
        rows = [{"choices": [{"delta": {"content": text}, "finish_reason": None}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for row in rows:
            chunk = ("data: " + json.dumps(row) + "\n\n").encode()
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ,
               AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "quick_title_restore_contracts"],
                            cwd=package.parent, env=env, timeout=240)
    assert result.returncode == 0, "quick title restore contract failed"
    print("PASS a rewrite lost to a restart is re-queued on the next launch",
          flush=True)
finally:
    server.shutdown()
    server.server_close()
