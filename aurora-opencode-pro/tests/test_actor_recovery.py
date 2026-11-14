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
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv and sys.argv.index("--only") + 1 < len(sys.argv) else ""


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
        if number > 12:
            self.respond(422, '{"error":{"message":"Fixture request bound exceeded"}}')
            return
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
        if mode == "task-stall":
            if number == 1:
                delta = {"tool_calls": [{"index": 0, "id": "substantive", "type": "function", "function": {
                    "name": "write", "arguments": json.dumps({"filePath": "unverified.txt", "content": "unverified change"})}}]}
                reason = "tool_calls"
            else:
                content = f"Short claim of completion {number}."
        if mode == "plan-approval":
            plan_approval = {"reason": "Plan mode is blocking every write. The implementation plan is recorded, but only the user can approve it or turn Plan mode off.",
                             "required_fact": "Explicit approval to execute the recorded plan, or Plan mode turned off.",
                             "question": "Plan mode is still active and is rejecting the file edits. Please approve the recorded plan or turn off Plan mode so I can create splitpane.d.",
                             "checked": ["The requested path was inspected.", "The plan was recorded with update_plan.", "The write was rejected because Plan mode is active."],
                             "independent_work_complete": True, "blocked_steps": ["planstep"]}
            if "plan-step" not in results:
                delta = {"tool_calls": [{"index": 0, "id": "plan-step", "type": "function", "function": {
                    "name": "update_plan", "arguments": json.dumps({"plan": [{"id": "planstep", "step": "Create splitpane.d with the 0BSD header", "kind": "edit", "status": "in_progress"}]})}}]}
                reason = "tool_calls"
            elif "plan-write" not in results:
                delta = {"tool_calls": [{"index": 0, "id": "plan-write", "type": "function", "function": {
                    "name": "write", "arguments": json.dumps({"filePath": "splitpane.d", "content": "// SPDX-License-Identifier: 0BSD\n"})}}]}
                reason = "tool_calls"
            elif "plan-approval" not in results:
                delta = {"tool_calls": [{"index": 0, "id": "plan-approval", "type": "function", "function": {
                    "name": "request_input", "arguments": json.dumps(plan_approval)}}]}
                reason = "tool_calls"
            else:
                content = "Waiting for plan approval."
        if mode == "unoffered" or (mode == "mixed-offer" and number == 1):
            delta = {"tool_calls": [{"index": 0, "id": "unoffered", "type": "function", "function": {
                "name": "write", "arguments": json.dumps({"filePath": "forbidden.txt", "content": "forbidden"})}}]}
            if mode == "mixed-offer":
                delta["tool_calls"].append({"index": 1, "id": "allowed", "type": "function", "function": {
                    "name": "read", "arguments": json.dumps({"filePath": "allowed.txt"})}})
            reason = "tool_calls"
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
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1",
               AURORA_ACTOR_RECOVERY_MODES=only)
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "actor_recovery_contracts"], cwd=package.parent, env=env, timeout=150)
    assert result.returncode == 0, "Actor recovery fixture failed"
    expected = {"retry": 2, "retry-stop": 1, "transient-cap": 3, "budget": 1,
                "quota": 2, "bad-output": 4, "summary": 2, "summary-error": 2, "task-stall": 7, "unoffered": 4, "mixed-offer": 2}
    expected["plan-approval"] = 4
    if only:
        assert set(counts) == set(only.split(",")), f"Unexpected recovery modes: {dict(counts)}"
    else:
        assert counts == expected, f"Unexpected retries or tool recovery loops: {dict(counts)}"
    assert not failures, failures
    print("PASS real HTTP retry budgets, quota reset, Stop, bounded output repair and tool-free handoff", dict(counts))
finally:
    server.shutdown()
