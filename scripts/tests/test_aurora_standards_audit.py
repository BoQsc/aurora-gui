"""Repository acceptance tests for the Aurora standards ratchet."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
AUDIT = ROOT / "scripts" / "audit-aurora-standards.py"


class AuroraStandardsAuditTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        completed = subprocess.run(
            [sys.executable, str(AUDIT), "--json"],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        cls.returncode = completed.returncode
        cls.stderr = completed.stderr
        cls.result = json.loads(completed.stdout)

    def test_repository_passes_the_standard_contract(self):
        self.assertEqual(self.returncode, 0, self.stderr)
        self.assertEqual(self.result["errors"], [])

    def test_every_package_uses_the_canonical_core(self):
        self.assertGreaterEqual(len(self.result["packages"]), 10)
        self.assertTrue(all(
            package["uses_canonical_core"]
            for package in self.result["packages"]
        ))

    def test_font_rendering_is_a_core_contract(self):
        contracts = self.result["contracts"]
        self.assertIn("sharp font rasterization is the window default", contracts)
        self.assertIn(
            "native-weight grayscale contrast is the atlas default", contracts)

    def test_frameless_window_shell_is_a_core_contract(self):
        self.assertIn(
            "frameless window shell orchestration is framework-owned",
            self.result["contracts"],
        )

    def test_no_downstream_policy_copies_remain(self):
        self.assertEqual(self.result["debt"], [])

    def test_no_unresolved_promotions_remain(self):
        self.assertEqual(self.result["promotion_candidates"], [])


if __name__ == "__main__":
    unittest.main()
