"""An active goal cannot be closed by summarizing its audit as unmet.

Reported behavior: the assistant refused the remaining goal work, then called
goal_complete with a summary saying the goal was "found unmet" / "a critical
failure". That was accepted, the goal became completed, and automatic
continuation stopped with the requested outcome still missing.

This fixture drives the real headless loop with the completion call itself: the
model tries to close the action goal with an unmet summary (which must be
refused and leave the goal active), then asks for the one user-owned fact it
actually needs. Only in-process tools are used, so no filesystem or process host
is involved.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

package = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--executable", type=Path, default=package / "aurora-opencode-pro.exe")
args = parser.parse_args()
requests, failures = [], []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        data = b'{"data":[{"id":"goal-unmet-fixture"}]}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        messages = request["messages"]
        results = {m["tool_call_id"]: m["content"] for m in messages if m["role"] == "tool"}
        content, tool = "", None
        if len(requests) > 4:
            failures.append("The refused goal completion did not settle")
            content = "FIXTURE_FAILED"
        elif "failed-close" not in results:
            tool = ("failed-close", "goal_complete", {
                "summary": "Strict deployment goal audited and found unmet: the requested outcome is not achieved."})
        elif "missing-fact" not in results:
            tool = ("missing-fact", "request_input", {
                "reason": "The deployment environment name is absent from available configuration",
                "required_fact": "Deployment environment name",
                "question": "Which environment should the deployment note name?",
                "checked": ["Workspace configuration"], "independent_work_complete": True})
        else:
            content = "Waiting for the deployment environment."
        delta = {"content": content}
        if tool:
            identity, name, arguments = tool
            delta = {"tool_calls": [{"index": 0, "id": identity, "type": "function",
                "function": {"name": name, "arguments": json.dumps(arguments)}}]}
        data = ("data: " + json.dumps({"choices": [{"delta": delta, "finish_reason": None}]}) + "\n\n"
                + "data: " + json.dumps({"choices": [{"delta": {}, "finish_reason": "tool_calls" if tool else "stop"}]})
                + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
directory = Path(tempfile.mkdtemp(prefix="goal-unmet-", dir=package / "build"))
workspace = directory / "workspace"
workspace.mkdir()
state = directory / "appdata" / "Aurora OpenCode"
state.mkdir(parents=True)
(state / "settings.json").write_text(json.dumps({
    "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "fixture", "model": "goal-unmet-fixture",
    "workspace": str(workspace), "toolsEnabled": True, "quickTitle": False, "composerSuggestion": False,
    "legacyTools": False,
}), encoding="utf-8")
started = time.monotonic()
try:
    result = subprocess.run([str(args.executable.resolve()), "--headless-loop-json"],
                            input="/goal Write deployment.md for the deployment environment.\nexit\n",
                            cwd=workspace, env=dict(os.environ, APPDATA=str(directory / "appdata"),
                                                    AURORA_STRICT_PLAN="0"),
                            capture_output=True, text=True, encoding="utf-8", timeout=60)
    (directory / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    assert result.returncode == 0, (result.returncode, result.stdout, failures)
    assert not failures, failures
    assert not (workspace / "deployment.md").exists()
    index = json.loads((state / "threads.index.json").read_text(encoding="utf-8"))
    goals = [(s.get("goal"), s.get("goalStatus")) for s in index["sessions"] if s.get("goalStatus")]
    assert goals and goals[0] == ("Write deployment.md for the deployment environment.", "active"), goals
    histories = [json.loads(p.read_text(encoding="utf-8"))
                 for p in (state / "threads").glob("*.json")]
    messages = [m for history in histories for m in history["messages"]]
    refused = next(m for m in messages if m.get("toolCallId") == "failed-close")
    assert refused.get("failed") is True, refused
    assert "unmet or failed" in refused["content"], refused
    assert next(m for m in messages if m.get("toolCallId") == "missing-fact").get("failed") is not True
    (directory / "result.json").write_text(json.dumps({
        "status": "passed", "binarySha256": hashlib.sha256(args.executable.read_bytes()).hexdigest(),
        "seconds": time.monotonic() - started, "requests": len(requests),
        "goalStayedActiveAfterUnmetClose": True,
    }, indent=2), encoding="utf-8")
    print("PASS unmet goal_complete is refused, the goal stays active, and the model "
          "must ask for the fact it actually needs; ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
