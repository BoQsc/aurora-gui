#!/usr/bin/env python3
"""Exercise caption behavior on a scene-defined standard titleBar node."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from caption_behavior_test import exercise_caption, window_for_pid  # noqa: E402
from host_session import Host  # noqa: E402

SCENE = {
    "schemaVersion": 2,
    "window": {
        "title": "Standard Caption",
        "width": 900,
        "height": 620,
        "theme": "light",
        "decorated": False,
    },
    "root": {
        "id": "root",
        "type": "column",
        "spacing": 0,
        "padding": 0,
        "children": [
            {
                "id": "titlebar",
                "type": "titleBar",
                "text": "Standard Caption",
                "height": 40,
            },
            {
                "id": "body",
                "type": "label",
                "text": "Body",
                "flex": 1,
            },
        ],
    },
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=Path)
    args = parser.parse_args()

    handle = tempfile.NamedTemporaryFile(
        "w", suffix=".scene.json", delete=False, encoding="utf-8")
    try:
        json.dump(SCENE, handle)
        handle.close()
        scene = Path(handle.name)
        host = Host(scene, args.host)
        try:
            hwnd = window_for_pid(host.process.pid)
            exercise_caption(hwnd)
        finally:
            time.sleep(0.2)
            if host.errors:
                print("host stderr:", *host.errors, sep="\n", file=sys.stderr)
            host.close()
    finally:
        Path(handle.name).unlink(missing_ok=True)

    print("titlebar behavior test passed: scene titleBar maximizes, restores, "
          "and drag-restores")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"titlebar behavior test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
