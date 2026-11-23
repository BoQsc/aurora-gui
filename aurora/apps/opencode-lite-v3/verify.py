#!/usr/bin/env python3
"""v3.0.0 headless release gate."""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

APP = Path(__file__).resolve().parent
TESTS = [
    "tests/hot_swap_test.py",
    "tests/session_surface_test.py",
    "tests/session_persistence_test.py",
    "tests/scene_surface_test.py",
    "tests/controller_stream_test.py",
]


def run(args, cwd=APP):
    print("+", " ".join(str(a) for a in args), flush=True)
    result = subprocess.run(args, cwd=str(cwd))
    if result.returncode != 0:
        raise SystemExit(result.returncode)


def main() -> int:
    for config in ("contract", "stable-shell", "module-v1", "module-v2"):
        run(["dub", "build", f"--config={config}", "--compiler=dmd"])
    run(["build/aurora-opencode-lite-v3-contract.exe"])
    for test in TESTS:
        run([sys.executable, "-B", test])
    print("v3.0.0 release gate passed: core, shell, sessions, migration, controller")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
