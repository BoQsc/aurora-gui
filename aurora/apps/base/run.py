#!/usr/bin/env python3
"""Launch Aurora Base through the standard live host workflow."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parent
ROOT = PROJECT.parents[1]
HOST = ROOT / "aurora-host"
HOST_EXE = HOST / "aurora-host.exe"
HOTSWAP = HOST / "aurora-hotswap.exe"
OUT = PROJECT / "build" / "base"
TITLE = "Aurora Base"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--watch", type=int, default=3600,
                        help="seconds before hotswap stops watching")
    parser.add_argument("--hold", type=int, default=0,
                        help="extra seconds to keep the host open after watch")
    args = parser.parse_args()

    if not HOST_EXE.is_file():
        raise SystemExit(f"missing host: {HOST_EXE}")
    if not HOTSWAP.is_file():
        raise SystemExit(f"missing hotswap: {HOTSWAP}")

    OUT.mkdir(parents=True, exist_ok=True)
    log_path = OUT / "hotswap.log"
    log = open(log_path, "wb")
    print(f"Starting {TITLE}...", flush=True)
    print(f"workspace {OUT}", flush=True)
    command = [
        str(HOTSWAP), "dev",
        "--source", str(PROJECT / "module.d"),
        "--host", str(HOST_EXE),
        "--out", str(OUT),
        "--watch", str(args.watch),
        "--events", "pointer,key",
        "--title", TITLE,
        "--width", "1180",
        "--height", "760",
    ]
    if args.hold > 0:
        command.extend(["--hold", str(args.hold)])
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
    log.close()

    deadline = time.monotonic() + 30
    started = time.monotonic()
    offset = 0
    while time.monotonic() < deadline:
        text = log_path.read_text(encoding="utf-8", errors="replace")
        if len(text) > offset:
            chunk = text[offset:]
            offset = len(text)
            for line in chunk.splitlines():
                if line.startswith(("[trace]", "READY", "LISTEN",
                                    "aurora-host:", "[1]")):
                    print(line, flush=True)
                if "[1]" in line:
                    elapsed = (time.monotonic() - started) * 1000
                    print(f"RUNNING {TITLE} hotswapPid={process.pid}",
                          flush=True)
                    print(f"READY in {elapsed:.0f} ms", flush=True)
                    print(f"log={log_path}", flush=True)
                    return 0
        if process.poll() is not None:
            print(text, file=sys.stderr)
            return 1
        time.sleep(0.05)
    print(f"STARTED hotswapPid={process.pid} log={log_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
