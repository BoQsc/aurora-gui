#!/usr/bin/env python3
"""A bad live scene edit must not stop the host; restoring it must recover."""
from __future__ import annotations

import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time

APP = Path(__file__).resolve().parents[1]
HOST = APP / "build" / "aurora-opencode-lite-host.exe"
SCENE = APP / "assets" / "lite.scene.json"


def tree(stdin, lines: queue.Queue, request_id: int) -> dict:
    stdin.write(json.dumps({"id": request_id, "command": "tree"}) + "\n")
    stdin.flush()
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            line = lines.get(timeout=0.2)
        except queue.Empty:
            continue
        if line.startswith("RESPONSE "):
            response = json.loads(line[9:])
            if response.get("id") == request_id and "nodes" in response:
                return response
    raise RuntimeError("host did not answer tree request")


def nodes(response: dict) -> dict[str, str]:
    return {node["id"]: node.get("text", "")
            for node in response.get("nodes", [])}


def main() -> int:
    if not HOST.is_file():
        raise RuntimeError(f"missing host executable: {HOST}")
    with tempfile.TemporaryDirectory(prefix="aurora-scene-recovery-") as name:
        temp = Path(name)
        scene = temp / "lite.scene.json"
        shutil.copyfile(SCENE, scene)
        environment = os.environ.copy()
        environment["LOCALAPPDATA"] = str(temp)
        environment["APPDATA"] = str(temp)
        host = subprocess.Popen(
            [str(HOST), "--external-controller", "--no-activate",
             "--instance-group", "scene-recovery",
             "--scene", str(scene)],
            cwd=str(APP), env=environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        lines: queue.Queue[str] = queue.Queue()
        errors: queue.Queue[str] = queue.Queue()
        threading.Thread(
            target=lambda: [lines.put(line.rstrip()) for line in host.stdout],
            daemon=True).start()
        threading.Thread(
            target=lambda: [errors.put(line.rstrip()) for line in host.stderr],
            daemon=True).start()
        try:
            time.sleep(1.2)
            before = nodes(tree(host.stdin, lines, 9001))
            if before.get("root.0") != "Aurora OpenCode Lite":
                raise RuntimeError("initial scene did not load")

            original_stat = scene.stat()
            original_atime = original_stat.st_atime_ns
            original_mtime = original_stat.st_mtime_ns
            scene.write_text("{ broken json", encoding="utf-8")
            time.sleep(1.0)
            if host.poll() is not None:
                raise RuntimeError("host exited on a bad scene edit")
            still = nodes(tree(host.stdin, lines, 9002))
            if still.get("root.0") != "Aurora OpenCode Lite":
                raise RuntimeError("bad scene replaced the running scene")

            text = SCENE.read_text(encoding="utf-8").replace(
                '"text": "Aurora OpenCode Lite"',
                '"text": "Aurora OpenCode Lite Recovered"', 1)
            scene.write_text(text, encoding="utf-8")
            os.utime(scene, ns=(original_atime, original_mtime))
            time.sleep(1.2)
            if host.poll() is not None:
                raise RuntimeError("host exited while recovering scene")
            recovered = nodes(tree(host.stdin, lines, 9003))
            if recovered.get("root.0") != "Aurora OpenCode Lite Recovered":
                print("host stderr:", list(errors.queue), file=sys.stderr)
                print("recovered nodes:", recovered, file=sys.stderr)
                raise RuntimeError("valid replacement scene did not apply")
            print("scene recovery passed: invalid kept live, valid restored")
            return 0
        finally:
            if host.poll() is None:
                host.terminate()
                try:
                    host.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    host.kill()


if __name__ == "__main__":
    raise SystemExit(main())
