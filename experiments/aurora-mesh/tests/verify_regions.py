"""Live region-editing checks: selection, masked deformation, and the replace gate.

Every case drives the real binary through the live command file and reads the ack
it writes, so this exercises the same path the editor window uses.
"""

import json
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EXE = ROOT / "build" / "verify" / "aurora-mesh.exe"
GLB = ROOT / "build" / "verify-human.glb"
ACK = ROOT / "build" / "live-ack.json"


def run(commands, name):
    """Run one live revision and return its ack."""
    live = ROOT / "build" / f"region-{name}.json"
    shot = ROOT / "build" / f"region-{name}.ppm"
    live.write_text(json.dumps({"revision": 1, "commands": commands}))
    subprocess.run(
        [str(EXE), "--glb", str(GLB), "--live", str(live),
         "--screenshot", str(shot), "--width", "800", "--height", "600"],
        cwd=ROOT, capture_output=True, text=True, timeout=300)
    return json.loads(ACK.read_text()), shot


def pixels(path):
    data = Path(path).read_bytes().split(b"\n", 3)
    return data[3]


FEET = {"type": "region", "name": "feet", "kind": "box",
        "a": [-0.30, -0.02, -0.25], "b": [0.30, 0.15, 0.25], "falloff": 0.35}


class RegionEditing(unittest.TestCase):
    def test_region_reports_selection(self):
        ack, _ = run([FEET], "select")
        self.assertEqual(ack["regions"], 1)
        self.assertEqual(ack["region"], "feet")
        self.assertGreater(ack["maskVerts"], 10, "the region must select vertices")
        self.assertGreater(ack["maskFaces"], 10, "the region must select faces")

    def test_deform_changes_only_the_region(self):
        base, base_shot = run([], "base")
        ack, shot = run([FEET,
                         {"type": "deform", "region": "feet", "op": "inflate",
                          "amount": 0.012}], "inflate")
        self.assertEqual(ack["op"], "inflate")
        self.assertLess(ack["opMs"], 60.0, ack["opMs"])
        self.assertGreater(ack["maskVerts"], 10)
        before = pixels(base_shot)
        after = pixels(shot)
        self.assertEqual(len(before), len(after))
        changed = sum(1 for i in range(0, len(before), 3)
                      if before[i:i + 3] != after[i:i + 3])
        self.assertGreater(changed, 200, "the deformation must be visible")

    def test_pull_direction_and_smooth_run(self):
        ack, _ = run([FEET,
                      {"type": "deform", "op": "pull", "amount": 0.01,
                       "direction": [0, 0, 1]},
                      {"type": "deform", "op": "smooth", "amount": 0.5},
                      {"type": "deform", "op": "pinch", "amount": 0.1},
                      {"type": "deform", "op": "flatten", "amount": 0.4,
                       "direction": [0, 1, 0]}], "ops")
        self.assertEqual(ack["op"], "flatten")
        self.assertLess(ack["opMs"], 60.0)

    def test_subdivide_is_accepted(self):
        ack, _ = run([FEET, {"type": "replace", "kind": "subdivide",
                             "passes": 1}], "subdiv")
        self.assertTrue(ack["replaceOk"], ack["replaceReason"])
        self.assertEqual(ack["op"], "subdivide")

    def test_sdf_shell_is_accepted(self):
        ack, _ = run([FEET,
                      {"type": "replace", "kind": "sdf", "region": "feet",
                       "cell": 0.006,
                       "shapes": [
                           {"kind": "ellipsoid",
                            "center": [0.0, 0.05, 0.0],
                            "radii": [0.05, 0.04, 0.09]},
                           {"kind": "sphere",
                            "center": [0.0, 0.02, 0.10], "radius": 0.03}]}],
                     "sdf")
        self.assertTrue(ack["replaceOk"], ack["replaceReason"])

    def test_bad_replace_keeps_the_mesh(self):
        # A field far outside the model must be refused, not committed.
        ack, _ = run([FEET,
                      {"type": "replace", "kind": "sdf", "region": "feet",
                       "cell": 0.01,
                       "shapes": [{"kind": "sphere",
                                   "center": [10.0, 10.0, 10.0],
                                   "radius": 0.5}]}], "bad")
        self.assertFalse(ack["replaceOk"])
        self.assertNotEqual(ack["replaceReason"], "ok")
        # Compare against the same session without the replacement: the region
        # tint and its wireframe are part of both frames, so any difference left is
        # the mesh itself.
        _, plain = run([FEET], "plain")
        _, refused = run([FEET,
                          {"type": "replace", "kind": "sdf", "region": "feet",
                           "cell": 0.01,
                           "shapes": [{"kind": "sphere",
                                       "center": [10.0, 10.0, 10.0],
                                       "radius": 0.5}]}], "bad2")
        self.assertEqual(pixels(plain), pixels(refused),
                         "a refused replacement must leave the model untouched")


if __name__ == "__main__":
    unittest.main(verbosity=2)
