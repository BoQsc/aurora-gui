"""Tests for the dependency-free Aurora A/B review generator."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "scripts" / "make-aurora-visual-review.py"


class AuroraVisualReviewTests(unittest.TestCase):
    def test_review_starts_pending_and_contains_all_comparison_modes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "a.svg"
            candidate = root / "b.svg"
            baseline.write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
                '<rect width="10" height="10" fill="black"/></svg>',
                encoding="utf-8",
            )
            candidate.write_text(
                '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
                '<rect width="10" height="10" fill="white"/></svg>',
                encoding="utf-8",
            )
            output = root / "review"
            completed = subprocess.run(
                [
                    sys.executable, str(GENERATOR),
                    "--baseline", str(baseline),
                    "--candidate", str(candidate),
                    "--title", "Typography candidate",
                    "--output", str(output),
                ],
                cwd=ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            manifest = json.loads((output / "review.json").read_text("utf-8"))
            self.assertEqual(manifest["status"], "pending-user-review")
            self.assertIsNone(manifest["decision"])
            self.assertEqual(len(manifest["baseline"]["sha256"]), 64)
            page = (output / "review.html").read_text("utf-8")
            self.assertIn("A — current standard", page)
            self.assertIn("B — proposed candidate", page)
            self.assertIn("Same-position wipe comparison", page)
            self.assertIn("Blink A/B", page)
            self.assertIn("Final choice belongs to the project owner", page)


if __name__ == "__main__":
    unittest.main()
