#!/usr/bin/env python3
"""Run the in-process headless widget-input test without opening a window."""
from __future__ import annotations

import subprocess
from pathlib import Path
import sys

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[2]
HOST = ROOT / "aurora" / "aurora-host"
OUT = PROJECT / "build"
EXE = OUT / "host-input-test.exe"
SOURCE = PROJECT / "host_input_test.d"
SCENE = PROJECT / "scene.json"


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    build = subprocess.run(
        [
            "dmd", "-version=AuroraHeadless", "-i",
            f"-J{HOST / 'assets'}",
            f"-I{HOST.parent / 'aurora-d' / 'source'}",
            f"-I{HOST.parent / 'aurora-standard' / 'source'}",
            f"-I{HOST / 'source'}", f"-I{HOST / 'generated'}",
            f"-of={EXE}", str(SOURCE),
        ],
        capture_output=True, text=True, encoding="utf-8", timeout=300,
    )
    if build.returncode != 0:
        print(build.stdout + build.stderr, file=sys.stderr)
        return build.returncode
    run = subprocess.run(
        [str(EXE), str(SCENE)], capture_output=True, text=True,
        encoding="utf-8", timeout=60,
    )
    sys.stdout.write(run.stdout)
    sys.stderr.write(run.stderr)
    return run.returncode


if __name__ == "__main__":
    raise SystemExit(main())
