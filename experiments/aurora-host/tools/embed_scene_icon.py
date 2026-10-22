#!/usr/bin/env python3
"""Embed an ICO file in a scene as base64 `window.icon` data.

The host decodes the field at runtime, so the scene remains a single portable
file with no icon sidecar.
"""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scene", required=True, type=Path)
    parser.add_argument("--icon", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()

    scene = json.loads(args.scene.read_text(encoding="utf-8"))
    window = scene.get("window")
    if not isinstance(window, dict):
        raise SystemExit("scene has no window object")
    window["icon"] = base64.b64encode(args.icon.read_bytes()).decode("ascii")

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(scene, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {args.out} ({args.out.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())