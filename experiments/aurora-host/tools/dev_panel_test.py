#!/usr/bin/env python3
"""End-to-end test for the native --dev scene source panel.

Launches one dev host on a copied scene, replaces the panel's source through
the control channel, clicks Reload, and verifies both the new scene and the
surviving panel.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time

from image_io import read_ppm, write_png

ROOT = Path(__file__).resolve().parents[1]

MINIMAL_SCENE = {
    "schemaVersion": 2,
    "window": {
        "title": "Dev Panel Test",
        "width": 760,
        "height": 520,
        "theme": "dark",
    },
    "root": {
        "id": "root",
        "type": "column",
        "spacing": 12,
        "padding": 24,
        "children": [
            {
                "id": "heading",
                "type": "label",
                "text": "Panel reload works",
                "scale": 3,
            },
            {
                "id": "status",
                "type": "label",
                "text": "Edited inside the host",
                "scale": 1,
            },
        ],
    },
}


def request(port: int, payload: dict, timeout: float = 20.0) -> dict:
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as conn:
        conn.sendall(
            (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        )
        for line in conn.makefile("rb"):
            text = line.decode("utf-8").rstrip("\r\n")
            if text.startswith("EVENT "):
                continue
            if text.startswith("RESPONSE "):
                return json.loads(text[9:])
            if text:
                return json.loads(text)
    raise RuntimeError("host closed the connection")


def wait_ready(port: int, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if request(port, {"command": "ping"}, timeout=2.0).get("ok"):
                return
        except OSError:
            pass
        time.sleep(0.25)
    raise RuntimeError(f"dev bridge on port {port} did not become ready")


def capture(port: int, path: Path) -> dict:
    path.parent.mkdir(parents=True, exist_ok=True)
    ppm = path.with_suffix(".ppm")
    response = request(port, {"command": "screenshot", "path": str(ppm)})
    if not response.get("ok"):
        raise RuntimeError(f"screenshot failed: {response}")
    width, height, pixels = read_ppm(ppm)
    write_png(path, width, height, pixels)
    try:
        ppm.unlink()
    except OSError:
        pass
    return {"ok": True, "width": width, "height": height}


def tree_by_id(tree: dict) -> dict[str, dict]:
    return {node["id"]: node for node in tree.get("nodes", []) if "id" in node}


def find_node(node: dict, node_id: str) -> dict | None:
    if node.get("id") == node_id:
        return node
    for child in node.get("children", []):
        found = find_node(child, node_id)
        if found is not None:
            return found
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--exe",
        default="build/live-harness/host/aurora-host-experiment.exe",
    )
    parser.add_argument("--scene", default="samples/live-lab.scene.json")
    parser.add_argument("--port", type=int, default=8798)
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.is_absolute():
        exe = ROOT / exe
    source = Path(args.scene)
    if not source.is_absolute():
        source = ROOT / source
    if not exe.is_file():
        raise RuntimeError(f"host executable not found: {exe}")
    if not source.is_file():
        raise RuntimeError(f"scene not found: {source}")

    scene = ROOT / "build" / "live-harness" / "dev-test.scene.json"
    scene.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, scene)
    original_scene = json.loads(scene.read_text(encoding="utf-8"))

    host = subprocess.Popen(
        [str(exe), "--dev", str(scene), "--listen", str(args.port)],
        cwd=str(ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )

    try:
        wait_ready(args.port)

        status = request(args.port, {"command": "status"})
        if not status.get("ok") or status.get("nodes", 0) < 40:
            raise RuntimeError(f"unexpected dev status: {status}")

        before = tree_by_id(request(args.port, {"command": "tree"}))
        for node_id in (
            "aurora.dev.source",
            "aurora.dev.path",
            "aurora.dev.reload",
            "aurora.dev.save",
            "aurora.dev.live",
            "aurora.dev.new",
            "aurora.dev.open",
            "aurora.dev.saveas",
        ):
            if node_id not in before:
                raise RuntimeError(f"dev node missing: {node_id}")
        if before["aurora.dev.source"]["text"] != "<dev source>":
            raise RuntimeError("dev source is not quiet in the tree")

        shot_before = ROOT / "build" / "live-harness" / "shots" / "dev-before.png"
        first = capture(args.port, shot_before)
        if not first.get("ok") or not shot_before.is_file():
            raise RuntimeError(f"dev screenshot failed: {first}")

        selected = request(
            args.port,
            {"command": "setSelection", "node": "notes", "start": 10, "end": 20},
        )
        if not selected.get("ok"):
            raise RuntimeError(f"could not select scene editor text: {selected}")
        heading_node = find_node(original_scene["root"], "heading")
        if heading_node is None:
            raise RuntimeError("heading node missing from the source scene")
        heading_node["text"] = "State preserved"
        changed = request(
            args.port,
            {
                "command": "setText",
                "node": "aurora.dev.source",
                "text": json.dumps(original_scene, indent=2),
            },
        )
        if not changed.get("ok"):
            raise RuntimeError(f"state-preserving source set failed: {changed}")
        request(
            args.port,
            {"command": "setSelection", "node": "notes", "start": 10, "end": 20},
        )
        time.sleep(0.9)
        state = tree_by_id(request(args.port, {"command": "tree"}))
        if state.get("heading", {}).get("text") != "State preserved":
            raise RuntimeError(f"state-preserving live apply failed: {state}")
        editor_state = request(
            args.port, {"command": "getEditorState", "node": "notes"}
        )
        if (
            editor_state.get("cursor") != 20
            or editor_state.get("anchor") != 10
        ):
            raise RuntimeError(
                f"scene editor state was not preserved: {editor_state}"
            )

        toggled = request(args.port, {"command": "click", "node": "aurora.dev.live"})
        if not toggled.get("ok"):
            raise RuntimeError(f"could not turn Live off: {toggled}")

        changed = request(
            args.port,
            {
                "command": "setText",
                "node": "aurora.dev.source",
                "text": json.dumps(MINIMAL_SCENE, indent=2),
            },
        )
        if not changed.get("ok"):
            raise RuntimeError(f"dev source set failed: {changed}")

        reloaded = request(args.port, {"command": "click", "node": "aurora.dev.reload"})
        if not reloaded.get("ok"):
            raise RuntimeError(f"dev reload click failed: {reloaded}")

        after = tree_by_id(request(args.port, {"command": "tree"}))
        if after.get("heading", {}).get("text") != "Panel reload works":
            raise RuntimeError(f"scene did not reload: {after}")
        if "aurora.dev.source" not in after:
            raise RuntimeError("dev panel did not survive reload")
        source_text = request(
            args.port, {"command": "getText", "node": "aurora.dev.source"}
        )
        if "Panel reload works" not in source_text.get("text", ""):
            raise RuntimeError(f"dev editor lost its source: {source_text}")

        shot_after = ROOT / "build" / "live-harness" / "shots" / "dev-after.png"
        second = capture(args.port, shot_after)
        if not second.get("ok") or not shot_after.is_file():
            raise RuntimeError(f"post-reload screenshot failed: {second}")
        if hashlib.sha256(shot_before.read_bytes()).digest() == hashlib.sha256(
            shot_after.read_bytes()
        ).digest():
            raise RuntimeError("dev reload did not change the frame")

        second_scene = json.loads(json.dumps(MINIMAL_SCENE))
        second_scene["root"]["children"][0]["text"] = "Save and reload work"
        changed = request(
            args.port,
            {
                "command": "setText",
                "node": "aurora.dev.source",
                "text": json.dumps(second_scene, indent=2),
            },
        )
        if not changed.get("ok"):
            raise RuntimeError(f"second dev source set failed: {changed}")

        saved = request(args.port, {"command": "click", "node": "aurora.dev.save"})
        if not saved.get("ok"):
            raise RuntimeError(f"dev save click failed: {saved}")
        if "Save and reload work" not in scene.read_text(encoding="utf-8"):
            raise RuntimeError("Save did not write the editor source")
        still = tree_by_id(request(args.port, {"command": "tree"}))
        if still.get("heading", {}).get("text") != "Panel reload works":
            raise RuntimeError(f"Save unexpectedly reloaded the scene: {still}")

        reloaded = request(args.port, {"command": "click", "node": "aurora.dev.reload"})
        if not reloaded.get("ok"):
            raise RuntimeError(f"second dev reload click failed: {reloaded}")
        final = tree_by_id(request(args.port, {"command": "tree"}))
        if final.get("heading", {}).get("text") != "Save and reload work":
            raise RuntimeError(f"second scene did not reload: {final}")
        if "aurora.dev.source" not in final:
            raise RuntimeError("dev panel did not survive the second reload")
        final_source = request(
            args.port, {"command": "getText", "node": "aurora.dev.source"}
        )
        if "Save and reload work" not in final_source.get("text", ""):
            raise RuntimeError(
                f"dev editor lost the second source: {final_source}"
            )

        shot_final = ROOT / "build" / "live-harness" / "shots" / "dev-after2.png"
        third = capture(args.port, shot_final)
        if not third.get("ok") or not shot_final.is_file():
            raise RuntimeError(f"final dev screenshot failed: {third}")
        if hashlib.sha256(shot_after.read_bytes()).digest() == hashlib.sha256(
            shot_final.read_bytes()
        ).digest():
            raise RuntimeError("second dev reload did not change the frame")

        toggled = request(args.port, {"command": "click", "node": "aurora.dev.live"})
        if not toggled.get("ok"):
            raise RuntimeError(f"could not turn Live on: {toggled}")

        broken = request(
            args.port,
            {
                "command": "setText",
                "node": "aurora.dev.source",
                "text": "{ \"schemaVersion\": 2, ",
            },
        )
        if not broken.get("ok"):
            raise RuntimeError(f"invalid source set failed: {broken}")
        time.sleep(0.7)
        unchanged = tree_by_id(request(args.port, {"command": "tree"}))
        if unchanged.get("heading", {}).get("text") != "Save and reload work":
            raise RuntimeError(f"invalid live edit changed the scene: {unchanged}")
        if "Save and reload work" not in scene.read_text(encoding="utf-8"):
            raise RuntimeError("invalid live edit corrupted the scene file")

        live_scene = json.loads(json.dumps(MINIMAL_SCENE))
        live_scene["root"]["children"][0]["text"] = "Live typing works"
        changed = request(
            args.port,
            {
                "command": "setText",
                "node": "aurora.dev.source",
                "text": json.dumps(live_scene, indent=2),
            },
        )
        if not changed.get("ok"):
            raise RuntimeError(f"live source set failed: {changed}")
        time.sleep(0.9)
        live = tree_by_id(request(args.port, {"command": "tree"}))
        if live.get("heading", {}).get("text") != "Live typing works":
            raise RuntimeError(f"live edit did not apply: {live}")
        if "aurora.dev.source" not in live:
            raise RuntimeError("dev panel did not survive a live apply")
        if "Live typing works" not in scene.read_text(encoding="utf-8"):
            raise RuntimeError("live apply did not write the scene file")

        shot_live = ROOT / "build" / "live-harness" / "shots" / "dev-live.png"
        fourth = capture(args.port, shot_live)
        if not fourth.get("ok") or not shot_live.is_file():
            raise RuntimeError(f"live screenshot failed: {fourth}")

        hidden = request(args.port, {"command": "click", "node": "aurora.dev.hide"})
        if not hidden.get("ok"):
            raise RuntimeError(f"could not hide the dev panel: {hidden}")
        time.sleep(0.2)
        shot_collapsed = (
            ROOT / "build" / "live-harness" / "shots" / "dev-collapsed.png"
        )
        collapsed = capture(args.port, shot_collapsed)
        if not collapsed.get("ok") or not shot_collapsed.is_file():
            raise RuntimeError(f"collapsed screenshot failed: {collapsed}")
        expand_bounds = request(
            args.port, {"command": "getBounds", "node": "aurora.dev.expand"}
        )
        expand_rect = expand_bounds.get("rect", {})
        if (
            not expand_bounds.get("ok")
            or expand_rect.get("width", 0) <= 0
        ):
            raise RuntimeError(f"collapsed DEV tab is missing: {expand_bounds}")

        expanded = request(
            args.port, {"command": "click", "node": "aurora.dev.expand"}
        )
        if not expanded.get("ok"):
            raise RuntimeError(f"could not expand the dev panel: {expanded}")
        time.sleep(0.2)
        shot_expanded = (
            ROOT / "build" / "live-harness" / "shots" / "dev-expanded.png"
        )
        reopened = capture(args.port, shot_expanded)
        if not reopened.get("ok") or not shot_expanded.is_file():
            raise RuntimeError(f"expanded screenshot failed: {reopened}")

        project_dir = ROOT / "build" / "live-harness" / "projects"
        project_dir.mkdir(parents=True, exist_ok=True)
        new_path = project_dir / "new.scene.json"
        save_path = project_dir / "saved.scene.json"
        open_path = project_dir / "opened.scene.json"
        for path in (new_path, save_path, open_path):
            try:
                path.unlink()
            except FileNotFoundError:
                pass

        path_response = request(
            args.port,
            {"command": "setText", "node": "aurora.dev.path",
             "text": str(new_path)},
        )
        if not path_response.get("ok"):
            raise RuntimeError(f"project path set failed: {path_response}")
        created = request(args.port, {"command": "click", "node": "aurora.dev.new"})
        if not created.get("ok") or not new_path.is_file():
            raise RuntimeError(f"New project failed: {created}")
        time.sleep(0.2)
        new_tree = tree_by_id(request(args.port, {"command": "tree"}))
        if new_tree.get("heading", {}).get("text") != "New Aurora Scene":
            raise RuntimeError(f"New project did not apply: {new_tree}")

        request(args.port, {"command": "click", "node": "aurora.dev.live"})
        saved_scene = json.loads(json.dumps(MINIMAL_SCENE))
        saved_scene["root"]["children"][0]["text"] = "Project saved"
        request(
            args.port,
            {"command": "setText", "node": "aurora.dev.path",
             "text": str(save_path)},
        )
        request(
            args.port,
            {"command": "setText", "node": "aurora.dev.source",
             "text": json.dumps(saved_scene, indent=2)},
        )
        saved = request(args.port, {"command": "click", "node": "aurora.dev.saveas"})
        if not saved.get("ok") or "Project saved" not in save_path.read_text(
            encoding="utf-8"
        ):
            raise RuntimeError(f"Save As failed: {saved}")
        before_reload = tree_by_id(request(args.port, {"command": "tree"}))
        if before_reload.get("heading", {}).get("text") != "New Aurora Scene":
            raise RuntimeError(f"Save As unexpectedly applied: {before_reload}")
        request(args.port, {"command": "click", "node": "aurora.dev.reload"})
        reloaded_saved = tree_by_id(request(args.port, {"command": "tree"}))
        if reloaded_saved.get("heading", {}).get("text") != "Project saved":
            raise RuntimeError(f"Save As target did not reload: {reloaded_saved}")

        opened_scene = json.loads(json.dumps(MINIMAL_SCENE))
        opened_scene["root"]["children"][0]["text"] = "Project opened"
        open_path.write_text(
            json.dumps(opened_scene, indent=2), encoding="utf-8"
        )
        request(
            args.port,
            {"command": "setText", "node": "aurora.dev.path",
             "text": str(open_path)},
        )
        opened = request(args.port, {"command": "click", "node": "aurora.dev.open"})
        if not opened.get("ok"):
            raise RuntimeError(f"Open failed: {opened}")
        opened_tree = tree_by_id(request(args.port, {"command": "tree"}))
        if opened_tree.get("heading", {}).get("text") != "Project opened":
            raise RuntimeError(f"Open did not apply: {opened_tree}")
        path_text = request(
            args.port, {"command": "getText", "node": "aurora.dev.path"}
        )
        if str(open_path) not in path_text.get("text", ""):
            raise RuntimeError(f"Open did not update the project path: {path_text}")

        print("dev panel self-test passed")
        return 0
    finally:
        try:
            request(args.port, {"command": "close"}, timeout=5.0)
        except Exception:
            pass
        try:
            host.wait(timeout=5)
        except subprocess.TimeoutExpired:
            host.terminate()
            try:
                host.wait(timeout=5)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait(timeout=5)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"dev panel self-test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
