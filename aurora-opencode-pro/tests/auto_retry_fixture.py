"""Fixture provider for auto_retry_duration_contracts.

The real desktop, HTTP and retry-policy path runs against a provider whose
failing attempts each last longer than the configured outage budget: a slow
provider that answers nothing until the client gives up. Then the same provider
answers, which only an automatic re-send can have caused.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

package = Path(__file__).resolve().parents[1]
attempts = {}
lock = threading.Lock()
# One failing attempt that alone outlasts the budget, and two that each fit
# inside it but together do not: both used to end the automatic recovery.
stall_seconds = 12.0
inactivity_ms = 10000
outage_ms = 9000


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_body(self, status, body, kind):
        raw = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.send_body(200, '{"data":[{"id":"auto-retry-fixture"}]}', "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        model = request["model"]
        with lock:
            attempts[model] = attempts.get(model, 0) + 1
            attempt = attempts[model]
        if model == "declined":
            self.send_body(401, json.dumps({"error": {"message": "The fixture declined this request"}}),
                           "application/json")
            return
        if model == "slow-fail-once" and attempt == 1:
            # Answer nothing, past the outage budget, then close the connection:
            # the client reports a transport failure after a wait longer than the
            # whole recovery budget.
            time.sleep(stall_seconds)
            return
        if model == "slow-fail-twice" and attempt <= 2:
            time.sleep(stall_seconds)
            return
        content = "Recovered after the slow failure."
        if model == "slow-fail-twice":
            content = "Recovered after two slow failures."
        first = {"choices": [{"delta": {"content": content}, "finish_reason": None}]}
        last = {"choices": [{"delta": {}, "finish_reason": "stop"}]}
        body = ("data: " + json.dumps(first) + "\n\n" +
                "data: " + json.dumps(last) + "\n\ndata: [DONE]\n\n")
        self.send_body(200, body, "text/event-stream")


def run_fixture(output: Path) -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        env = dict(os.environ,
                   AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1",
                   AURORA_NETWORK_INACTIVITY_MS=str(inactivity_ms),
                   AURORA_PROVIDER_OUTAGE_MS=str(outage_ms))
        result = subprocess.run(
            [sys.executable, "-X", "utf8",
             str(package / "tests/run_architecture_checks.py"),
             "auto_retry_duration_contracts"],
            cwd=package, env=env, timeout=600)
        if result.returncode:
            return result.returncode
        assert attempts.get("slow-fail-once") == 2, \
            f"a slow failure was not re-sent automatically: {dict(attempts)}"
        assert attempts.get("slow-fail-twice") == 3, \
            f"repeated slow failures stopped retrying: {dict(attempts)}"
        assert attempts.get("declined") == 1, \
            f"a declined request was replayed: {dict(attempts)}"
        output.write_text(json.dumps({"status": "passed", "attempts": attempts}) + "\n",
                          encoding="utf-8")
        return 0
    finally:
        server.shutdown()
        server.server_close()


def main(argv=None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not args.build and output.is_file():
        return 0
    return run_fixture(output)


if __name__ == "__main__":
    raise SystemExit(main())
