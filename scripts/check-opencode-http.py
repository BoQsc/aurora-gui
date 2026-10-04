"""Exercise WinINet against a local SSE server; optionally compare send latency."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import argparse
import json
import re
import shutil
import statistics
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts/opencode-chat-review"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
            # Closing a request at DONE/Stop is the behavior under test.
            pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.path != "/v1/chat/completions" or self.headers.get("Authorization") != "Bearer original-key":
            self.send_error(401, "request used changed credentials")
            return
        model = json.loads(body)["model"]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(data):
            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
            self.wfile.flush()

        def data(value):
            return ("data: " + json.dumps(value, ensure_ascii=False) + "\n\n").encode()

        try:
            if model == "provider-error":
                chunk(data({"error": {"message": "quota exhausted"}}))
                time.sleep(3)
            elif model == "tool-length":
                chunk(data({"choices": [{"delta": {"tool_calls": [{"index": 0,
                    "id": "call", "function": {"name": "write", "arguments": "{"}}]}}]}))
                chunk(data({"choices": [{"delta": {}, "finish_reason": "length"}]}))
                chunk(b"data: [DONE]\n\n")
            elif model == "snapshot":
                chunk(data({"choices": [{"delta": {"content": "ok"}, "finish_reason": "stop"}]}))
                chunk(b"data: [DONE]\n\n")
            else:
                payload = data({"choices": [{"delta": {"content": "Hello 😀世界"}}]})
                split = payload.index("😀".encode()) + 2
                chunk(payload[:split])
                time.sleep(0.01)
                chunk(payload[split:])
                if model == "keep-open":
                    chunk(b"data: [DONE]\n\n")
                    time.sleep(3)  # keep the HTTP body open beyond completion
                elif model == "slow-stream":
                    time.sleep(1)
                    chunk(b"data: [DONE]\n\n")
                elif model == "cancel":
                    time.sleep(3)
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def do_GET(self):
        variants = {"/v1/models": ("original-key", "old-model"),
                    "/v1/next/models": ("new-key", "new-model")}
        if self.path not in variants:
            self.send_error(404)
            return
        key, model = variants[self.path]
        if self.headers.get("Authorization") != "Bearer " + key:
            self.send_error(401)
            return
        if model == "old-model":
            time.sleep(0.1)
        body = json.dumps({"data": [{"id": model}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def compile_test(source, output, prior=None):
    includes = [ROOT / "aurora-opencode-core/source", ROOT / "vendor/aurora-d-0.4.5/source"]
    if prior:
        includes.insert(0, prior)
    command = [shutil.which("dmd") or "dmd", "-i", "-version=AuroraHeadless"]
    command.extend("-I" + str(path) for path in includes)
    command += [str(ROOT / "aurora-opencode-core/tests" / source), "user32.lib",
                "gdi32.lib", "shell32.lib", "wininet.lib", "-of=" + str(output)]
    subprocess.run(command, cwd=ROOT, check=True, timeout=180)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compare", action="store_true", help="Compare against the client at Git HEAD")
    options = parser.parse_args()
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    build = ROOT / "aurora-opencode-core/build"
    build.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = f"http://127.0.0.1:{server.server_port}/v1"
    try:
        executable = build / "http-stream-test.exe"
        compile_test("http_stream_test.d", executable)
        subprocess.run([str(executable), base], check=True, timeout=30)
        if options.compare:
            baseline = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
            report = {"baseline_commit": baseline, "payload_bytes": 24 * 1024 * 1024,
                "trials": 3, "scope": "UI-thread request snapshot, excluding provider/network latency"}
            with tempfile.TemporaryDirectory(prefix="aurora-chat-benchmark-") as directory:
                prior = Path(directory)
                target = prior / "auroraopencode/opencode_client.d"
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(subprocess.check_output(["git", "show",
                    baseline + ":aurora-opencode-core/source/auroraopencode/opencode_client.d"], cwd=ROOT))
                for name, includes in [("before", prior), ("after", None)]:
                    executable = build / f"request-snapshot-{name}.exe"
                    compile_test("request_snapshot_benchmark.d", executable, includes)
                    result = subprocess.run([str(executable), base], check=True,
                        capture_output=True, text=True, timeout=120)
                    samples = [int(value) / 1000 for value in re.findall(r"snapshot_us=(\d+)", result.stdout)]
                    report[name] = {"samples_ms": samples, "median_ms": statistics.median(samples)}
            report["speedup"] = report["before"]["median_ms"] / report["after"]["median_ms"]
            (ARTIFACTS / "request-snapshot-benchmark.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2))
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
