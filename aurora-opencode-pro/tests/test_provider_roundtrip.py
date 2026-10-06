"""Exercise the desktop execution path against a local deterministic provider."""
import http.server
import json
import os
import subprocess
import sys
import threading
import tempfile
import hashlib
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]
requests = []
failures = []
main_rounds = []
hold = threading.Event()

def call(identity, name, arguments):
    return {"id": identity, "type": "function",
            "function": {"name": name, "arguments": json.dumps(arguments)}}

def plan(status):
    return {"objective": "Write and verify a fixture",
            "plan": [{"step": "Write and verify out.txt", "status": status}]}

class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def respond(self, body, kind):
        body = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def do_GET(self):
        self.respond(json.dumps({"data": [{"id": "fixture", "owned_by": "fixture"}]}),
                     "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        if request.get("model") == "cancel-fixture":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            row = {"choices": [{"delta": {"content": "partial"}, "finish_reason": None}]}
            self.wfile.write(("data: " + json.dumps(row) + "\n\n").encode())
            self.wfile.flush()
            hold.wait(20)
            return
        if not request.get("tools"):
            rounds = [{"choices": [{"delta": {"content": "Fixture"}, "finish_reason": "stop"}]}]
        else:
            messages = request["messages"]
            # Every outgoing tool result must retain its owning assistant call.
            owners = set()
            results = set()
            for message in messages:
                for tool in message.get("tool_calls", []):
                    owners.add(tool["id"])
                if message["role"] == "tool":
                    identity = message["tool_call_id"]
                    if identity not in owners or identity in results:
                        failures.append("Unpaired or duplicate tool result: " + identity)
                    results.add(identity)
            main_rounds.append(request)
            number = len(main_rounds)
            if number == 1:
                test = ("import unittest\nfrom pathlib import Path\n"
                        "class Fixture(unittest.TestCase):\n"
                        " def test_contents(self): self.assertEqual(Path('out.txt').read_text(), 'success')\n")
                tools = [call("plan", "update_plan", plan("in_progress")),
                         call("write-output", "write", {"filePath": "out.txt", "content": "success"}),
                         call("write-check", "write", {"filePath": "test_fixture.py", "content": test})]
            elif number == 2:
                tools = [call("check", "run", {"program": "python", "args": ["-m", "unittest", "test_fixture"]})]
            elif number == 3:
                tools = [call("complete-plan", "update_plan", plan("completed"))]
            else:
                tools = []
            if tools:
                fragments = [dict(tool, index=i) for i, tool in enumerate(tools)]
                rounds = [{"choices": [{"delta": {"reasoning_content": "Proceeding.", "content": "Working."},
                                        "finish_reason": None}]},
                          {"choices": [{"delta": {"tool_calls": fragments}, "finish_reason": "tool_calls"}]}]
            else:
                rounds = [{"choices": [{"delta": {"content": "READY"}, "finish_reason": "stop"}]}]
        rounds.append({"choices": [], "usage": {"prompt_tokens": 100, "completion_tokens": 20, "total_tokens": 120}})
        self.respond("".join("data: " + json.dumps(row) + "\n\n" for row in rounds) + "data: [DONE]\n\n",
                     "text/event-stream")

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
worker = threading.Thread(target=server.serve_forever, daemon=True)
worker.start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    if "--production" in sys.argv:
        directory = Path(tempfile.mkdtemp(prefix="production-roundtrip-", dir=package / "build"))
        workspace = directory / "workspace"
        workspace.mkdir()
        state = directory / "appdata" / "Aurora OpenCode"
        state.mkdir(parents=True)
        (state / "settings.json").write_text(json.dumps({
            "baseUrl": env["AURORA_CONTRACT_PROVIDER_BASE"], "apiKey": "local-fixture",
            "model": "fixture", "workspace": str(workspace), "toolsEnabled": True,
            "legacyTools": False, "quickTitle": False,
        }), encoding="utf-8")
        env["APPDATA"] = str(directory / "appdata")
        executable = package / "aurora-opencode-pro.exe"
        started = time.monotonic()
        result = subprocess.run([str(executable), "--headless",
            "Write out.txt containing success, verify its contents with unittest, then reply READY."],
            cwd=workspace, env=env, timeout=60, capture_output=True, text=True)
        (directory / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
        assert result.returncode == 0, result.stdout + result.stderr
        assert (workspace / "out.txt").read_text() == "success"
        histories = list((state / "threads").glob("*.json"))
        assert any(any(message.get("content") == "READY" for message in json.loads(path.read_text())["messages"])
                   for path in histories), "Built image did not persist its final response"
        evidence = {"status": "passed", "exitCode": result.returncode,
                    "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
                    "seconds": time.monotonic() - started, "mainRounds": len(main_rounds)}
        (directory / "result.json").write_text(json.dumps(evidence, indent=2), encoding="utf-8")
        print("PASS built desktop image round trip; ARTIFACTS", directory, flush=True)
    else:
        result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                                 "provider_roundtrip"], cwd=package.parent, env=env, timeout=120)
        assert result.returncode == 0, "Desktop round trip failed"
    assert len(main_rounds) == 4, f"Unexpected continuation count: {len(main_rounds)}"
    assert not failures, failures
    print("PASS four real HTTP/SSE rounds, native tools, request pairing and final settlement", flush=True)
finally:
    hold.set()
    server.shutdown()
    server.server_close()
