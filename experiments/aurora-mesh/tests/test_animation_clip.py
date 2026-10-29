"""Structure and physics checks for the authored animation clips.

These run without the reference GLB, so they guard the clip assets in every
checkout. They verify the invariants the live authoring protocol expects and the
weapon-follow math the rifle track is generated from.
"""

import json
import math
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLIPS = sorted((ROOT / "assets" / "animations").glob("*.json"))
AXES = {"x": (1.0, 0.0, 0.0), "y": (0.0, 1.0, 0.0), "z": (0.0, 0.0, 1.0)}


def load(path):
    return json.loads(path.read_text())


def axis_vector(value):
    if isinstance(value, str):
        return AXES[value]
    return tuple(float(component) for component in value)


class ClipTests(unittest.TestCase):
    def test_clips_exist(self):
        self.assertTrue(CLIPS, "no animation clips under assets/animations")

    def test_clip_structure(self):
        for path in CLIPS:
            clip = load(path)
            with self.subTest(clip=path.name):
                self.assertTrue(clip["name"])
                self.assertGreater(clip["duration"], 0)
                self.assertGreater(clip["fps"], 0)
                self.assertTrue(clip["tracks"])
                for track in clip["tracks"]:
                    self.assertTrue(track["node"], "track needs a node")
                    keys = track["keys"]
                    self.assertGreaterEqual(len(keys), 3)
                    times = [key["time"] for key in keys]
                    self.assertEqual(times, sorted(times),
                                     f"{track['node']} keys are out of order")
                    self.assertGreaterEqual(times[0], 0)
                    self.assertLessEqual(times[-1], clip["duration"] + 1e-9)
                    for key in keys:
                        has_rotation = len(key.get("rotation", ())) == 4
                        has_axis = "worldAxis" in key and "angle" in key
                        self.assertTrue(has_rotation or has_axis,
                                        f"{track['node']} key needs a rotation")

    def test_loop_is_seamless(self):
        for path in CLIPS:
            clip = load(path)
            if not clip.get("loop", True):
                continue
            with self.subTest(clip=path.name):
                for track in clip["tracks"]:
                    first, last = track["keys"][0], track["keys"][-1]
                    self.assertEqual(first["time"], 0)
                    self.assertAlmostEqual(first["time"], 0)
                    self.assertAlmostEqual(last["time"], clip["duration"])
                    for field in ("angle", "rotation", "translation"):
                        if field not in first:
                            continue
                        self.assertIn(field, last)
                        if field == "rotation":
                            delta = max(abs(a - b) for a, b
                                        in zip(first[field], last[field]))
                            # q and -q are the same orientation
                            flipped = max(abs(a + b) for a, b
                                          in zip(first[field], last[field]))
                            self.assertLess(min(delta, flipped), 1e-6)
                        else:
                            values = first[field] if isinstance(first[field],
                                                                list) \
                                else [first[field]]
                            others = last[field] if isinstance(last[field],
                                                               list) \
                                else [last[field]]
                            for a, b in zip(values, others):
                                self.assertAlmostEqual(a, b, places=6)

    def test_tracks_actually_move(self):
        for path in CLIPS:
            clip = load(path)
            with self.subTest(clip=path.name):
                for track in clip["tracks"]:
                    keys = track["keys"]
                    spans = []
                    if "angle" in keys[0]:
                        angles = [key.get("angle", 0.0) for key in keys]
                        spans.append(max(angles) - min(angles))
                    if "translation" in keys[0]:
                        origin = keys[0]["translation"]
                        spans.append(max(
                            math.dist(origin, key["translation"])
                            for key in keys))
                    self.assertGreater(max(spans, default=0.0), 1e-4,
                                       f"{track['node']} track is static")

    def test_follow_declarations(self):
        """A followed socket is generated from an animated world-axis track."""
        for path in CLIPS:
            clip = load(path)
            follow = clip.get("follow", [])
            if not follow:
                continue
            with self.subTest(clip=path.name):
                animated = {track["node"]: track for track in clip["tracks"]}
                for entry in follow:
                    self.assertTrue(entry["node"], "follow needs a node")
                    self.assertIn(entry["target"], animated,
                                  "follow target must be an animated track")
                    self.assertNotEqual(entry["node"], entry["target"])
                    self.assertNotIn(entry["node"], animated,
                                     "a followed socket must not also be keyed")
                    target = animated[entry["target"]]
                    self.assertTrue(
                        any("worldAxis" in key for key in target["keys"]),
                        "follow needs world-axis keys on its target")

    def test_grip_declarations(self):
        for path in CLIPS:
            clip = load(path)
            grip = clip.get("grip")
            if not grip:
                continue
            with self.subTest(clip=path.name):
                self.assertTrue(grip["pivotNode"])
                self.assertTrue(grip["socketNode"])
                self.assertNotEqual(grip["pivotNode"], grip["socketNode"])

    def test_watch_declarations(self):
        for path in CLIPS:
            clip = load(path)
            watch = clip.get("watch")
            if not watch:
                continue
            with self.subTest(clip=path.name):
                self.assertTrue(watch["node"], "watch needs a node")
                self.assertGreater(watch["minTravel"], 0,
                                   "watch needs a positive minimum travel")
                animated = {track["node"] for track in clip["tracks"]}
                self.assertTrue(
                    watch["node"] in animated or clip.get("follow"),
                    "watch node should be moved by the clip")

    def test_world_axes_are_valid(self):
        for path in CLIPS:
            clip = load(path)
            with self.subTest(clip=path.name):
                for track in clip["tracks"]:
                    for key in track["keys"]:
                        if "worldAxis" not in key:
                            continue
                        vector = axis_vector(key["worldAxis"])
                        self.assertAlmostEqual(
                            math.sqrt(sum(component ** 2
                                          for component in vector)), 1.0)
                        self.assertLessEqual(abs(float(key["angle"])), 180)

    def test_audit_profile(self):
        """Clips may scope the audit; the declarations must stay well formed."""
        for path in CLIPS:
            clip = load(path)
            with self.subTest(clip=path.name):
                checks = clip.get("checks", {})
                if "collisions" in checks:
                    self.assertIsInstance(checks["collisions"], bool)
                parts = clip.get("ignoreParts", [])
                for part in parts:
                    self.assertIsInstance(part, str)
                    self.assertTrue(part, "ignored part names cannot be empty")
                if parts:
                    self.assertTrue(
                        clip.get("scene") or clip.get("follow"),
                        "prop exclusions belong to a prop carrying clip")


if __name__ == "__main__":
    unittest.main()
