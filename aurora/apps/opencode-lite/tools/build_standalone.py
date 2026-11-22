#!/usr/bin/env python3
"""Build the Lite app as a zero-CRT Windows executable.

This fixture uses only the Aurora tree: `aurora-d`, the Aurora CRT, and the
Aurora COFF linker. The icon is embedded from `assets/aurora-opencode-lite.ico`.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
AURORA = APP.parents[1]
REPO = APP.parents[2]
AURORA_D = AURORA / "aurora-d"
AURORA_STANDARD = AURORA / "aurora-standard"
HOST_CORE = AURORA / "aurora-host-core"
CRT = AURORA / "libraries" / "aurora-exp-win32-crt"
COFF = AURORA / "libraries" / "aurora-exp-coff"
LINKER = COFF / "coff-link.exe"
BUILD = APP / "build" / "standalone"
ICON = APP / "assets" / "aurora-opencode-lite.ico"
PATCHER = APP / "tools" / "patch_pe_icon.py"


def relative(path: Path) -> str:
    return Path(os.path.relpath(path, BUILD)).as_posix()


def main() -> int:
    running = subprocess.run(
        ["tasklist", "/FI",
         "IMAGENAME eq aurora-opencode-lite-standalone.exe",
         "/FO", "CSV", "/NH"],
        capture_output=True, timeout=30)
    if b"aurora-opencode-lite-standalone.exe" in running.stdout.lower():
        print(
            "standalone is running; refusing to rebuild it in place. "
            "Use `python verify.py --live` while the host is open, or close "
            "it at an explicit restart point.",
            file=sys.stderr)
        return 1

    BUILD.mkdir(parents=True, exist_ok=True)
    linker = subprocess.run(
        ["dub", "build", "--config=link", "--compiler=dmd"],
        cwd=COFF, capture_output=True, text=True, timeout=600)
    if linker.returncode != 0:
        print(linker.stdout + linker.stderr, file=sys.stderr)
        return linker.returncode

    manifest = {
        "name": "aurora-opencode-lite-standalone",
        "description": "Zero-CRT build of Aurora OpenCode Lite",
        "license": "0BSD",
        "targetType": "executable",
        "targetName": "aurora-opencode-lite",
        "targetPath": ".",
        "mainSourceFile": relative(APP / "source" / "hostlite.d"),
        "sourcePaths": [
            relative(APP / "source"),
            relative(HOST_CORE / "source"),
            relative(AURORA_D / "source"),
            relative(AURORA_STANDARD / "source"),
        ],
        "excludedSourceFiles": [
            relative(APP / "source" / "app.d"),
            relative(APP / "source" / "controller_main.d"),
            relative(APP / "source" / "plugin_main.d"),
            relative(APP / "source" / "plugin_entry.d"),
        ],
        "stringImportPaths": [
            relative(APP / "assets"),
            relative(HOST_CORE / "assets"),
        ],
        "libs-windows": [
            "user32", "gdi32", "shell32", "ole32", "winhttp", "ws2_32",
            "winmm", "avrt",
        ],
        "dflags-windows": ["-mscrtlib=msvcrt"],
        "lflags-windows": [
            "/NODEFAULTLIB:msvcrt",
            "/NODEFAULTLIB:libcmt",
            "/NODEFAULTLIB:oldnames",
            "/ENTRY:mainCRTStartup",
            "kernel32.lib",
            "/EXPORT:_tls_used",
            "/EXPORT:_tls_index",
            "/SUBSYSTEM:WINDOWS",
        ],
        "dependencies": {
            "aurora-exp-win32-crt": {"path": relative(CRT)},
        },
        "version": "0.1.0",
    }
    (BUILD / "dub.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    environment = os.environ.copy()
    environment["LINKCMD64"] = str(LINKER)
    result = subprocess.run(
        ["dub", "build", "--compiler=dmd", "--build=release"],
        cwd=BUILD, env=environment, capture_output=True, text=True,
        timeout=1800)
    if result.returncode != 0:
        print(result.stdout + result.stderr, file=sys.stderr)
        return result.returncode

    executable = BUILD / "aurora-opencode-lite.exe"
    if not executable.is_file():
        print(f"missing executable: {executable}", file=sys.stderr)
        return 1
    if not ICON.is_file() or not PATCHER.is_file():
        print("missing local icon asset or icon patcher", file=sys.stderr)
        return 1
    icon = subprocess.run(
        [sys.executable, "-B", str(PATCHER), str(ICON), str(executable)],
        capture_output=True, text=True, timeout=120)
    if icon.returncode != 0:
        print(icon.stdout + icon.stderr, file=sys.stderr)
        return icon.returncode
    print(icon.stdout, end="")
    final = APP / "build" / "aurora-opencode-lite-standalone.exe"
    shutil.copy2(executable, final)
    print(f"standalone: {final} ({final.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
