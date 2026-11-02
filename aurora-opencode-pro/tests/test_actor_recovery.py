"""Real HTTP recovery and exact offline replay without a window or UI ticks."""
import collections
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

package = Path(__file__).resolve().parents[1]
counts = collections.Counter()
failures = []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def respond(self, status, body, kind="application/json"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        mode = request["model"].removeprefix("actor-")
        counts[mode] += 1
        number = counts[mode]
        owners, results = set(), set()
        for message in request["messages"]:
            owners.update(call["id"] for call in message.get("tool_calls", []))
            if message["role"] == "tool":
                identity = message["tool_call_id"]
                if identity not in owners or identity in results:
                    failures.append(f"{mode}: unpaired or duplicate tool result {identity}")
                results.add(identity)
        if mode in ("transient-cap", "budget"):
            self.respond(503, json.dumps({"error": {"message": "Fixture provider is unavailable"}}))
            return
        if mode in ("retry", "retry-stop") and number == 1:
            self.respond(400, json.dumps({"error": {"message": "Fixture model is provisioning"}}))
            return
        if mode == "quota" and number == 1:
            self.respond(429, json.dumps({"error": {"message": "Usage limit reached. Resets in 1 second"}}))
            return
        content, reason = "Analysis is complete.", "stop"
        delta = None
        if mode == "bad-output":
            assert request.get("tools"), "Recovery dropped the structured tools"
            content = '<invoke name="read">\n<parameter name="filePath">sample.txt</parameter>\n</invoke>'
        if mode in ("summary", "summary-error"):
            if number == 1:
                content, reason = "A truncated analysis", "length"
            else:
                if request.get("tools"):
                    failures.append(f"{mode}: handoff still offered tools")
                if mode == "summary-error":
                    self.respond(401, json.dumps({"error": {"message": "Fixture summary is unavailable"}}))
                    return
                delta = {"tool_calls": [{"index": 0, "id": "forbidden", "type": "function", "function": {
                    "name": "write", "arguments": json.dumps({"filePath": "must-not-exist.txt", "content": "forbidden"})}}]}
                reason = "tool_calls"
        event = {"choices": [{"delta": delta or {"content": content}, "finish_reason": reason}]}
        self.respond(200, "data: " + json.dumps(event) + "\n\ndata: [DONE]\n\n", "text/event-stream")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "actor_recovery_contracts"], cwd=package.parent, env=env, timeout=150)
    assert result.returncode == 0, "Actor recovery fixture failed"
    expected = {"retry": 2, "retry-stop": 1, "transient-cap": 3, "budget": 1,
                "quota": 2, "bad-output": 4, "summary": 2, "summary-error": 2}
    assert counts == expected, f"Unexpected retries or tool recovery loops: {dict(counts)}"
    assert not failures, failures
    print("PASS real HTTP retry budgets, quota reset, Stop, bounded output repair and tool-free handoff", dict(counts))
finally:
    server.shutdown()
