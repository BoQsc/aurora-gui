"""Real HTTP/SSE, compaction and exact recall using an isolated desktop process.

Run after building: python tests/test_history_recall.py [--executable path]
No hosted provider, user history or real workspace is used.
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
parser = argparse.ArgumentParser()
parser.add_argument("--executable", type=Path, default=package / "aurora-opencode-pro.exe")
args = parser.parse_args()
requests, summaries, failures = [], [], []
reference = "REFERENCE_RECORD " + "historical padding " * 400 + "CRITICAL_REFERENCE_VALUE=Q9-7316 " + "historical padding " * 400
prompts = [
    "Remember this reference for later questions and reply RECORDED: " + reference,
    "Remember this additional context and reply RECORDED: " + "unrelated context " * 7000,
    "What is CRITICAL_REFERENCE_VALUE? Recover the exact original reference with read_history and return only the value.",
]


def call(identity, name, arguments):
    return {"id": identity, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send(self, content="", calls=()):
        delta = {"tool_calls": [dict(c, index=i) for i, c in enumerate(calls)]} if calls else {"content": content}
        body = ("data: " + json.dumps({"choices": [{"delta": delta, "finish_reason": None}]}) + "\n\n"
                + "data: " + json.dumps({"choices": [{"delta": {}, "finish_reason": "tool_calls" if calls else "stop"}]})
                + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass

    def do_GET(self):
        body = b'{"data":[{"id":"history-fixture"}]}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        try:
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            messages = request["messages"]
            if not request.get("tools"):
                summaries.append(request)
                # Deliberately omit the middle fact: recovery must use the
                # preserved transcript rather than a convenient summary.
                return self.send("Goal: retain reference material for later questions. Constraints: answer precisely. "
                                 "Decisions: original messages remain saved. Evidence: reference received. "
                                 "Blocker: none. Next action: answer the latest question, retrieving exact details when needed.")
            requests.append(request)
            names = {tool["function"]["name"] for tool in request["tools"]}
            assert "read_history" in names, "Recall tool not advertised"
            if len(requests) > 8:
                raise AssertionError("Recall added repeated continuation rounds")
            question = any(m.get("role") == "user" and m.get("content") == prompts[2] for m in messages)
            if not question:
                return self.send("RECORDED")
            owners, results = set(), {}
            for message in messages:
                owners.update(c["id"] for c in message.get("tool_calls", []))
                if message["role"] == "tool":
                    identity = message["tool_call_id"]
                    assert identity in owners and identity not in results, "Unpaired/duplicate tool result"
                    results[identity] = message["content"]
            if "find-reference" not in results:
                assert not any("Q9-7316" in str(m.get("content", "")) for m in messages), "Fixture failed to omit the middle fact"
                return self.send(calls=[call("find-reference", "read_history", {"query": "CRITICAL_REFERENCE_VALUE=", "role": "user"})])
            result = json.loads(results["find-reference"])
            row = result["messages"][0]
            assert "Q9-7316" in row["text"], "Exact fact was not retrieved"
            if "read-reference" not in results:
                return self.send(calls=[call("read-reference", "read_history", {
                    "message_id": row["message_id"], "offset": row["offset"], "limit": 600})])
            assert "Q9-7316" in json.loads(results["read-reference"])["messages"][0]["text"]
            return self.send("Q9-7316")
        except Exception as error:
            failures.append(str(error))
            self.send("FIXTURE_FAILED")


class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, address):
        import sys
        if not isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError, ConnectionAbortedError)):
            super().handle_error(request, address)


server = Server(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
directory = Path(tempfile.mkdtemp(prefix="history-recall-", dir=package / "build"))
workspace = directory / "workspace"
workspace.mkdir()
state = directory / "appdata" / "Aurora OpenCode"
state.mkdir(parents=True)
endpoint = f"http://127.0.0.1:{server.server_port}/v1"
(state / "settings.json").write_text(json.dumps({
    "baseUrl": endpoint, "apiKey": "local-fixture", "model": "history-fixture",
    "workspace": str(workspace), "toolsEnabled": True, "legacyTools": False, "quickTitle": False,
    "autoGoalFromFirstMessage": True,
    "contextBudgets": [{"baseUrl": endpoint, "model": "history-fixture", "tokens": 32000}],
    "contextCompactions": [{"baseUrl": endpoint, "model": "history-fixture"}],
}), encoding="utf-8")
started = time.monotonic()
try:
    result = subprocess.run([str(args.executable.resolve()), "--headless-loop-json"],
                            input="\n".join(prompts + ["exit"]) + "\n", cwd=workspace,
                            env=dict(os.environ, APPDATA=str(directory / "appdata"), AURORA_STRICT_PLAN="0"),
                            capture_output=True, text=True, encoding="utf-8", timeout=90)
    (directory / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    (directory / "requests.json").write_text(json.dumps({"requests":requests,"summaries":summaries,"failures":failures}), encoding="utf-8")
    assert not failures, (failures[:3], directory)
    assert result.returncode == 0, (result.returncode, result.stdout[-2000:], result.stderr[-1000:])
    replies = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"')]
    assert len(replies) == 3 and replies[-1]["reply"] == "Q9-7316", replies
    assert summaries and len(requests) == 5, (len(summaries), len(requests))
    assert not failures, failures
    histories = [json.loads(p.read_text(encoding="utf-8")) for p in (state / "threads").glob("*.json")]
    assert any(m.get("content") == prompts[0].strip() for h in histories for m in h["messages"])
    (directory / "result.json").write_text(json.dumps({
        "status": "passed", "binarySha256": hashlib.sha256(args.executable.read_bytes()).hexdigest(),
        "seconds": time.monotonic() - started, "mainRequests": len(requests), "summaryRequests": len(summaries),
        "originalHistoryPreserved": True, "exactMiddleFactRecovered": True,
    }, indent=2), encoding="utf-8")
    print("PASS real compaction, two recall tools, exact answer, five main requests and durable history; ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
