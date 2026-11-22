#!/usr/bin/env python3
"""Verify the COFF archive reader against real toolchain libraries.

Builds `coff-archive`, resolves `ExitProcess` in `kernel32.lib` and
`_d_run_main` in `phobos64.lib`, and requires a missing symbol to be reported.

Run from anywhere; paths resolve from the repository root.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
PACKAGE = REPO / "aurora" / "libraries" / "aurora-exp-coff"
TOOL = PACKAGE / "coff-archive.exe"


class CheckError(Exception):
    pass


def tool(name: str, fallback: str) -> str:
    found = shutil.which(name)
    if found:
        return found
    path = Path(fallback)
    if path.is_file():
        return str(path)
    raise CheckError(f"{name} was not found on PATH")


def library(name: str) -> Path:
    dmd = Path(tool("dmd", r"C:\D\dmd2\windows\bin64\dmd.exe")).resolve()
    root = dmd.parents[1]
    for candidate in (root / "lib64" / "mingw" / name,
                      root / "lib64" / name,
                      root / "lib" / name):
        if candidate.is_file():
            return candidate
    raise CheckError(f"library not found: {name}")


def main() -> int:
    try:
        built = subprocess.run(
            [tool("dub", r"C:\D\dmd2\windows\bin64\dub.exe"),
             "build", "--config=archive", "--compiler=dmd"],
            cwd=PACKAGE, capture_output=True, text=True, timeout=300,
        )
        if built.returncode != 0:
            raise CheckError("tool build failed\n" + built.stdout + built.stderr)
        if not TOOL.is_file():
            raise CheckError("coff-archive was not produced")

        kernel32 = library("kernel32.lib")
        phobos = library("phobos64.lib")
        for archive, symbol in ((kernel32, "ExitProcess"),
                                (phobos, "_d_run_main")):
            result = subprocess.run(
                [str(TOOL), str(archive), symbol],
                capture_output=True, text=True, timeout=300,
            )
            if result.returncode != 0 or "found=yes" not in result.stdout:
                raise CheckError(
                    f"{archive.name}: {symbol} not found\n"
                    + result.stdout + result.stderr
                )
            print(f"{archive.name}: {symbol} found — "
                  + result.stdout.strip().replace("\n", ", "))

        missing = subprocess.run(
            [str(TOOL), str(kernel32), "aurora_no_such_symbol"],
            capture_output=True, text=True, timeout=300,
        )
        if missing.returncode == 0 or "found=no" not in missing.stdout:
            raise CheckError("missing symbol was not reported")
    except CheckError as error:
        print(f"COFF archive verification failed: {error}", file=sys.stderr)
        return 1

    print("COFF archive verification passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())