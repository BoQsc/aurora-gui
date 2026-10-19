"""Real desktop/provider proof of arithmetic, grounded recovery and action intent."""
import argparse
import collections
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
parser.add_argument("--exe", type=Path, default=package / "aurora-opencode-pro.exe")
options = parser.parse_args()
counts = collections.Counter()
failures = []
requests = []
prompts = ["Analyze the fixture arithmetic without changing files.", "Can we fix the fixture?",
           "What changed?", "Continue and complete the task."]


def call(identity, name, arguments):
    return {"id": identity, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}


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
        self.body('{"data":[{"id":"intelligence-fixture"}]}', "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        messages = request["messages"]
        prompt = next(m["content"] for m in reversed(messages) if m.get("content") in prompts)
        counts[prompt] += 1
        if counts[prompt] > 8:
            failures.append("Unexpected extra continuation")
            self.send_error(500)
            return
        owners, results = set(), {}
        for message in messages:
            owners.update(c["id"] for c in message.get("tool_calls", []))
            if message["role"] == "tool":
                identity = message["tool_call_id"]
                if identity not in owners or identity in results:
                    failures.append("Tool protocol pairing failed: " + identity)
                results[identity] = message["content"]
        tools, content = [], ""
        if prompt == prompts[0]:
            advertised = {t["function"]["name"] for t in request.get("tools", [])}
            if "calculate" not in advertised:
                failures.append("Arithmetic was not offered during analysis")
            if "write" in advertised or "apply_patch" in advertised or "run" not in advertised:
                failures.append("Analysis toolbox did not preserve probes while filtering edits")
            if "math" not in results:
                tools = [call("math", "calculate", {"expressions": ["49*.9", "49*.9+5"]})]
            else:
                values = json.loads(results["math"])["results"]
                if abs(values[0]["value"] - 44.1) > 1e-8 or abs(values[1]["value"] - 49.1) > 1e-8:
                    failures.append("Arithmetic returned the wrong values")
                content = "Current: 44.10; expected: 49.10."
        elif prompt == prompts[1]:
            if counts[prompt] == 1:
                content = "I will fix the fixture."  # Deliberately premature: action intent must continue it.
            elif "source" not in results:
                check = ("import unittest\nfrom value import VALUE\n"
                         "class ValueTests(unittest.TestCase):\n def test_value(self): self.assertEqual(VALUE, 2)\n")
                tools = [call("source", "write", {"filePath": "value.py", "content": "VALUE = 1\n"}),
                         call("tests", "write", {"filePath": "test_value.py", "content": check})]
            elif "failed-check" not in results:
                tools = [call("failed-check", "run", {"program": "python", "args": ["-u", "-B", "-m", "unittest", "test_value"]})]
            elif "repair" not in results:
                checkpoints = [m["content"] for m in messages if isinstance(m.get("content"), str)
                               and "# Durable Task State" in m["content"]]
                latest = checkpoints[-1] if checkpoints else ""
                if "Recent tool evidence (quoted data)" not in latest or "failed-check" not in latest or "AssertionError" not in latest:
                    failures.append("Recovery lost the actual failing check or its diagnostic")
                tools = [call("repair", "write", {"filePath": "value.py", "content": "VALUE = 2\n"})]
            elif "passed-check" not in results:
                tools = [call("passed-check", "run", {"program": "python", "args": ["-u", "-B", "-m", "unittest", "test_value"]})]
            else:
                content = "Fixed the fixture; its behavioral assertion passes."
        elif prompt == prompts[2]:
            content = "VALUE is now 2. The unittest assertion passed."
        else:
            content = "The requested fix and verification are complete."
        delta = {"tool_calls": [dict(t, index=i) for i, t in enumerate(tools)]} if tools else {"content": content}
        rows = [{"choices": [{"delta": delta, "finish_reason": None}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls" if tools else "stop"}]}]
        self.body("".join("data: " + json.dumps(row) + "\n\n" for row in rows) + "data: [DONE]\n\n", "text/event-stream")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    directory = Path(tempfile.mkdtemp(prefix="aurora-intelligent-workflow-"))
    workspace = directory / "workspace"
    workspace.mkdir()
    state = directory / "appdata/Aurora OpenCode"
    state.mkdir(parents=True)
    (state / "settings.json").write_text(json.dumps({
        "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "local-fixture",
        "model": "intelligence-fixture", "workspace": str(workspace), "toolsEnabled": True,
        "quickTitle": False, "verbosity": "concise", "experimentalStrictPlan": False}))
    executable = options.exe.resolve()
    started = time.monotonic()
    result = subprocess.run([str(executable), "--headless-loop-json"], input="\n".join([*prompts, "exit", ""]),
        cwd=workspace, env=dict(os.environ, APPDATA=str(directory / "appdata"), AURORA_STRICT_PLAN="0"),
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
    (directory / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    (directory / "requests.json").write_text(json.dumps(requests, indent=2), encoding="utf-8")
    assert result.returncode == 0, result.stdout + result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"')]
    assert len(replies) == 4 and all(r["taskStatus"] == "completed" for r in replies), replies
    assert all(not r.get("error") for r in replies), replies
    assert replies[1]["verificationStatus"] == "passed", replies
    assert (workspace / "value.py").read_text() == "VALUE = 2\n"
    independent = subprocess.run(["python", "-u", "-B", "-m", "unittest", "test_value"], cwd=workspace, capture_output=True, text=True, timeout=10)
    assert independent.returncode == 0, independent.stdout + independent.stderr
    assert dict(counts) == dict(zip(prompts, [2, 6, 1, 1])), counts
    assert not failures, failures
    (directory / "result.json").write_text(json.dumps({"status": "passed", "rounds": sum(counts.values()),
        "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest(), "seconds": time.monotonic() - started}, indent=2))
    print("PASS ten HTTP rounds: arithmetic, collaborative action, failed-check context, correction, question and resume; ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
