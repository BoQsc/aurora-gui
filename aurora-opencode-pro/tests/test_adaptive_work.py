"""Real HTTP/native proof for small work, discoveries and accountable completion."""
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import hashlib
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]
rounds = 0
failures = []

def call(identity, name, arguments):
    return {"id": identity, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}

class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def do_GET(self):
        body = b'{"data":[{"id":"adaptive-work-fixture"}]}'
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        global rounds
        rounds += 1
        messages = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["messages"]
        owners, results = set(), {}
        for message in messages:
            for tool in message.get("tool_calls", []): owners.add(tool["id"])
            if message["role"] == "tool":
                identity = message["tool_call_id"]
                if identity not in owners or identity in results: failures.append("Unpaired tool result: " + identity)
                results[identity] = message["content"]
                if message["content"].startswith("Error:"): failures.append(message["content"])
        text = "\n".join(m["content"] for m in messages if isinstance(m.get("content"), str))
        tools, content = [], ""
        if "mini-start" not in results:
            tools = [call("mini-start", "update_plan", {"work_items":[{"id":"main", "step":"Write main document", "kind":"edit", "status":"in_progress", "done":"Main document saved"}], "work_context":{"action":"Write main document", "next_action":"Check legacy compatibility"}})]
        elif "write-main" not in results:
            tools = [call("write-main", "write", {"filePath":"main.md", "content":"Main document"})]
        elif "discovery" not in results:
            tools = [call("discovery", "update_plan", {"work_items":[{"id":"main", "status":"completed", "evidence":["write-main"]}, {"id":"compat", "step":"Write compatibility document", "kind":"edit", "status":"in_progress", "origin":"discovery", "reason":"Legacy compatibility is necessary for the requested result", "done":"Compatibility document saved"}, {"id":"optional", "step":"Add optional examples", "required":False, "status":"deferred", "reason":"Examples are outside the requested fix"}], "work_context":{"action":"Write compatibility document", "detour_reason":"Legacy format discovered", "done_when":"Compatibility document saved", "return_to":"Finish main objective"}})]
        elif "Continuation: unfinished authorized work" not in text:
            content = "Main document saved."
        elif "focused" not in results:
            if "Required action compat" not in text or "Finish main objective" not in text: failures.append("Discovery or return point missing from working context")
            tools = [call("focused", "read_plan", {"view":"details", "parent_id":""})]
        elif "write-compat" not in results:
            detail = json.loads(results["focused"])
            if [item["id"] for item in detail["items"]] != ["compat", "optional"]: failures.append("Focused plan view lost outstanding records")
            tools = [call("write-compat", "write", {"filePath":"compat.md", "content":"Legacy compatibility"})]
        elif "finish-work" not in results:
            tools = [call("finish-work", "update_plan", {"work_items":[{"id":"compat", "status":"completed", "evidence":["write-compat"]}], "work_context":None})]
        elif "overview" not in results:
            tools = [call("overview", "read_plan", {"view":"summary"})]
        else:
            if "Optional follow-up optional" not in results["overview"]: failures.append("Optional follow-up was forgotten")
            content = "Both required documents completed."
        if rounds > 12: failures.append("Unexpected extra continuation"); content = "Fixture failed."; tools = []
        delta = {"tool_calls":[dict(tool,index=i) for i,tool in enumerate(tools)]} if tools else {"content":content}
        body = ("data: " + json.dumps({"choices":[{"delta":delta,"finish_reason":None}]}) + "\n\n" + "data: " + json.dumps({"choices":[{"delta":{},"finish_reason":"tool_calls" if tools else "stop"}]}) + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200); self.send_header("Content-Type","text/event-stream"); self.send_header("Content-Length",str(len(body))); self.send_header("Connection","close"); self.end_headers(); self.wfile.write(body)

class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, address):
        if not isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            super().handle_error(request, address)

server = Server(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_STRICT_PLAN="0", AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    if "--production" in sys.argv:
        directory = Path(tempfile.mkdtemp(prefix="production-adaptive-work-", dir=package / "build"))
        workspace = directory / "workspace"; workspace.mkdir()
        state = directory / "appdata/Aurora OpenCode"; state.mkdir(parents=True)
        (state / "settings.json").write_text(json.dumps({"baseUrl":env["AURORA_CONTRACT_PROVIDER_BASE"], "apiKey":"local-fixture", "model":"adaptive-work-fixture", "workspace":str(workspace), "toolsEnabled":True, "legacyTools":False, "quickTitle":False}))
        executable = package / "aurora-opencode-pro.exe"
        started = time.monotonic()
        result = subprocess.run([str(executable), "--headless", "Implement the adaptive work fixture."], cwd=workspace, env=dict(env, APPDATA=str(directory / "appdata")), capture_output=True, text=True, timeout=45)
        (directory / "process.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (workspace / "main.md").read_text() == "Main document"
        assert (workspace / "compat.md").read_text() == "Legacy compatibility"
        assert any(any(m.get("content") == "Both required documents completed." for m in json.loads(path.read_text())["messages"]) for path in (state / "threads").glob("*.json"))
        (directory / "result.json").write_text(json.dumps({"status":"passed", "binarySha256":hashlib.sha256(executable.read_bytes()).hexdigest(), "rounds":rounds, "seconds":time.monotonic()-started}, indent=2))
        print("PASS production adaptive work; ARTIFACTS", directory)
    else:
        subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"), "adaptive_work_contracts", "adaptive_work_ui_contracts"], env=env, check=True, timeout=180)
    assert not failures, failures
    assert rounds == 9, rounds
    print("PASS nine real HTTP rounds: discoveries, detours, views and completion without a mandatory checklist")
finally:
    server.shutdown(); server.server_close()
