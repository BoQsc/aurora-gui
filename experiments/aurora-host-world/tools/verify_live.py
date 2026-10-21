"""Drive the demo through aurora-host and assert the live surface path.

Checks that the surface maps at 960x540, that an injected W press is consumed
from the input ring, and that host screenshots change while the player moves.
The script is self-contained so the demo package does not depend on host tools.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

EXPERIMENT = Path(__file__).resolve().parents[1]
EXPERIMENTS = EXPERIMENT.parent
CLIENT = EXPERIMENT / "aurora-host-world.exe"
HOST = EXPERIMENTS / "aurora-host" / "aurora-host-experiment.exe"
SCENE = EXPERIMENT / "world.scene.json"
WIDTH = 960
HEIGHT = 540
SURFACE = EXPERIMENT / "build" / "world.surface"
HEADER = 80
EVENT = 24


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    position = 0
    tokens: list[bytes] = []
    while len(tokens) < 4:
        while position < len(data) and data[position] in b" \t\r\n":
            position += 1
        if position < len(data) and data[position : position + 1] == b"#":
            while position < len(data) and data[position] not in b"\r\n":
                position += 1
            continue
        start = position
        while position < len(data) and data[position] not in b" \t\r\n":
            position += 1
        tokens.append(data[start:position])
    if tokens[0] != b"P6":
        raise AssertionError(f"{path}: expected a binary PPM, got {tokens[0]!r}")
    width, height = int(tokens[1]), int(tokens[2])
    if tokens[3] != b"255":
        raise AssertionError(f"{path}: unsupported max value {tokens[3]!r}")
    if position < len(data) and data[position] in b" \t\r\n":
        position += 1
    pixels = data[position:]
    expected = width * height * 3
    if len(pixels) != expected:
        raise AssertionError(f"{path}: {len(pixels)} pixel bytes, expected {expected}")
    return width, height, pixels


def differing(a: bytes, b: bytes) -> int:
    if len(a) != len(b):
        raise AssertionError("screenshots have different byte lengths")
    return sum(left != right for left, right in zip(a, b))


def read_events(start: int, end: int) -> list[dict]:
    with SURFACE.open("rb") as stream:
        header = stream.read(HEADER)
        capacity = int.from_bytes(header[28:32], "little")
        events: list[dict] = []
        for index in range(start, end):
            stream.seek(HEADER + (index % capacity) * EVENT)
            raw = stream.read(EVENT)
            if len(raw) != EVENT:
                raise AssertionError(f"short input event at index {index}")
            kind, button, key, modifiers, x, y, wheel_x, wheel_y = (
                int.from_bytes(raw[0:1], "little"),
                int.from_bytes(raw[1:2], "little"),
                int.from_bytes(raw[2:4], "little"),
                int.from_bytes(raw[4:8], "little"),
                int.from_bytes(raw[8:12], "little", signed=True),
                int.from_bytes(raw[12:16], "little", signed=True),
                int.from_bytes(raw[16:20], "little", signed=True),
                int.from_bytes(raw[20:24], "little", signed=True),
            )
            events.append(
                {
                    "kind": kind,
                    "button": button,
                    "key": key,
                    "modifiers": modifiers,
                    "x": x,
                    "y": y,
                    "wheelX": wheel_x,
                    "wheelY": wheel_y,
                }
            )
    return events


class Host:
    def __init__(self) -> None:
        self.process = subprocess.Popen(
            [str(HOST), "--run", str(SCENE), "--control"],
            cwd=str(EXPERIMENTS / "aurora-host"),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self.next_id = 100

    def line(self) -> str:
        assert self.process.stdout is not None
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("aurora-host exited unexpectedly")
        return line.strip()

    def wait_ready(self) -> None:
        for _ in range(200):
            if self.line() == "READY":
                return
        raise RuntimeError("aurora-host did not report READY")

    def request(self, command: dict) -> dict:
        if "id" not in command:
            command["id"] = self.next_id
            self.next_id += 1
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.line()
            if line.startswith("EVENT "):
                continue
            if line.startswith("RESPONSE "):
                line = line[len("RESPONSE ") :]
            try:
                response = json.loads(line)
            except json.JSONDecodeError:
                continue
            if response.get("id") == command["id"]:
                return response

    def surface(self) -> dict:
        return self.request({"command": "surface", "node": "world"})

    def screenshot(self, path: Path) -> None:
        response = self.request({"command": "screenshot", "path": str(path)})
        if not response.get("ok"):
            raise AssertionError(f"screenshot failed: {response}")

    def close(self) -> int:
        try:
            self.request({"command": "close"})
        except Exception:
            pass
        try:
            if self.process.stdin is not None:
                self.process.stdin.close()
        except Exception:
            pass
        try:
            return self.process.wait(timeout=10)
        finally:
            if self.process.poll() is None:
                self.process.terminate()
                self.process.wait(timeout=5)


def wait_head(host: Host, expected: int, timeout: float = 3.0) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        info = host.surface()
        if info.get("inputHead", 0) >= expected:
            return info
        time.sleep(0.05)
    raise AssertionError(
        f"input head did not reach {expected}: {host.surface()}"
    )


def main() -> int:
    for path in (CLIENT, HOST, SCENE):
        if not path.exists():
            raise SystemExit(f"missing required file: {path}")

    shots = Path(tempfile.mkdtemp(prefix="aurora-world-verify-"))
    before, during, after, look = (
        shots / f"{name}.ppm" for name in ("before", "during", "after", "look")
    )
    client = subprocess.Popen(
        [str(CLIENT), "--no-host", "--seconds", "8"],
        cwd=str(EXPERIMENT),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    host: Host | None = None
    try:
        time.sleep(0.8)
        host = Host()
        host.wait_ready()

        info = None
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline:
            info = host.surface()
            if info.get("mapped"):
                break
            time.sleep(0.05)
        assert info and info.get("mapped"), f"surface not mapped: {info}"
        assert (info["width"], info["height"]) == (WIDTH, HEIGHT), info
        if info["stale"] or info["frameAgeMs"] >= 500:
            raise AssertionError(f"mapped surface is not fresh: {info}")
        initial_tail = info["inputTail"]

        status = host.request({"command": "status"})
        assert status.get("ok"), status
        window = status["window"]
        if (
            window["framebufferWidth"] < window["width"]
            or window["framebufferHeight"] < window["height"]
            or window["displayScaleX"] < 1
            or window["displayScaleY"] < 1
        ):
            raise AssertionError(f"invalid display metrics: {status}")
        input_map = host.request({"command": "inputmap"})
        assert input_map.get("ok"), input_map
        if (
            input_map["keys"]["w"] != 48
            or input_map["modifiers"]["shift"] != 1
            or input_map["kinds"]["keyDown"] != 5
        ):
            raise AssertionError(f"input map is inconsistent: {input_map}")

        host.screenshot(before)
        down = host.request(
            {"command": "key", "node": "world", "kind": "down", "key": "w"}
        )
        assert down.get("ok"), down
        held = wait_head(host, 1)
        down_events = read_events(initial_tail, held["inputTail"])
        if not any(e["kind"] == 5 and e["key"] == 48 for e in down_events):
            raise AssertionError(f"W down missing from ring: {down_events}")
        time.sleep(1.0)
        host.screenshot(during)

        up = host.request(
            {"command": "key", "node": "world", "kind": "up", "key": "w"}
        )
        assert up.get("ok"), up
        released = wait_head(host, 2)
        time.sleep(0.4)
        host.screenshot(after)

        pointer_start = released["inputTail"]
        host.request(
            {"command": "pointer", "node": "world", "kind": "down", "x": 480, "y": 270, "button": "left"}
        )
        host.request(
            {"command": "pointer", "node": "world", "kind": "move", "x": 560, "y": 270, "button": "left"}
        )
        host.request(
            {"command": "pointer", "node": "world", "kind": "up", "x": 560, "y": 270, "button": "left"}
        )
        dragged = wait_head(host, 5)
        time.sleep(0.3)
        host.screenshot(look)

        assert released["inputHead"] >= 2, released
        all_events = read_events(initial_tail, released["inputTail"])
        if not any(e["kind"] == 6 and e["key"] == 48 for e in all_events):
            raise AssertionError(f"W up missing from ring: {all_events}")
        pointer_events = read_events(pointer_start, dragged["inputTail"])
        for kind, x, y in ((1, 480, 270), (2, 560, 270), (3, 560, 270)):
            if not any(
                e["kind"] == kind and e["x"] == x and e["y"] == y
                for e in pointer_events
            ):
                raise AssertionError(f"pointer drag missing {kind} at {x},{y}: {pointer_events}")

        width, height, first = read_ppm(before)
        width2, height2, second = read_ppm(during)
        width3, height3, third = read_ppm(after)
        width4, height4, fourth = read_ppm(look)
        assert (width, height) == (width2, height2) == (width3, height3) == (width4, height4)

        moved = differing(first, second)
        settled = differing(second, third)
        turned = differing(third, fourth)
        pixels = width * height
        if moved < pixels * 3 // 100:
            raise AssertionError(
                f"W press changed only {moved} of {pixels * 3} pixel bytes"
            )
        if settled < pixels // 100:
            raise AssertionError(
                f"post-release frame barely changed ({settled} bytes)"
            )
        if turned < pixels // 100:
            raise AssertionError(f"pointer drag barely changed the frame ({turned} bytes)")

        print(
            "live surface OK: "
            f"{width}x{height}, ring head/tail {released['inputHead']}/"
            f"{released['inputTail']}, "
            f"W down/up verified across {len(all_events)} events, "
            f"before/during diff {moved} bytes, "
            f"during/after diff {settled} bytes, "
            f"pointer drag diff {turned} bytes, shots {shots}"
        )
    finally:
        try:
            if host is not None:
                code = host.close()
                if code != 0:
                    raise AssertionError(f"aurora-host exited with {code}")
        finally:
            if client.poll() is None:
                try:
                    client.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    client.terminate()
                    client.wait(timeout=5)
                    raise AssertionError("client did not exit after --seconds 8")
            if client.returncode != 0:
                raise AssertionError(f"client exited with {client.returncode}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
