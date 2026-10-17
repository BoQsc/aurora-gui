"""Exercise parent-task continuity with real HTTP, native tools and saved state."""
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
counts = collections.Counter()
failures = []
prompts = {
    "Implement the fixture project.": "initial",
    "Investigate the fixture migration. Do not change any files.": "analysis",
    "Continue and finish the fixture project.": "resume",
    "New task: analyze another fixture.": "new",
}

def call(identity, name, arguments):
    return {"id": identity, "type": "function", "function": {"name": name, "arguments": json.dumps(arguments)}}

class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def do_GET(self):
        raw = b'{"data":[{"id":"continuity-fixture"}]}'
        self.send_response(200); self.send_header("Content-Length",str(len(raw))); self.end_headers(); self.wfile.write(raw)
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body["messages"]
        scenario = next(prompts[m["content"]] for m in reversed(messages) if m["role"] == "user" and isinstance(m.get("content"),str) and m["content"] in prompts)
        counts[scenario] += 1
        if counts[scenario] > 8:
            failures.append("Unexpected automatic continuation: " + scenario); self.send_error(500); return
        results = {m["tool_call_id"]:m["content"] for m in messages if m["role"] == "tool"}
        tools, content, delay = [], "", 0
        if scenario == "initial":
            if "initial-write" not in results:
                tools = [call("initial-plan", "update_plan", {"objective":"Complete the fixture project", "plan":[
                    {"id":"first","step":"First outcome","status":"in_progress"},
                    {"id":"migrate","step":"Second outcome","status":"pending"},
                    {"id":"third","step":"Third outcome","status":"pending"}]}),
                    call("initial-write","write",{"filePath":"first.md","content":"First outcome"})]
            elif "position-plan" not in results:
                tools = [call("position-plan","update_plan",{"plan":[
                    {"id":"first","step":"First outcome","status":"completed"},
                    {"id":"migrate","step":"Second outcome","status":"in_progress"},
                    {"id":"third","step":"Third outcome","status":"pending"}],
                    "work_context":{"action":"Migrate old records","next_action":"Finish third outcome",
                    "detour_reason":"Compatibility for existing records","done_when":"Existing IDs survive migration","return_to":"Finish the second outcome"}})]
            else:
                content, delay = "Initial stage ready; continuing.", 0.8
        elif scenario == "analysis":
            text = "\n".join(m.get("content", "") for m in messages if isinstance(m.get("content"),str))
            if "Return to: Finish the second outcome" not in text or "Requested outcome: Implement the fixture project." not in text:
                failures.append("Provider lost parent objective or return point")
            if "investigate-read" not in results:
                tools = [call("investigate-read","read",{"filePath":"first.md"})]
            else:
                content = "The migration preserves the old record IDs."
        elif scenario == "resume":
            if "second-write" not in results:
                tools = [call("second-write","write",{"filePath":"second.md","content":"Second outcome"}),
                         call("third-write","write",{"filePath":"third.md","content":"Third outcome"})]
            elif "complete-plan" not in results:
                tools = [call("complete-plan","update_plan",{"plan":[
                    {"id":"migrate","step":"Second outcome","status":"completed"},
                    {"id":"third","step":"Third outcome","status":"completed"}]})]
            else:
                content = "All three outcomes completed."
        else:
            if "new-read" not in results:
                tools = [call("new-read","read",{"filePath":"first.md"})]
            else:
                content = "The new fixture was analyzed."
        delta = {"tool_calls":[dict(tool,index=i) for i,tool in enumerate(tools)]} if tools else {"content":content}
        first = ('data: '+json.dumps({"choices":[{"delta":delta,"finish_reason":None}]})+'\n\n').encode()
        final = ('data: '+json.dumps({"choices":[{"delta":{},"finish_reason":"tool_calls" if tools else "stop"}]})+'\n\ndata: [DONE]\n\n').encode()
        self.send_response(200); self.send_header("Content-Type","text/event-stream"); self.send_header("Content-Length",str(len(first)+len(final))); self.send_header("Connection","close"); self.end_headers()
        try:
            self.wfile.write(first); self.wfile.flush(); time.sleep(delay or .01); self.wfile.write(final); self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError): pass

class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, address):
        if not isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError)):
            super().handle_error(request, address)

server = Server(("127.0.0.1",0), Provider)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
    subprocess.run([sys.executable,str(package/"tests/run_architecture_checks.py"),"work_continuity_contracts","work_continuity_ui_contracts"],
                   env=dict(os.environ,AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1"),check=True,timeout=180)
    assert not failures, failures
    assert counts == {"initial":3,"analysis":2,"resume":3,"new":2}, counts
    print("PASS parent continuity and exact HTTP request counts",dict(counts))
finally:
    server.shutdown(); server.server_close()
