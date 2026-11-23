#!/usr/bin/env python3
"""Verify v3 controller streaming, stop, and retry without windows."""
from __future__ import annotations

import subprocess
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
SHELL = APP / "build" / "aurora-opencode-lite-v3-shell.exe"
CREATE_NO_WINDOW = 0x08000000


def command(shell, text: str) -> list[str]:
    shell.stdin.write(text + "\n")
    shell.stdin.flush()
    lines = []
    while True:
        line = shell.stdout.readline()
        if not line:
            raise RuntimeError(f"shell closed during {text}: {lines}")
        line = line.rstrip()
        lines.append(line)
        if line.startswith(("STATUS ", "TRANSCRIPT ", "ERROR")):
            return lines


def main() -> int:
    shell = subprocess.Popen(
        [str(SHELL)], cwd=str(APP), stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        bufsize=1, creationflags=CREATE_NO_WINDOW)
    try:
        if not shell.stdout.readline().startswith("READY pid="):
            raise RuntimeError("shell not ready")
        if command(shell, "send hello")[0] != "STATUS Streaming":
            raise RuntimeError("send did not start streaming")
        for _ in range(3):
            command(shell, "tick")
        status = command(shell, "chat status")
        transcript = shell.stdout.readline().rstrip()
        status.append(transcript)
        if status[0] != "STATUS Complete":
            raise RuntimeError(f"stream did not complete: {status}")
        if "hello" not in "\n".join(status):
            raise RuntimeError(f"transcript missing prompt: {status}")
        command(shell, "send again")
        if command(shell, "stop")[0] != "STATUS Stopped":
            raise RuntimeError("stop failed")
        if command(shell, "retry")[0] != "STATUS Streaming":
            raise RuntimeError("retry failed")
        print("v3 controller passed: stream, complete, stop, retry")
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