#!/usr/bin/env python3
"""Exercise the host's generic text-area, action, and screenshot controls."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from control_client import HostSession


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=str(ROOT / "build" / "editor.ppm"))
    args = parser.parse_args()

    session = HostSession("samples/editor.scene.json")
    try:
        session.wait_ready()
        initial = session.send("getText", node="editor")
        if initial.get("text") != "Initial editor text":
            raise RuntimeError(f"unexpected initial editor text: {initial}")

        session.send("setText", node="editor", text="Edited by host control")
        edited = session.send("getText", node="editor")
        if edited.get("text") != "Edited by host control":
            raise RuntimeError(f"setText/getText mismatch: {edited}")

        wrapped = session.send("setWordWrap", node="editor", wrap=True)
        if wrapped.get("wrap") is not True:
            raise RuntimeError(f"setWordWrap did not report true: {wrapped}")

        session.send("click", node="apply")
        if not any(
            event.get("event") == "action"
            and event.get("node") == "apply"
            and event.get("action") == "apply"
            for event in session.events
        ):
            raise RuntimeError("button action event was not received")

        session.send("screenshot", path=args.out)
    finally:
        code = session.close()

    if code != 0:
        raise RuntimeError(f"host exited with {code}")
    if not Path(args.out).is_file():
        raise RuntimeError(f"screenshot was not written: {args.out}")
    print("editor control passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"editor control failed: {error}", file=sys.stderr)
        raise SystemExit(1)
