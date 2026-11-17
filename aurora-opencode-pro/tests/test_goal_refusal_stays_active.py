"""A prose-only refusal on an active goal must not settle as a completed turn.

Reported behavior: the agent refused the outstanding goal work, the app accepted
the refusal as a normal completion, paused the goal, and the conversation looked
finished even though the outcome was missing.

This fixture drives the real headless loop with a provider that never acts. The
goal turn, its execution-recovery turn and the bounded output recovery must all
keep the goal active; when the retries are exhausted the turn is a visible
stall, never a completion.
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

    def do_GET(self):
        data = b'{"data":[{"id":"goal-refusal-fixture"}]}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        # Never call a tool. This is the refusal the app must not accept as a
        # completed goal turn.
        content = ("No new source change is warranted while the strict blocker is unchanged. "
                   "The goal remains active and incomplete; no completion is claimed.")
        data = ("data: " + json.dumps({"choices": [{"delta": {"content": content}, "finish_reason": None}]}) + "\n\n"
                + "data: " + json.dumps({"choices": [{"delta": {}, "finish_reason": "stop"}]})
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
directory = Path(tempfile.mkdtemp(prefix="goal-refusal-", dir=package / "build"))
workspace = directory / "workspace"
workspace.mkdir()
state = directory / "appdata" / "Aurora OpenCode"
state.mkdir(parents=True)
(state / "settings.json").write_text(json.dumps({
    "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "fixture", "model": "goal-refusal-fixture",
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
    assert result.returncode == 0, (result.returncode, result.stdout)
    assert 3 <= len(requests) <= 7, f"refusal recovery used {len(requests)} requests"
    index = json.loads((state / "threads.index.json").read_text(encoding="utf-8"))
    goals = [(s.get("goal"), s.get("goalStatus")) for s in index["sessions"] if s.get("goalStatus")]
    assert goals, index
    assert goals[0][0] == "Write deployment.md for the deployment environment.", goals
    assert goals[0][1] == "active", f"a refused goal was not kept active: {goals[0]}"
    histories = [json.loads(p.read_text(encoding="utf-8"))
                 for p in (state / "threads").glob("*.json")]
    messages = [m for history in histories for m in history["messages"]]
    stalls = [m for m in messages if m.get("failed") and
              "Agent output stalled" in (m.get("error") or "")]
    assert stalls, messages
    assert not any(m.get("toolName") == "goal_complete" for m in messages), messages
    (directory / "result.json").write_text(json.dumps({
        "status": "passed", "binarySha256": hashlib.sha256(args.executable.read_bytes()).hexdigest(),
        "seconds": time.monotonic() - started, "requests": len(requests),
        "goalStatusAfterRefusal": goals[0][1],
    }, indent=2), encoding="utf-8")
    print("PASS a prose-only goal refusal stays active and ends as a visible stall, "
          "never a completed goal; ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
