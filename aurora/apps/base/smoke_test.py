#!/usr/bin/env python3
"""Build and launch Aurora Base through the standard live host workflow."""
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
TITLE = "Aurora Base"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def main() -> int:
    require(HOST_EXE.is_file(), f"missing host: {HOST_EXE}")
    require(HOTSWAP.is_file(), f"missing hotswap: {HOTSWAP}")

    source_text = (PROJECT / "module.d").read_text(encoding="utf-8")
    for forbidden in (
        "gdi32", "core.sys.windows", "CreateFont", "TextOutA", "DrawTextA",
        "SelectObject",
    ):
        require(forbidden not in source_text,
                f"base must not use native text/GDI API: {forbidden}")
    require("aurora.canvas" in source_text and
            "layoutText" in source_text and "drawLayout" in source_text,
            "base must render through Aurora Canvas/text")
    require("LiveSurface" in source_text and "publish" in source_text,
            "base must publish through the shared surface")

    with tempfile.TemporaryDirectory(prefix="aurora-base-") as name:
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
                "--events", "pointer,key",
                "--title", TITLE,
                "--width", "1180",
                "--height", "760",
            ],
            cwd=str(HOST),
            capture_output=True,
            text=True,
            encoding="utf-8",
            timeout=90,
        )
        output = completed.stdout + completed.stderr
        require(completed.returncode == 0, f"live app failed:\n{output}")
        require("[1]" in completed.stdout, "first live build was not reported")
        for stage in ("module built", "module spawned", "host spawned",
                      "surface mapped", "first frame captured"):
            require(f"[trace] " in completed.stdout and stage in completed.stdout,
                    f"startup trace is missing stage: {stage}")
        shot = out / "build-1.ppm"
        require(shot.is_file(), f"missing first frame: {shot}")
        data = shot.read_bytes()
        require(len(data) > 32 and data[:2] == b"P6",
                "first frame is not a binary PPM")
        header = data[:32].split(b"\n", 3)
        require(header[0] == b"P6", "PPM magic changed")
        width, height = map(int, header[1].split())
        require(width >= 200 and height >= 200,
                f"unexpected host screenshot dimensions: {width}x{height}")
        require(abs(width * 760 - height * 1180) <= 8,
                f"host screenshot is not the 1180x760 base: {width}x{height}")
        print(f"PASS Aurora Base live host shot={shot} bytes={len(data)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL Aurora Base live host: {error}", file=sys.stderr)
        raise SystemExit(1)
