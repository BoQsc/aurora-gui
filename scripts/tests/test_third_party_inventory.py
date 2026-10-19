"""Acceptance tests for third-party inventory provenance paths."""
from __future__ import annotations

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
INVENTORY = ROOT / "aurora-browser" / "docs" / "third-party-inventory.json"

# Exact paths cited by the inventory. Globs and prose descriptions are excluded.
EXACT_PATHS = (
    "aurora-web/dub.json",
    "aurora-browser/dub.json",
    "vendor/aurora-d-0.4.5/LICENSE",
    "vendor/aurora-d-0.4.5/LICENSE-UNICODE.txt",
    "aurora-web/source/auroraweb/net.d",
    "vendor/aurora-d-0.4.5/source/aurora/image.d",
    "aurora-browser/tests/verify-render.json",
    "aurora-browser/docs/AGENT-HANDOFF.md",
    "aurora-browser/docs/IMPLEMENTATION-BRIEF.md",
    "aurora-opencode-pro/tools/capture-browser-reference.py",
    "aurora-opencode-pro/tools/browser-probe.d",
    "aurora-opencode-pro/tools/browser-engine-check.d",
)


class ThirdPartyInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = INVENTORY.read_text(encoding="utf-8")
        cls.data = json.loads(cls.text)
        cls.components = {
            component["component"]: component
            for component in cls.data["components"]
        }

    def test_vendored_patches_reference_the_repository_ledger(self):
        component = self.components[
            "Aurora-D GUI, text and raster toolkit (vendored)"
        ]
        self.assertIn("AURORA-PATCHES.md at the repository root", component["origin"])
        self.assertTrue((ROOT / "AURORA-PATCHES.md").is_file())

    def test_no_component_cites_the_missing_vendor_ledger(self):
        self.assertNotIn("vendor/aurora-d-0.4.5/AURORA-PATCHES.md", self.text)

    def test_exact_inventory_paths_exist(self):
        missing = [path for path in EXACT_PATHS if not (ROOT / path).exists()]
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
