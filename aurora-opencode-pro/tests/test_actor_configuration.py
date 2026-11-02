"""Change model, tools, credentials and workspace during a held SSE request."""
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
directory = Path(tempfile.mkdtemp(prefix="configuration-provider-", dir=package / "build"))
release = directory / "release"
requests = []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append((request, self.headers.get("Authorization")))
        if len(requests) > 12:
            body = b'{"error":{"message":"Fixture request bound exceeded"}}'
            self.send_response(422)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

        def send(delta, reason=None):
            self.wfile.write(("data: " + json.dumps({"choices": [{"delta": delta, "finish_reason": reason}]}) + "\n\n").encode())
            self.wfile.flush()

        if len(requests) == 1:
            send({"content": "Preparing the original note."})
            deadline = time.monotonic() + 20
            while not release.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            tool = {"index": 0, "id": "fenced", "type": "function", "function": {
                "name": "write", "arguments": json.dumps({"filePath": "fenced.md", "content": "original workspace"})}}
            send({"tool_calls": [tool]}, "tool_calls")
        else:
            send({"content": "The design analysis and plain text note are complete."}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1",
               AURORA_CONTRACT_RELEASE_FILE=str(release))
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "actor_configuration_contracts"], cwd=package.parent, env=env, timeout=150)
    (directory / "requests.json").write_text(json.dumps([request for request, _ in requests], indent=2), encoding="utf-8")
    if result.returncode:
        print("Configuration fixture requests:", len(requests), [request["model"] for request, _ in requests[:8]], flush=True)
    assert result.returncode == 0, "Hot configuration fixture failed"
    assert len(requests) == 2, f"Configuration reset the task or launched extra requests: {len(requests)}"
    before, after = requests
    assert before[0]["model"] == "configuration-old" and before[1] == "Bearer fixture-secret-before"
    assert after[0]["model"] == "configuration-new" and after[1] == "Bearer fixture-secret-after"
    assert [tool["function"]["name"] for tool in after[0]["tools"]] == ["read"]
    print("PASS real HTTP configuration captured per round and original workspace effect fence")
finally:
    release.touch(exist_ok=True)
    server.shutdown()
