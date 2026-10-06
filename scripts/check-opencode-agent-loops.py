"""Replay agent output failures offline and verify bounded recovery over real HTTP/SSE."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import runpy
import tempfile
import threading
import zipfile
import argparse

ROOT = Path(__file__).resolve().parents[1]
COUNTS = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = b'{"data":[{"id":"fixture"}]}'
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert request.get("tools"), "Recovery dropped the tool schemas"
        actual = [m["content"] for m in request["messages"] if m["role"] == "user"
                  and isinstance(m.get("content"), str) and m["content"].startswith("fixture:")]
        case = actual[-1]
        COUNTS[case] = COUNTS.get(case, 0) + 1
        recovery = any("Agent output recovery:" in m.get("content", "")
                       for m in request["messages"] if isinstance(m.get("content"), str))
        if recovery:
            assert all("<invoke" not in m.get("content", "") for m in request["messages"]
                       if isinstance(m.get("content"), str)), "Failed output replayed"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def event(delta, finish=None):
            self.wfile.write(("data: " + json.dumps({"choices": [{"delta": delta,
                                "finish_reason": finish}]}) + "\n\n").encode())
            self.wfile.flush()

        try:
            if case == "fixture: stuck-xml" or case == "fixture: recover-xml" and not recovery:
                call = '<invoke name="run">\n<parameter name="program">never-execute-this</parameter>\n</invoke>\n'
                event({"content": "Let me actually run it.\n" + call * 5}, "stop")
            elif case == "fixture: recover-xml" and not any(m["role"] == "tool" for m in request["messages"]):
                event({"tool_calls": [{"index": 0, "id": "recovery-tool", "type": "function",
                       "function": {"name": "run", "arguments": json.dumps({"program": "python",
                       "args": ["-c", "print('recovery executed once')"]})}}]}, "tool_calls")
            elif case == "fixture: recover-xml":
                event({"content": "Recovered."}, "stop")
            elif case == "fixture: recover-prose" and not recovery:
                paragraph = ("Still crashing before printf. Let me check the runtime again. "
                             "Actually the isolated tests passed, so let me try a different approach.\n\n")
                event({"content": paragraph * 6}, "stop")
            else:
                event({"content": "Recovered prose."}, "stop")
            self.wfile.write(b"data: [DONE]\n\n")
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", type=Path, help="Also replay the supplied chat-snapshot.zip")
    args = parser.parse_args()
    check = runpy.run_path(str(ROOT / "scripts/check-opencode-chat.py"))["check"]
    check("aurora-opencode-core", ["tests/agent_loop_test.d"], "agent-loop-test")
    if args.snapshot:
        with zipfile.ZipFile(args.snapshot) as archive, tempfile.TemporaryDirectory() as directory:
            targets = {"m639269190812863764-220", "m639269192883697135-280",
                       "m639269177319235973-319"}
            executable = ROOT / "aurora-opencode-core/build/agent-loop-test.exe"
            import subprocess
            for name in archive.namelist():
                if "/threads/" not in name or not name.endswith(".json"):
                    continue
                for message in json.loads(archive.read(name))["messages"]:
                    if message["id"] in targets:
                        target = Path(directory) / (message["id"] + ".txt")
                        target.write_text(message["content"], encoding="utf-8")
                        subprocess.run([str(executable), str(target)], check=True, timeout=20)
                        targets.remove(message["id"])
            assert not targets, f"Missing archived evidence: {targets}"
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        check("aurora-opencode-pro", ["tests/agent_loop_smoke.d"], "agent-loop-smoke",
              run_args=(f"http://127.0.0.1:{server.server_port}/v1",))
        # A successful run also opens the app's existing verification reminder.
        assert COUNTS == {"fixture: recover-xml": 4, "fixture: stuck-xml": 2,
                          "fixture: recover-prose": 2}, COUNTS
    finally:
        server.shutdown()
        server.server_close()
    print("PASS exact recovery budgets over real HTTP/SSE", COUNTS)


if __name__ == "__main__":
    main()
