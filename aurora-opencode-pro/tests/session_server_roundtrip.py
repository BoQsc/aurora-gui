"""Drive concurrent sessions through the JSON-lines session server.

The repository's D fixtures cover the protocol parser. This test covers the
routing contract that cannot be checked by parsing alone:

* two sessions run provider turns at the same time;
* each turn carries its caller request id and its own turn id;
* per-session instructions reach only that session's system prompt;
* cancelling one turn does not disturb the others.

It launches an isolated session-server build and a deterministic local SSE
provider. The production executable is never used:

    python tests/session_server_roundtrip.py
    python tests/session_server_roundtrip.py --exe build/session-server-verify.exe
"""
import argparse
import http.server
import json
import queue
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

package = Path(__file__).resolve().parents[1]
repo = package.parent


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

    def do_GET(self):
        self.respond(json.dumps({
            "data": [{"id": "fixture", "owned_by": "fixture"}],
        }), "application/json")

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request.get("messages", [])
        user = next((m.get("content", "") for m in reversed(messages)
                     if m.get("role") == "user"), "")
        system = next((m.get("content", "") for m in messages
                       if m.get("role") == "system"), "")
        with self.server.lock:
            self.server.requests.append({"system": system, "user": user,
                                         "tools": request.get("tools")})
            self.server.in_flight += 1
            self.server.peak = max(self.server.peak, self.server.in_flight)
        try:
            if request.get("model") == "cancel-fixture":
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                row = {"choices": [{"delta": {"content": "partial"},
                                    "finish_reason": None}]}
                self.wfile.write(
                    ("data: " + json.dumps(row) + "\n\n").encode())
                self.wfile.flush()
                self.server.hold.wait(20)
                return
            time.sleep(0.6)
            rows = [
                {"choices": [{"delta": {"content": "reply:" + user},
                              "finish_reason": None}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
                {"choices": [], "usage": {"prompt_tokens": 10,
                                          "completion_tokens": 5,
                                          "total_tokens": 15}},
            ]
            body = "".join("data: " + json.dumps(row) + "\n\n"
                           for row in rows) + "data: [DONE]\n\n"
            self.respond(body, "text/event-stream")
        finally:
            with self.server.lock:
                self.server.in_flight -= 1


class SessionServerRoundtrip(unittest.TestCase):
    test_executable = package / "build" / "session-server-verify.exe"

    def setUp(self):
        self.assertTrue(self.test_executable.exists(),
                        "missing isolated session-server build: %s" %
                        self.test_executable)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        self.server.requests = []
        self.server.in_flight = 0
        self.server.peak = 0
        self.server.lock = threading.Lock()
        self.server.hold = threading.Event()
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

        self.directory = Path(tempfile.mkdtemp(
            prefix="session-server-roundtrip-", dir=package / "build"))
        self.workspace = self.directory / "workspace"
        self.workspace.mkdir()
        self.state = self.directory / "state"
        self.state.mkdir()
        (self.state / "settings.json").write_text(json.dumps({
            "baseUrl": "http://127.0.0.1:%d/v1" % self.server.server_port,
            "apiKey": "local-fixture",
            "model": "fixture",
            "workspace": str(self.workspace),
            "toolsEnabled": False,
            "legacyTools": False,
            "quickTitle": False,
        }), encoding="utf-8")

        self.process = subprocess.Popen(
            [str(self.test_executable), "--session-server",
             "--state-dir", str(self.state),
             "--workspace", str(self.workspace)],
            cwd=str(package), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, encoding="utf-8",
            errors="replace", bufsize=1)
        self.events = []
        self.lines = queue.Queue()
        self.stderr = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self):
        for line in self.process.stdout:
            line = line.strip()
            if line:
                self.lines.put(line)

    def _read_stderr(self):
        for line in self.process.stderr:
            self.stderr.append(line.rstrip())

    def tearDown(self):
        self.server.hold.set()
        try:
            if self.process.poll() is None:
                self.process.kill()
        except Exception:
            pass
        for stream in (self.process.stdin, self.process.stdout,
                       self.process.stderr):
            try:
                stream.close()
            except Exception:
                pass
        self.server.shutdown()
        self.server.server_close()

    def send(self, operation):
        self.process.stdin.write(json.dumps(operation) + "\n")
        self.process.stdin.flush()

    def count(self, kind, **fields):
        return sum(1 for event in self.events if event.get("type") == kind and
                   all(event.get(key) == value for key, value in fields.items()))

    def wait_until(self, predicate, timeout, label):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            try:
                line = self.lines.get(timeout=min(
                    0.25, max(0.01, deadline - time.monotonic())))
            except queue.Empty:
                continue
            self.events.append(json.loads(line))
        return predicate()

    def test_concurrent_turns_and_cancel(self):
        self.assertTrue(self.wait_until(
            lambda: self.count("ready") == 1, 90, "ready"),
            "session server did not become ready: %s" % "\n".join(self.stderr[-20:]))

        self.send({"type": "create", "id": "a", "title": "A",
                   "model": "fixture", "tools": False,
                   "instructions": "You are session A.",
                   "workspace": str(self.workspace)})
        self.send({"type": "create", "id": "b", "title": "B",
                   "model": "fixture", "tools": False,
                   "instructions": "You are session B.",
                   "workspace": str(self.workspace)})
        self.assertTrue(self.wait_until(
            lambda: self.count("created") == 2, 30, "created"))

        self.send({"type": "submit", "id": "a", "requestId": "ra",
                   "text": "alpha"})
        self.send({"type": "submit", "id": "b", "requestId": "rb",
                   "text": "beta"})
        settled = ("turn.completed", "turn.failed", "turn.interrupted")
        self.assertTrue(self.wait_until(
            lambda: sum(self.count(kind) for kind in settled) == 2,
            90, "two settled turns"))

        self.assertFalse([e for e in self.events if e.get("type") == "error"])
        self.assertEqual(self.count("turn.failed"), 0)
        self.assertEqual(self.count("turn.interrupted"), 0)
        completed = {event["id"]: event for event in self.events
                     if event.get("type") == "turn.completed"}
        self.assertEqual(set(completed), {"a", "b"})
        self.assertEqual(completed["a"]["requestId"], "ra")
        self.assertEqual(completed["b"]["requestId"], "rb")
        self.assertEqual(completed["a"]["reply"], "reply:alpha")
        self.assertEqual(completed["b"]["reply"], "reply:beta")
        self.assertTrue(completed["a"]["turnId"])
        self.assertTrue(completed["b"]["turnId"])
        self.assertNotEqual(completed["a"]["turnId"], completed["b"]["turnId"])

        with self.server.lock:
            requests = list(self.server.requests)
            peak = self.server.peak
        self.assertEqual(len(requests), 2)
        by_user = {request["user"]: request for request in requests}
        self.assertIn("You are session A.", by_user["alpha"]["system"])
        self.assertIn("You are session B.", by_user["beta"]["system"])
        self.assertFalse(by_user["alpha"]["tools"])
        self.assertFalse(by_user["beta"]["tools"])
        self.assertGreaterEqual(
            peak, 2, "turns did not overlap; peak in-flight was %d" % peak)

        # A turn can be stopped without touching the already completed sessions.
        self.send({"type": "create", "id": "c", "title": "C",
                   "model": "cancel-fixture", "tools": False,
                   "workspace": str(self.workspace)})
        self.assertTrue(self.wait_until(
            lambda: self.count("created", id="c") == 1, 30, "created c"))
        self.send({"type": "submit", "id": "c", "requestId": "rc",
                   "text": "hold"})
        self.assertTrue(self.wait_until(
            lambda: self.count("turn.started", id="c") == 1, 30, "started c"))
        self.send({"type": "cancel", "id": "c"})
        self.assertTrue(self.wait_until(
            lambda: self.count("cancelled", id="c", accepted=True) == 1,
            30, "cancel accepted"))
        cancelled = next(event for event in self.events
                         if event.get("type") == "cancelled" and
                         event.get("id") == "c")
        self.assertEqual(cancelled["requestId"], "rc")
        self.assertTrue(self.wait_until(
            lambda: self.count("turn.interrupted", id="c") == 1,
            30, "c interrupted"))
        self.assertEqual(self.count("turn.completed", id="c"), 0)

        self.send({"type": "list"})
        self.assertTrue(self.wait_until(
            lambda: self.count("sessions") == 1, 30, "sessions"))
        listed = next(e for e in self.events if e.get("type") == "sessions")
        self.assertEqual({item["id"] for item in listed["sessions"]},
                         {"a", "b", "c"})

        for identity in ("a", "b", "c"):
            self.send({"type": "close", "id": identity})
        self.send({"type": "shutdown"})
        self.assertTrue(self.wait_until(
            lambda: self.count("bye") == 1, 30, "bye"))
        self.process.stdin.close()
        self.assertEqual(self.process.wait(timeout=30), 0)

        # Session-level configuration must survive the process, not just the
        # in-memory turn, so a restarted host can resume the same callers.
        saved = json.loads((self.state / "threads.index.json").read_text(
            encoding="utf-8"))
        by_title = {session["title"]: session for session in saved["sessions"]}
        self.assertEqual(by_title["A"]["instructions"], "You are session A.")
        self.assertEqual(by_title["B"]["instructions"], "You are session B.")
        self.assertEqual(by_title["A"]["toolsMode"], 0)
        self.assertEqual(by_title["B"]["toolsMode"], 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--exe", default=str(package / "build" / "session-server-verify.exe"),
        help="isolated session-server build (never the production image)")
    options, remaining = parser.parse_known_args()
    SessionServerRoundtrip.test_executable = Path(options.exe)
    unittest.main(argv=[__file__, *remaining])