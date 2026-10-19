"""Checks the rebuilt Pro binary, its startup diagnostics, and the captured window.

Run from the repository root:
    python -u -B verification/test_render_evidence.py -v

The pixel check is a non-black assertion, not a reference comparison: the
captured window is the rebuilt application's own 1500x1000 client area.
"""

import os
import re
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
]
SCREENSHOT = Path(tempfile.gettempdir()) / "aurora-pro-app-window.png"
LOG = Path(os.environ.get("APPDATA", "")) / "Aurora OpenCode" / "logs" / "errors.log"


def log_tail(limit=262144):
    size = LOG.stat().st_size
    with LOG.open("rb") as stream:
        if size > limit:
            stream.seek(size - limit)
        return stream.read().decode("utf-8", "replace")


class RebuiltBinaryRenders(unittest.TestCase):
    def test_binary_is_newer_than_the_fixed_sources(self):
        self.assertTrue(EXE.exists(), EXE)
        for source in SOURCES:
            self.assertGreater(
                EXE.stat().st_mtime, source.stat().st_mtime,
                f"{EXE.name} predates {source}")

    def test_rebuild_report_records_success_and_relaunch(self):
        report = (APP / "rebuild-report.txt").read_text(errors="replace")
        self.assertIn("build succeeded", report)
        self.assertIn("running ", report)
        self.assertIn(str(EXE), report)

    def test_running_build_logged_its_renderer_and_framebuffer(self):
        tail = log_tail()
        self.assertRegex(tail, r"renderer: (Vulkan|Software) \((hardware|software)\)")
        match = re.search(r"window: (\d+)x(\d+) framebuffer", tail)
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


if __name__ == "__main__":
    unittest.main()
