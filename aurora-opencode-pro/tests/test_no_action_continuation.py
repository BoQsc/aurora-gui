"""A production agent turn must stop after a no-action automatic continuation."""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

package = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--executable", type=Path, default=package / "aurora-opencode-pro.exe")
args = parser.parse_args()
executable = args.executable.resolve(strict=True)
requests = []


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def respond(self, text, kind):
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.respond('{"data":[{"id":"no-action-fixture"}]}', "application/json")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(body)
        if len(requests) == 1:
            delta = {"tool_calls": [{"index": 0, "id": "plan", "type": "function",
                "function": {"name": "update_plan", "arguments": json.dumps({"plan": [
                    {"step": "Implement the requested feature", "status": "in_progress"},
                    {"step": "Verify the result", "status": "pending"}]})}}]}
            finish = "tool_calls"
        else:
            delta = {"content": "The implementation still needs work."}
            finish = "stop"
        row = {"choices": [{"delta": delta, "finish_reason": finish}]}
        self.respond("data: " + json.dumps(row) + "\n\ndata: [DONE]\n\n", "text/event-stream")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
directory = Path(tempfile.mkdtemp(prefix="no-action-continuation-", dir=package / "build"))
print("ARTIFACTS", directory, flush=True)
try:
    state = directory / "appdata" / "Aurora OpenCode"
    state.mkdir(parents=True)
    workspace = directory / "workspace"
    workspace.mkdir()
    settings = {"baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "fixture",
                "model": "no-action-fixture", "workspace": str(workspace),
                "toolsEnabled": True, "quickTitle": False, "thinking": False,
                "autoGoalFromFirstMessage": True}
    (state / "settings.json").write_text(json.dumps(settings))
    result = subprocess.run([str(executable), "--headless-loop-json"],
        input="Write result.txt and verify its contents.\nexit\n", text=True,
        encoding="utf-8", errors="replace", capture_output=True, cwd=workspace,
        env=dict(os.environ, APPDATA=str(directory / "appdata"), AURORA_STRICT_PLAN="0"), timeout=45)
    (directory / "output.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    assert result.returncode == 0, result.stdout + result.stderr
    rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    assert len(rows) == 1, result.stdout
    assert len(requests) == 3, f"No-action continuation generated {len(requests)} requests instead of 3"
    assert rows[0]["turnStatus"] == "idle" and rows[0]["taskStatus"] == "active", rows
    assert not rows[0]["error"], rows
    histories = [json.loads(p.read_text(encoding="utf-8")) for p in (state / "threads").glob('*.json')]
    messages = [m for history in histories for m in history["messages"]]
    assert not any(m.get("failed") for m in messages), "No-action stop polluted the transcript with a failure"
    assert not any(m.get("content", "").startswith("Agent output recovery:") for m in messages)
    (directory / "result.json").write_text(json.dumps({"status": "passed", "requests": len(requests),
        "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest(), "turn": rows[0]}, indent=2))
    print("PASS three requests: plan, response, one no-action continuation; idle turn, active unfinished work, no recovery loop")
finally:
    server.shutdown()
    server.server_close()
