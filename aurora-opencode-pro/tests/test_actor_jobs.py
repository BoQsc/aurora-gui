"""Hold optional model jobs while the autonomous foreground turn completes."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

package = Path(__file__).resolve().parents[1]
directory = Path(tempfile.mkdtemp(prefix="jobs-provider-", dir=package / "build"))
requests = []
lock = threading.Lock()


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        mode = request["model"]
        system = request["messages"][0].get("content", "")
        job = system.startswith("Reply with only a short title") or system.startswith("Write a concise, faithful continuation checkpoint")
        with lock:
            requests.append((mode, job, request))
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()

            def send(delta, reason=None):
                self.wfile.write(("data: " + json.dumps({"choices": [{"delta": delta, "finish_reason": reason}]}) + "\n\n").encode())
                self.wfile.flush()

            if job:
                assert not request.get("tools"), "Background job offered tools"
                (directory / f"{mode}.started").touch()
                send({"role": "assistant"})
                deadline = time.monotonic() + 20
                while not (directory / f"{mode}.release").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                if mode in ("title-bound", "summary-invalid"):
                    send({"tool_calls": [{"index": 0, "id": "forbidden-job-call", "type": "function", "function": {
                        "name": "write", "arguments": json.dumps({"filePath": "forbidden.txt", "content": "never"})}}]}, "tool_calls")
                elif mode.startswith("summary"):
                    send({"content": "Goal: continue the analysis. Constraints: retain every user instruction. Evidence: earlier findings remain saved. Remaining outcomes: explain the design accurately. Next action: continue from the recent transcript."}, "stop")
                else:
                    send({"content": 'Title: "Ясність 😀 агентів"'}, "stop")
            else:
                send({"content": "The analysis is complete. The design is explained by the recorded findings."}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (ConnectionError, OSError):
            pass  # Stop/rename cancels the optional connection.


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ, AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1",
               AURORA_CONTRACT_RELEASE_DIR=str(directory))
    result = subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                             "conversation_job_contracts", "actor_jobs_contracts", "engine_policy_contracts"],
                            cwd=package.parent, env=env, timeout=240)
    (directory / "requests.json").write_text(json.dumps(requests, indent=2, ensure_ascii=False), encoding="utf-8")
    assert result.returncode == 0, "Background job fixture failed"
    for mode in ("title", "rename", "title-bound", "summary", "summary-goal", "summary-stop", "summary-invalid", "summary-branch"):
        foreground = [r for m, j, r in requests if m == mode and not j]
        background = [r for m, j, r in requests if m == mode and j]
        assert len(foreground) == 1, (mode, "Foreground restarted", len(foreground))
        assert len(background) == (2 if mode == "title-bound" else 1), (mode, len(background))
    print("PASS optional jobs never block or restart the foreground; bounded attempts and stale-result rejection")
finally:
    for mode in ("title", "rename", "title-bound", "summary", "summary-goal", "summary-stop", "summary-invalid", "summary-branch"):
        (directory / f"{mode}.release").touch()
    server.shutdown()
