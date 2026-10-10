"""Verify the built application completes parallel calls through a local provider."""
import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

package = Path(__file__).resolve().parents[1]
requests = []
errors = []


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        data = json.dumps({"data": [{"id": "fixture"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        results = [m for m in request["messages"] if m["role"] == "tool"]
        if not results:
            delta = {"role": "assistant", "tool_calls": [{
                "index": 0, "id": "fixture-plan", "type": "function",
                "function": {"name": "update_plan", "arguments": json.dumps({
                    "plan": [{"step": "Read five fixture files", "status": "in_progress"},
                             {"step": "Confirm the results", "status": "pending"}]})}}]}
            reason = "tool_calls"
        elif not any(m.get("tool_call_id", "").startswith("parallel-") for m in results):
            calls = [
                {"index": i, "id": f"parallel-{i}", "type": "function",
                 "function": {"name": "read", "arguments": json.dumps({"filePath": f"file-{i}.txt"})}}
                for i in range(5)
            ]
            delta = {"role": "assistant", "tool_calls": calls}
            reason = "tool_calls"
        else:
            results = [m for m in results if m.get("tool_call_id", "").startswith("parallel-")]
            ids = [m.get("tool_call_id") for m in results]
            if len(ids) != 5 or set(ids) != {f"parallel-{i}" for i in range(5)}:
                errors.append(f"Missing or duplicated tool result: {ids}")
            for result in results:
                identifier = result.get("tool_call_id", "")
                index = identifier.removeprefix("parallel-")
                if f"unique fixture {index}" not in result.get("content", ""):
                    errors.append(f"Wrong content for result {identifier}")
            delta = {"role": "assistant", "content": "PARALLEL_TOOLS_OK"}
            reason = "stop"
        chunks = [
            {"choices": [{"index": 0, "delta": delta, "finish_reason": None}]},
            {"choices": [{"index": 0, "delta": {}, "finish_reason": reason}]},
        ]
        data = ("".join("data: " + json.dumps(c) + "\n\n" for c in chunks) + "data: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="aurora-binary-tools-") as temporary:
        directory = Path(temporary)
        state = directory / "Aurora OpenCode"
        state.mkdir()
        for i in range(5):
            (directory / f"file-{i}.txt").write_text(f"unique fixture {i}")
        (state / "settings.json").write_text(json.dumps({
            "baseUrl": f"http://127.0.0.1:{server.server_port}/v1",
            "apiKey": "fixture", "model": "fixture", "workspace": str(directory),
            "quickTitle": False, "toolsEnabled": True,
        }))
        environment = dict(os.environ, APPDATA=str(directory))
        completed = subprocess.run([
            str(package / "aurora-opencode-pro.exe"), "--headless",
            "Read the five fixture files in parallel and confirm completion.",
        ], cwd=directory, env=environment, capture_output=True, text=True, timeout=45)
        assert completed.returncode == 0, completed.stderr
        assert "PARALLEL_TOOLS_OK" in completed.stdout, completed.stdout
        assert 3 <= len(requests) <= 4, f"Expected plan, tools, and continuation (plus optional plan reminder); got {len(requests)}"
        assert not errors, errors
        print("PASS: rebuilt application -> five parallel tools -> every result exactly once with correct content -> final answer.")
finally:
    server.shutdown()
