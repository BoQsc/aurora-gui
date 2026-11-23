#!/usr/bin/env python3
"""Verify the headless v3 multi-session command surface."""
from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
SHELL = APP / "build" / "aurora-opencode-lite-v3-shell.exe"
CREATE_NO_WINDOW = 0x08000000


def run(shell, command: str) -> list[str]:
    shell.stdin.write(command + "\n")
    shell.stdin.flush()
    lines = []
    while True:
        line = shell.stdout.readline()
        if not line:
            raise RuntimeError(f"shell closed on {command}: {lines}")
        line = line.rstrip()
        lines.append(line)
        if line.startswith(("SESSIONS ", "ACTIVE ", "OK", "ERROR")):
            return lines


def list_sessions(shell) -> list[str]:
    shell.stdin.write("sessions list\n")
    shell.stdin.flush()
    header = shell.stdout.readline().rstrip()
    if not header.startswith("SESSIONS "):
        raise RuntimeError(f"bad session header: {header}")
    count = int(header.split(" ", 1)[1])
    rows = [header]
    for _ in range(count):
        rows.append(shell.stdout.readline().rstrip())
    return rows


def main() -> int:
    if not SHELL.is_file():
        raise RuntimeError(f"missing shell: {SHELL}")
    with tempfile.TemporaryDirectory(prefix="v3-sessions-") as temp:
        env = os.environ.copy()
        env["APPDATA"] = temp
        env["LOCALAPPDATA"] = temp
        shell = subprocess.Popen(
            [str(SHELL)], cwd=str(APP), stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            bufsize=1, env=env, creationflags=CREATE_NO_WINDOW)
        try:
            ready = shell.stdout.readline().rstrip()
            if not ready.startswith("READY pid="):
                raise RuntimeError(f"shell not ready: {ready}")
            if list_sessions(shell)[0] != "SESSIONS 0":
                raise RuntimeError("initial session list was not empty")
            if run(shell, "sessions new Alpha")[0] != "ACTIVE s1":
                raise RuntimeError("create Alpha failed")
            if run(shell, "sessions new Beta")[0] != "ACTIVE s2":
                raise RuntimeError("create Beta failed")
            listing = list_sessions(shell)
            if not any("SESSION s1 Alpha idle" in line for line in listing):
                raise RuntimeError(f"Alpha not listed: {listing}")
            if not any("SESSION s2 Beta active" in line for line in listing):
                raise RuntimeError(f"Beta not active: {listing}")
            if run(shell, "sessions use s1")[0] != "OK":
                raise RuntimeError("session use failed")
            if run(shell, "sessions rename s1 Alpha2")[0] != "OK":
                raise RuntimeError("session rename failed")
            if run(shell, "sessions delete s2")[0] != "OK":
                raise RuntimeError("session delete failed")
            final = list_sessions(shell)
            if not any("SESSION s1 Alpha2 active" in line for line in final):
                raise RuntimeError(f"final active session wrong: {final}")
            print("v3 session surface passed: create, list, use, rename, delete")
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
