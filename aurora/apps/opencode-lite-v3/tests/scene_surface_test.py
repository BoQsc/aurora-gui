#!/usr/bin/env python3
"""Validate the v3 visual multi-session scene definition."""
from __future__ import annotations

import json
from pathlib import Path

SCENE = Path(__file__).resolve().parents[1] / "assets" / "v3.scene.json"
REQUIRED = {
    "v3-version",
    "v3-session-list",
    "v3-session-active",
    "v3-session-new",
    "v3-session-title",
    "v3-status",
    "v3-transcript",
    "v3-input",
    "v3-send",
}


def main() -> int:
    scene = json.loads(SCENE.read_text(encoding="utf-8"))
    if scene.get("schemaVersion") != 3:
        raise RuntimeError("v3 scene must use schemaVersion 3")
    ids = set()

    def visit(node):
        if "id" in node:
            ids.add(node["id"])
        for child in node.get("children", []):
            visit(child)

    visit(scene["root"])
    missing = REQUIRED - ids
    if missing:
        raise RuntimeError(f"missing v3 visual nodes: {sorted(missing)}")
    if scene["window"]["title"] != "Aurora OpenCode Lite v3":
        raise RuntimeError("wrong v3 window title")
    print(f"v3 visual surface passed: {len(ids)} nodes, sessions + composer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
