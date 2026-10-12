"""Local HTTP fixture for native download contracts; never contacts the internet."""
import http.server
import json
from pathlib import Path
import sys

DATA = b"fixture bytes\n" * 65536
attempts = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/data")
            self.end_headers()
            return
        if self.path == "/forbidden":
            self.send_response(403)
            self.end_headers()
            return
        attempts[self.path] = attempts.get(self.path, 0) + 1
        offset = int(self.headers.get("Range", "bytes=0-").split("=")[1].split("-")[0])
        if self.path == "/ignore-range":
            offset = 0
        if offset >= len(DATA):
            self.send_response(416)
            self.send_header("ETag", '"fixture-v1"')
            self.send_header("Content-Range", f"bytes */{len(DATA)}")
            self.end_headers()
            return
        self.send_response(206 if offset else 200)
        self.send_header("ETag", '"fixture-v1"')
        if self.path != "/unknown":
            self.send_header("Content-Length", str(len(DATA) - offset))
        if offset:
            self.send_header("Content-Range", f"bytes {offset}-{len(DATA)-1}/{len(DATA)}")
        self.end_headers()
        body = DATA[offset:]
        if self.path == "/truncated" and attempts[self.path] == 1:
            body = body[:32768]
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(json.dumps({"port": server.server_port}))
server.serve_forever()
