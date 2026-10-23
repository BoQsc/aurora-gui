"""Check per-response plan guidance in the built app against a local provider."""
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
requests = []
failures = []


def call(identity, name, arguments):
    return {"id": identity, "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments)}}


def plan(status):
    if status != "in_progress":
        return {"plan_mode": "patch", "plan": (
            [{"id": "write", "status": "completed"}, {"id": "verify", "status": "in_progress"}]
            if status == "checking" else
            [{"id": "verify", "status": "completed", "evidence": ["write-output", "check"]}])}
    return {"objective": "Write and verify a fixture",
            "plan": [{"id": "write", "step": "Write out.txt and its test",
                      "status": "in_progress" if status == "in_progress" else "completed",
                      **({"evidence": ["write-output", "check"]} if status == "completed" else {})},
                     {"id": "verify", "step": "Run unittest checks for out.txt",
                      "status": "pending" if status == "in_progress" else "in_progress" if status == "checking" else "completed",
                      **({"evidence": ["write-output", "check"]} if status == "completed" else {})}]}


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def respond(self, body, kind):
        body = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.respond('{"data":[{"id":"plan-review-fixture"}]}', "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        system = "\n".join(message.get("content", "") for message in request["messages"]
                           if message["role"] == "system")
        if system.count("# Plan review on every response") != 1:
            failures.append("Missing or duplicated plan-review hint")
        for instruction in ("Before every response, reassess the plan using current intent and evidence",
                            "Update changed steps/statuses/next actions via update_plan when available",
                            "Review silently; skip redundant updates", "Report unfinished work accurately"):
            if instruction not in system:
                failures.append("Missing instruction: " + instruction)
        tools = []
        for message in request["messages"]:
            if message["role"] == "tool" and message.get("content", "").startswith("Error:"):
                failures.append("Tool result rejected: " + message["content"])
        if request.get("tools"):
            number = sum(bool(previous.get("tools")) for previous in requests)
            if number == 1:
                test = ("import unittest\nfrom pathlib import Path\n"
                        "class Fixture(unittest.TestCase):\n"
                        " def test_contents(self): self.assertEqual(Path('out.txt').read_text(), 'success')\n")
                tools = [call("plan", "update_plan", plan("in_progress")),
                         call("write-output", "write", {"filePath": "out.txt", "content": "success"}),
                         call("write-check", "write", {"filePath": "test_fixture.py", "content": test})]
            elif number == 2:
                tools = [call("advance-plan", "update_plan", plan("checking")),
                         call("check", "run", {"program": "python", "args": ["-m", "unittest", "test_fixture"]})]
            elif number == 3:
                tools = [call("complete-plan", "update_plan", plan("completed"))]
        delta = {"tool_calls": [dict(tool, index=i) for i, tool in enumerate(tools)]} if tools else {"content": "READY"}
        row = {"choices": [{"delta": delta, "finish_reason": "tool_calls" if tools else "stop"}]}
        self.respond("data: " + json.dumps(row) + "\n\ndata: [DONE]\n\n", "text/event-stream")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    directory = Path(tempfile.mkdtemp(prefix="plan-review-", dir=package / "build"))
    print("ARTIFACTS", directory, flush=True)
    workspace = Path(tempfile.mkdtemp(prefix="aurora-plan-review-workspace-"))
    state = directory / "appdata" / "Aurora OpenCode"
    state.mkdir(parents=True)
    settings = {"baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "local-fixture",
                "model": "plan-review-fixture", "workspace": str(workspace),
                "legacyTools": False, "quickTitle": False}
    executable = package / "aurora-opencode-pro.exe"
    env = dict(os.environ, APPDATA=str(directory / "appdata"))
    durations = []
    for enabled in (True, False):
        settings["toolsEnabled"] = enabled
        (state / "settings.json").write_text(json.dumps(settings), encoding="utf-8")
        prompt = ("Write out.txt containing success, verify its contents with unittest, then reply READY."
                  if enabled else "Review the current plan and reply READY.")
        started = time.monotonic()
        result = subprocess.run([str(executable), "--headless", prompt], cwd=workspace,
                                env=env, timeout=60, capture_output=True, text=True)
        durations.append(time.monotonic() - started)
        (directory / f"tools-{enabled}.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        assert result.returncode == 0, result.stdout + result.stderr
    (directory / "requests.json").write_text(json.dumps(requests, indent=2), encoding="utf-8")
    assert len(requests) == 5 and sum(bool(request.get("tools")) for request in requests) == 4, \
        "Plan review introduced extra requests or missed a continuation"
    assert not failures, failures
    prefixes = [request["messages"][0]["content"] for request in requests[:4]]
    # The provider folds appended task checkpoints into the first system
    # message. Its original prefix must stay identical as that suffix grows.
    assert all(prefix.startswith(prefixes[0]) for prefix in prefixes), \
        "Plan-review hint invalidated the cached system prefix"
    assert (workspace / "out.txt").read_text() == "success"
    histories = [json.loads(path.read_text(encoding="utf-8")) for path in (state / "threads").glob("*.json")]
    updates = [message for history in histories for message in history["messages"]
               if message.get("toolName") == "update_plan"]
    assert len(updates) == 3 and not any(message.get("failed") for message in updates), \
        "Plan progress was rejected in the production tool loop"
    assert "2. [>] Run unittest checks" in updates[1]["content"]
    assert "2. [x] Run unittest checks" in updates[2]["content"]
    assert sum(any(message.get("content") == "READY" for message in history["messages"])
               for history in histories) == 2, "Responses did not complete and persist"
    assert not any("# Plan review on every response" in message.get("content", "")
                   for history in histories for message in history["messages"]), \
        "Per-response reminders accumulated in the conversation history"
    (directory / "result.json").write_text(json.dumps({"status": "passed", "requests": len(requests),
        "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "localProviderSeconds": durations}, indent=2), encoding="utf-8")
    print("PASS plan-review hints on every response; actual phase updates and mixed check receipts accepted; stable prefix; no extra requests")
finally:
    server.shutdown()
    server.server_close()
