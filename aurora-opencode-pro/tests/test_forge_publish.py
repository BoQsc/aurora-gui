"""Publisher HTTP contracts, including installed-runtime builds and failures."""
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch

PACKAGE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("publisher", PACKAGE / "tools/publish-forge.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def pe(dll):
    data = bytearray(1024)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3c, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", data, 0x86, 1)
    struct.pack_into("<H", data, 0x94, 240)
    struct.pack_into("<H", data, 0x98, 0x20b)
    struct.pack_into("<II", data, 0x98 + 112 + 8, 0x1000, 40)
    struct.pack_into("<IIII", data, 0x98 + 240 + 8, 512, 0x1000, 512, 512)
    struct.pack_into("<IIIII", data, 512, 0, 0, 0, 0x1040, 0)
    data[576:576 + len(dll) + 1] = dll.encode() + b"\0"
    return bytes(data)


class PublisherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.package = self.root / "pro"
        (self.package / "tools").mkdir(parents=True)
        (self.package / "assets").mkdir()
        (self.root / "scripts").mkdir()
        shutil.copy(PACKAGE.parent / "scripts/verify-windows-portability.py", self.root / "scripts")
        (self.package / "assets/update-project.txt").write_text("fg_test\n")
        (self.package / "dub.json").write_text('{"version":"1.2.3"}')
        self.content = pe("MSVCR120.dll")
        (self.package / publisher.EXE_NAME).write_bytes(self.content)
        self.config = self.root / "state/Aurora OpenCode/forge-publisher.json"
        self.config.parent.mkdir(parents=True)
        self.original_config = {"enabled": True, "id": "fg_test", "key": "fsk_fixture"}
        self.config.write_text(json.dumps(self.original_config))
        self.files = {}
        self.uploads = []
        self.fail_metadata = False
        self.corrupt_download = False
        test = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                if self.headers.get("Authorization") != "Bearer fsk_fixture":
                    self.send_error(401)
                    return
                name = self.path.partition("path=")[2]
                body = self.rfile.read(int(self.headers["Content-Length"]))
                test.uploads.append(name)
                if name == "release.json" and test.fail_metadata:
                    self.send_error(503)
                    return
                test.files[name] = body
                self.send_response(201)
                self.end_headers()

            def do_GET(self):
                name = self.path.rsplit("/", 1)[-1]
                if name not in test.files:
                    self.send_error(404)
                    return
                body = test.files[name]
                if test.corrupt_download and name == publisher.EXE_NAME:
                    body = b"wrong binary"
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body)

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.patches = [
            patch.object(publisher, "__file__", str(self.package / "tools/publish-forge.py")),
            patch.object(publisher, "FORGE_URL", f"http://127.0.0.1:{self.server.server_port}"),
            patch.dict(os.environ, {"APPDATA": str(self.root / "state"),
                "FORGE_PUBLISHER_KEY": "", "FORGE_PUBLISHER_ID": "", "FORGE_PUBLISH_SKIP": "",
                "NO_PROXY": "127.0.0.1,localhost"}),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def publish(self):
        return publisher.main(["--required"])

    def test_dynamic_runtime_is_published_and_publicly_verified(self):
        self.assertEqual(self.publish(), 0)
        release = json.loads(self.files["release.json"])
        self.assertEqual(release["runtime_dlls"], ["MSVCR120.dll"])
        self.assertEqual(release["sha256"], hashlib.sha256(self.content).hexdigest())
        self.assertEqual(self.files[publisher.EXE_NAME], self.content)
        self.assertEqual(self.uploads, [publisher.EXE_NAME, "release.json"])
        self.assertEqual(json.loads(self.config.read_text())["key"], "fsk_fixture")

    def test_static_runtime_build_is_also_accepted(self):
        (self.package / publisher.EXE_NAME).write_bytes(pe("KERNEL32.dll"))
        self.assertEqual(self.publish(), 0)
        self.assertEqual(json.loads(self.files["release.json"])["runtime_dlls"], [])

    def test_invalid_exe_is_rejected(self):
        (self.package / publisher.EXE_NAME).write_bytes(b"not an exe")
        self.assertEqual(self.publish(), 1)
        self.assertEqual(self.uploads, [])

    def test_missing_credential_fails_required_publish(self):
        self.config.unlink()
        self.assertEqual(self.publish(), 1)
        self.assertEqual(self.uploads, [])

    def test_skip_does_not_publish(self):
        os.environ["FORGE_PUBLISH_SKIP"] = "1"
        self.assertEqual(publisher.main([]), 0)
        self.assertEqual(self.publish(), 1)
        self.assertEqual(self.uploads, [])

    def test_wrong_project_is_rejected(self):
        self.config.write_text(json.dumps({**self.original_config, "id": "fg_other"}))
        self.assertEqual(self.publish(), 1)
        self.assertEqual(self.uploads, [])

    def test_partial_upload_can_be_retried(self):
        self.fail_metadata = True
        self.assertEqual(self.publish(), 1)
        self.assertNotIn("published_sha256", json.loads(self.config.read_text()))
        self.fail_metadata = False
        self.assertEqual(self.publish(), 0)

    def test_wrong_public_download_fails(self):
        self.corrupt_download = True
        self.assertEqual(self.publish(), 1)
        self.assertNotIn("published_sha256", json.loads(self.config.read_text()))

    def test_unchanged_public_release_is_verified_without_upload(self):
        self.assertEqual(self.publish(), 0)
        self.uploads.clear()
        self.assertEqual(self.publish(), 0)
        self.assertEqual(self.uploads, [])
        self.corrupt_download = True
        self.assertEqual(self.publish(), 1)

    def test_ci_credential_does_not_overwrite_local_config(self):
        os.environ["FORGE_PUBLISHER_KEY"] = "fsk_fixture"
        self.assertEqual(self.publish(), 0)
        self.assertEqual(json.loads(self.config.read_text()), self.original_config)


if __name__ == "__main__":
    unittest.main()
