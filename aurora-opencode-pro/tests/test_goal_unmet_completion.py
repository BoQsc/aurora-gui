"""An active goal cannot be closed by summarizing its audit as unmet.

Reported behavior: the assistant refused the remaining goal work, then called
goal_complete with a summary saying the goal was "found unmet" / "a critical
failure". That was accepted, the goal became completed, and automatic
continuation stopped with the requested outcome still missing.

This fixture drives the real headless loop: the model plans, does the work and
runs an actual check (process tools only, so no filesystem host is involved),
tries to close the goal as unmet (which must be refused with an error), then
completes it with the achieved result.

Run it standalone against a built executable; the app's own verify step cannot
host the nested process tools this fixture drives.
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
        if len(requests) > 8:
            failures.append("The refused goal completion did not resume useful work")
            content = "FIXTURE_FAILED"
        elif "plan" not in results:
            tool = ("plan", "update_plan", {"plan": [
                {"id": "deliver", "step": "Calculate the deployment total", "kind": "edit", "status": "in_progress"}]})
        elif "run-calc" not in results:
            tool = ("run-calc", "run", {"program": "python",
                "args": ["-c", "open('total.txt', 'w').write('42')"]})
        elif "complete-plan" not in results:
            tool = ("complete-plan", "update_plan", {"plan_mode": "patch", "plan": [
                {"id": "deliver", "status": "completed", "evidence": ["run-calc"]}]})
        elif "check" not in results:
            tool = ("check", "verify", {"inputs": ["total.txt"], "steps": [{"kind": "tests",
                "command": {"program": "python", "args": ["-c", "assert open('total.txt').read() == '42'"]}}]})
        elif "failed-close" not in results:
            tool = ("failed-close", "goal_complete", {
                "summary": "Strict deployment goal audited and found unmet: the requested outcome is not achieved.",
                "evidence": ["run-calc"]})
        elif "complete-goal" not in results:
            if "unmet or failed" not in results["failed-close"]:
                failures.append("An unmet goal summary was accepted as completion: " + results["failed-close"])
            tool = ("complete-goal", "goal_complete", {
                "summary": "Calculated and published the deployment total: 42.",
                "evidence": ["run-calc", "check"]})
        else:
            if "Error:" in results["complete-goal"]:
                failures.append(results["complete-goal"])
            content = "The calculated deployment total is 42."
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
                            input="/goal Publish the calculated deployment total for the release.\nexit\n",
                            cwd=workspace, env=dict(os.environ, APPDATA=str(directory / "appdata"),
                                                    AURORA_STRICT_PLAN="0"),
                            capture_output=True, text=True, encoding="utf-8", timeout=180)
    (directory / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    assert result.returncode == 0, (result.returncode, result.stdout, failures)
    assert not failures, failures
    index = json.loads((state / "threads.index.json").read_text(encoding="utf-8"))
    completed = [s for s in index["sessions"] if s.get("goalStatus") == "completed"]
    assert len(completed) == 1, index
    histories = [json.loads(p.read_text(encoding="utf-8"))
                 for p in (state / "threads").glob("*.json")]
    messages = [m for history in histories for m in history["messages"]]
    refused = next(m for m in messages if m.get("toolCallId") == "failed-close")
    assert refused.get("failed") is True, refused
    assert "unmet or failed" in refused["content"], refused
    calculated = next(m for m in messages if m.get("toolCallId") == "run-calc")
    assert not calculated.get("failed"), calculated
    checked = next(m for m in messages if m.get("toolCallId") == "check")
    assert not checked.get("failed"), checked
    accepted = next(m for m in messages if m.get("toolCallId") == "complete-goal")
    assert not accepted.get("failed"), accepted
    (directory / "result.json").write_text(json.dumps({
        "status": "passed", "binarySha256": hashlib.sha256(args.executable.read_bytes()).hexdigest(),
        "seconds": time.monotonic() - started, "requests": len(requests),
        "goalCompletedOnlyAfterRealWork": True,
    }, indent=2), encoding="utf-8")
    print("PASS unmet goal_complete is refused, the goal stays active, and it completes only "
          "after the real result; ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
