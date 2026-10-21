"""Small reusable stdin/stdout client for aurora-host-experiment."""
from __future__ import annotations

import json
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
EXE = ROOT / "aurora-host-experiment.exe"


class Host:
    def __init__(self, scene: Path, exe: Path = EXE) -> None:
        self.exe = exe
        self.process = subprocess.Popen(
            [str(exe), "--run", str(scene), "--control"],
            cwd=str(ROOT),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.lines: queue.Queue[str] = queue.Queue()
        self.events: list[dict] = []
        self.errors: list[str] = []
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._read_err, daemon=True).start()

    def _read(self) -> None:
        assert self.process.stdout is not None
        for line in self.process.stdout:
            self.lines.put(line.rstrip("\n"))

    def _read_err(self) -> None:
        assert self.process.stderr is not None
        for line in self.process.stderr:
            self.errors.append(line.rstrip("\n"))

    def read(self, timeout: float = 5.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"host produced no protocol line; stderr={self.errors!r}")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError(
                    f"host produced no protocol line; stderr={self.errors!r}"
                ) from error
            if line == "READY":
                continue
            if line.startswith("EVENT "):
                self.events.append(json.loads(line[6:]))
                continue
            if line.startswith("RESPONSE "):
                return json.loads(line[9:])
            raise RuntimeError(f"unexpected host line: {line!r}")

    def request(self, command: str, **fields) -> dict:
        self.next_id += 1
        request_id = self.next_id
        payload = {"id": request_id, "command": command, **fields}
        assert self.process.stdin is not None
        self.process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        response = self.read()
        if response.get("id") != request_id:
            raise RuntimeError(f"response id mismatch: {response!r}")
        if not response.get("ok"):
            raise RuntimeError(f"{command} failed: {response.get('error')}")
        return response

    def wait_event(self, predicate, timeout: float = 5.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            for event in self.events:
                if predicate(event):
                    return event
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"event not observed; events={self.events!r}")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError(
                    f"event not observed; events={self.events!r}; stderr={self.errors!r}"
                ) from error
            if line.startswith("EVENT "):
                self.events.append(json.loads(line[6:]))
            elif line.startswith("RESPONSE "):
                raise RuntimeError(f"unexpected response while waiting: {line!r}")
            elif line != "READY":
                raise RuntimeError(f"unexpected host line: {line!r}")

    def pop_event(self, predicate, timeout: float = 5.0) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            for index, event in enumerate(self.events):
                if predicate(event):
                    return self.events.pop(index)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"event not observed; events={self.events!r}")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty as error:
                raise TimeoutError(
                    f"event not observed; events={self.events!r}; stderr={self.errors!r}"
                ) from error
            if line.startswith("EVENT "):
                self.events.append(json.loads(line[6:]))
            elif line.startswith("RESPONSE "):
                raise RuntimeError(f"unexpected response while waiting: {line!r}")
            elif line != "READY":
                raise RuntimeError(f"unexpected host line: {line!r}")

    def close(self) -> None:
        try:
            self.request("close")
        except Exception:
            pass
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


def read_ppm(path: Path) -> tuple[int, int, bytes]:
    data = path.read_bytes()
    header, pixels = data.split(b"\n255\n", 1)
    parts = header.split()
    width, height = int(parts[-2]), int(parts[-1])
    if len(pixels) != width * height * 3:
        raise RuntimeError(f"bad PPM payload: {len(pixels)} != {width * height * 3}")
    return width, height, pixels


def ppm_counts(path: Path, colors: set[tuple[int, int, int]]) -> dict[tuple[int, int, int], int]:
    _, _, pixels = read_ppm(path)
    counts = {color: 0 for color in colors}
    for index in range(0, len(pixels), 3):
        color = tuple(pixels[index : index + 3])
        if color in counts:
            counts[color] += 1
    return counts


def ppm_unique(path: Path) -> int:
    _, _, pixels = read_ppm(path)
    return len({pixels[index : index + 3] for index in range(0, len(pixels), 3)})


def screenshot_path(name: str) -> Path:
    return Path(tempfile.gettempdir()) / name
