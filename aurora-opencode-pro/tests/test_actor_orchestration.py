"""Autonomous child rounds, single-worker parent eviction and Stop without UI drains."""
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
directory = Path(tempfile.mkdtemp(prefix="orchestration-provider-", dir=package / "build"))
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
        if number > 8:
            self.send_error(422, "Fixture request limit")
            return
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()

            def send(delta, reason=None):
                self.wfile.write(("data: " + json.dumps({"choices": [{"delta": delta, "finish_reason": reason}]}) + "\n\n").encode())
                self.wfile.flush()

            send({"role": "assistant"})
            if model == "parent-queued-stop" or model.startswith("worker-stop-"):
                marker = "queued-stop" if model.startswith("parent-") else "stop-" + model.split("-")[-1]
                (directory / f"{marker}.started").touch()
                until = time.monotonic() + 20
                release = directory / ("queued-stop.release" if marker == "queued-stop" else "stop.release")
                while not release.exists() and time.monotonic() < until:
                    time.sleep(0.01)
            if model.startswith("parent-"):
                mode = model.removeprefix("parent-")
                if number == 1:
                    name, arguments = "assign", {"assignments": [
                        {"agent_id": "builder", "task": "Analyze design implementation tradeoffs."},
                        {"agent_id": "reviewer", "task": "Analyze independent design risks."}]}
                elif mode == "serial" and number == 2:
                    name, arguments = "assign", {"agent_id": "builder", "task": "Analyze one further design detail using earlier findings."}
                else:
                    name, arguments = "finish", {"summary": "The participant findings complete this design analysis."}
                send({"tool_calls": [{"index": 0, "id": f"route-{number}", "type": "function", "function": {
                    "name": name, "arguments": json.dumps(arguments)}}]}, "tool_calls")
            else:
                tools = {tool["function"]["name"] for tool in request.get("tools", [])}
                if tools & {"assign", "ask_user", "finish"}:
                    failures.append((model, "Worker received routing tools"))
                send({"content": f"Recorded participant analysis {number}: the design tradeoffs and risks are explained by the available evidence."}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (ConnectionError, OSError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_ORCHESTRATOR="1", AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1",
               AURORA_CONTRACT_RELEASE_DIR=str(directory))
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"), "actor_orchestration_contracts"],
                            cwd=package.parent, env=env, timeout=180)
    (directory / "counts.json").write_text(json.dumps(counts, indent=2), encoding="utf-8")
    assert result.returncode == 0, "Autonomous orchestration fixture failed"
    assert not failures, failures
    assert counts["parent-serial"] == 3 and counts["worker-serial-builder"] == 2 and counts["worker-serial-reviewer"] == 1, counts
    assert counts["parent-parallel"] == 2 and counts["worker-parallel-builder"] == counts["worker-parallel-reviewer"] == 1, counts
    assert counts["parent-stop"] == 1 and counts["worker-stop-builder"] == counts["worker-stop-reviewer"] == 1, counts
    assert counts["parent-queued-stop"] == 1 and not counts["worker-queued-stop-builder"] and not counts["worker-queued-stop-reviewer"], counts
    assert counts["parent-concurrent"] == counts["parent-concurrent-second"] == 2, counts
    for child in ("worker-concurrent-builder", "worker-concurrent-reviewer", "worker-concurrent-second-builder", "worker-concurrent-second-reviewer"):
        assert counts[child] == 1, counts
    print("PASS autonomous child rounds, bounded single-worker execution, named history reuse and Stop", dict(counts))
finally:
    (directory / "stop.release").touch()
    (directory / "queued-stop.release").touch()
    server.shutdown()
