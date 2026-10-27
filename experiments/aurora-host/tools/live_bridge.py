#!/usr/bin/env python3
"""Keep one visible aurora-host alive for live scene building.

The bridge owns the host's stdin/stdout control channel and exposes a
loopback JSON-lines socket, so the window survives between tool calls. It
also converts host screenshots to PNG and can return a tree with bounds.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
sys.path.insert(0, str(TOOLS))

from image_io import read_ppm, write_png  # noqa: E402


class LiveHost:
    def __init__(self, exe: Path, scene: Path, dev: bool = False) -> None:
        self.scene = scene
        arguments = [
            str(exe),
            "--dev" if dev else "--run",
            str(scene),
            "--control",
        ]
        if not dev:
            arguments.append("--watch")
        self.process = subprocess.Popen(
            arguments,
            cwd=str(ROOT),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self._condition = threading.Condition()
        self._responses: dict[int, dict] = {}
        self._events: list[dict] = []
        self._ready = threading.Event()
        self._closed = threading.Event()
        self._next_id = 0
        self._stderr: list[str] = []
        threading.Thread(
            target=self._read_stdout, name="host-stdout", daemon=True
        ).start()
        threading.Thread(
            target=self._read_stderr, name="host-stderr", daemon=True
        ).start()

    def _read_stdout(self) -> None:
        assert self.process.stdout is not None
        try:
            for raw in self.process.stdout:
                line = raw.rstrip("\r\n")
                if line == "READY":
                    self._ready.set()
                    continue
                if line.startswith("EVENT "):
                    try:
                        event = json.loads(line[6:])
                    except json.JSONDecodeError:
                        continue
                    with self._condition:
                        self._events.append(event)
                        self._condition.notify_all()
                    continue
                if line.startswith("RESPONSE "):
                    try:
                        response = json.loads(line[9:])
                    except json.JSONDecodeError:
                        continue
                    request_id = response.get("id")
                    with self._condition:
                        if isinstance(request_id, int):
                            self._responses[request_id] = response
                        self._condition.notify_all()
        finally:
            self._closed.set()
            with self._condition:
                self._condition.notify_all()

    def _read_stderr(self) -> None:
        assert self.process.stderr is not None
        for raw in self.process.stderr:
            line = raw.rstrip("\r\n")
            self._stderr.append(line)
            print(f"[host] {line}", flush=True)

    def wait_ready(self, timeout: float = 20.0) -> None:
        if not self._ready.wait(timeout):
            raise RuntimeError(
                f"host did not become ready; stderr={self._stderr[-20:]!r}"
            )

    def request(self, command: str, timeout: float = 20.0, **fields) -> dict:
        with self._condition:
            if self._closed.is_set():
                raise RuntimeError("host is closed")
            self._next_id += 1
            request_id = self._next_id
            payload = {"id": request_id, "command": command, **fields}
            assert self.process.stdin is not None
            self.process.stdin.write(
                json.dumps(payload, ensure_ascii=False) + "\n"
            )
            self.process.stdin.flush()
            deadline = time.monotonic() + timeout
            while request_id not in self._responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(
                        f"timeout waiting for {command}; "
                        f"stderr={self._stderr[-20:]!r}"
                    )
                if self._closed.is_set():
                    raise RuntimeError(
                        f"host closed during {command}; "
                        f"stderr={self._stderr[-20:]!r}"
                    )
                self._condition.wait(remaining)
            return self._responses.pop(request_id)

    def events(self, clear: bool = False) -> list[dict]:
        with self._condition:
            result = list(self._events)
            if clear:
                self._events.clear()
            return result

    def screenshot(self, path: Path) -> dict:
        path = path.resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        ppm = path.with_suffix(".ppm")
        response = self.request("screenshot", timeout=30.0, path=str(ppm))
        if not response.get("ok"):
            raise RuntimeError(response.get("error", "screenshot failed"))
        width, height, pixels = read_ppm(ppm)
        write_png(path, width, height, pixels)
        try:
            ppm.unlink()
        except OSError:
            pass
        return {
            "ok": True,
            "path": str(path),
            "width": width,
            "height": height,
        }

    def snapshot(self) -> dict:
        tree = self.request("tree")
        status = self.request("status")
        nodes = []
        for node in tree.get("nodes", []):
            node_id = node.get("id")
            if not node_id:
                continue
            item = dict(node)
            try:
                bounds = self.request("getBounds", node=node_id)
            except Exception:
                bounds = {}
            if bounds.get("ok"):
                item["rect"] = bounds.get("rect")
            nodes.append(item)
        return {"ok": True, "nodes": nodes, "status": status}

    def close(self) -> None:
        if self.process.poll() is not None:
            return
        try:
            self.request("close", timeout=5.0)
        except Exception:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


def send(stream, response: dict, request_id=None) -> None:
    if request_id is not None:
        response.setdefault("id", request_id)
    stream.write(
        (json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8")
    )
    stream.flush()


def handle_client(conn, host: LiveHost, shot_dir: Path, stop: threading.Event):
    request_id = None
    with conn:
        stream = conn.makefile("rwb")
        for raw in stream:
            line = raw.decode("utf-8").strip()
            if not line:
                continue
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ValueError("request must be a JSON object")
                command = request.pop("command", None)
                if not isinstance(command, str) or not command:
                    raise ValueError("command must be a non-empty string")
                request_id = request.pop("id", None)
                if command == "screenshot":
                    raw_path = request.pop("path", None)
                    path = (
                        Path(raw_path)
                        if raw_path
                        else shot_dir
                        / f"shot-{int(time.time() * 1000)}.png"
                    )
                    if not path.is_absolute():
                        path = ROOT / path
                    response = host.screenshot(path)
                elif command == "snapshot":
                    response = host.snapshot()
                elif command == "events":
                    response = {
                        "ok": True,
                        "events": host.events(clear=bool(request.pop("clear", False))),
                    }
                elif command == "reload":
                    response = host.request("reload", timeout=30.0)
                elif command == "shutdown":
                    response = {"ok": True}
                    send(stream, response, request_id)
                    host.close()
                    stop.set()
                    return
                else:
                    timeout = float(request.pop("timeout", 20.0))
                    response = host.request(command, timeout=timeout, **request)
                send(stream, response, request_id)
            except Exception as error:
                send(stream, {"ok": False, "error": str(error)}, request_id)


def serve(host: LiveHost, port: int, shot_dir: Path) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen(8)
    actual_port = server.getsockname()[1]
    stop = threading.Event()
    pid_path = ROOT / "build" / "live-harness" / "bridge.pid"
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    pid_path.write_text(
        json.dumps({"pid": os.getpid(), "port": actual_port}),
        encoding="utf-8",
    )
    print(
        f"BRIDGE port={actual_port} scene={host.scene} "
        f"host_pid={host.process.pid}",
        flush=True,
    )
    try:
        while not stop.is_set():
            try:
                conn, _ = server.accept()
            except OSError:
                break
            threading.Thread(
                target=handle_client,
                args=(conn, host, shot_dir, stop),
                daemon=True,
            ).start()
    finally:
        server.close()
        try:
            pid_path.unlink()
        except OSError:
            pass


def spawn_daemon(exe: Path, scene: Path, port: int, dev: bool = False) -> int:
    """Start the bridge in a detached process so it outlives this command."""
    stamp = time.strftime("%Y%m%d-%H%M%S")
    log_path = (
        ROOT
        / "build"
        / "live-harness"
        / f"bridge-{stamp}-{os.getpid()}.log"
    )
    log_path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        sys.executable,
        "-u",
        "-B",
        str(Path(__file__).resolve()),
        "--scene",
        str(scene),
        "--exe",
        str(exe),
        "--port",
        str(port),
    ]
    if dev:
        command.append("--dev")
    kwargs = {
        "cwd": str(ROOT),
        "stdin": subprocess.DEVNULL,
        "close_fds": True,
    }
    if sys.platform == "win32":
        # Detach from the console and from the tool's process group.
        kwargs["creationflags"] = 0x00000008 | 0x00000200
    else:
        kwargs["start_new_session"] = True
    with log_path.open("w", encoding="utf-8") as log:
        kwargs["stdout"] = log
        kwargs["stderr"] = subprocess.STDOUT
        process = subprocess.Popen(command, **kwargs)
    deadline = time.monotonic() + 20.0
    text = ""
    while time.monotonic() < deadline:
        text = log_path.read_text(encoding="utf-8", errors="replace")
        if "BRIDGE port=" in text or process.poll() is not None:
            break
        time.sleep(0.25)
    if "BRIDGE port=" not in text:
        raise RuntimeError(
            f"bridge daemon failed; log={log_path}\n{text[-2000:]}"
        )
    print(f"BRIDGE_DAEMON pid={process.pid} log={log_path}", flush=True)
    print(text.strip(), flush=True)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scene",
        default="samples/live-lab.scene.json",
        help="scene file to watch and reload",
    )
    parser.add_argument(
        "--exe",
        default="build/live-harness/host/aurora-host-experiment.exe",
        help="windowed host executable",
    )
    parser.add_argument("--port", type=int, default=8791)
    parser.add_argument(
        "--dev",
        action="store_true",
        help="open the native scene source panel",
    )
    parser.add_argument(
        "--daemon",
        action="store_true",
        help="start detached and return immediately",
    )
    args = parser.parse_args()

    exe = Path(args.exe)
    if not exe.is_absolute():
        exe = ROOT / exe
    scene = Path(args.scene)
    if not scene.is_absolute():
        scene = ROOT / scene
    exe = exe.resolve()
    scene = scene.resolve()
    if not exe.is_file():
        raise RuntimeError(f"host executable not found: {exe}")
    if not scene.is_file():
        raise RuntimeError(f"scene not found: {scene}")

    if args.daemon:
        return spawn_daemon(exe, scene, args.port, args.dev)

    stamp = time.strftime("%Y%m%d-%H%M%S")
    runtime_dir = ROOT / "build" / "live-harness" / "run" / stamp
    runtime_dir.mkdir(parents=True)
    runtime_exe = runtime_dir / exe.name
    shutil.copy2(exe, runtime_exe)

    shot_dir = ROOT / "build" / "live-harness" / "shots"
    shot_dir.mkdir(parents=True, exist_ok=True)

    host = LiveHost(runtime_exe, scene, args.dev)
    try:
        host.wait_ready()
        serve(host, args.port, shot_dir)
    except KeyboardInterrupt:
        pass
    finally:
        host.close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"live bridge failed: {error}", file=sys.stderr)
        raise SystemExit(1)
