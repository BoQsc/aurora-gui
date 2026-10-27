#!/usr/bin/env python3
"""End-to-end self-test for the live scene bridge.

Starts a detached bridge on a spare port, drives one text change, captures a
PNG, checks the preview layout, reloads the scene, clicks a button, verifies
the action event, and shuts the bridge down.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import socket
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def request(port: int, payload: dict, timeout: float = 20.0) -> dict:
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as conn:
        conn.sendall(
            (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        )
        line = conn.makefile("rb").readline()
    if not line:
        raise RuntimeError("bridge closed the connection")
    return json.loads(line)


def wait_ready(port: int, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            response = request(port, {"command": "ping"}, timeout=2.0)
            if response.get("ok"):
                return
        except OSError:
            pass
        time.sleep(0.25)
    raise RuntimeError(f"bridge on port {port} did not become ready")


def heading_text(tree: dict) -> str:
    for node in tree.get("nodes", []):
        if node.get("id") == "heading":
            return node.get("text", "")
    raise RuntimeError("heading node is missing")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--exe",
        default="build/live-harness/host/aurora-host-experiment.exe",
    )
    parser.add_argument("--scene", default="samples/live-lab.scene.json")
    parser.add_argument("--port", type=int, default=8799)
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.is_absolute():
        exe = ROOT / exe
    scene = Path(args.scene)
    if not scene.is_absolute():
        scene = ROOT / scene
    if not exe.is_file():
        raise RuntimeError(f"host executable not found: {exe}")
    if not scene.is_file():
        raise RuntimeError(f"scene not found: {scene}")

    launched = subprocess.run(
        [
            sys.executable,
            "-u",
            "-B",
            str(ROOT / "tools" / "live_bridge.py"),
            "--daemon",
            "--port",
            str(args.port),
            "--exe",
            str(exe),
            "--scene",
            str(scene),
        ],
        cwd=str(ROOT),
        capture_output=True,
        text=True,
        timeout=30,
    )
    if launched.returncode != 0:
        raise RuntimeError(
            "bridge launch failed:\n" + launched.stdout + launched.stderr
        )

    try:
        wait_ready(args.port)

        status = request(args.port, {"command": "status"})
        if not status.get("ok") or status.get("nodes", 0) < 1:
            raise RuntimeError(f"unexpected status: {status}")

        tree = request(args.port, {"command": "tree"})
        original = heading_text(tree)
        if not original:
            raise RuntimeError(f"unexpected scene heading: {original!r}")

        changed = request(
            args.port,
            {
                "command": "setText",
                "node": "heading",
                "text": "Live bridge self-test",
            },
        )
        if not changed.get("ok"):
            raise RuntimeError(f"setText failed: {changed}")
        tree = request(args.port, {"command": "tree"})
        if heading_text(tree) != "Live bridge self-test":
            raise RuntimeError("setText did not reach the live tree")

        shot = (
            ROOT
            / "build"
            / "live-harness"
            / "shots"
            / f"selftest-{args.port}.png"
        )
        captured = request(
            args.port, {"command": "screenshot", "path": str(shot)}
        )
        if not captured.get("ok") or not shot.is_file():
            raise RuntimeError(f"screenshot failed: {captured}")
        if not shot.read_bytes().startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("screenshot is not a PNG")

        snapshot = request(args.port, {"command": "snapshot"})
        window = status.get("window", {})
        for node in snapshot.get("nodes", []):
            rect = node.get("rect")
            if not rect:
                continue
            if (
                rect["x"] < 0
                or rect["y"] < 0
                or rect["x"] + rect["width"] > window.get("width", 0) + 1
                or rect["y"] + rect["height"] > window.get("height", 0) + 1
            ):
                raise RuntimeError(
                    f"node {node.get('id')} overflows the window: {rect}"
                )
        preview = next(
            (
                node
                for node in snapshot.get("nodes", [])
                if node.get("id") == "preview"
            ),
            None,
        )
        if preview is None or preview.get("rect", {}).get("height", 0) < 320:
            raise RuntimeError(f"preview layout regressed: {preview}")

        reloaded = request(args.port, {"command": "reload"})
        if not reloaded.get("ok"):
            raise RuntimeError(f"reload failed: {reloaded}")
        tree = request(args.port, {"command": "tree"})
        if heading_text(tree) != original:
            raise RuntimeError("reload did not restore the scene heading")

        request(args.port, {"command": "events", "clear": True})
        clicked = request(args.port, {"command": "click", "node": "pulse"})
        if not clicked.get("ok"):
            raise RuntimeError(f"click failed: {clicked}")
        events = request(args.port, {"command": "events"})
        if not any(
            event.get("action") == "demo.pulse"
            for event in events.get("events", [])
        ):
            raise RuntimeError(f"pulse action event missing: {events}")

        print("live bridge self-test passed")
        return 0
    finally:
        try:
            request(args.port, {"command": "shutdown"}, timeout=5.0)
        except Exception:
            pass


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"live bridge self-test failed: {error}", file=sys.stderr)
        raise SystemExit(1)
