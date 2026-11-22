#!/usr/bin/env python3
"""Run DUB with the Aurora linker as the default standalone linker.

Builds `coff-link`, sets `LINKCMD64`, and forwards all arguments to DUB in the
current package. After a successful build, embeds an app icon from
`assets/<target>.ico`, `<target>.ico`, or the Aurora host fallback. Use this
instead of `dub` for standalone (zero-CRT) builds:

    python scripts/dub-standalone.py build --compiler=dmd
"""
from __future__ import annotations

import os
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
COFF = REPO / "aurora" / "libraries" / "aurora-exp-coff"
LINKER = COFF / "coff-link.exe"
ICON_HELPER = REPO / "scripts" / "embed-app-icon.py"


def dub_path() -> str:
    found = shutil.which("dub")
    if found:
        return found
    fallback = Path(r"C:\D\dmd2\windows\bin64\dub.exe")
    if fallback.is_file():
        return str(fallback)
    raise SystemExit("dub was not found on PATH")


def main() -> int:
    built = subprocess.run(
        [dub_path(), "build", "--config=link", "--compiler=dmd"],
        cwd=COFF,
        capture_output=True,
        text=True,
    )
    if built.returncode != 0:
        print(built.stdout + built.stderr, file=sys.stderr)
        return built.returncode
    if not LINKER.is_file():
        print("coff-link was not produced", file=sys.stderr)
        return 1
    environment = os.environ.copy()
    environment["LINKCMD64"] = str(LINKER)
    result = subprocess.run([dub_path(), *sys.argv[1:]], env=environment)
    if result.returncode == 0:
        manifest = Path.cwd() / "dub.json"
        if manifest.is_file():
            try:
                data = json.loads(manifest.read_text(encoding="utf-8"))
                target = data.get("targetName") or data.get("name")
                if target:
                    candidates = list(Path.cwd().rglob(f"{target}.exe"))
                    if candidates:
                        executable = max(candidates,
                                         key=lambda path: path.stat().st_mtime)
                        icon = subprocess.run(
                            [sys.executable, "-B", str(ICON_HELPER),
                             str(executable), str(Path.cwd()), target],
                            capture_output=True, text=True, timeout=120,
                        )
                        if icon.returncode != 0:
                            print(icon.stdout + icon.stderr, file=sys.stderr)
            except (OSError, ValueError):
                pass
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
