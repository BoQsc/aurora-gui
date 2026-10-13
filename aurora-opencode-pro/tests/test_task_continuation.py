"""Real HTTP/SSE regressions for premature completion and bounded stalls."""
import collections
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

package = Path(__file__).resolve().parents[1]
rounds = collections.Counter()
failures = []
prompts = {
    "Finish all six fixture steps.": "work",
    "Implement the fixture stalled task.": "stall",
    "Implement the fixture task requiring a missing deployment address.": "input",
    "What does the fixture pending plan mean?": "question",
    "Finish the fixture cancellation task.": "cancel",
}


def call(identity, name, arguments):
    return {"id": identity, "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments)}}


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def body(self, body, kind):
        raw = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.body('{"data":[{"id":"continuation-fixture"}]}', "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        scenario = next(prompts[m["content"]] for m in reversed(messages)
                        if m["role"] == "user" and isinstance(m.get("content"), str)
                        and m["content"] in prompts)
        rounds[scenario] += 1
        if rounds[scenario] > 22:
            failures.append("Unbounded continuation: " + scenario)
            self.send_error(500)
            return
        owners, results = set(), {}
        for message in messages:
            for tool in message.get("tool_calls", []):
                owners.add(tool["id"])
            if message["role"] == "tool":
                identity = message["tool_call_id"]
                if identity not in owners or identity in results:
                    failures.append("Unpaired/duplicate result: " + identity)
                results[identity] = message["content"]
        continuations = sum(m["content"].count("Continuation: unfinished authorized work\n")
                            for m in messages if isinstance(m.get("content"), str))
        tools, content, delay = [], "", 0
        if scenario == "work":
            stage = continuations
            if f"write{stage}" not in results:
                tools = [call(f"plan{stage}", "update_plan", {
                    "objective": "Complete six real outcomes",
                    "plan": [{"step": f"Outcome {i}", "status": "completed" if i <= stage
                              else "in_progress" if i == stage + 1 else "pending"} for i in range(6)]}),
                    call(f"write{stage}", "write", {"filePath": f"step{stage}.md", "content": f"outcome{stage}"})]
            else:
                content = "All six outcomes completed." if stage == 5 else f"Partial outcome {stage} landed. Say the word and I will continue."
        elif scenario in ("stall", "input", "cancel"):
            if "pending-plan" not in results:
                tools = [call("pending-plan", "update_plan", {
                    "objective": "Implement fixture outcome",
                    "plan": [{"step": "Unfinished outcome", "status": "in_progress"}]})]
            elif scenario == "stall":
                content = f"Remaining work is unchanged; attempt {continuations}."
            elif scenario == "input":
                if "missing-input" not in results:
                    tools = [call("missing-input", "task_blocker", {
                        "kind": "input", "reason": "The deployment server address has not been provided.",
                        "question": "Which deployment server should I use?"})]
                else:
                    content = "Which deployment server should I use?"
            else:
                content, delay = "Partial cancellation response.", 1
        else:
            content = "The old implementation remains unfinished."
        first = {"choices": [{"delta": {"tool_calls": [{"index": i, **tool} for i, tool in enumerate(tools)]}
                             if tools else {"content": content}, "finish_reason": None}]}
        last = {"choices": [{"delta": {}, "finish_reason": "tool_calls" if tools else "stop"}]}
        wire = lambda item: ("data: " + json.dumps(item) + "\n\n").encode()
        start, end = wire(first), wire(last) + b"data: [DONE]\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(start) + len(end)))
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            self.wfile.write(start)
            self.wfile.flush()
            time.sleep(delay or 0.01)
            self.wfile.write(end)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"), "--release",
                    "task_continuation_contracts", "task_continuation_ui_contracts"],
                   cwd=package.parent, env=env, check=True, timeout=300)
    assert not failures, failures
    assert rounds == {"work": 12, "stall": 5, "input": 3, "question": 1, "cancel": 2}, rounds
    print("PASS bounded real request counts", dict(rounds))
finally:
    server.shutdown()
    server.server_close()
