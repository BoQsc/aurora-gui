"""Duplicate an admitted prompt while HTTP is held, including a conflicting edit."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

package = Path(__file__).resolve().parents[1]
directory = Path(tempfile.mkdtemp(prefix="input-identity-provider-", dir=package / "build"))
requests = []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        number = len(requests)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        (directory / f"request-{number}.started").touch()
        until = time.monotonic() + 15
        while not (directory / f"request-{number}.release").exists() and time.monotonic() < until:
            time.sleep(0.01)
        body = {"choices": [{"delta": {"content": f"Analysis {number}: the requested design tradeoffs are explained."}, "finish_reason": "stop"}]}
        try:
            self.wfile.write(("data: " + json.dumps(body) + "\n\ndata: [DONE]\n\n").encode())
            self.wfile.flush()
        except (ConnectionError, OSError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1",
               AURORA_CONTRACT_RELEASE_DIR=str(directory))
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"), "actor_input_identity_contracts"],
                            cwd=package.parent, env=env, timeout=150)
    assert result.returncode == 0, "Submission identity fixture failed"
    assert len(requests) == 3, f"Submission replay repeated a provider effect: {len(requests)}"
    assert "inputId" not in json.dumps(requests), "Durable submission identity leaked into the provider wire"
    print("PASS three HTTP requests for distinct inputs, including an append interrupted before command commit")
finally:
    for number in range(1, 10):
        (directory / f"request-{number}.release").touch()
    server.shutdown()
