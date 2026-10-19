"""Checkout-level acceptance test for the separate host-notepad project."""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "tools" / "verify_notepad.py"


class HostNotepadTests(unittest.TestCase):
    def test_notepad_gate(self):
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
        self.assertIn(
            "aurora-host-notepad verification passed",
            completed.stdout,
        )


if __name__ == "__main__":
    unittest.main()
