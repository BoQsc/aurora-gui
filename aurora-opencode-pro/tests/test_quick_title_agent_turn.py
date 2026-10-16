"""Regression: a new chat's quick name is generated even across tool rounds.

Serves a deterministic provider whose opening turn spills its tool call over
several seconds (the stream stays open, so the conversation is continuously
busy) before it answers DONE, and whose no-thinking title rewrite answers
Fixture. That continuous busy window is exactly the case that used to starve the
rewrite, so the fixture fails when the rewrite is gated on the whole turn.
"""
import http.server
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]


def call(identity, name, args):
    return {"id": identity, "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)}}


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

    def stream(self, rows, drip=0.0):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        for row in rows:
            chunk = ("data: " + json.dumps(row) + "\n\n").encode("utf-8")
            self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
            self.wfile.flush()
            if drip:
                time.sleep(drip)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()

    def do_GET(self):
        self.respond(json.dumps({"data": [{"id": "fixture", "owned_by": "fixture"}]}),
                     "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("messages", [])
        is_title = any(m.get("role") == "system" and
                       "short title" in (m.get("content") or "") for m in messages)
        answered_tool = any(m.get("role") == "tool" for m in messages)
        if is_title:
            rows = [{"choices": [{"delta": {"content": "Fixture"},
                                  "finish_reason": None}]},
                    {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
            self.stream(rows)
            return
        if answered_tool:
            rows = [{"choices": [{"delta": {"content": "TITLE_TURN_DONE"},
                                  "finish_reason": None}]},
                    {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
            self.stream(rows)
            return
        # Opening round: drip a `dshell` tool call over ~4 s so the stream (and
        # therefore the conversation) stays continuously busy with no gap. The
        # fixture asserts DONE is only reached after the tool result returns.
        tool = call("call_list", "dshell",
                    {"command": "list", "path": "."})
        args = tool["function"]["arguments"]
        pieces = [args[i:i + 8] for i in range(0, len(args), 8)]
        rows = []
        for i, piece in enumerate(pieces):
            fragment = {**tool, "index": 0,
                        "function": {**tool["function"], "arguments": piece}}
            if i:
                fragment = {"index": 0, "function": {"arguments": piece}}
            rows.append({"choices": [{"delta": {"tool_calls": [fragment]},
                                      "finish_reason": None}]})
        rows.append({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]})
        self.stream(rows, drip=0.5)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ,
               AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "quick_title_agent_turn_contracts"],
                            cwd=package.parent, env=env, timeout=240)
    assert result.returncode == 0, "quick title agent-turn contract failed"
    print("PASS quick title generated across an agent turn's tool rounds", flush=True)
finally:
    server.shutdown()
    server.server_close()
