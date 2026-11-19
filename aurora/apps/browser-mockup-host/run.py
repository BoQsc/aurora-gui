#!/usr/bin/env python3
"""Launch the reflowing host-scene browser mockup detached."""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parent
OUT = PROJECT / "build"
LOG = OUT / "controller.log"


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    log = open(LOG, "wb")
    command = [sys.executable, "-B", str(PROJECT / "controller.py")]
    flags = (subprocess.CREATE_NEW_PROCESS_GROUP |
             subprocess.DETACHED_PROCESS |
             subprocess.CREATE_BREAKAWAY_FROM_JOB)
    try:
        process = subprocess.Popen(
            command, cwd=str(PROJECT), stdin=subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT, close_fds=True,
            creationflags=flags,
        )
    except OSError:
        flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.DETACHED_PROCESS
        process = subprocess.Popen(
            command, cwd=str(PROJECT), stdin=subprocess.DEVNULL,
            stdout=log, stderr=subprocess.STDOUT, close_fds=True,
            creationflags=flags,
        )
    time.sleep(0.8)
    if process.poll() is not None:
        print(LOG.read_text(encoding="utf-8", errors="replace"),
              file=sys.stderr)
        return 1
    print(f"RUNNING host-scene browser controllerPid={process.pid}")
    print(f"log={LOG}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
