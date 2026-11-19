"""Real app path: read_history fallback after compaction.

Builds a real conversation through the running executable's headless loop with
HTTP/SSE and native tool workers, forces compaction, then asks for a message id
that no longer exists. The fallback digest must reach the model and be used.

Run after building: python tests/test_history_fallback_live.py
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
token = "RETIRED_TOKEN=R7-2200"
# Four questions after compaction: three fallback triggers and one exact read.
questions = [
    ("The exact record may be gone. Call read_history for message_id=missing-record "
     "and reply with the retired token it returns."),
    ("Search for a fact that was never recorded. Call read_history with a query that cannot "
     "match anything "
     "and reply with the retired token it returns."),
    ("Page from a missing row. Call read_history with before_id=missing-before and "
     "query=RETIRED_TOKEN; reply with the token it returns."),
    ("Recover the exact saved requirement. Call read_history with query=RETIRED_TOKEN "
     "and role=user; reply EXACT-OK when a matching row contains the token."),
]
# Several moderate messages instead of one huge paste: painting a single
# six-figure user bubble stalls the headless UI before the request even starts,
# which is unrelated to the fallback under test.
prompts = [
    "Remember this reference for later questions and reply RECORDED: " + token + " " +
    "historical padding " * 220,
] + [
    "Remember context chunk %d and reply RECORDED: " % index + token + " " +
    "unrelated context " * 250
    for index in range(2, 13)
] + questions


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
        body = b'{"data":[{"id":"fallback-fixture"}]}'
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        try:
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            messages = request["messages"]
            if not request.get("tools"):
                system = next((str(m.get("content", "")) for m in messages
                               if m.get("role") == "system"), "")
                if "continuation checkpoint" not in system:
                    # Follow-up suggestions are not compaction summaries.
                    return self.send("Continue the current task.")
                summaries.append(request)
                # The checkpoint keeps a durable decision; the exact record for
                # the requested id is deliberately not recoverable.
                return self.send(
                    "Goal: retain the reference material for later questions. "
                    "Constraints: answer precisely. Decisions: " + token +
                    " remains in the retired checkpoint. Evidence: reference received. "
                    "Blocker: none. Next action: answer the latest question."
                )
            requests.append(request)
            names = {tool["function"]["name"] for tool in request["tools"]}
            assert "read_history" in names, "Recall tool not advertised"
            if len(requests) > len(prompts) * 3:
                raise AssertionError("fallback probe added repeated continuation rounds")
            user_texts = [str(m.get("content", "")) for m in messages
                          if m.get("role") == "user"]
            current = next((text for text in reversed(user_texts) if text in questions), None)
            if current is None:
                return self.send("RECORDED")
            owners, results = set(), {}
            for message in messages:
                owners.update(c["id"] for c in message.get("tool_calls", []))
                if message["role"] == "tool":
                    identity = message["tool_call_id"]
                    assert identity in owners and identity not in results, "Unpaired/duplicate tool result"
                    results[identity] = message["content"]
            scenario = {
                questions[0]: ("fb-missing", {"message_id": "missing-record"}, "message_id"),
                questions[1]: ("fb-query", {"query": "PRIVATE-ABSENT-4411"}, None),
                questions[2]: ("fb-before", {"before_id": "missing-before", "query": token}, "before_id"),
                questions[3]: ("fb-exact", {"query": token, "role": "user"}, None),
            }[current]
            identity, arguments, reason = scenario
            if identity not in results:
                return self.send(calls=[call(identity, "read_history", arguments)])
            result = json.loads(results[identity])
            if current == questions[3]:
                assert result.get("fallback") is not True, "exact recall reported a fallback"
                rows = result.get("messages", [])
                assert rows and any(token in row.get("text", "") for row in rows), \
                    "exact recall did not return the saved token"
                return self.send("EXACT-OK")
            assert result.get("fallback") is True, \
                "read_history did not return a fallback digest: " + str(result)[:400]
            if reason:
                assert reason in result.get("fallback_reason", ""), \
                    "fallback did not name the failed " + reason
            assert result.get("retired_messages", 0) > 0, "fallback reported no retired messages"
            assert len(result.get("messages", [])) == 1, "fallback did not return a digest row"
            text = result["messages"][0]["text"]
            assert token in text, "fallback digest lost the retired token"
            assert "Retired checkpoint digest" in text, "fallback digest is not labelled"
            return self.send("FALLBACK-OK")
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
directory = Path(tempfile.mkdtemp(prefix="history-fallback-"))
workspace = directory / "workspace"
workspace.mkdir()
state = directory / "appdata" / "Aurora OpenCode"
state.mkdir(parents=True)
endpoint = f"http://127.0.0.1:{server.server_port}/v1"
(state / "settings.json").write_text(json.dumps({
    "baseUrl": endpoint, "apiKey": "local-fixture", "model": "fallback-fixture",
    "workspace": str(workspace), "toolsEnabled": True, "legacyTools": False,
    "quickTitle": False, "composerSuggestion": False,
    "autoGoalFromFirstMessage": False,
    "contextBudgets": [{"baseUrl": endpoint, "model": model, "tokens": 32000}
                       for model in ("fallback-fixture", "deepseek/deepseek-v4.1-flash-fast",
                                     "deepseek/deepseek-v4.1-flash")],
    "contextCompactions": [{"baseUrl": endpoint, "model": model}
                          for model in ("fallback-fixture", "deepseek/deepseek-v4.1-flash-fast",
                                        "deepseek/deepseek-v4.1-flash")],
}), encoding="utf-8")
started = time.monotonic()
try:
    result = subprocess.run([str(args.executable.resolve()), "--headless-loop-json"],
                            input="\n".join(prompts + ["exit"]) + "\n", cwd=workspace,
                            env=dict(os.environ, APPDATA=str(directory / "appdata"),
                                     AURORA_STRICT_PLAN="0"),
                            capture_output=True, text=True, encoding="utf-8", timeout=300)
    (directory / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    (directory / "requests.json").write_text(json.dumps({
        "requests": requests, "summaries": summaries, "failures": failures,
    }, ensure_ascii=False), encoding="utf-8")
    assert not failures, (failures[:3], directory)
    assert result.returncode == 0, (result.returncode, result.stdout[-2000:], result.stderr[-1000:])
    replies = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"')]
    assert len(replies) == len(prompts), replies
    assert [reply["reply"] for reply in replies[-4:]] == \
        ["FALLBACK-OK", "FALLBACK-OK", "FALLBACK-OK", "EXACT-OK"], replies[-4:]
    assert summaries, "compaction never ran"
    assert requests, "no main request reached the provider"
    histories = [json.loads(p.read_text(encoding="utf-8")) for p in (state / "threads").glob("*.json")]
    assert any(m.get("content") == prompts[2].strip() for h in histories for m in h["messages"]), \
        "the original transcript was not preserved"
    (directory / "result.json").write_text(json.dumps({
        "status": "passed",
        "binarySha256": hashlib.sha256(args.executable.read_bytes()).hexdigest(),
        "seconds": time.monotonic() - started,
        "mainRequests": len(requests), "summaryRequests": len(summaries),
        "fallbackTriggers": ["missing message_id", "no-match query", "missing before_id"],
        "exactRecallAfterFallback": True, "retiredTokenRecovered": token,
    }, indent=2), encoding="utf-8")
    print("PASS real compaction, three read_history fallback triggers, exact recall and answers; ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
