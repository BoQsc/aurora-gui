#!/usr/bin/env python3
"""Breakout-specific live edit test. The host dev tool stays game-generic."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOTSWAP = HOST / "aurora-hotswap.exe"
HOST_EXE = HOST / "aurora-host.exe"
SOURCE = PROJECT / "module.d"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", type=Path, default=HOST_EXE)
    parser.add_argument("--hotswap", type=Path, default=HOTSWAP)
    args = parser.parse_args()
    require(args.host.is_file(), f"missing host: {args.host}")
    require(args.hotswap.is_file(), f"missing hotswap: {args.hotswap}")

    with tempfile.TemporaryDirectory(prefix="aurora-breakout-dev-") as name:
        temp = Path(name)
        source = temp / "module.d"
        shutil.copyfile(SOURCE, source)
        out = temp / "shots"
        process = subprocess.Popen(
            [
                str(args.hotswap),
                "dev",
                "--source",
                str(source),
                "--host",
                str(args.host),
                "--out",
                str(out),
                "--watch",
                "30",
                "--hold",
                "1",
                "--events",
                "pointer",
                "--title",
                "Live Breakout",
            ],
            cwd=str(HOST),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        lines: list[str] = []
        edited = False
        try:
            assert process.stdout is not None
            for line in process.stdout:
                lines.append(line.rstrip("\n"))
                print(line, end="")
                if not edited and "[1]" in line:
                    text = source.read_text(encoding="utf-8")
                    match = re.search(r"enum PaddleWidth = (\d+);", text)
                    require(match is not None, "PaddleWidth declaration missing")
                    width = int(match.group(1))
                    next_width = 80 if width != 80 else 140
                    source.write_text(
                        text.replace(
                            f"enum PaddleWidth = {width};",
                            f"enum PaddleWidth = {next_width};",
                        ),
                        encoding="utf-8",
                    )
                    edited = True
                    time.sleep(0.2)
            process.wait(timeout=60)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=10)

        output = "\n".join(lines)
        require(edited, "never saw the first dev build")
        require("[2]" in output, "source edit did not trigger a second build")
        require(process.returncode == 0, f"dev exited {process.returncode}")
        first = out / "build-1.ppm"
        second = out / "build-2.ppm"
        require(first.is_file() and second.is_file(), "dev screenshots missing")
        require(first.read_bytes() != second.read_bytes(),
                "paddle edit did not change the frame")
        print("PASS Breakout project live edit")
        return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL Breakout project live edit: {error}", file=sys.stderr)
        raise SystemExit(1)
