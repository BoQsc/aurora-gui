"""Check which images the autonomous owner actually puts on the wire."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

package = Path(__file__).resolve().parents[1]
image_counts = []
failures = []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        images = [part for message in request["messages"] if isinstance(message["content"], list)
                  for part in message["content"] if part.get("type") == "image_url"]
        image_counts.append(len(images))
        if any(not image["image_url"]["url"].startswith("data:image/png;base64,") for image in images):
            failures.append("Wire image lost its data URL")
        row = {"choices": [{"delta": {"content": f"Analysis {len(image_counts)} is complete."}, "finish_reason": "stop"}]}
        body = ("data: " + json.dumps(row) + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "actor_image_contracts"], cwd=package.parent, env=env, timeout=150)
    assert result.returncode == 0, "Actor image fixture failed"
    assert image_counts == [2, 0, 2], f"Image retirement or branch hydration failed: {image_counts}"
    assert not failures, failures
    print("PASS real HTTP image window, text-only follow-up, branch reload", image_counts)
finally:
    server.shutdown()
