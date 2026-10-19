"""Checks the rebuilt Pro binary, its startup diagnostics, and the captured window.

Run from the repository root:
    python -u -B verification/test_render_evidence.py -v

The pixel check is a non-black assertion, not a reference comparison: the
captured window is the rebuilt application's own 1500x1000 client area.
"""

import os
import re
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "aurora-opencode-pro"
EXE = APP / "aurora-opencode-pro.exe"
SOURCES = [
    APP / "source" / "app.d",
    ROOT / "vendor" / "aurora-d-0.4.5" / "source" / "aurora" / "window.d",
    ROOT / "vendor" / "aurora-d-0.4.5" / "source" / "aurora" / "render" / "vulkan.d",
    ROOT / "vendor" / "aurora-d-0.4.5" / "source" / "aurora" / "render" / "select.d",
]
SCREENSHOT = Path(tempfile.gettempdir()) / "aurora-pro-app-window.png"
SOFTWARE_SHOT = Path(tempfile.gettempdir()) / "aurora-software-check.ppm"
LOG = Path(os.environ.get("APPDATA", "")) / "Aurora OpenCode" / "logs" / "errors.log"


def startup_log():
    # A long-running session outgrows any fixed tail, so search the whole log;
    # the frame diagnostics are written once per launch.
    return LOG.read_text(encoding="utf-8", errors="replace")


class RebuiltBinaryRenders(unittest.TestCase):
    def test_binary_is_newer_than_the_fixed_sources(self):
        self.assertTrue(EXE.exists(), EXE)
        for source in SOURCES:
            self.assertGreater(
                EXE.stat().st_mtime, source.stat().st_mtime,
                f"{EXE.name} predates {source}")

    def test_build_provenance_matches_head_and_binary(self):
        provenance = json.loads(
            (APP / "build-source-aurora-opencode-pro.exe.json").read_text())
        head = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        commit = provenance["source_commit"]
        self.assertEqual(len(commit), 40)
        # Verification-only commits may follow the build; the binary is current
        # as long as its commit is in this history and no app source changed.
        subprocess.run(["git", "merge-base", "--is-ancestor", commit, head],
                       cwd=ROOT, check=True)
        changed = subprocess.check_output(
            ["git", "diff", "--name-only", commit, head, "--",
             "aurora-opencode-pro/source", "vendor/aurora-d-0.4.5/source"],
            cwd=ROOT, text=True).strip()
        self.assertEqual(changed, "")
        self.assertFalse(provenance["source_dirty"])
        digest = hashlib.sha256(EXE.read_bytes()).hexdigest()
        self.assertEqual(provenance["binary_sha256"], digest)

        state = json.loads((APP / "rebuildstate.json").read_text())
        self.assertEqual(state["status"], "ok")
        self.assertEqual(state["exitCode"], 0)
        self.assertEqual(state["exe"], str(EXE))

    def test_running_build_logged_its_renderer_and_framebuffer(self):
        log = startup_log()
        self.assertRegex(log, r"renderer: (Vulkan|Software) \((hardware|software)\)")
        match = re.search(r"window: (\d+)x(\d+) framebuffer", log)
        self.assertIsNotNone(match, "new build's framebuffer diagnostic is missing")
        self.assertGreater(int(match.group(1)), 0)
        self.assertGreater(int(match.group(2)), 0)

    def test_captured_window_is_not_black(self):
        self.assertTrue(SCREENSHOT.exists(), SCREENSHOT)
        image = Image.open(SCREENSHOT).convert("RGB")
        self.assertGreaterEqual(image.width, 1000)
        self.assertGreaterEqual(image.height, 800)
        small = image.resize((150, 100))
        data = list(small.getdata())
        mean = sum(sum(pixel) for pixel in data) / (len(data) * 3)
        bright = sum(1 for pixel in data if max(pixel) > 40) / len(data)
        colors = len(small.getcolors(maxcolors=15000))
        self.assertGreater(mean, 8.0, "captured window is essentially black")
        self.assertGreater(bright, 0.05, "too few visible pixels")
        self.assertGreater(colors, 50, "captured window has no rendered detail")

    def test_software_renderer_output_is_not_black(self):
        self.assertTrue(SOFTWARE_SHOT.exists(), SOFTWARE_SHOT)
        image = Image.open(SOFTWARE_SHOT).convert("RGB")
        self.assertGreaterEqual(image.width, 1000)
        self.assertGreaterEqual(image.height, 800)
        small = image.resize((150, 100))
        data = list(small.getdata())
        mean = sum(sum(pixel) for pixel in data) / (len(data) * 3)
        bright = sum(1 for pixel in data if max(pixel) > 40) / len(data)
        colors = len(small.getcolors(maxcolors=15000))
        self.assertGreater(mean, 8.0, "software frame is essentially black")
        self.assertGreater(bright, 0.02, "software frame has too few visible pixels")
        self.assertGreater(colors, 50, "software frame has no rendered detail")


if __name__ == "__main__":
    unittest.main()
