"""Checkout-level acceptance test for aurora-host."""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "tools" / "verify_host.py"


class AuroraHostTests(unittest.TestCase):
    def test_host_gate(self):
        completed = subprocess.run(
            [sys.executable, "-B", str(VERIFY)],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            completed.returncode,
            0,
            completed.stdout + completed.stderr,
        )
        self.assertIn("aurora-host verification passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()
