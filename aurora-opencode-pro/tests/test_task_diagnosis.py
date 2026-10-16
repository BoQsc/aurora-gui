"""Exercise optional diagnostic routing through real GUI, HTTP, tools and storage."""
import http.server
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading

counts = {}
observed = []


class Provider(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.send_json({"data": [{"id": x} for x in ("diagnosis-main", "diagnosis-review")]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = request["model"]
        counts[model] = counts.get(model, 0) + 1
        observed.append(request)
        prompt = next(x["content"] for x in request["messages"]
                      if x["role"] == "user" and isinstance(x.get("content"), str)
                      and x["content"].startswith("DIAGNOSE:"))
        recipe = re.search(r"RECIPE: ([^\n]+)", prompt)[1]
        source = str(Path(recipe).parent)
        tools = []
        content = "Still investigating."

        def call(identity, name, args):
            return {"id": identity, "type": "function", "function": {
                "name": name, "arguments": json.dumps(args)}}

        if model == "diagnosis-review":
            advertised = {x["function"]["name"] for x in request.get("tools", [])}
            assert "write" not in advertised and "run" not in advertised
            if counts[model] == 1:
                tools = [call("blocked-write", "write", {
                    "filePath": str(Path(source) / "forbidden.txt"), "content": "must not be created"})]
                content = ""
            else:
                assert any(x["role"] == "tool" and "read-only" in x.get("content", "")
                           for x in request["messages"])
                content = "Independent diagnosis: run the saved helper assertion recipe; do not infer success from searches."
        elif counts[model] == 5:
            tools = [call("complete-plan", "update_plan", {"plan": [
                {"step": "Verify the helper", "status": "completed"}]}),
                call("acceptance", "verify", {"recipe": recipe})]
            content = ""
        elif counts[model] == 6:
            content = "Verified the helper after diagnostic review."
        delta = {"content": content}
        if tools:
            delta["tool_calls"] = [{"index": index, **tool} for index, tool in enumerate(tools)]
        data = "data: " + json.dumps({"choices": [{"delta": delta,
                "finish_reason": "tool_calls" if tools else "stop"}],
                "usage": {"prompt_tokens": 100, "completion_tokens": 10, "total_tokens": 110}}) + "\n\ndata: [DONE]\n\n"
        body = data.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    runner = Path(__file__).with_name("run_architecture_checks.py")
    result = subprocess.run([sys.executable, str(runner), "task_diagnosis_contracts"], env=env, timeout=90)
    print("Observed routing:", counts, flush=True)
    assert result.returncode == 0
    assert counts == {"diagnosis-main": 6, "diagnosis-review": 2}, counts
    print("PASS bounded reviewer routing: two read-only review requests; main model resumes and completes")
finally:
    server.shutdown()
    server.server_close()
