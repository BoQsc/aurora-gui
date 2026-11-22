#!/usr/bin/env python3
"""Verify the Aurora COFF reader against a DMD-generated object.

Builds `coff-inspect`, compiles the probe with `dmd -c -betterC`, inspects the
object, and requires the section and symbol facts a linker depends on. It also
requires truncated input to be rejected.

Run from anywhere; paths resolve from the repository root.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
PACKAGE = REPO / "aurora" / "libraries" / "aurora-exp-coff"
TOOL = PACKAGE / "coff-inspect.exe"
PROBE = PACKAGE / "tests" / "probe.d"
OUTPUT = REPO / "build" / "coff"


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


def run(command: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True,
                          timeout=300)


def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    try:
        built = run([tool("dub", r"C:\D\dmd2\windows\bin64\dub.exe"),
                     "build", "--config=inspect", "--compiler=dmd"], PACKAGE)
        if built.returncode != 0:
            raise CheckError("tool build failed\n" + built.stdout + built.stderr)
        if not TOOL.is_file():
            raise CheckError("coff-inspect was not produced")

        obj = OUTPUT / "probe.obj"
        compiled = run([tool("dmd", r"C:\D\dmd2\windows\bin64\dmd.exe"),
                        "-c", "-betterC", f"-of={obj}", str(PROBE)], PACKAGE)
        if compiled.returncode != 0:
            raise CheckError("probe compile failed\n"
                             + compiled.stdout + compiled.stderr)
        if not obj.is_file():
            raise CheckError("probe object was not produced")

        inspected = run([str(TOOL), str(obj)], REPO)
        if inspected.returncode != 0:
            raise CheckError("inspect failed\n" + inspected.stdout + inspected.stderr)
        output = inspected.stdout
        for marker in ("machine=0x8664", "section .text",
                       "symbol _D5probe3addFiiZi", "symbol _D5probe7counteri",
                       "primarySymbols="):
            if marker not in output:
                raise CheckError(f"inspect output missing {marker!r}:\n{output}")
        if "relocations=" not in output:
            raise CheckError("inspect output has no relocation count")

        truncated = OUTPUT / "truncated.obj"
        truncated.write_bytes(obj.read_bytes()[:10])
        rejected = run([str(TOOL), str(truncated)], REPO)
        if rejected.returncode == 0 or "rejected" not in rejected.stderr:
            raise CheckError("truncated object was not rejected")
    except CheckError as error:
        print(f"COFF verification failed: {error}", file=sys.stderr)
        return 1

    print("COFF verification passed")
    for line in output.splitlines():
        if line.startswith(("machine=", "sections=", "symbols=", "relocations=",
                            "section .text", "symbol _D5probe3addFiiZi",
                            "symbol _D5probe7counteri")):
            print("  " + line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
