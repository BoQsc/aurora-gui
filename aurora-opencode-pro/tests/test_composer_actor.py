"""Submit through durable composer storage into real autonomous HTTP/native turns."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

package = Path(__file__).resolve().parents[1]
requests = []


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        requests.append(request)
        if len(requests) == 1:
            delta = {"tool_calls": [{"index": 0, "id": "saved-read", "type": "function", "function": {
                "name": "read", "arguments": json.dumps({"filePath": "evidence.md"})}}]}
            reason = "tool_calls"
        else:
            results = [message for message in request["messages"] if message["role"] == "tool"]
            assert len(results) == 1 and "ACTUAL_EVIDENCE" in results[0]["content"]
            delta = {"content": "The design analysis is complete using the actual recorded evidence and attached image."}
            reason = "stop"
        body = ("data: " + json.dumps({"choices": [{"delta": delta, "finish_reason": reason}]}) + "\n\ndata: [DONE]\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"), "composer_actor_contracts"],
                            cwd=package.parent, env=env, timeout=150)
    assert result.returncode == 0, "Composer/actor integration failed"
    assert len(requests) == 2 and "inputId" not in json.dumps(requests), len(requests)
    assert any(isinstance(message["content"], list) and any(part.get("type") == "image_url" for part in message["content"])
               for message in requests[0]["messages"])
    print("PASS durable image-bearing submission, two HTTP requests, actual native evidence and newer draft preservation")
finally:
    server.shutdown()
