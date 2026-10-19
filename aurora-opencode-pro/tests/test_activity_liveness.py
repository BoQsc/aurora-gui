"""Reproduce competing chat continuations through actual HTTP, tools and UI."""
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


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        self.reply(json.dumps({"data": [{"id": "liveness-fixture"}]}).encode(), "application/json")

    def reply(self, data, content_type):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body["messages"]
        prompt = next(m["content"] for m in messages if m["role"] == "user"
                      and isinstance(m.get("content"), str)
                      and (m["content"].startswith("probe ") or m["content"] == "quiet provider"))
        rounds[prompt] += 1
        def event(delta, finish=None):
            return ("data: " + json.dumps({"choices": [{"delta": delta, "finish_reason": finish}]}) + "\n\n").encode()
        if prompt == "quiet provider":
            time.sleep(2.8)
            first = event({"content": "Partial response."})
            last = event({"content": " Resumed."}) + event({}, "stop") + b"data: [DONE]\n\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(first) + len(last)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(first); self.wfile.flush()
            time.sleep(0.8)
            self.wfile.write(last); self.wfile.flush()
        elif not any(m["role"] == "tool" for m in messages):
            call = {"index": 0, "id": prompt.split(":")[0].replace(" ", "-"), "type": "function",
                    "function": {"name": "read", "arguments": json.dumps({"filePath": "fixture.txt"})}}
            self.reply(event({"tool_calls": [call]}) + event({}, "tool_calls") + b"data: [DONE]\n\n", "text/event-stream")
        else:
            assert any(m["role"] == "tool" and "recorded fixture evidence" in m["content"] for m in messages)
            self.reply(event({"content": "Finished " + prompt.split(":")[0] + "."}) + event({}, "stop")
                       + b"data: [DONE]\n\n", "text/event-stream")


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                    "activity_liveness_contracts"], cwd=package.parent, env=env, check=True, timeout=180)
    assert rounds == {"probe alpha: read fixture.txt then report": 2,
                      "probe beta: read fixture.txt then report": 2,
                      "probe removed: read fixture.txt then report": 1,
                      "probe survivor: read fixture.txt then report": 2,
                      "quiet provider": 1}, rounds
    print("PASS 8 HTTP requests: concurrent completion, selected Stop, deletion, provider silence, orphan recovery")
finally:
    server.shutdown()
    server.server_close()
