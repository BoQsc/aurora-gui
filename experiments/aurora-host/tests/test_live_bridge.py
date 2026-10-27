#!/usr/bin/env python3
"""Checkout checker for the live scene bridge."""
from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(
    sys.platform == "win32",
    "the live GUI host is verified on Windows",
)
class LiveBridgeTest(unittest.TestCase):
    def test_round_trip(self) -> None:
        exe = ROOT / "build" / "live-harness" / "host" / (
            "aurora-host-experiment.exe"
        )
        if not exe.is_file():
            subprocess.run(
                [
                    "dub",
                    "build",
                    "--config=host",
                    "--build=release",
                    "--dest=build/live-harness/host",
                ],
                cwd=ROOT,
                check=True,
                timeout=600,
            )
        completed = subprocess.run(
            [
                sys.executable,
                "-u",
                "-B",
                "tools/live_bridge_test.py",
                "--port",
                "8799",
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=180,
        )
        self.assertEqual(
            completed.returncode,
            0,
            completed.stdout + completed.stderr,
        )
        self.assertIn("live bridge self-test passed", completed.stdout)


if __name__ == "__main__":
    unittest.main()