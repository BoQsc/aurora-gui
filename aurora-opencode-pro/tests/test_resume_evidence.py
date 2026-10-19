"""Verify resumed work in the built desktop image, without a paid provider."""
import collections
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
options = parser.parse_args()
rounds = collections.Counter()
failures = []
initial = "Write the fixture document and verify it after I provide the delivery label."
resume = "The delivery label is staging. Continue the task."
planning = "Plan how to fix the fixture without changing files."


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
        self.body('{"data":[{"id":"resume-fixture"}]}', "application/json")

    def do_POST(self):
        messages = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["messages"]
        resumed = any(m.get("content") == resume for m in messages)
        started = any(m.get("content") == initial for m in messages)
        scenario = "resume" if resumed else "initial" if started else "planning"
        rounds[scenario] += 1
        if rounds[scenario] > 5:
            failures.append("An already saved document demanded further continuation")
            self.send_error(500)
            return
        owners, results = set(), {}
        for message in messages:
            owners.update(c["id"] for c in message.get("tool_calls", []))
            if message["role"] == "tool":
                identity = message["tool_call_id"]
                if identity not in owners or identity in results:
                    failures.append("Unpaired tool result: " + identity)
                results[identity] = message["content"]
                if message["content"].startswith("Error:") and identity != "forbidden-plan-write":
                    failures.append(message["content"])
        tools, content = [], ""
        if scenario == "planning":
            if "forbidden-plan-write" not in results:
                tools = [call("forbidden-plan-write", "write", {"filePath": "forbidden.md", "content": "unrequested implementation"})]
            else:
                if not results["forbidden-plan-write"].startswith("Error:"):
                    failures.append("A planning-only request allowed a workspace mutation")
                content = "Inspect the fixture, identify the defect, and propose the smallest correction."
        elif not resumed:
            if "save" not in results:
                check = ("import unittest\nfrom pathlib import Path\n"
                         "class Contents(unittest.TestCase):\n"
                         " def test_saved(self): self.assertEqual(Path('out.md').read_text(), 'saved')\n")
                tools = [call("save", "write", {"filePath": "out.md", "content": "saved"}),
                         call("test", "write", {"filePath": "test_fixture.py", "content": check})]
            elif "label" not in results:
                tools = [call("label", "request_input", {
                    "reason": "The requested delivery label has not been provided.",
                    "required_fact": "Delivery label", "question": "Which delivery label should I use?",
                    "checked": ["The request and workspace contain no delivery label"],
                    "independent_work_complete": True})]
            else:
                content = "Document saved. Which delivery label should I use?"
        elif "check" not in results:
            if "save" not in results:
                failures.append("Resume lost the earlier write result")
            tools = [call("check", "run", {"program": "python", "args": ["-u", "-B", "-m", "unittest", "test_fixture"]})]
        else:
            content = "Document verified for staging."
        delta = {"tool_calls": [dict(tool, index=i) for i, tool in enumerate(tools)]} if tools else {"content": content}
        rows = [{"choices": [{"delta": delta, "finish_reason": None}]},
                {"choices": [{"delta": {}, "finish_reason": "tool_calls" if tools else "stop"}]}]
        self.body("".join("data: " + json.dumps(row) + "\n\n" for row in rows) + "data: [DONE]\n\n", "text/event-stream")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    directory = Path(tempfile.mkdtemp(prefix="production-resume-", dir=package / "build"))
    workspace = directory / "workspace"
    workspace.mkdir()
    state = directory / "appdata/Aurora OpenCode"
    state.mkdir(parents=True)
    (state / "settings.json").write_text(json.dumps({
        "baseUrl": f"http://127.0.0.1:{server.server_port}/v1", "apiKey": "local-fixture",
        "model": "resume-fixture", "workspace": str(workspace), "toolsEnabled": True,
        "legacyTools": False, "quickTitle": False, "experimentalStrictPlan": False}))
    executable = options.executable.resolve()
    started = time.monotonic()
    result = subprocess.run([str(executable), "--headless-loop-json"],
        input=planning + "\n" + initial + "\n" + resume + "\nexit\n", cwd=workspace,
        env=dict(os.environ, APPDATA=str(directory / "appdata"), AURORA_STRICT_PLAN="0"),
        capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
    (directory / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    assert result.returncode == 0, result.stdout + result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{"')]
    assert len(replies) == 3, replies
    assert replies[0]["taskStatus"] == "completed" and not (workspace / "forbidden.md").exists(), replies
    assert replies[1]["taskStatus"] == "waiting_input", replies
    assert replies[2]["taskStatus"] == "completed" and replies[2]["verificationStatus"] == "passed", replies
    assert replies[2]["reply"] == "Document verified for staging.", replies
    assert rounds == {"planning": 2, "initial": 3, "resume": 2}, rounds
    assert not failures, failures
    saved = [json.loads(p.read_text(encoding="utf-8")) for p in (state / "threads").glob("*.json")]
    writes = [m for chat in saved for m in chat["messages"] if m.get("role") == "tool" and m.get("toolName") == "write" and not m.get("failed")]
    assert len(writes) == 2, "Resuming needlessly rewrote an already saved artifact"
    assert (workspace / "out.md").read_text() == "saved"
    (directory / "result.json").write_text(json.dumps({
        "status": "passed", "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
        "rounds": rounds, "seconds": time.monotonic() - started}, indent=2))
    print("PASS planning refuses writes; saved action -> required input -> resume -> verification; seven HTTP rounds; ARTIFACTS", directory)
finally:
    server.shutdown()
    server.server_close()
