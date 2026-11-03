"""A real goal waits for a missing fact, resumes on the reply and completes."""
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
parser = argparse.ArgumentParser()
parser.add_argument("--executable", type=Path, default=package / "aurora-opencode-pro.exe")
args = parser.parse_args()
requests, failures = [], []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        data = b'{"data":[{"id":"goal-input-fixture"}]}'
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
        supplied = any(m["role"] == "user" and m.get("content") == "Use staging." for m in messages)
        content, tool = "", None
        if len(requests) > 7:
            failures.append("Goal did not wait or settle")
            content = "FIXTURE_FAILED"
        elif not supplied and "missing-fact" not in results:
            tool = ("missing-fact", "request_input", {
                "reason": "The deployment environment name is absent from available configuration",
                "required_fact": "Deployment environment name", "question": "Which environment should the note name?",
                "checked": ["Workspace configuration"], "independent_work_complete": True,
            })
        elif not supplied:
            content = "Which environment should the note name?"
        elif "save-note" not in results:
            assert "goal_complete" in {t["function"]["name"] for t in request["tools"]}, "Reply left the goal paused"
            tool = ("save-note", "write", {"filePath": "deployment.md", "content": "Environment: staging"})
        elif "complete-goal" not in results:
            tool = ("complete-goal", "goal_complete", {"summary": "Saved the staging deployment note", "evidence": ["save-note"]})
        else:
            if "Error:" in results["complete-goal"]:
                failures.append(results["complete-goal"])
            content = "Saved deployment.md for staging."
        delta = {"content": content}
        if tool:
            identity, name, arguments = tool
            delta = {"tool_calls": [{"index": 0, "id": identity, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}]}
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
directory = Path(tempfile.mkdtemp(prefix="goal-input-", dir=package / "build"))
workspace = directory / "workspace"
workspace.mkdir()
state = directory / "appdata" / "Aurora OpenCode"
state.mkdir(parents=True)
(state / "settings.json").write_text(json.dumps({
    "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "fixture", "model": "goal-input-fixture",
    "workspace": str(workspace), "toolsEnabled": True, "quickTitle": False, "composerSuggestion": False, "legacyTools": False,
}), encoding="utf-8")
started = time.monotonic()
try:
    result = subprocess.run([str(args.executable.resolve()), "--headless-loop-json"],
                            input="/goal Write deployment.md for the environment after obtaining its missing name.\nUse staging.\nexit\n",
                            cwd=workspace, env=dict(os.environ, APPDATA=str(directory / "appdata"), AURORA_STRICT_PLAN="0"),
                            capture_output=True, text=True, encoding="utf-8", timeout=45)
    (directory / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    assert result.returncode == 0, (result.returncode, result.stdout, failures)
    replies = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"')]
    assert len(replies) == 2 and replies[0]["taskStatus"] == "waiting_input", replies
    assert replies[1]["reply"] == "Saved deployment.md for staging.", replies
    assert not failures and len(requests) == 5, (failures, len(requests))
    assert (workspace / "deployment.md").read_text() == "Environment: staging"
    index = json.loads((state / "threads.index.json").read_text(encoding="utf-8"))
    assert any(s.get("goalStatus") == "completed" for s in index["sessions"]), index
    (directory / "result.json").write_text(json.dumps({
        "status": "passed", "binarySha256": hashlib.sha256(args.executable.read_bytes()).hexdigest(),
        "seconds": time.monotonic() - started, "requests": len(requests),
        "goalCompletedAfterReply": True,
    }, indent=2), encoding="utf-8")
    print("PASS active goal waits, resumes on a reply and completes in five HTTP requests; ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
