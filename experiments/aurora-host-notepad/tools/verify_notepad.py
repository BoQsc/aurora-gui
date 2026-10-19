#!/usr/bin/env python3
"""Verify the separate notepad project against a freshly built aurora host."""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[1]
HOST_ROOT = REPO / "experiments" / "aurora-host"
VENDOR = REPO / "vendor"
AURORA = VENDOR / "aurora-d-0.4.5"
STANDARD = VENDOR / "aurora-standard"
MAIN = HOST_ROOT / "source" / "experiment" / "aurorahost" / "main.d"


class VerificationError(Exception):
    pass


def run(command: list[str], *, cwd: Path, expect: int = 0,
        env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        command,
        cwd=cwd,
        capture_output=True,
        text=True,
        env=env,
    )
    if completed.returncode != expect:
        raise VerificationError(
            "command failed: " + " ".join(command)
            + f"\nexpected exit {expect}, got {completed.returncode}\n"
            + completed.stdout + completed.stderr
        )
    return completed


def build_host(dmd: str, temp: Path) -> Path:
    object_dir = temp / "obj-host"
    object_dir.mkdir()
    executable = temp / "host.exe"
    run(
        [
            dmd,
            f"-I{AURORA / 'source'}",
            f"-I{STANDARD / 'source'}",
            f"-I{HOST_ROOT / 'generated'}",
            f"-I{HOST_ROOT / 'source'}",
            "-i",
            f"-od={object_dir}",
            f"-of={executable}",
            str(MAIN),
            "user32.lib",
            "gdi32.lib",
        ],
        cwd=HOST_ROOT,
    )
    if not executable.is_file():
        raise VerificationError(f"host executable was not produced: {executable}")
    return executable


def verify_ppm(path: Path) -> None:
    data = path.read_bytes()
    match = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not match:
        raise VerificationError("notepad screenshot has no valid P6 header")
    width, height, maximum = (int(value) for value in match.groups())
    if maximum != 255:
        raise VerificationError("notepad screenshot is not 8-bit RGB")
    pixels = data[match.end():]
    if len(pixels) != width * height * 3:
        raise VerificationError("notepad screenshot payload has the wrong size")
    colors = {
        pixels[index:index + 3]
        for index in range(0, len(pixels), 3 * 97)
    }
    if len(colors) < 8:
        raise VerificationError("notepad screenshot appears blank")


def main() -> int:
    dmd = shutil.which("dmd")
    if not dmd:
        print("dmd is not on PATH", file=sys.stderr)
        return 1
    try:
        with tempfile.TemporaryDirectory(prefix="aurora-notepad-") as temp_name:
            temp = Path(temp_name)
            host = build_host(dmd, temp)
            document = temp / "notepad-demo.txt"
            image = temp / "notepad.ppm"
            png = temp / "notepad.png"
            env = os.environ.copy()
            env["AURORA_HOST_EXE"] = str(host)
            completed = run(
                [
                    sys.executable,
                    "-B",
                    str(ROOT / "notepad.py"),
                    "--demo",
                    "--host",
                    str(host),
                    "--file",
                    str(document),
                    "--out",
                    str(image),
                    "--png",
                    str(png),
                ],
                cwd=ROOT,
                env=env,
            )
            if "notepad demo passed" not in completed.stdout:
                raise VerificationError(
                    "notepad demo did not report success\n" + completed.stdout
                )
            if not document.is_file():
                raise VerificationError("notepad demo did not write its document")
            text = document.read_text(encoding="utf-8")
            if "clicking the real Save button" not in text:
                raise VerificationError("saved document is missing the edited body")
            if "café, 日本語, 🚀" not in text:
                raise VerificationError("saved document lost Unicode content")
            verify_ppm(image)
            if not png.is_file():
                raise VerificationError("notepad PNG was not produced")
    except VerificationError as error:
        print(f"aurora-host-notepad verification failed: {error}",
              file=sys.stderr)
        return 1

    print("host executable: built in temp")
    print("notepad controller: launched host and handled actions")
    print("document: edited, saved by button action, Unicode preserved")
    print("screenshot: live PPM and PNG produced")
    print("aurora-host-notepad verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
