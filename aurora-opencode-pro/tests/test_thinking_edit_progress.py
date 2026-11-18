"""Real provider path for the thinking-then-editing progress contract.

The provider streams a reasoning chunk, holds the connection quiet for a few
seconds (the "end of thinking" window the user reported as "no new output"),
then streams the arguments of an `apply_patch` call over a couple of seconds,
and afterwards answers the tool result. The native fixture drives the real
widget tree, lets the real tool run, and asserts the transcript keeps showing
the live edit row - counters and body - during the streaming phase.
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

PROMPT = "edit the notes file"
PATCH = "\n".join([
    "*** Begin Patch",
    "*** Add File: notes.txt",
    "+alpha",
    "+beta",
    "+gamma",
    "+extra line",
    "+another added line",
    "+a third added line",
    "*** End Patch",
])
CALL_ID = "call_patch_1"


def sse(delta, finish=None):
    return ("data: " + json.dumps(
        {"choices": [{"delta": delta, "finish_reason": finish}]}) + "\n\n").encode()


def has_call_id(messages):
    for message in messages:
        if message.get("tool_call_id") == CALL_ID:
            return True
    return False


class Provider(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        data = json.dumps({"data": [{"id": "thinking-edit-fixture"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        self.wfile.flush()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = body.get("messages", [])
        prompt = next((m["content"] for m in messages
                       if m.get("role") == "user"
                       and isinstance(m.get("content"), str)
                       and m["content"] == PROMPT), None)

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()

        if prompt is None:
            # Title / follow-up / unrelated side requests: answer briefly.
            self.wfile.write(sse({"content": "ok"}) + sse({}, "stop")
                             + b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        if has_call_id(messages):
            self.wfile.write(sse({"reasoning": "The patch landed. Report it."})
                             + sse({"content": "Applied the patch."})
                             + sse({}, "stop") + b"data: [DONE]\n\n")
            self.wfile.flush()
            return

        # The streamed `arguments` value is the tool call's JSON text, not the
        # patch itself, so chunk the encoded argument object.
        arguments = json.dumps({"patch": PATCH})
        chunks = [arguments[i:i + 12] for i in range(0, len(arguments) - 1, 12)]
        self.wfile.write(sse({"reasoning": "Looking at notes.txt before editing it."}))
        self.wfile.flush()
        time.sleep(4.0)
        self.wfile.write(sse({"tool_calls": [{
            "index": 0, "id": CALL_ID,
            "function": {"name": "apply_patch", "arguments": chunks[0]}}]}))
        self.wfile.flush()
        for chunk in chunks[1:]:
            time.sleep(0.09)
            self.wfile.write(sse({"tool_calls": [{
                "index": 0, "function": {"arguments": chunk}}]}))
            self.wfile.flush()
        time.sleep(0.09)
        self.wfile.write(sse({}, "tool_calls") + b"data: [DONE]\n\n")
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    env = dict(os.environ,
               AURORA_CONTRACT_PROVIDER_BASE=f"http://127.0.0.1:{server.server_port}/v1")
    subprocess.run([sys.executable, str(package / "tests/run_architecture_checks.py"),
                    "thinking_edit_progress_contracts"],
                   cwd=package.parent, env=env, check=True, timeout=600)
    print("PASS thinking followed by editing keeps the live edit visible")
finally:
    server.shutdown()
    server.server_close()
