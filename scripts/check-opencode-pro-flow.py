"""Exercise Pro's complete chat/tool lifecycle against a local provider fixture."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import runpy
import threading
import time

ROOT = Path(__file__).resolve().parents[1]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
            pass

    def do_GET(self):
        body = b'{"data":[{"id":"fixture"}]}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        actual = [m.get("content") for m in messages if m["role"] == "user" and
                  isinstance(m.get("content"), str) and m["content"].startswith("fixture:")]
        tools = [m for m in messages if m["role"] == "tool"]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(data):
            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
            self.wfile.flush()

        def delta(value, finish=None):
            body = {"choices": [{"delta": value, "finish_reason": finish}]}
            chunk(("data: " + json.dumps(body) + "\n\n").encode())

        try:
            if actual[-1] == "fixture: replacement":
                delta({"content": "Replacement answer."}, "stop")
            elif actual[0] == "fixture: full flow" and not tools:
                delta({"content": "Checking the command."})
                arguments = json.dumps({"program": "python", "args": ["-u", "-c",
                    "import time; print('fixture'+' live output'); time.sleep(1); print('fixture final output')"]})
                delta({"tool_calls": [{"index": 0, "id": "fixture-command", "type": "function",
                       "function": {"name": "run", "arguments": arguments}}]}, "tool_calls")
            elif actual[0] == "fixture: full flow":
                if len(tools) != 1 or "fixture final output" not in tools[0]["content"] or \
                        actual.count("fixture: steering applied once") != 1:
                    chunk(b'data: {"error":{"message":"tool/guidance protocol mismatch"}}\n\n')
                else:
                    delta({"content": "Confirmed result and steering."}, "stop")
            elif actual[-1] == "fixture: quiet":
                delta({"content": "Initial fragment."})
                time.sleep(2)
                delta({"content": " Resumed."}, "stop")
            else:
                chunk(b'data: {"error":{"message":"unexpected fixture request"}}\n\n')
            chunk(b"data: [DONE]\n\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except OSError:
            pass


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        check = runpy.run_path(str(ROOT / "scripts/check-opencode-chat.py"))["check"]
        check("aurora-opencode-pro", ["tests/turn_flow_http_test.d"], "turn-flow-http-test",
              run_args=[f"http://127.0.0.1:{server.server_port}/v1"])
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
