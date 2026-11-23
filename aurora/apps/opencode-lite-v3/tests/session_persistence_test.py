#!/usr/bin/env python3
"""Verify v3 session persistence and v2 history import without windows."""
from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
SHELL = APP / "build" / "aurora-opencode-lite-v3-shell.exe"
CREATE_NO_WINDOW = 0x08000000


def start(env):
    p = subprocess.Popen(
        [str(SHELL)], cwd=str(APP), stdin=subprocess.PIPE,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        bufsize=1, env=env, creationflags=CREATE_NO_WINDOW)
    if not p.stdout.readline().startswith("READY pid="):
        raise RuntimeError("shell did not start")
    return p


def command(p, text):
    p.stdin.write(text + "\n")
    p.stdin.flush()
    lines = []
    while True:
        line = p.stdout.readline()
        if not line:
            raise RuntimeError(f"shell closed during {text}: {lines}")
        line = line.rstrip()
        lines.append(line)
        if line.startswith(("SESSIONS ", "ACTIVE ", "OK", "ERROR")):
            return lines


def list_sessions(p):
    p.stdin.write("sessions list\n")
    p.stdin.flush()
    header = p.stdout.readline().rstrip()
    count = int(header.split(" ", 1)[1])
    rows = [header]
    for _ in range(count):
        rows.append(p.stdout.readline().rstrip())
    return rows


def stop(p):
    if p.poll() is None:
        p.stdin.write("quit\n")
        p.stdin.flush()
        p.wait(timeout=5)


def scenario(root: Path):
    env = os.environ.copy()
    env["APPDATA"] = str(root)
    env["LOCALAPPDATA"] = str(root)
    p = start(env)
    try:
        command(p, "sessions new Alpha")
        command(p, "sessions new Beta")
        command(p, "sessions use s1")
        command(p, "sessions rename s1 Alpha2")
        command(p, "sessions delete s2")
    finally:
        stop(p)
    p = start(env)
    try:
        rows = list_sessions(p)
        if not any("SESSION s1 Alpha2 active" in row for row in rows):
            raise RuntimeError(f"persisted session wrong: {rows}")
        if any("s2" in row for row in rows):
            raise RuntimeError(f"deleted session returned: {rows}")
    finally:
        stop(p)


def migration(root: Path):
    legacy = root / "AuroraOpenCodeLiteV2"
    legacy.mkdir(parents=True)
    (legacy / "conversation.json").write_text(json.dumps({
        "transcript": "Imported transcript.\n",
        "messages": 1,
        "lastPrompt": "hello",
        "failed": False,
    }), encoding="utf-8")
    env = os.environ.copy()
    env["APPDATA"] = str(root)
    env["LOCALAPPDATA"] = str(root)
    p = start(env)
    try:
        rows = list_sessions(p)
        if not any("Imported_v2 active" in row for row in rows):
            raise RuntimeError(f"v2 migration missing: {rows}")
    finally:
        stop(p)


def main() -> int:
    if not SHELL.is_file():
        raise RuntimeError(f"missing shell: {SHELL}")
    with tempfile.TemporaryDirectory(prefix="v3-persist-") as tmp:
        scenario(Path(tmp) / "persist")
    with tempfile.TemporaryDirectory(prefix="v3-migrate-") as tmp:
        migration(Path(tmp))
    print("v3 persistence passed: restart restore, delete persistence, v2 import")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
