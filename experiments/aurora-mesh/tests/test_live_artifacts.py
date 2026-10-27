import json
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LiveArtifactTests(unittest.TestCase):
    def test_live_revision_and_ack(self):
        command_path = ROOT / "build" / "live.json"
        ack_path = ROOT / "build" / "live-ack.json"
        self.assertTrue(command_path.exists())
        self.assertTrue(ack_path.exists())
        command = json.loads(command_path.read_text())
        ack = json.loads(ack_path.read_text())
        self.assertGreaterEqual(command["revision"], 8)
        self.assertEqual(ack["revision"], command["revision"])
        self.assertEqual(ack["status"], "ok")
        self.assertGreaterEqual(ack["objects"], 1)
        self.assertEqual(ack.get("clip"), "ArmWave")

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
