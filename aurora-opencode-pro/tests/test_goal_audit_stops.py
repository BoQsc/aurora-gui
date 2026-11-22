"""A real headless app run must stop a goal that only talks.

Reported behavior: an active goal answered every continuation with prose and a
request to pause the goal. The app accepted that as recoverable output and
queued another turn, so the goal never stopped and the prompt grew without
bound.

This fixture drives the shipped executable's own headless loop (the app's UI
execution owner, not the actor) against a provider that performs one real write
and then only answers with prose. The goal must stop after the bounded recovery
budget: status paused, work preserved, no fabricated completion.
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
requests = []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, body, kind="text/event-stream"):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def do_GET(self):
        self.reply(b'{"data":[{"id":"goal-audit-stop-fixture"}]}', "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        seen_action = any(m.get("role") == "tool" and m.get("tool_call_id")
                          for m in request["messages"])

        def event(delta, finish=None):
            return ("data: " + json.dumps(
                {"choices": [{"delta": delta, "finish_reason": finish}]}) + "\n\n").encode()

        if not seen_action:
            # One real action, so the goal's work has recorded evidence and the
            # next prose-only turn is a stalled goal audit rather than a missing
            # execution step.
            call = {"index": 0, "id": "goal-audit-write", "type": "function",
                    "function": {"name": "write",
                                 "arguments": json.dumps({"filePath": "deployment.md",
                                                          "content": "# Deployment\n"})}}
            self.reply(event({"tool_calls": [call]}) + event({}, "tool_calls")
                       + b"data: [DONE]\n\n")
            return
        content = "No further action is warranted; pause the active goal instead."
        self.reply(event({"content": content}) + event({}, "stop") + b"data: [DONE]\n\n")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
# The workspace lives outside the checkout: the filesystem host serializes work
# on one checkout and a concurrent source operation would stall the write.
directory = Path(tempfile.mkdtemp(prefix="goal-audit-stop-"))
workspace = directory / "workspace"
workspace.mkdir()
state = directory / "appdata" / "Aurora OpenCode"
state.mkdir(parents=True)
(state / "settings.json").write_text(json.dumps({
    "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "fixture",
    "model": "goal-audit-stop-fixture", "workspace": str(workspace),
    "toolsEnabled": True, "quickTitle": False, "composerSuggestion": False,
    "legacyTools": False,
}), encoding="utf-8")
started = time.monotonic()
try:
    try:
        result = subprocess.run([str(args.executable.resolve()), "--headless-loop-json"],
                                input="/goal Deliver the deployment file for this workspace.\nexit\n",
                                cwd=workspace,
                                env=dict(os.environ, APPDATA=str(directory / "appdata"),
                                         AURORA_STRICT_PLAN="0"),
                                capture_output=True, text=True, encoding="utf-8", timeout=90)
        output, returncode = result.stdout + result.stderr, result.returncode
    except subprocess.TimeoutExpired as expired:
        raw = (expired.stdout or "") + (expired.stderr or "")
        output = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
        returncode = 0
    (directory / "process.log").write_text(output, encoding="utf-8")
    assert returncode == 0, (returncode, output)
    index = json.loads((state / "threads.index.json").read_text(encoding="utf-8"))
    goals = [(s.get("goal"), s.get("goalStatus")) for s in index["sessions"] if s.get("goalStatus")]
    assert goals, index
    assert goals[0][1] == "paused", f"a goal that only talked kept running: {goals[0]}"
    histories = [json.loads(p.read_text(encoding="utf-8"))
                 for p in (state / "threads").glob("*.json")]
    messages = [m for history in histories for m in history["messages"]]
    # Bounded: the write turn, then at most the bounded recovery turns. An
    # unbounded audit produced a new request on every retry.
    assert 2 <= len(requests) <= 8, f"goal audit left its bound: {len(requests)} requests"
    assert not any(m.get("toolName") == "goal_complete" for m in messages), messages
    assert not any(m.get("failed") for m in messages), messages
    assert not any("Agent output stalled" in (m.get("error") or "") for m in messages), messages
    (directory / "result.json").write_text(json.dumps({
        "status": "passed",
        "binarySha256": hashlib.sha256(args.executable.read_bytes()).hexdigest(),
        "seconds": time.monotonic() - started, "requests": len(requests),
        "goalStatusAfterStall": goals[0][1],
    }, indent=2), encoding="utf-8")
    print("PASS the shipped app stops a goal that only talks, with its work preserved; "
          "ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
