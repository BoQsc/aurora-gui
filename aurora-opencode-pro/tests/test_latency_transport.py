"""Local transport proof: intentional tokenizer delay and separated SSE chunks."""
import http.server
import json
import os
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]
received = []
attempts = {}
lock = threading.Lock()
parallel_arrived = set()
parallel_ready = threading.Event()


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = body["model"]
        with lock:
            received.append((model, self.path, self.client_address[1]))
            attempts[model] = attempts.get(model, 0) + 1
            attempt = attempts[model]
        if model.startswith("parallel-"):
            with lock:
                parallel_arrived.add(model)
                if len(parallel_arrived) == 8:
                    parallel_ready.set()
            assert parallel_ready.wait(6), "Transport prevented eight parallel admissions"
        if self.path.endswith("/input_tokens"):
            time.sleep(0.5)
            payload = b'{"input_tokens":42}'
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if model == "hold-headers":
            time.sleep(2.5)
            return
        if model == "delayed-headers":
            time.sleep(0.4)
        if model == "retry" and attempt == 1:
            payload = b'{"error":{"message":"brief unavailable"}}'
            self.send_response(503)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        first = 'data: ' + json.dumps({"choices": [{"delta": {"content": "first"}, "finish_reason": None}]}) + '\n\n'
        last = ('data: ' + json.dumps({"choices": [{"delta": {"content": "last"}, "finish_reason": "stop"}],
                                      "usage": {"prompt_tokens": 42, "completion_tokens": 2, "total_tokens": 44}})
                + '\n\ndata: [DONE]\n\n')
        first, last = first.encode(), last.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(first) + len(last)))
        self.end_headers()
        try:
            self.wfile.write(first)
            self.wfile.flush()
            time.sleep(0.4)
            self.wfile.write(last)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, address):
        if not isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            super().handle_error(request, address)


server = Server(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "latency_transport_contracts"], cwd=package.parent, env=env, timeout=120)
    assert result.returncode == 0
    assert not any(model == "skip-count" and path.endswith("input_tokens") for model, path, port in received)
    assert sum(model == "counted" and path.endswith("input_tokens") for model, path, port in received) == 1
    first_port = next(port for model, path, port in received if model == "skip-count")
    warm_port = next(port for model, path, port in received if model == "warm")
    assert first_port == warm_port, "Different chats did not reuse the actual TCP connection"
    assert attempts["retry"] == 2
    assert len(parallel_arrived) == 8
    print("PASS actual TCP reuse across clients, skipped tokenizer call, exact-count opt-in and bounded recovery", flush=True)
finally:
    server.shutdown()
    server.server_close()
