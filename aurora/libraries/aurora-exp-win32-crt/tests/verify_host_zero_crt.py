#!/usr/bin/env python3
"""Prove aurora-host can be linked with the Aurora CRT.

Builds the `tests/host_app` fixture with DUB through the Aurora linker
(`LINKCMD64`), requires no Microsoft CRT import, then runs the host headless
scene check and a software render. The rendered PPM must be a valid binary PPM.

Run from anywhere; paths resolve from the repository root.
"""
from __future__ import annotations

import shutil
import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
PACKAGE = REPO / "aurora" / "libraries" / "aurora-exp-win32-crt"
COFF = REPO / "aurora" / "libraries" / "aurora-exp-coff"
LINKER = COFF / "coff-link.exe"
FIXTURE = PACKAGE / "tests" / "host_app"
EXECUTABLE = FIXTURE / "build" / "host-zero-crt.exe"
OUTPUT = REPO / "build" / "zero-crt" / "host"
SCENE = REPO / "aurora" / "aurora-host" / "samples" / "hello.scene.json"

sys.path.insert(0, str(PACKAGE / "tests"))
from verify_zero_crt import CheckError  # noqa: E402

sys.path.insert(0, str(REPO / "experiments" / "aurora-host" / "tools"))
from pe_imports import read_imports  # noqa: E402

FORBIDDEN_PREFIXES = (
    "msvcrt", "msvcr", "ucrt", "vcruntime", "api-ms-win-crt",
)


def dub_path() -> str:
    found = shutil.which("dub")
    if found:
        return found
    fallback = Path(r"C:\D\dmd2\windows\bin64\dub.exe")
    if fallback.is_file():
        return str(fallback)
    raise CheckError("dub was not found on PATH")


def build_host() -> Path:
    built = subprocess.run(
        [dub_path(), "build", "--config=link", "--compiler=dmd"],
        cwd=COFF,
        capture_output=True,
        text=True,
        timeout=300,
    )
    if built.returncode != 0:
        raise CheckError("coff-link build failed\n" + built.stdout + built.stderr)
    environment = os.environ.copy()
    environment["LINKCMD64"] = str(LINKER)
    result = subprocess.run(
        [dub_path(), "build", "--compiler=dmd"],
        cwd=FIXTURE,
        capture_output=True,
        text=True,
        timeout=600,
        env=environment,
    )
    if result.returncode != 0:
        raise CheckError(
            "host fixture build failed\n" + result.stdout + result.stderr
        )
    if not EXECUTABLE.is_file():
        raise CheckError("host fixture produced no executable")
    return EXECUTABLE


def check() -> list[str]:
    executable = build_host()
    imports = read_imports(executable)
    forbidden = sorted(
        dll for dll in imports if dll.startswith(FORBIDDEN_PREFIXES)
    )
    if forbidden:
        raise CheckError(
            "host imports Microsoft CRT libraries: " + ", ".join(forbidden)
        )

    checked = subprocess.run(
        [str(executable), "--check", str(SCENE)],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if checked.returncode != 0 or "scene OK" not in checked.stdout:
        raise CheckError(
            "host scene check failed\n" + checked.stdout + checked.stderr
        )

    OUTPUT.mkdir(parents=True, exist_ok=True)
    rendered = OUTPUT / "host-zero-crt.ppm"
    rendered.unlink(missing_ok=True)
    result = subprocess.run(
        [str(executable), "--render", str(SCENE), "--out", str(rendered)],
        capture_output=True,
        text=True,
        timeout=180,
    )
    if result.returncode != 0:
        raise CheckError(
            "host render failed\n" + result.stdout + result.stderr
        )
    if not rendered.is_file():
        raise CheckError("host render wrote no screenshot")
    data = rendered.read_bytes()
    if len(data) < 32 or data[:2] != b"P6":
        raise CheckError("host render is not a binary PPM")
    return sorted(imports)


def main() -> int:
    try:
        imports = check()
    except CheckError as error:
        print(f"host zero-CRT verification failed: {error}", file=sys.stderr)
        return 1
    print("host zero-CRT verification passed")
    print("  imports:", ", ".join(imports))
    print("  headless render: P6")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
