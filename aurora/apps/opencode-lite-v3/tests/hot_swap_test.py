#!/usr/bin/env python3
"""Prove a stable headless shell can replace app-module processes."""
from __future__ import annotations

import subprocess
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
SHELL = APP / "build" / "aurora-opencode-lite-v3-shell.exe"
MODULE_V1 = APP / "build" / "v3-module-v1.exe"
MODULE_V2 = APP / "build" / "v3-module-v2.exe"
CREATE_NO_WINDOW = 0x08000000


def read_until(process, needle: str) -> list[str]:
    lines = []
    while True:
        line = process.stdout.readline()
        if not line:
            raise RuntimeError(
                f"shell exited before {needle!r}: {lines}")
        line = line.rstrip()
        lines.append(line)
        if needle in line:
            return lines


def main() -> int:
    for path in (SHELL, MODULE_V1, MODULE_V2):
        if not path.is_file():
            raise RuntimeError(f"missing M1 artifact: {path}")
    shell = subprocess.Popen(
        [str(SHELL)], cwd=str(APP), stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        bufsize=1, creationflags=CREATE_NO_WINDOW)
    try:
        ready = read_until(shell, "READY pid=")[0]
        shell_pid = ready.split("pid=", 1)[1]
        shell.stdin.write(f"load {MODULE_V1}\n")
        shell.stdin.flush()
        v1 = read_until(shell, "LOADED ")
        if not any("MODULE 1 v1 ABI 1" in line for line in v1):
            raise RuntimeError(f"v1 module output missing: {v1}")
        if shell.poll() is not None:
            raise RuntimeError("shell exited during v1 module run")
        shell.stdin.write(f"load {MODULE_V2}\n")
        shell.stdin.flush()
        v2 = read_until(shell, "LOADED ")
        if not any("MODULE 2 v2 ABI 1" in line for line in v2):
            raise RuntimeError(f"v2 module output missing: {v2}")
        shell.stdin.write("pid\n")
        shell.stdin.flush()
        pid_line = read_until(shell, "PID ")[0]
        if pid_line != f"PID {shell_pid}":
            raise RuntimeError(
                f"shell PID changed: {shell_pid} -> {pid_line}")
        print(f"v3 hot-swap passed: shell pid {shell_pid} survived v1->v2")
        return 0
    finally:
        if shell.poll() is None:
            try:
                shell.stdin.write("quit\n")
                shell.stdin.flush()
            except Exception:
                pass
            try:
                shell.wait(timeout=5)
            except subprocess.TimeoutExpired:
                shell.kill()


if __name__ == "__main__":
    raise SystemExit(main())