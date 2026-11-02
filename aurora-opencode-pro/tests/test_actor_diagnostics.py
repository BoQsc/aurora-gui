"""Drive output recovery into bounded read-only diagnosis and back to the main model."""
import collections
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
directory = Path(tempfile.mkdtemp(prefix="diagnostics-provider-", dir=package / "build"))
counts = collections.Counter()
failures = []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = request["model"]
        counts[model] += 1
        number = counts[model]
        mode = model.split("-", 1)[1]
        review = model.startswith("review-")
        if number > 8:
            self.send_error(422, "Fixture request limit")
            return
        if review:
            tools = {tool["function"]["name"] for tool in request.get("tools", [])}
            if not tools or not tools <= {"calculate", "read", "read_plan", "read_history", "grep", "glob", "view_image", "checksum", "tool_status"}:
                failures.append((model, "Unsafe diagnostic capabilities", sorted(tools)))
            if mode == "unavailable":
                body = b'{"error":{"message":"Diagnostic provider unavailable"}}'
                self.send_response(401)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()

            def send(delta, reason=None):
                self.wfile.write(("data: " + json.dumps({"choices": [{"delta": delta, "finish_reason": reason}]}) + "\n\n").encode())
                self.wfile.flush()

            if review:
                send({"content": "Reviewing the recorded evidence. "})
                if mode == "stop":
                    (directory / "stop.started").touch()
                    until = time.monotonic() + 20
                    while not (directory / "stop.release").exists() and time.monotonic() < until:
                        time.sleep(0.01)
                if mode in ("badtool", "bounded") or (mode == "read" and number == 1):
                    name = "write" if mode == "badtool" else "read"
                    arguments = {"filePath": "forbidden.txt", "content": "never"} if name == "write" else {"filePath": "evidence.txt"}
                    send({"tool_calls": [{"index": 0, "id": f"review-{number}", "type": "function", "function": {
                        "name": name, "arguments": json.dumps(arguments)}}]}, "tool_calls")
                else:
                    send({"content": "DIAGNOSTIC FINDING: compare the recorded outcome with the expected design before concluding."}, "stop")
            elif number <= 2:
                send({"content": '<invoke name="read"><parameter name="filePath">evidence.txt</parameter></invoke>'}, "stop")
            else:
                send({"content": "MAIN RESULT: The design tradeoffs are clear from the recorded evidence, and the analysis is complete."}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (ConnectionError, OSError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1",
               AURORA_CONTRACT_RELEASE_DIR=str(directory))
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"), "actor_diagnostic_contracts"],
                            cwd=package.parent, env=env, timeout=180)
    (directory / "counts.json").write_text(json.dumps(counts, indent=2), encoding="utf-8")
    assert result.returncode == 0, "Automatic diagnostic fixture failed"
    assert not failures, failures
    for mode in ("read", "badtool", "unavailable", "stop", "bounded"):
        assert counts[f"main-{mode}"] == (2 if mode == "stop" else 3), (mode, counts)
        assert counts[f"review-{mode}"] == {"read": 2, "badtool": 4, "unavailable": 1, "stop": 1, "bounded": 4}[mode], counts
    print("PASS bounded automatic diagnosis, read-only capability fence, main-model handoff, failure fallback, Stop and offline replay", dict(counts))
finally:
    (directory / "stop.release").touch()
    server.shutdown()
