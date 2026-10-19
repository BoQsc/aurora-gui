#!/usr/bin/env python3
"""Drive the isolated Aurora host over its stdin/stdout control channel."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(os.environ.get("AURORA_HOST_EXE", str(ROOT / "aurora-host-experiment.exe")))


class LineReader(threading.Thread):
    def __init__(self, stream, name: str):
        super().__init__(daemon=True, name=name)
        self.stream = stream
        self.lines: queue.Queue[str | None] = queue.Queue()

    def run(self) -> None:
        try:
            for line in self.stream:
                self.lines.put(line.rstrip("\r\n"))
        finally:
            self.lines.put(None)

    def next_line(self, timeout: float = 15.0, label: str = "line") -> str:
        try:
            line = self.lines.get(timeout=timeout)
        except queue.Empty as error:
            raise RuntimeError(f"timed out waiting for {label}") from error
        if line is None:
            raise RuntimeError(f"host exited before {label}")
        return line


class HostSession:
    def __init__(self, scene: str):
        if not EXE.is_file():
            raise RuntimeError(f"build the host first: {EXE}")
        self.process = subprocess.Popen(
            [str(EXE), "--run", scene, "--control"],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.stdout = LineReader(self.process.stdout, "host-stdout")
        self.stderr = LineReader(self.process.stderr, "host-stderr")
        self.stdout.start()
        self.stderr.start()
        self.next_id = 0
        self.events: list[dict] = []

    def wait_ready(self) -> None:
        while True:
            line = self.stdout.next_line(label="READY")
            if line == "READY":
                return
            print(f"host: {line}")

    def send(self, command: str, **fields) -> dict:
        self.next_id += 1
        request_id = self.next_id
        payload = {"id": request_id, "command": command}
        payload.update(fields)
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.stdout.next_line(label=f"response to {command}")
            if line.startswith("EVENT "):
                event = json.loads(line[len("EVENT "):])
                self.events.append(event)
                print(f"event: {json.dumps(event, sort_keys=True)}")
                continue
            if not line.startswith("RESPONSE "):
                print(f"host: {line}")
                continue
            response = json.loads(line[len("RESPONSE "):])
            if response.get("id") != request_id:
                print(f"unexpected response: {json.dumps(response, sort_keys=True)}")
                continue
            return response

    def close(self) -> int:
        if self.process.poll() is None:
            try:
                self.send("close")
            except Exception:
                pass
        try:
            return self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return self.process.wait(timeout=5)


def print_response(label: str, response: dict) -> None:
    print(f"{label}: {json.dumps(response, sort_keys=True)}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scene", default="samples/hello.scene.json")
    parser.add_argument("--out", default="build/control-shot.ppm")
    parser.add_argument("--png", default="build/control-shot.png")
    args = parser.parse_args()

    session = HostSession(args.scene)
    try:
        session.wait_ready()
        print_response("ping", session.send("ping"))
        print_response("status", session.send("status"))
        print_response("tree", session.send("tree"))
        print_response(
            "setText",
            session.send("setText", node="status", text="Set by client"),
        )
        tree = session.send("tree")
        print_response("tree-after-setText", tree)
        status = next(
            (node for node in tree.get("nodes", []) if node.get("id") == "status"),
            None,
        )
        if not status or status.get("text") != "Set by client":
            raise RuntimeError("setText did not update the status label")

        print_response("click", session.send("click", node="hello"))
        if not any(
            event.get("event") == "activated" and event.get("node") == "hello"
            for event in session.events
        ):
            raise RuntimeError("activation event was not received")
        session.send("setText", node="status", text="Activated hello")
        tree = session.send("tree")
        print_response("tree-after-click", tree)
        status = next(
            (node for node in tree.get("nodes", []) if node.get("id") == "status"),
            None,
        )
        if not status or status.get("text") != "Activated hello":
            raise RuntimeError("status label did not update after click")
        print_response("screenshot", session.send("screenshot", path=args.out))
        unknown = session.send("bogus")
        print_response("unknown", unknown)
        if unknown.get("ok") is not False:
            raise RuntimeError("unknown command was not rejected")

    finally:
        exit_code = session.close()

    ppm = ROOT / args.out
    if not ppm.is_file():
        raise RuntimeError(f"screenshot was not written: {ppm}")
    try:
        from PIL import Image
    except ImportError:
        print("Pillow is unavailable; leaving the PPM screenshot")
    else:
        png = ROOT / args.png
        png.parent.mkdir(parents=True, exist_ok=True)
        Image.open(ppm).save(png)
        print(f"png: {png}")

    print(f"host exit: {exit_code}")
    if exit_code != 0:
        raise RuntimeError(f"host exited with {exit_code}")
    print("control demo passed")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"control demo failed: {error}", file=sys.stderr)
        raise SystemExit(1)
