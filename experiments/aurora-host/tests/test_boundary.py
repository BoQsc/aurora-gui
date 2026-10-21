"""Tests for the aurora-host responsibility boundary checker."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import check_boundary  # noqa: E402


def write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


class BoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.root = self.repo / "experiments" / "aurora-host"
        self.source = self.root / "source" / "experiment" / "aurorahost" / "main.d"
        self.demo = self.repo / "experiments" / "demo"
        self.demo_manifest = self.demo / "dub.json"
        self.demo_source = self.demo / "source" / "main.d"

        write(
            self.root / "protocol" / "aurora-host.boundary.json",
            (ROOT / "protocol" / "aurora-host.boundary.json").read_text(
                encoding="utf-8"
            ),
        )
        write(
            self.root / "dub.json",
            json.dumps(
                {
                    "name": "aurora-host-experiment",
                    "dependencies": {
                        "aurora-d": {"path": "../../vendor/aurora-d-0.4.5"},
                        "aurora-standard": {"path": "../../vendor/aurora-standard"},
                    },
                }
            ),
        )
        write(
            self.source,
            "module experiment.aurorahost.main;\n"
            "import aurora;\n"
            "import std.stdio;\n",
        )
        write(self.demo_manifest, json.dumps({"name": "demo"}))
        write(self.demo_source, "module demo.main;\n")

    def errors(self) -> list[str]:
        return check_boundary.verify_boundary(self.root, self.repo)

    def test_current_checkout_passes(self):
        self.assertEqual(
            check_boundary.verify_boundary(ROOT, ROOT.parents[1]),
            [],
        )

    def test_forbidden_import_is_rejected(self):
        with self.source.open("a", encoding="utf-8") as stream:
            stream.write("import browser.engine;\n")
        self.assertTrue(
            any("forbidden module 'browser.engine'" in error for error in self.errors())
        )

    def test_extra_dependency_is_rejected(self):
        manifest = json.loads(self.root.joinpath("dub.json").read_text())
        manifest["dependencies"]["vibe-d"] = {"path": "../../vendor/vibe-d"}
        write(self.root / "dub.json", json.dumps(manifest))
        self.assertTrue(
            any("unapproved dependency: vibe-d" in error for error in self.errors())
        )

    def test_wrong_dependency_path_is_rejected(self):
        manifest = json.loads(self.root.joinpath("dub.json").read_text())
        manifest["dependencies"]["aurora-d"]["path"] = "../../vendor/other"
        write(self.root / "dub.json", json.dumps(manifest))
        self.assertTrue(
            any("aurora-d points to" in error for error in self.errors())
        )

    def test_missing_dependency_is_rejected(self):
        manifest = json.loads(self.root.joinpath("dub.json").read_text())
        del manifest["dependencies"]["aurora-standard"]
        write(self.root / "dub.json", json.dumps(manifest))
        self.assertTrue(
            any("missing required dependency" in error for error in self.errors())
        )

    def test_reverse_dependency_is_rejected(self):
        write(
            self.demo_manifest,
            json.dumps(
                {
                    "name": "demo",
                    "dependencies": {
                        "aurora-host-experiment": {"path": "../aurora-host"}
                    },
                }
            ),
        )
        self.assertTrue(
            any("depends on host" in error for error in self.errors())
        )

    def test_outside_import_is_rejected(self):
        write(
            self.demo_source,
            "module demo.main;\n"
            "import experiment.aurorahost.surface;\n",
        )
        self.assertTrue(
            any("outside code imports host namespace" in error for error in self.errors())
        )

    def test_non_package_evidence_import_is_ignored(self):
        write(
            self.repo / "artifacts" / "capture" / "capture.d",
            "module capture;\n"
            "import experiment.aurorahost.scene;\n",
        )
        self.assertEqual(self.errors(), [])


if __name__ == "__main__":
    unittest.main()