#!/usr/bin/env python3
"""Verify the self-contained Aurora v2 tree using Python only."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"

ROOT = Path(__file__).resolve().parent
LIBRARY = ROOT / "aurora-d"
DESIGNER = ROOT / "aurora-designer"
HOST = ROOT / "aurora-host"
DUB = os.environ.get("DUB", "dub")
COMPILER = os.environ.get("DC", "dmd")
PYTHON = sys.executable


def run(command: list[object], cwd: Path) -> None:
    printable = " ".join(str(part) for part in command)
    print(f"+ {printable}", flush=True)
    subprocess.run([str(part) for part in command], cwd=cwd, check=True)


def host_executable(name: str) -> Path:
    return HOST / (name + (".exe" if os.name == "nt" else ""))


def check_python_only() -> None:
    forbidden = {".ps1", ".bat", ".cmd"}
    found = sorted(
        str(path.relative_to(ROOT))
        for path in ROOT.rglob("*")
        if path.is_file() and path.suffix.lower() in forbidden
    )
    if found:
        raise RuntimeError(
            "v2 verification and helper scripts must be Python only; found: "
            + ", ".join(found)
        )
    print("script entry points: Python only")


def main() -> int:
    check_python_only()

    # ---- Aurora-D ----
    run([DUB, "build", "--config=library", f"--compiler={COMPILER}"], LIBRARY)
    run([DUB, "run", "--config=headless-test", f"--compiler={COMPILER}"], LIBRARY)
    run([DUB, "run", "--config=public-api-test", f"--compiler={COMPILER}"], LIBRARY)
    run([DUB, "run", "--config=text-system-test", f"--compiler={COMPILER}"], LIBRARY)

    # ---- Aurora Designer ----
    designer_build = "build/verify"
    run([DUB, "build", "--config=default", f"--compiler={COMPILER}",
         f"--dest={designer_build}"], DESIGNER)
    smoke = DESIGNER / "build" / "headless-smoke" / "designer-smoke.ppm"
    smoke.unlink(missing_ok=True)
    run([DUB, "build", "--config=headless-smoke", f"--compiler={COMPILER}",
         f"--dest={designer_build}"], DESIGNER)
    smoke_exe = DESIGNER / designer_build / (
        "aurora-designer-headless-smoke" + (".exe" if os.name == "nt" else ""))
    run([smoke_exe], DESIGNER)
    if not smoke.is_file():
        raise RuntimeError("designer headless smoke did not write its screenshot")
    smoke_data = smoke.read_bytes()
    if len(smoke_data) < 32 or smoke_data[:2] != b"P6":
        raise RuntimeError("designer headless screenshot is not a binary PPM")
    print(f"designer smoke: {len(smoke_data)} bytes, P6")

    # ---- Aurora Host ----
    run([PYTHON, "-B", "tools/check_boundary.py"], HOST)
    run([PYTHON, "-B", "tools/generate_reference.py", "--check"], HOST)
    run([DUB, "build", "--config=host-headless", f"--compiler={COMPILER}"], HOST)
    run([DUB, "build", "--config=host", f"--compiler={COMPILER}"], HOST)

    headless = host_executable("aurora-host-headless")
    render = Path(tempfile.gettempdir()) / (
        "aurora-v2-verify-" + os.urandom(8).hex() + ".ppm"
    )
    try:
        run([headless, "--check", "samples/hello.scene.json"], HOST)
        run(
            [headless, "--render", "samples/hello.scene.json", "--out", render],
            HOST,
        )
        data = render.read_bytes()
        if len(data) < 32 or data[:2] != b"P6":
            raise RuntimeError("headless render did not produce a binary PPM")
        print(f"headless render: {len(data)} bytes, P6")
    finally:
        try:
            render.unlink()
        except FileNotFoundError:
            pass

    run([PYTHON, "-B", "tools/verify_host.py"], HOST)

    print()
    print("Aurora v2 verification passed.")
    print(
        "Note: the upstream library's bare 'dub test' still has its pre-existing "
        "texteditor clipboard unittest failure; it is not part of this gate."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
