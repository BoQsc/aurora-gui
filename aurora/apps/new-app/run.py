#!/usr/bin/env python3
"""Launch the New App live session detached from the current terminal/turn."""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOST_EXE = HOST / "aurora-host.exe"
HOTSWAP = HOST / "aurora-hotswap.exe"
OUT = PROJECT / "build" / "new-app"


def main() -> int:
    if not HOST_EXE.is_file():
        raise SystemExit(f"missing host: {HOST_EXE}")
    if not HOTSWAP.is_file():
        raise SystemExit(f"missing hotswap: {HOTSWAP}")
    OUT.mkdir(parents=True, exist_ok=True)
    log_path = OUT / "hotswap.log"
    log = open(log_path, "wb")
    command = [
        str(HOTSWAP), "dev",
        "--source", str(PROJECT / "module.d"),
        "--host", str(HOST_EXE),
        "--out", str(OUT),
        "--watch", "3600",
        "--events", "pointer",
        "--title", "New App",
    ]
    flags = (subprocess.CREATE_NEW_PROCESS_GROUP |
             subprocess.DETACHED_PROCESS |
             subprocess.CREATE_BREAKAWAY_FROM_JOB)
    try:
        process = subprocess.Popen(
            command, cwd=str(HOST), stdin=subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT, close_fds=True,
            creationflags=flags,
        )
    except OSError:
        flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
        process = subprocess.Popen(
            command, cwd=str(HOST), stdin=subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT, close_fds=True,
            creationflags=flags,
        )
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        text = log_path.read_text(encoding="utf-8", errors="replace")
        if "[1]" in text:
            print(f"RUNNING hotswapPid={process.pid} log={log_path}")
            return 0
        if process.poll() is not None:
            print(text, file=sys.stderr)
            return 1
        time.sleep(0.1)
    print(f"STARTED hotswapPid={process.pid} log={log_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
