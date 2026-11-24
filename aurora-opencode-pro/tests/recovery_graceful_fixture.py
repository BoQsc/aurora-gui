"""Fixture provider for recovery_graceful_ui_contracts.

The UI fixture drives the real desktop, HTTP and turn-policy path for an
ordinary task whose recovery budget runs out. It requires a deterministic
provider, so the architecture runner delegates this fixture here instead of
failing on the missing AURORA_CONTRACT_PROVIDER_BASE guard.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import threading

package = Path(__file__).resolve().parents[1]


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_body(self, body, kind):
        raw = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self.send_body('{"data":[{"id":"continuation-fixture"}]}', "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        has_plan = any(message.get("role") == "tool" for message in messages)
        if has_plan and not request.get("tools"):
            # Optional title request: the fixture sets quickTitle false, but a
            # deployed build may still ask for a session title.
            first = {"choices": [{"delta": {"content": "Recovery fixture"},
                                  "finish_reason": None}]}
            last = {"choices": [{"delta": {}, "finish_reason": "stop"}]}
        elif not has_plan:
            arguments = json.dumps({
                "objective": "Implement fixture outcome",
                "plan": [{"step": "Unfinished outcome", "status": "in_progress"}],
            })
            delta = {"tool_calls": [{
                "index": 0, "id": "fixture-plan", "type": "function",
                "function": {"name": "update_plan", "arguments": arguments},
            }]}
            first = {"choices": [{"delta": delta, "finish_reason": None}]}
            last = {"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}
        else:
            first = {"choices": [{"delta": {
                "content": "Remaining work is unchanged; attempt recorded.",
            }, "finish_reason": None}]}
            last = {"choices": [{"delta": {}, "finish_reason": "stop"}]}
        body = ("data: " + json.dumps(first) + "\n\n" +
                "data: " + json.dumps(last) + "\n\n" +
                "data: [DONE]\n\n")
        self.send_body(body, "text/event-stream")


def run_fixture(output: Path) -> int:
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        env = dict(os.environ,
                   AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
        result = subprocess.run(
            [sys.executable, "-X", "utf8",
             str(package / "tests/run_architecture_checks.py"),
             "recovery_graceful_ui_contracts"],
            cwd=package, env=env, timeout=300)
        if result.returncode:
            return result.returncode
        output.write_text(json.dumps({"status": "passed"}) + "\n", encoding="utf-8")
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
