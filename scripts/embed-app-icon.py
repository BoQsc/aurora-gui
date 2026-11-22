#!/usr/bin/env python3
"""Embed an application icon into a linked EXE.

Discovers `<app>/assets/<name>.ico`, `<app>/<name>.ico`, or `icon.ico`, falling
back to the Aurora host icon. Runs the existing tested `patch-pe-icon.py`
resource builder, then verifies Windows can extract at least one icon.

Usage: embed-app-icon.py <exe> <app-dir> <app-name>
"""
from __future__ import annotations

import ctypes
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PATCHER = REPO / "scripts" / "patch-pe-icon.py"
FALLBACK = REPO / "aurora" / "aurora-host" / "assets" / "aurora-host.ico"


def find_icon(app_dir: Path, name: str) -> Path | None:
    candidates = [
        app_dir / "assets" / f"{name}.ico",
        app_dir / f"{name}.ico",
        app_dir / "assets" / "icon.ico",
        app_dir / "icon.ico",
        FALLBACK,
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def icon_count(executable: Path) -> int:
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    shell32.ExtractIconExW.argtypes = [
        ctypes.c_wchar_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_uint,
    ]
    shell32.ExtractIconExW.restype = ctypes.c_uint
    return shell32.ExtractIconExW(str(executable), -1, None, None, 0)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    executable = Path(sys.argv[1])
    app_dir = Path(sys.argv[2])
    name = sys.argv[3]
    if not executable.is_file():
        print(f"embed-app-icon: no executable: {executable}", file=sys.stderr)
        return 1
    icon = find_icon(app_dir, name)
    if icon is None:
        print(f"embed-app-icon: no icon found for {name}", file=sys.stderr)
        return 1
    patched = subprocess.run(
        [sys.executable, "-B", str(PATCHER), str(icon), str(executable)],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if patched.returncode != 0:
        print(patched.stdout + patched.stderr, file=sys.stderr)
        return patched.returncode
    count = icon_count(executable)
    if count == 0:
        print(f"embed-app-icon: Windows cannot extract an icon from {executable}",
              file=sys.stderr)
        return 1
    print(f"icon: {icon.name} -> {executable.name} ({count} images)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
