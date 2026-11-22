#!/usr/bin/env python3
"""Verify DMD can link a real zero-CRT program with the Aurora linker.

Sets `LINKCMD64` to `coff-link.exe`, compiles the probe with the Aurora CRT
sources, and requires the produced EXE to import no Microsoft CRT and exit 0.
This replaces `lld-link` for the invocation while the wrapper path is active.

Run from anywhere; paths resolve from the repository root.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
COFF = REPO / "aurora" / "libraries" / "aurora-exp-coff"
CRT = REPO / "aurora" / "libraries" / "aurora-exp-win32-crt"
TOOL = COFF / "coff-link.exe"
OUTPUT = REPO / "build" / "coff" / "lld"

sys.path.insert(0, str(REPO / "experiments" / "aurora-host" / "tools"))
from pe_imports import read_imports  # noqa: E402


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


def main() -> int:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    try:
        built = subprocess.run(
            [tool("dub", r"C:\D\dmd2\windows\bin64\dub.exe"),
             "build", "--config=link", "--compiler=dmd"],
            cwd=COFF, capture_output=True, text=True, timeout=300,
        )
        if built.returncode != 0:
            raise CheckError("tool build failed\n" + built.stdout + built.stderr)
        if not TOOL.is_file():
            raise CheckError("coff-link was not produced")

        exe = OUTPUT / "lld-hello.exe"
        exe.unlink(missing_ok=True)
        objects = OUTPUT / "obj"
        objects.mkdir(exist_ok=True)
        sources = sorted(str(path) for path in (CRT / "source").rglob("*.d"))
        sources.append(str(CRT / "tests" / "probe.d"))
        environment = os.environ.copy()
        environment["LINKCMD64"] = str(TOOL)
        map_path = OUTPUT / "link.map"
        environment["AURORA_LINK_MAP"] = str(map_path)
        command = [
            tool("dmd", r"C:\D\dmd2\windows\bin64\dmd.exe"),
            "-mscrtlib=msvcrt",
            f"-I{CRT / 'source'}",
            f"-od={objects}",
            f"-of={exe}",
            *sources,
            "-L/NODEFAULTLIB:msvcrt",
            "-L/NODEFAULTLIB:libcmt",
            "-L/NODEFAULTLIB:oldnames",
            "-L/ENTRY:mainCRTStartup",
            "-Lkernel32.lib",
            "-Lshell32.lib",
        ]
        result = subprocess.run(command, cwd=REPO, capture_output=True,
                                text=True, timeout=300, env=environment)
        if result.returncode != 0:
            raise CheckError(
                "DMD link through coff-link failed\n"
                + result.stdout + result.stderr
            )
        if not exe.is_file():
            raise CheckError("DMD produced no executable")

        imports = read_imports(exe)
        forbidden = sorted(
            dll for dll in imports
            if dll.startswith(("msvcrt", "msvcr", "ucrt", "vcruntime",
                               "api-ms-win-crt"))
        )
        if forbidden:
            raise CheckError("CRT imports present: " + ", ".join(forbidden))

        run = subprocess.run([str(exe)], capture_output=True, text=True,
                             timeout=30)
        if run.returncode != 0:
            symbols = []
            if map_path.is_file():
                for line in map_path.read_text(encoding="utf-8").splitlines():
                    name, _, rva = line.rpartition(" 0x")
                    if not rva:
                        continue
                    try:
                        symbols.append((int(rva.split(" ")[0], 16), name))
                    except ValueError:
                        continue
                symbols.sort()
            located = []
            for line in run.stderr.splitlines():
                if (line.startswith("AuroraCRT: constructor ")
                        and "returned" not in line):
                    value = int(line.rsplit(" ", 1)[1], 16) - 0x140000000
                    best = None
                    for rva, name in symbols:
                        if rva <= value:
                            best = (rva, name)
                        else:
                            break
                    if best:
                        located.append(f"{best[1]} +0x{value - best[0]:X}")
            raise CheckError(
                f"linked executable exited {run.returncode}\n"
                + run.stdout + run.stderr
                + ("constructors: " + ", ".join(located) if located else "")
            )
    except CheckError as error:
        print(f"LINKCMD64 verification failed: {error}", file=sys.stderr)
        return 1

    print("LINKCMD64 verification passed")
    print("  DMD invoked coff-link instead of lld-link")
    print("  imports:", ", ".join(sorted(imports)))
    print("  executable exit=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
