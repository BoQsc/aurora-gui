#!/usr/bin/env python3
"""Smoke-test the blank new app through the live host workflow."""
from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOST_EXE = HOST / "aurora-host.exe"
HOTSWAP = HOST / "aurora-hotswap.exe"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    require(HOST_EXE.is_file(), f"missing host: {HOST_EXE}")
    require(HOTSWAP.is_file(), f"missing hotswap: {HOTSWAP}")
    with tempfile.TemporaryDirectory(prefix="aurora-new-app-") as name:
        temp = Path(name)
        source = temp / "module.d"
        shutil.copyfile(PROJECT / "module.d", source)
        out = temp / "shots"
        completed = subprocess.run(
            [
                str(HOTSWAP),
                "dev",
                "--source", str(source),
                "--host", str(HOST_EXE),
                "--out", str(out),
                "--watch", "4",
                "--hold", "1",
                "--events", "pointer",
                "--title", "New App",
            ],
            cwd=str(HOST), capture_output=True, text=True, encoding="utf-8",
            timeout=60,
        )
        need = "New App"
        require(completed.returncode == 0,
                f"live app failed: {completed.stdout}{completed.stderr}")
        require("[1]" in completed.stdout, "first live build was not reported")
        shot = out / "build-1.ppm"
        require(shot.is_file(), f"missing first frame: {shot}")
        data = shot.read_bytes()
        require(len(data) > 32 and data[:2] == b"P6",
                "first frame is not a binary PPM")
        print(f"PASS new app live build shot={shot} bytes={len(data)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL new app: {error}", file=sys.stderr)
        raise SystemExit(1)
