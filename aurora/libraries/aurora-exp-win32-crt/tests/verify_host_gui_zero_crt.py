#!/usr/bin/env python3
"""Prove the windowed aurora-host launches with the Aurora CRT.

Builds the `tests/host_gui_app` fixture through the Aurora linker, requires no
Microsoft CRT import, then starts the real windowed host on the hello scene and
requires the process to still be alive after a short settling period.

Run from anywhere; paths resolve from the repository root.
"""
from __future__ import annotations

import shutil
import os
import struct
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
PACKAGE = REPO / "aurora" / "libraries" / "aurora-exp-win32-crt"
COFF = REPO / "aurora" / "libraries" / "aurora-exp-coff"
LINKER = COFF / "coff-link.exe"
FIXTURE = PACKAGE / "tests" / "host_gui_app"
EXECUTABLE = FIXTURE / "build" / "host-zero-crt-gui.exe"
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


def check() -> list[str]:
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
            "GUI host fixture build failed\n" + result.stdout + result.stderr
        )
    if not EXECUTABLE.is_file():
        raise CheckError("GUI host fixture produced no executable")
    data = EXECUTABLE.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    subsystem = struct.unpack_from("<H", data, pe + 24 + 68)[0]
    if subsystem != 2:
        raise CheckError(
            f"GUI host PE subsystem is {subsystem}, expected 2 (WINDOWS)")
    imports = read_imports(EXECUTABLE)
    forbidden = sorted(
        dll for dll in imports if dll.startswith(FORBIDDEN_PREFIXES)
    )
    if forbidden:
        raise CheckError(
            "GUI host imports Microsoft CRT libraries: " + ", ".join(forbidden)
        )

    process = subprocess.Popen(
        [str(EXECUTABLE), "--run", str(SCENE)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        time.sleep(2.0)
        if process.poll() is not None:
            stdout, stderr = process.communicate(timeout=10)
            raise CheckError(
                f"windowed host exited early ({process.returncode})\n"
                + stdout + stderr
            )
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
    return sorted(imports)


def main() -> int:
    try:
        imports = check()
    except CheckError as error:
        print(f"GUI host zero-CRT verification failed: {error}", file=sys.stderr)
        return 1
    print("GUI host zero-CRT verification passed")
    print("  imports:", ", ".join(imports))
    print("  windowed launch: alive after 2s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
