import json
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LiveArtifactTests(unittest.TestCase):
    def test_live_revision_and_ack(self):
        ack_path = ROOT / "build" / "live-ack.json"
        self.assertTrue(ack_path.exists())
        ack = json.loads(ack_path.read_text())
        self.assertEqual(ack["status"], "ok")
        self.assertTrue(ack.get("valid"))
        self.assertGreaterEqual(ack.get("frameScan", 0), 1)
        self.assertEqual(ack.get("invalidFrames"), 0)
        self.assertIn("collisions", ack)
        self.assertGreaterEqual(ack["collisions"], 0)

    def test_frame_scan_report(self):
        path = ROOT / "build" / "live-frames.json"
        self.assertTrue(path.exists())
        report = json.loads(path.read_text())
        self.assertGreaterEqual(len(report["frames"]), 1)
        self.assertEqual(report["invalidFrames"], 0)
        self.assertTrue(all(frame["valid"] for frame in report["frames"]))

    def test_obj_injection_source(self):
        obj = (ROOT / "build" / "live-cube.obj").read_text().splitlines()
        self.assertEqual(sum(1 for line in obj if line.startswith("v ")), 8)
        self.assertEqual(sum(1 for line in obj if line.startswith("f ")), 12)

    def test_exported_glb_structure(self):
        path = ROOT / "build" / "live-export.glb"
        self.assertTrue(path.exists())
        data = path.read_bytes()
        self.assertEqual(data[:4], b"glTF")
        version, length = struct.unpack_from("<II", data, 4)
        self.assertEqual(version, 2)
        self.assertEqual(length, len(data))
        json_length = struct.unpack_from("<I", data, 12)[0]
        document = json.loads(data[20:20 + json_length].decode("utf-8").rstrip())
        self.assertEqual(document["asset"]["version"], "2.0")
        self.assertEqual(len(document["meshes"]), 1)
        self.assertEqual(len(document["images"]), 24)
        self.assertEqual(len(document["textures"]), 24)


if __name__ == "__main__":
    unittest.main()
