"""Real provider path for the Thinking quiet-gap contract.

The provider streams a reasoning chunk, holds the connection quiet for several
seconds (the end-of-thinking window the user reported as "nothing is
happening"), then streams the answer. The native fixture drives the real widget
tree and asserts the live Thinking header explains the gap and clears on the
first answer fragment.
"""
import collections
import http.server
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

package = Path(__file__).resolve().parents[1]
rounds = collections.Counter()


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        data = json.dumps({"data": [{"id": "thinking-fixture"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        prompt = next(m["content"] for m in body["messages"]
                      if m["role"] == "user"
                      and isinstance(m.get("content"), str)
                      and m["content"] == "explain the reasoning gap")
        rounds[prompt] += 1

        def event(delta, finish=None):
            return ("data: " + json.dumps({"choices": [{"delta": delta,
                                                        "finish_reason": finish}]}) + "\n\n").encode()

        reasoning = event({"reasoning": "Considering the request."})
        answer = (event({"content": "Answer after thinking."})
                  + event({}, "stop") + b"data: [DONE]\n\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(reasoning) + len(answer)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(reasoning)
        self.wfile.flush()
        time.sleep(5.0)
        self.wfile.write(answer)
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ,
               AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                    "thinking_transition_contracts"],
                   cwd=package.parent, env=env, check=True, timeout=300)
    assert rounds == {"explain the reasoning gap": 1}, rounds
    print("PASS 1 HTTP request: reasoning quiet window then answer in one ordered reply")
finally:
    server.shutdown()
    server.server_close()
