#!/usr/bin/env python3
"""Verify that a running host can rebuild its retained scene in place."""
from __future__ import annotations

import argparse
import json
import pathlib
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from host_session import Host, read_ppm  # noqa: E402


def node_text(tree: dict, node_id: str) -> str | None:
    for node in tree.get("nodes", []):
        if node.get("id") == node_id:
            return node.get("text")
    return None


def scene_node(node: dict, node_id: str) -> dict | None:
    if node.get("id") == node_id:
        return node
    for child in node.get("children", []):
        found = scene_node(child, node_id)
        if found is not None:
            return found
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, type=pathlib.Path)
    parser.add_argument("--scene", required=True, type=pathlib.Path)
    args = parser.parse_args()

    source = args.scene.resolve()
    host_path = args.host.resolve()
    if not source.is_file() or not host_path.is_file():
        print("reload test failed: missing scene or host", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="aurora-reload-") as temp_name:
        scene_path = pathlib.Path(temp_name) / "workspace.scene.json"
        document = json.loads(source.read_text(encoding="utf-8"))
        scene_path.write_text(
            json.dumps(document, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        host = Host(scene_path, host_path)
        try:
            tree = host.request("tree")
            if not node_text(tree, "heading"):
                raise RuntimeError("initial heading was not loaded")
            if node_text(tree, "new") != "New":
                raise RuntimeError("initial toolbar action was not loaded")
            before_shot = pathlib.Path(temp_name) / "before.ppm"
            host.request("screenshot", path=str(before_shot))

            toolbar_new = scene_node(document["root"], "new")
            if toolbar_new is None:
                raise RuntimeError("scene has no New toolbar node")
            toolbar_new["text"] = "New+"
            scene_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            time.sleep(0.05)

            response = host.request("reload")
            if "Aurora Workspace" not in response.get("scene", ""):
                raise RuntimeError("reload did not report the reparsed scene")
            tree = host.request("tree")
            if node_text(tree, "new") != "New+":
                raise RuntimeError("reload did not replace the retained tree")
            after_shot = pathlib.Path(temp_name) / "after.ppm"
            host.request("screenshot", path=str(after_shot))
            if read_ppm(before_shot)[2] == read_ppm(after_shot)[2]:
                raise RuntimeError("reloaded toolbar did not change visible pixels")
        finally:
            host.close()

        watched = Host(scene_path, host_path, watch=True)
        try:
            watched_tree = watched.request("tree")
            if node_text(watched_tree, "new") != "New+":
                raise RuntimeError("watch host did not load the current scene")
            toolbar_open = scene_node(document["root"], "open")
            if toolbar_open is None:
                raise RuntimeError("scene has no Open toolbar node")
            toolbar_open["text"] = "Open..."
            scene_path.write_text(
                json.dumps(document, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            time.sleep(0.3)
            watched_tree = watched.request("tree")
            if node_text(watched_tree, "open") != "Open...":
                raise RuntimeError("watch mode did not reload the changed scene")
        finally:
            watched.close()

    print("reload test passed: scene tree replaced in the running host")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"reload test failed: {error}", file=sys.stderr)
        raise SystemExit(1)