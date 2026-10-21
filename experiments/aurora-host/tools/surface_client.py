"""Versioned shared-surface producer used by host conformance checks."""
from __future__ import annotations

import mmap
from pathlib import Path
import struct
import time

HEADER = 80
EVENT = 24
CAPACITY = 64
BUFFERS = 2
MAGIC = b"AURSFACE"
VERSION = 2


class SharedSurface:
    def __init__(
        self,
        path: Path,
        width: int,
        height: int,
        reuse_existing: bool = False,
    ) -> None:
        self.path = path
        self.width = width
        self.height = height
        self.frame_bytes = width * height * 4
        self.size = HEADER + CAPACITY * EVENT + BUFFERS * self.frame_bytes
        path.parent.mkdir(parents=True, exist_ok=True)
        if reuse_existing:
            if not path.is_file() or path.stat().st_size != self.size:
                raise RuntimeError(f"surface cannot be reused: {path}")
            self.file = path.open("r+b")
        else:
            with path.open("wb") as stream:
                stream.truncate(self.size)
            self.file = path.open("r+b")
        self.map = mmap.mmap(self.file.fileno(), self.size)
        struct.pack_into(
            "<8sIIIIII", self.map, 0, MAGIC, VERSION, HEADER, width, height, 0, CAPACITY
        )
        struct.pack_into("<Q", self.map, 32, 0)
        struct.pack_into("<Q", self.map, 40, 0)
        struct.pack_into("<IIIII", self.map, 48, 0, 0, EVENT, BUFFERS, self.frame_bytes)
        self.sequence = 0
        self.closed = False

    def frame_offset(self, index: int) -> int:
        return HEADER + CAPACITY * EVENT + index * self.frame_bytes

    def publish(self, pixels: bytes) -> int:
        if self.closed:
            raise RuntimeError("cannot publish through a closed surface")
        if len(pixels) != self.frame_bytes:
            raise ValueError(f"frame is {len(pixels)} bytes, expected {self.frame_bytes}")
        active = struct.unpack_from("<I", self.map, 24)[0]
        target = 1 - active
        offset = self.frame_offset(target)
        self.map[offset : offset + self.frame_bytes] = pixels
        struct.pack_into("<I", self.map, 24, target)
        self.sequence += 1
        struct.pack_into("<Q", self.map, 32, self.sequence)
        return self.sequence

    def host_read(self) -> int:
        return struct.unpack_from("<Q", self.map, 40)[0]

    def wait_for_host(self, sequence: int, timeout: float = 5.0) -> None:
        deadline = time.monotonic() + timeout
        while self.host_read() < sequence:
            if time.monotonic() >= deadline:
                raise TimeoutError(f"host did not read frame {sequence}: {self.host_read()}")
            time.sleep(0.005)

    def read_inputs(self) -> list[dict]:
        head = struct.unpack_from("<I", self.map, 48)[0]
        tail = struct.unpack_from("<I", self.map, 52)[0]
        events: list[dict] = []
        for index in range(head, tail):
            offset = HEADER + (index % CAPACITY) * EVENT
            kind, button, key, modifiers, x, y, wheel_x, wheel_y = struct.unpack_from(
                "<BBHIiiii", self.map, offset
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
        struct.pack_into("<I", self.map, 48, tail)
        return events

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.map.close()
        self.file.close()