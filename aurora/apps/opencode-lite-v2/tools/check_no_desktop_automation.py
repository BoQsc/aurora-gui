#!/usr/bin/env python3
"""Fail if v2 tests/tools contain synthetic desktop-input automation."""
from __future__ import annotations

from pathlib import Path
import sys

APP = Path(__file__).resolve().parents[1]
FORBIDDEN = (
    "SendKeys",
    "mouse_event",
    "SetCursorPos",
    "keybd_event",
    "AttachThreadInput",
    "SetForegroundWindow",
    "ShowWindow",
)


def main() -> int:
    offenders = []
    for folder in (APP / "tests", APP / "tools"):
        if not folder.is_dir():
            continue
        for path in folder.rglob("*"):
            if not path.is_file() or path.suffix.lower() not in {".py", ".d"}:
                continue
            if path.resolve() == Path(__file__).resolve():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
            for token in FORBIDDEN:
                if token in text:
                    offenders.append(f"{path}: {token}")
    if offenders:
        print("synthetic desktop input is forbidden:", file=sys.stderr)
        print("\n".join(offenders), file=sys.stderr)
        return 1
    print("no synthetic desktop-input automation in v2 tests/tools")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
