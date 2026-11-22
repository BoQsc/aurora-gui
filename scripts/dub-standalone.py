#!/usr/bin/env python3
"""Run DUB with the Aurora linker as the default standalone linker.

Builds `coff-link`, sets `LINKCMD64`, and forwards all arguments to DUB in the
current package. Use this instead of `dub` for standalone (zero-CRT) builds:

    python scripts/dub-standalone.py build --compiler=dmd
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
COFF = REPO / "aurora" / "libraries" / "aurora-exp-coff"
LINKER = COFF / "coff-link.exe"


def dub_path() -> str:
    found = shutil.which("dub")
    if found:
        return found
    fallback = Path(r"C:\D\dmd2\windows\bin64\dub.exe")
    if fallback.is_file():
        return str(fallback)
    raise SystemExit("dub was not found on PATH")


def main() -> int:
    built = subprocess.run(
        [dub_path(), "build", "--config=link", "--compiler=dmd"],
        cwd=COFF,
        capture_output=True,
        text=True,
    )
    if built.returncode != 0:
        print(built.stdout + built.stderr, file=sys.stderr)
        return built.returncode
    if not LINKER.is_file():
        print("coff-link was not produced", file=sys.stderr)
        return 1
    environment = os.environ.copy()
    environment["LINKCMD64"] = str(LINKER)
    result = subprocess.run([dub_path(), *sys.argv[1:]], env=environment)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
