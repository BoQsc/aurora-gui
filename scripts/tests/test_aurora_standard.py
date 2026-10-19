"""Checkout acceptance tests for the frozen aurora-standard package."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "vendor" / "aurora-standard"
VERIFY = PACKAGE / "tools" / "verify_standard.py"


class AuroraStandardTests(unittest.TestCase):
    def test_package_location_and_version(self):
        self.assertFalse((ROOT / "standard").exists())
        self.assertTrue((PACKAGE / "VERSION").is_file())
        self.assertTrue((PACKAGE / "MANIFEST.sha256").is_file())
        version = (PACKAGE / "VERSION").read_text(encoding="utf-8").strip()
        metadata = json.loads((PACKAGE / "dub.json").read_text(encoding="utf-8"))
        self.assertEqual(metadata["version"], version)

    def test_package_verification_gate(self):
        completed = subprocess.run(
            [sys.executable, str(VERIFY)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            completed.returncode,
            0,
            completed.stdout + completed.stderr,
        )
        self.assertIn("aurora-standard verification passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()
